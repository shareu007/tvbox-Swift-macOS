import Foundation

/// 网络请求封装 - 对应 Android 版 OkGo
class NetworkManager {
    /// 全局共享实例。
    static let shared = NetworkManager()
    
    /// 默认最大重试次数（不含首次请求）。
    static let defaultMaxRetries = 2
    /// 配置、接口和播放清单响应的最大体积，避免异常源耗尽进程内存。
    static let maximumResponseBytes = 16 * 1024 * 1024
    /// 重试基础延迟（秒），实际延迟 = base * 2^attempt + jitter。
    private static let retryBaseDelay: TimeInterval = 0.5
    /// 重试最大延迟上限（秒）。
    private static let retryMaxDelay: TimeInterval = 8.0
    
    /// 兜底字符集名称列表（按常见中文资源站编码优先级排序）。
    private static let fallbackCharsetNames: [String] = [
        "utf-8",
        "gb18030",
        "gbk",
        "gb2312",
        "utf-16",
        "utf-16le",
        "utf-16be",
        "utf-32",
        "windows-1252",
        "iso-8859-1"
    ]
    
    /// 兜底字符串编码列表（与字符集列表互补）。
    private static let fallbackStringEncodings: [String.Encoding] = [
        .utf8,
        .utf16,
        .utf16LittleEndian,
        .utf16BigEndian,
        .utf32,
        .utf32LittleEndian,
        .utf32BigEndian,
        .windowsCP1252,
        .isoLatin1
    ]
    
    /// 内部会话对象，统一超时与连接上限配置。
    private let session: URLSession
    
    /// 默认使用共享会话；测试可以注入隔离配置验证完整请求链路。
    init(configuration: URLSessionConfiguration = .default) {
        let config = configuration.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 5
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }
    
    /// GET 请求获取字符串，支持自动重试。
    func getString(
        from urlString: String,
        headers: [String: String]? = nil,
        maxRetries: Int = NetworkManager.defaultMaxRetries
    ) async throws -> String {
        let prepared = try Self.prepareURL(from: urlString)
        var request = URLRequest(url: prepared.url)
        request.httpMethod = "GET"
        if let authorization = prepared.authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        headers?.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        
        let (data, httpResponse) = try await performRequest(request, maxRetries: maxRetries)
        
        guard let str = Self.decodeString(data: data, response: httpResponse) else {
            throw NetworkError.decodingError("文本解码失败")
        }
        
        return str
    }
    
    /// GET 请求解码 JSON，支持自动重试。
    func getJSON<T: Decodable>(
        from urlString: String,
        type: T.Type,
        headers: [String: String]? = nil,
        maxRetries: Int = NetworkManager.defaultMaxRetries
    ) async throws -> T {
        let str = try await getString(from: urlString, headers: headers, maxRetries: maxRetries)
        guard let data = str.data(using: .utf8) else {
            throw NetworkError.decodingError("字符串转 Data 失败")
        }
        // JSONDecoder is mutable and is not documented as safe for concurrent use.
        // A request-local decoder avoids races when several sources load in parallel.
        return try JSONDecoder().decode(T.self, from: data)
    }
    
    /// GET 请求获取原始 Data，支持自动重试和 HTTP 状态码校验。
    func getData(
        from urlString: String,
        maxRetries: Int = NetworkManager.defaultMaxRetries
    ) async throws -> Data {
        let prepared = try Self.prepareURL(from: urlString)
        var request = URLRequest(url: prepared.url)
        if let authorization = prepared.authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        let (data, _) = try await performRequest(request, maxRetries: maxRetries)
        return data
    }

    /// POST JSON 并返回响应文本，供结构化远程服务调用。
    func postJSON<T: Encodable>(
        to urlString: String,
        body: T,
        headers: [String: String]? = nil,
        maxRetries: Int = NetworkManager.defaultMaxRetries
    ) async throws -> String {
        let prepared = try Self.prepareURL(from: urlString)
        var request = URLRequest(url: prepared.url)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authorization = prepared.authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        headers?.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        let (data, response) = try await performRequest(request, maxRetries: maxRetries)
        guard let value = Self.decodeString(data: data, response: response) else {
            throw NetworkError.decodingError("文本解码失败")
        }
        return value
    }
    
    // MARK: - 带重试的核心请求方法
    
    /// 执行 HTTP 请求，遇到可重试错误时自动指数退避重试。
    private func performRequest(
        _ request: URLRequest,
        maxRetries: Int
    ) async throws -> (Data, HTTPURLResponse) {
        var lastError: Error = NetworkError.invalidResponse
        let totalAttempts = max(1, maxRetries + 1)
        
        for attempt in 0..<totalAttempts {
            do {
                try Task.checkCancellation()

                let requestDelegate = ProtectedRequestDelegate(
                    originalURL: request.url,
                    maximumResponseBytes: Self.maximumResponseBytes
                )
                let data: Data
                let response: URLResponse
                do {
                    (data, response) = try await session.data(
                        for: request,
                        delegate: requestDelegate
                    )
                } catch {
                    if requestDelegate.didRejectOversizedResponse {
                        throw NetworkError.responseTooLarge(Self.maximumResponseBytes)
                    }
                    throw error
                }

                try Self.validateResponseSize(
                    expectedContentLength: response.expectedContentLength,
                    actualByteCount: data.count
                )
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NetworkError.invalidResponse
                }
                
                guard (200...299).contains(httpResponse.statusCode) else {
                    let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
                    let error: NetworkError = message.map {
                        .serverError(httpResponse.statusCode, $0)
                    } ?? .httpError(httpResponse.statusCode)
                    if Self.isRetryableHTTPStatus(httpResponse.statusCode) && attempt < totalAttempts - 1 {
                        lastError = error
                        try await retryDelay(attempt: attempt)
                        continue
                    }
                    throw error
                }
                
                return (data, httpResponse)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if Self.isRetryableError(error) && attempt < totalAttempts - 1 {
                    try await retryDelay(attempt: attempt)
                    continue
                }
                throw error
            }
        }
        
        throw lastError
    }

    static func prepareURL(
        from value: String
    ) throws -> (url: URL, authorization: String?) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              !host.isEmpty else {
            throw NetworkError.invalidURL(value)
        }

        let authorization: String?
        if components.user != nil || components.password != nil {
            let user = components.user ?? ""
            let password = components.password ?? ""
            authorization = "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
            components.user = nil
            components.password = nil
        } else {
            authorization = nil
        }
        // URL fragments are never part of an HTTP request and may contain tokens.
        // Removing them also keeps those values out of URLSession/CFNetwork logs.
        components.fragment = nil
        guard let url = components.url else {
            throw NetworkError.invalidURL(value)
        }
        return (url, authorization)
    }

    static func validateResponseSize(
        expectedContentLength: Int64,
        actualByteCount: Int
    ) throws {
        if expectedContentLength > Int64(maximumResponseBytes)
            || actualByteCount > maximumResponseBytes {
            throw NetworkError.responseTooLarge(maximumResponseBytes)
        }
    }

    static func sanitizedRedirectRequest(
        _ request: URLRequest,
        originalURL: URL?
    ) -> URLRequest {
        guard NetworkOrigin(url: request.url) != NetworkOrigin(url: originalURL) else {
            return request
        }
        var sanitized = request
        for header in ["Authorization", "Proxy-Authorization", "Cookie"] {
            sanitized.setValue(nil, forHTTPHeaderField: header)
        }
        return sanitized
    }
    
    /// 指数退避延迟 + 随机抖动，避免多请求同时重试造成惊群效应。
    private func retryDelay(attempt: Int) async throws {
        let base = Self.retryBaseDelay * pow(2.0, Double(attempt))
        let jitter = Double.random(in: 0...0.5)
        let delay = min(base + jitter, Self.retryMaxDelay)
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }
    
    /// 判断 HTTP 状态码是否值得重试（仅服务端临时错误）。
    private static func isRetryableHTTPStatus(_ statusCode: Int) -> Bool {
        switch statusCode {
        case 408, 429, 500, 502, 503, 504: return true
        default: return false
        }
    }
    
    /// 判断错误是否为可重试的瞬态网络错误。
    private static func isRetryableError(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        
        if let networkError = error as? NetworkError {
            if case .httpError(let code) = networkError {
                return isRetryableHTTPStatus(code)
            }
            if case .serverError(let code, _) = networkError {
                return isRetryableHTTPStatus(code)
            }
            if case .invalidURL = networkError { return false }
            if case .decodingError = networkError { return false }
        }
        
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut,
                 NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorNotConnectedToInternet,
                 NSURLErrorSecureConnectionFailed,
                 NSURLErrorDataNotAllowed:
                return true
            default:
                return false
            }
        }
        
        return false
    }
    
    /// 文本解码策略：
    /// 1) 先用响应头声明字符集；
    /// 2) 再按常见字符集与编码顺序尝试；
    /// 3) 最后用 UTF-8 宽容解码兜底。
    private static func decodeString(data: Data, response: HTTPURLResponse) -> String? {
        // 优先使用服务端声明的字符集（如 gbk / gb2312 / gb18030）
        if let charset = response.textEncodingName,
           let declaredEncoding = encoding(fromIANACharset: charset),
           let value = String(data: data, encoding: declaredEncoding) {
            return value
        }
        
        for charset in fallbackCharsetNames {
            if let encoding = encoding(fromIANACharset: charset),
               let value = String(data: data, encoding: encoding) {
                return value
            }
        }
        
        for encoding in fallbackStringEncodings {
            if let value = String(data: data, encoding: encoding) {
                return value
            }
        }
        
        // 最后兜底，避免单纯因编码不一致直接报错
        if !data.isEmpty {
            return String(decoding: data, as: UTF8.self)
        }
        
        return nil
    }
    
    /// IANA 字符集名转 `String.Encoding`。
    private static func encoding(fromIANACharset charset: String) -> String.Encoding? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else {
            return nil
        }
        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
        return String.Encoding(rawValue: nsEncoding)
    }
}

private struct NetworkOrigin: Equatable {
    let scheme: String
    let host: String
    let port: Int?

    init?(url: URL?) {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else {
            return nil
        }
        self.scheme = scheme
        self.host = host
        if let port = url.port {
            self.port = port
        } else if scheme == "http" {
            self.port = 80
        } else if scheme == "https" {
            self.port = 443
        } else {
            self.port = nil
        }
    }
}

final class ProtectedRequestDelegate: NSObject, URLSessionDataDelegate {
    private let originalURL: URL?
    private let maximumResponseBytes: Int64
    private let stateLock = NSLock()
    private var rejectedOversizedResponse = false

    var didRejectOversizedResponse: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return rejectedOversizedResponse
    }

    init(originalURL: URL?, maximumResponseBytes: Int) {
        self.originalURL = originalURL
        self.maximumResponseBytes = Int64(maximumResponseBytes)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(
            NetworkManager.sanitizedRedirectRequest(request, originalURL: originalURL)
        )
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard response.expectedContentLength <= maximumResponseBytes else {
            stateLock.lock()
            rejectedOversizedResponse = true
            stateLock.unlock()
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }
}

/// 网络层错误定义。
enum NetworkError: LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case httpError(Int)
    case serverError(Int, String)
    case decodingError(String)
    case responseTooLarge(Int)
    
    /// 面向 UI/日志的错误描述。
    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "无效的URL: \(SensitiveURLRedactor.redact(url))"
        case .invalidResponse: return "无效的响应"
        case .httpError(let code): return "HTTP 错误: \(code)"
        case .serverError(_, let message): return message
        case .decodingError(let msg): return "解码错误: \(msg)"
        case .responseTooLarge(let maximumBytes):
            return "响应内容过大（上限 \(maximumBytes / 1024 / 1024) MB）"
        }
    }
    
    /// 是否为网络不可用导致的错误（供 UI 层判断是否显示网络提示）。
    var isNetworkUnavailable: Bool {
        if case .httpError = self { return false }
        if case .serverError = self { return false }
        return true
    }
}

extension Error {
    /// 判断是否为网络连接类错误（超时、断网、DNS 失败等）。
    var isNetworkConnectionError: Bool {
        if self is CancellationError { return false }
        let nsError = self as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut,
                 NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorNotConnectedToInternet,
                 NSURLErrorDataNotAllowed:
                return true
            default:
                return false
            }
        }
        return false
    }
}
