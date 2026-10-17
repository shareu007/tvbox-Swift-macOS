import Foundation

/// Streams network chunks straight to disk. Each request has an isolated
/// session: account cookies are supplied explicitly, never read from Safari.
struct OfflineHTTPClient {
    let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) { self.configuration = configuration }

    func download(_ url: URL, headers: [String: String], to file: URL,
                  maximumBytes: Int64 = 100 * 1024 * 1024 * 1024, resume: Bool = true,
                  progress: @escaping (Int64, Int64?) -> Void = { _, _ in }) async throws -> HTTPURLResponse {
        guard SourceSubtitleParser.isRemoteURL(url) else { throw OfflineDownloadError.invalidURL }
        func perform(resume: Bool) async throws -> HTTPURLResponse {
            let transfer = OfflineHTTPTransfer(configuration: configuration, url: url, headers: headers,
                                               file: file, maximumBytes: maximumBytes, resume: resume, progress: progress)
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { transfer.start($0) }
            } onCancel: { transfer.cancel() }
        }
        do { return try await perform(resume: resume) }
        catch {
            try Task.checkCancellation()
            // Expired validators and an already complete partial can produce
            // 416. Retry once without Range; never loop on an invalid server.
            if resume, let reason = error as? OfflineDownloadError {
                switch reason {
                case .invalidRange, .http(416): return try await perform(resume: false)
                default: break
                }
            }
            throw error
        }
    }
}

private struct OfflineResumeMetadata: Codable {
    let urlHash: String
    let validator: String?
}

private final class OfflineHTTPTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let url: URL
    private let headers: [String: String]
    private let file: URL
    private let maximumBytes: Int64
    private let progress: (Int64, Int64?) -> Void
    private let allowsResume: Bool
    private let lock = NSLock()
    private var cancelled = false
    private var task: URLSessionDataTask?
    // The following mutable state is confined to the serial delegate queue.
    private var continuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var handle: FileHandle?
    private var response: HTTPURLResponse?
    private var failure: Error?
    private var offset: Int64 = 0
    private var received: Int64 = 0
    private var expected: Int64?
    private var validator: String?
    private var redirects = 0
    private var lastProgress = Date.distantPast
    private var prefix = Data()
    private var bodyLimit: Int64
    private var metadataURL: URL { file.appendingPathExtension("resume.json") }

    init(configuration: URLSessionConfiguration, url: URL, headers: [String: String], file: URL,
         maximumBytes: Int64, resume: Bool, progress: @escaping (Int64, Int64?) -> Void) {
        self.configuration = configuration
        self.url = url
        self.headers = headers
        self.file = file
        self.maximumBytes = maximumBytes
        self.bodyLimit = maximumBytes
        self.allowsResume = resume
        self.progress = progress
    }

    func start(_ continuation: CheckedContinuation<HTTPURLResponse, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        if allowsResume, OfflineDownloadStore.size(metadataURL) < 16384,
           let data = try? Data(contentsOf: metadataURL),
           let metadata = try? JSONDecoder().decode(OfflineResumeMetadata.self, from: data),
           metadata.urlHash == OfflineDownload.requestIdentity(url: url, headers: headers), let savedValidator = metadata.validator {
            offset = OfflineDownloadStore.size(file)
            validator = savedValidator
        }
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = SourceSubtitleParser.safeHeaders(headers)
            .filter { !["range", "if-range", "accept-encoding"].contains($0.key.lowercased()) }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            request.setValue(validator, forHTTPHeaderField: "If-Range")
        }
        let config = configuration.copy() as! URLSessionConfiguration
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 24 * 60 * 60
        config.httpMaximumConnectionsPerHost = 4
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        let newTask = session.dataTask(with: request)
        task = newTask
        newTask.resume()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let response = response as? HTTPURLResponse else { throw OfflineDownloadError.invalidResponse }
            guard response.statusCode == 200 || response.statusCode == 206 else { throw OfflineDownloadError.http(response.statusCode) }
            if let encoding = response.value(forHTTPHeaderField: "Content-Encoding"), encoding.lowercased() != "identity" {
                throw OfflineDownloadError.invalidResponse
            }
            guard !["text/html", "application/json", "application/xhtml+xml"].contains(response.mimeType?.lowercased() ?? "") else {
                throw OfflineDownloadError.notMedia
            }
            let etag = response.value(forHTTPHeaderField: "ETag").flatMap { $0.hasPrefix("W/") ? nil : $0 }
            let newValidator = etag ?? response.value(forHTTPHeaderField: "Last-Modified")
            if response.statusCode == 206 {
                guard let range = Self.contentRange(response.value(forHTTPHeaderField: "Content-Range")),
                      range.start == offset, range.end == range.total - 1,
                      offset == 0 || newValidator == validator,
                      response.expectedContentLength < 0 || response.expectedContentLength == range.total - offset else {
                    throw OfflineDownloadError.invalidRange
                }
                expected = range.total
            } else {
                // A server may ignore Range or replace the resource. Start a new
                // file rather than append a second complete movie to the old one.
                offset = 0
                expected = response.expectedContentLength > 0 ? response.expectedContentLength : nil
            }
            guard expected.map({ $0 <= maximumBytes }) ?? true else { throw OfflineDownloadError.tooLarge }
            if !FileManager.default.fileExists(atPath: file.path) {
                guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw OfflineDownloadError.storage
                }
            }
            handle = try FileHandle(forWritingTo: file)
            if offset == 0 { try handle?.truncate(atOffset: 0) }
            try handle?.seek(toOffset: UInt64(offset))
            received = offset
            self.response = response
            let metadata = OfflineResumeMetadata(urlHash: OfflineDownload.requestIdentity(url: url, headers: headers), validator: newValidator)
            try OfflineDownloadStore.writePrivate(JSONEncoder().encode(metadata), to: metadataURL)
            progress(received, expected)
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        do {
            if offset == 0, prefix.count < 1024 {
                prefix.append(data.prefix(1024 - prefix.count))
                let text = String(decoding: prefix, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if text.hasPrefix("#EXTM3U") { bodyLimit = min(maximumBytes, OfflineHLSPlaylist.maximumPlaylistBytes) }
                let lower = text.lowercased()
                if lower.hasPrefix("<!doctype html") || lower.hasPrefix("<html") || lower.hasPrefix("<?xml") {
                    throw OfflineDownloadError.notMedia
                }
            }
            guard Int64(data.count) <= bodyLimit - received else { throw OfflineDownloadError.tooLarge }
            try handle?.write(contentsOf: data)
            received += Int64(data.count)
            let now = Date()
            if now.timeIntervalSince(lastProgress) >= 0.25 {
                lastProgress = now
                progress(received, expected)
            }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        defer { session.finishTasksAndInvalidate() }
        guard let continuation else { return }
        self.continuation = nil
        if let failure = failure ?? error { continuation.resume(throwing: failure); return }
        guard let response, received > 0, expected.map({ received == $0 }) ?? true else {
            continuation.resume(throwing: OfflineDownloadError.incomplete)
            return
        }
        progress(received, expected)
        continuation.resume(returning: response)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 5 else { completionHandler(nil); return }
        completionHandler(SourceSubtitleLoader.redirect(request, from: response.url))
    }

    private static func contentRange(_ value: String?) -> (start: Int64, end: Int64, total: Int64)? {
        guard let value, value.hasPrefix("bytes ") else { return nil }
        let parts = value.dropFirst(6).split(separator: "/")
        guard parts.count == 2, let total = Int64(parts[1]), total > 0 else { return nil }
        let bounds = parts[0].split(separator: "-")
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
              start >= 0, end >= start, end < total else { return nil }
        return (start, end, total)
    }
}
