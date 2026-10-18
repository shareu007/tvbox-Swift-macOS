import Foundation

/// 抽检媒体的少量字节。普通 CatVod 可只读解析；网盘转存留给实际播放。
struct MediaAvailabilityService {
    typealias SampleLoader = (URL) async throws -> (Data, HTTPURLResponse)
    typealias RequestSampleLoader = (URLRequest) async throws -> (Data, HTTPURLResponse)
    typealias PlayerResolver = (String, String) async throws -> SpiderPlaybackResult
    static let maximumSampleBytes = 8 * 1024
    private let sample: RequestSampleLoader

    init() {
        sample = { try await Self.readSampleShared($0) }
    }

    init(sample: @escaping SampleLoader) {
        self.sample = { try await sample($0.url!) }
    }

    init(sampleRequest: @escaping RequestSampleLoader) {
        sample = sampleRequest
    }

    func verify(info: VodInfo, source: SourceBean, resolvePlayer: PlayerResolver) async throws -> ResourcePlaybackVerification {
        guard !source.isSearchOnly else { return .needsPlayback("网盘资源需要登录后播放确认") }
        return try await verifyRoutes(info: info) { flag, episode in
            if source.type == 3 && source.api.hasPrefix("/spider/") {
                if source.isCloudShareCatalog && !Self.isDirectMediaURL(episode.url) {
                    throw SpiderGatewayError.playbackVerificationRequired
                }
                let result = try await resolvePlayer(flag, episode.url)
                guard let url = URL(string: result.url), Self.canRead(url) else { return nil }
                var request = URLRequest(url: url)
                SourceSubtitleParser.safeHeaders(result.headers).forEach { request.setValue($1, forHTTPHeaderField: $0) }
                return request
            }
            guard let url = URL(string: episode.url), Self.canRead(url) else { return nil }
            return URLRequest(url: url)
        }
    }

    func verify(info: VodInfo, requiresPlayerResolution: Bool) async throws -> ResourcePlaybackVerification {
        if requiresPlayerResolution {
            return .needsPlayback("目录有效，需要登录或播放器解析后确认")
        }
        return try await verifyRoutes(info: info) { _, episode in
            guard let url = URL(string: episode.url), Self.canRead(url) else { return nil }
            return URLRequest(url: url)
        }
    }

    private func verifyRoutes(info: VodInfo, route: (String, VodInfo.Episode) async throws -> URLRequest?) async throws -> ResourcePlaybackVerification {
        var lastFailure: String?
        var needsPlayback: String?
        for flag in info.playFlags.prefix(3) {
            try Task.checkCancellation()
            guard let episode = info.playUrlMap[flag]?.first else { continue }
            do {
                guard let request = try await route(flag, episode) else {
                    needsPlayback = "该线路需要播放器进一步解析"
                    continue
                }
                switch try await inspect(request, depth: 0) {
                case .verified:
                    return .verified(flag: flag, episode: episode.name)
                case .needsPlayback(let reason): needsPlayback = reason
                case .failed(let reason): lastFailure = reason
                case .notChecked: break
                }
            } catch {
                try Task.checkCancellation()
                if let error = error as? SpiderGatewayError,
                   case .playbackVerificationRequired = error {
                    needsPlayback = "网盘资源需要登录后播放确认"
                } else if let error = error as? SpiderGatewayError, case .parseNotSupported = error {
                    needsPlayback = "该线路需要网页解析后播放确认"
                } else if let error = error as? URLError, error.code == .timedOut {
                    lastFailure = "连接超时，可重新检查"
                } else {
                    lastFailure = "暂时无法读取媒体，可重试或在播放器中确认"
                }
            }
        }
        if let needsPlayback { return .needsPlayback(needsPlayback) }
        return .failed(lastFailure ?? "没有可抽检的播放线路")
    }

    private func inspect(_ request: URLRequest, depth: Int) async throws -> ResourcePlaybackVerification {
        guard let url = request.url else { return .needsPlayback("媒体地址无效") }
        guard depth <= 2, Self.canRead(url) else { return .needsPlayback("播放清单需要播放器进一步解析") }
        let (data, response) = try await sample(request)
        try Task.checkCancellation()
        guard (200...299).contains(response.statusCode) else {
            switch response.statusCode {
            case 401, 403: return .needsPlayback("媒体访问需要授权或播放请求头")
            case 404, 410: return .failed("抽检的媒体地址不存在或已下线，可换线路或重试")
            default: return .failed("媒体服务暂时返回 HTTP \(response.statusCode)，可重试")
            }
        }
        guard !data.isEmpty else { return .failed("媒体地址返回空内容") }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#EXTM3U") {
            let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            // 不把可读取的加密清单视为已通过播放鉴权。
            if lines.contains(where: { $0.hasPrefix("#EXT-X-KEY:") && !$0.contains("METHOD=NONE") }) {
                return .needsPlayback("加密媒体需要播放器确认授权")
            }
            guard let reference = lines.first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
                  let target = URL(string: reference, relativeTo: response.url ?? url)?.absoluteURL else {
                return .needsPlayback("清单中暂未找到可抽检片段")
            }
            // 必须实际读取子清单/片段，单个可访问的 m3u8 不算可用。
            guard let next = Self.redirectRequest(URLRequest(url: target), from: response.url ?? url,
                                                 headers: Self.headers(request, scopedTo: response.url ?? url)) else {
                return .needsPlayback("播放清单需要播放器进一步解析")
            }
            return try await inspect(next, depth: depth + 1)
        }
        let lower = text.prefix(100).lowercased()
        if lower.hasPrefix("<!doctype html") || lower.hasPrefix("<html") || response.mimeType == "text/html" {
            return .failed("地址返回了网页，而不是媒体内容")
        }
        if Self.hasMediaSignature(data) { return .verified(flag: "", episode: "") }
        return .needsPlayback("媒体格式需在播放器中确认")
    }

    static func hasMediaSignature(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(maximumSampleBytes))
        guard bytes.count >= 32 else { return false }
        let box = String(decoding: bytes[4..<8], as: UTF8.self)
        if ["ftyp", "styp", "moof"].contains(box) { return true }
        if bytes.starts(with: [0x1a, 0x45, 0xdf, 0xa3]) { return true } // Matroska / WebM
        if bytes.starts(with: [0x46, 0x4c, 0x56]) { return true } // FLV
        return bytes.count > 376 && bytes[0] == 0x47 && bytes[188] == 0x47 && bytes[376] == 0x47
    }

    static func canRead(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil && url.user == nil && url.password == nil
    }

    static func hasDirectMediaRoute(_ info: VodInfo) -> Bool {
        info.playFlags.prefix(3).contains { flag in
            guard let episode = info.playUrlMap[flag]?.first else { return false }
            return isDirectMediaURL(episode.url)
        }
    }

    private static func isDirectMediaURL(_ value: String) -> Bool {
        guard let url = URL(string: value), canRead(url) else { return false }
        return ["m3u8", "mp4", "m4v", "mov", "mkv", "webm", "flv", "ts"].contains(url.pathExtension.lowercased())
    }

    private static func headers(_ request: URLRequest, scopedTo url: URL) -> [String: String] {
        guard let original = request.url, SourceSubtitleParser.sameOrigin(original, url) else { return [:] }
        return SourceSubtitleParser.safeHeaders(request.allHTTPHeaderFields)
    }

    static func redirectRequest(_ request: URLRequest, from previousURL: URL?, headers: [String: String]? = nil) -> URLRequest? {
        guard let target = request.url, let previousURL, canRead(target),
              !(previousURL.scheme?.lowercased() == "https" && target.scheme?.lowercased() == "http") else { return nil }
        // Foundation may merge an empty header dictionary into an existing
        // request. Build a clean GET request so removed credentials stay removed.
        var result = URLRequest(url: target, cachePolicy: request.cachePolicy, timeoutInterval: request.timeoutInterval)
        result.allHTTPHeaderFields = SourceSubtitleParser.sameOrigin(previousURL, target)
            ? SourceSubtitleParser.safeHeaders(headers ?? request.allHTTPHeaderFields ?? [:]) : [:]
        result.setValue("bytes=0-\(maximumSampleBytes - 1)", forHTTPHeaderField: "Range")
        return result
    }

    static func readSample(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        try await readSample(url, configuration: .ephemeral)
    }

    static func readSample(_ url: URL, configuration: URLSessionConfiguration) async throws -> (Data, HTTPURLResponse) {
        try await readSample(URLRequest(url: url), configuration: configuration)
    }

    static func readSample(_ originalRequest: URLRequest, configuration: URLSessionConfiguration) async throws -> (Data, HTTPURLResponse) {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 8
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            var request = originalRequest
            request.setValue("bytes=0-\(maximumSampleBytes - 1)", forHTTPHeaderField: "Range")
            let (bytes, response) = try await session.bytes(for: request, delegate: MediaProbeRedirectDelegate())
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            var data = Data()
            if (200...299).contains(response.statusCode) {
                for try await byte in bytes {
                    try Task.checkCancellation()
                    data.append(byte)
                    if data.count == maximumSampleBytes { break }
                }
            }
            return (data, response)
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    /// 共享抽检会话：跨请求复用，避免每次抽检都新建并销毁 ephemeral 会话（会话 churn）。
    /// 配置与 `readSample(_:configuration:)` 的逐项设置等价：无 cookie/凭证、短超时、忽略本地缓存。
    private static let probeSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 8
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// 使用共享会话抽检请求；取消时依赖结构化并发中断字节流，不销毁共享会话。
    static func readSampleShared(_ originalRequest: URLRequest, session: URLSession = probeSession) async throws -> (Data, HTTPURLResponse) {
        var request = originalRequest
        request.setValue("bytes=0-\(maximumSampleBytes - 1)", forHTTPHeaderField: "Range")
        let (bytes, response) = try await session.bytes(for: request, delegate: MediaProbeRedirectDelegate())
        // Reaching the sample limit does not finish a range-ignoring transfer.
        // Cancel only this task, leaving the shared connection pool usable.
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var data = Data()
        if (200...299).contains(response.statusCode) {
            for try await byte in bytes {
                try Task.checkCancellation()
                data.append(byte)
                if data.count == maximumSampleBytes { break }
            }
        }
        return (data, response)
    }
}

private final class MediaProbeRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private var count = 0

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        count += 1
        guard count <= 4 else {
            completionHandler(nil)
            return
        }
        completionHandler(MediaAvailabilityService.redirectRequest(request, from: response.url))
    }
}
