import Foundation

/// 只读抽检：不调用可能转存网盘文件的 player 接口，不下载完整媒体。
struct MediaAvailabilityService {
    typealias SampleLoader = (URL) async throws -> (Data, HTTPURLResponse)
    static let maximumSampleBytes = 8 * 1024
    private let sample: SampleLoader

    init(sample: @escaping SampleLoader = Self.readSample) {
        self.sample = sample
    }

    func verify(info: VodInfo, requiresPlayerResolution: Bool) async throws -> ResourcePlaybackVerification {
        if requiresPlayerResolution {
            return .needsPlayback("目录有效，需要登录或播放器解析后确认")
        }
        var lastFailure: String?
        var needsPlayback: String?
        for flag in info.playFlags.prefix(3) {
            try Task.checkCancellation()
            guard let episode = info.playUrlMap[flag]?.first else { continue }
            guard let url = URL(string: episode.url), Self.canRead(url) else {
                needsPlayback = "该线路需要播放器解析"
                continue
            }
            do {
                switch try await inspect(url, depth: 0) {
                case .verified:
                    return .verified(flag: flag, episode: episode.name)
                case .needsPlayback(let reason): needsPlayback = reason
                case .failed(let reason): lastFailure = reason
                case .notChecked: break
                }
            } catch {
                try Task.checkCancellation()
                if let error = error as? URLError, error.code == .timedOut {
                    lastFailure = "连接超时，可重新检查"
                } else {
                    lastFailure = "暂时无法读取媒体，可重试或在播放器中确认"
                }
            }
        }
        if let needsPlayback { return .needsPlayback(needsPlayback) }
        return .failed(lastFailure ?? "没有可抽检的播放线路")
    }

    private func inspect(_ url: URL, depth: Int) async throws -> ResourcePlaybackVerification {
        guard depth <= 2, Self.canRead(url) else { return .needsPlayback("播放清单需要播放器进一步解析") }
        let (data, response) = try await sample(url)
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
            return try await inspect(target, depth: depth + 1)
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
            guard let episode = info.playUrlMap[flag]?.first, let url = URL(string: episode.url), canRead(url) else { return false }
            return ["m3u8", "mp4", "m4v", "mov", "mkv", "webm", "flv", "ts"].contains(url.pathExtension.lowercased())
        }
    }

    static func readSample(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        try await readSample(url, configuration: .ephemeral)
    }

    static func readSample(_ url: URL, configuration: URLSessionConfiguration) async throws -> (Data, HTTPURLResponse) {
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
            var request = URLRequest(url: url)
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
}

private final class MediaProbeRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private var count = 0

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        count += 1
        guard count <= 4, let url = request.url, MediaAvailabilityService.canRead(url),
              !(response.url?.scheme == "https" && url.scheme == "http") else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
