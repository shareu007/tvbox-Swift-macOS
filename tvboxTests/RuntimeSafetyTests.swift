import Foundation
import XCTest
@testable import TVBox

private final class NetworkStubState: @unchecked Sendable {
    static let shared = NetworkStubState()
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private let lock = NSLock()
    private var handler: Handler?
    private var lastRequest: URLRequest?

    func setHandler(_ handler: @escaping Handler) {
        lock.lock()
        self.handler = handler
        lastRequest = nil
        lock.unlock()
    }

    func response(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let currentHandler: Handler?
        lock.lock()
        lastRequest = request
        currentHandler = handler
        lock.unlock()
        guard let currentHandler else {
            throw URLError(.badServerResponse)
        }
        return try currentHandler(request)
    }

    func recordedRequest() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return lastRequest
    }
}

private final class NetworkStubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try NetworkStubState.shared.response(for: request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
final class RuntimeSafetyTests: XCTestCase {
    func testPrivateSettingsFileStoreUsesRestrictedPermissionsAndRemovesValues() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tvbox-private-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("private-settings.json")
        let store = PrivateSettingsFileStore(fileURL: fileURL)

        try store.save("https://demo:secret@example.com/config", forKey: "vod-url")
        XCTAssertEqual(
            store.values()["vod-url"],
            "https://demo:secret@example.com/config"
        )

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        try store.save("", forKey: "vod-url")
        XCTAssertNil(store.values()["vod-url"])
    }

    func testPrivateSettingsFileStoreRejectsOversizedValues() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tvbox-private-settings-\(UUID().uuidString).json")
        let store = PrivateSettingsFileStore(fileURL: fileURL)
        let oversized = String(
            repeating: "x",
            count: PrivateSettingsFileStore.maximumValueBytes + 1
        )

        XCTAssertThrowsError(try store.save(oversized, forKey: "token"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testSensitiveURLRedactorRemovesCredentialsAndSecretQueryValues() {
        let redacted = SensitiveURLRedactor.redact(
            "http://demo:secret@example.com/config.json?token=private&mode=tv#cookie"
        )

        XCTAssertFalse(redacted.contains("demo"))
        XCTAssertFalse(redacted.contains("secret"))
        XCTAssertFalse(redacted.contains("private"))
        XCTAssertFalse(redacted.contains("cookie"))
        XCTAssertTrue(redacted.contains("example.com/config.json"))
        XCTAssertTrue(redacted.contains("mode=tv"))
        XCTAssertTrue(redacted.contains("token=REDACTED"))
    }

    func testSensitiveURLRedactorHandlesMalformedCredentialURL() {
        let redacted = SensitiveURLRedactor.redact("http://demo:secret@[invalid")

        XCTAssertEqual(redacted, "http://[invalid")
        XCTAssertFalse(redacted.contains("secret"))
    }

    func testSensitiveURLRedactorCoversCommonSignedQueryNames() {
        for name in [
            "auth_token", "X-Amz-Signature", "X-Amz-Credential",
            "session_id", "ticket", "sig"
        ] {
            let value = "https://example.com/config?\(name)=private&mode=tv"
            let redacted = SensitiveURLRedactor.redact(value)
            XCTAssertFalse(redacted.contains("private"), name)
            XCTAssertTrue(redacted.contains("REDACTED"), name)
            XCTAssertTrue(SensitiveURLRedactor.containsSensitiveData(value), name)
        }
        XCTAssertFalse(
            SensitiveURLRedactor.containsSensitiveData("https://example.com/config?mode=tv")
        )
    }

    func testNetworkAndSourceErrorsDoNotExposeURLCredentials() {
        let value = "http://demo:secret@example.com/config?api_key=private"

        XCTAssertFalse(NetworkError.invalidURL(value).localizedDescription.contains("secret"))
        XCTAssertFalse(NetworkError.invalidURL(value).localizedDescription.contains("private"))
        XCTAssertFalse(SourceError.invalidApiUrl(value).localizedDescription.contains("secret"))
        XCTAssertFalse(SourceError.invalidApiUrl(value).localizedDescription.contains("private"))
    }

    func testNetworkManagerMovesBasicCredentialsOutOfURL() throws {
        let prepared = try NetworkManager.prepareURL(
            from: "http://demo:secret@example.com/config.json?mode=tv#private-token"
        )

        XCTAssertEqual(
            prepared.url.absoluteString,
            "http://example.com/config.json?mode=tv"
        )
        XCTAssertEqual(
            prepared.authorization,
            "Basic " + Data("demo:secret".utf8).base64EncodedString()
        )
    }

    func testNetworkManagerRejectsNonHTTPURLs() {
        for value in [
            "file:///etc/passwd",
            "javascript:alert(1)",
            "../local-config.json"
        ] {
            XCTAssertThrowsError(try NetworkManager.prepareURL(from: value))
        }
    }

    func testNetworkManagerRejectsOversizedResponses() {
        XCTAssertNoThrow(
            try NetworkManager.validateResponseSize(
                expectedContentLength: Int64(NetworkManager.maximumResponseBytes),
                actualByteCount: NetworkManager.maximumResponseBytes
            )
        )
        XCTAssertThrowsError(
            try NetworkManager.validateResponseSize(
                expectedContentLength: Int64(NetworkManager.maximumResponseBytes + 1),
                actualByteCount: 0
            )
        )
        XCTAssertThrowsError(
            try NetworkManager.validateResponseSize(
                expectedContentLength: -1,
                actualByteCount: NetworkManager.maximumResponseBytes + 1
            )
        )
    }

    func testNetworkManagerSanitizesCredentialsInActualRequest() async throws {
        NetworkStubState.shared.setHandler { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/plain; charset=utf-8"]
                )
            )
            return (response, Data("ok".utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NetworkStubURLProtocol.self]
        let network = NetworkManager(configuration: configuration)

        let result = try await network.getString(
            from: "http://demo:secret@example.com/config#private-token",
            maxRetries: 0
        )

        let request = try XCTUnwrap(NetworkStubState.shared.recordedRequest())
        XCTAssertEqual(result, "ok")
        XCTAssertEqual(request.url?.absoluteString, "http://example.com/config")
        XCTAssertNil(request.url?.user)
        XCTAssertNil(request.url?.password)
        XCTAssertNil(request.url?.fragment)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Basic " + Data("demo:secret".utf8).base64EncodedString()
        )
    }

    func testNetworkManagerCancelsDeclaredOversizedResponse() async throws {
        NetworkStubState.shared.setHandler { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Length": "\(NetworkManager.maximumResponseBytes + 1)"
                    ]
                )
            )
            return (response, Data())
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NetworkStubURLProtocol.self]
        let network = NetworkManager(configuration: configuration)

        do {
            _ = try await network.getString(from: "https://example.com/large", maxRetries: 0)
            XCTFail("Expected an oversized response error")
        } catch NetworkError.responseTooLarge(let maximumBytes) {
            XCTAssertEqual(maximumBytes, NetworkManager.maximumResponseBytes)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCrossOriginRedirectDropsSensitiveRequestHeaders() throws {
        let originalURL = try XCTUnwrap(URL(string: "https://source.example/config"))
        let redirectedURL = try XCTUnwrap(URL(string: "https://mirror.example/config"))
        var request = URLRequest(url: redirectedURL)
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        request.setValue("session=secret", forHTTPHeaderField: "Cookie")
        request.setValue("Basic secret", forHTTPHeaderField: "Proxy-Authorization")

        let sanitized = NetworkManager.sanitizedRedirectRequest(
            request,
            originalURL: originalURL
        )

        XCTAssertNil(sanitized.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(sanitized.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(sanitized.value(forHTTPHeaderField: "Proxy-Authorization"))
    }

    func testSameOriginRedirectKeepsAuthorizationHeader() throws {
        let originalURL = try XCTUnwrap(URL(string: "https://source.example/config"))
        let redirectedURL = try XCTUnwrap(URL(string: "https://source.example/next"))
        var request = URLRequest(url: redirectedURL)
        request.setValue("Basic credential", forHTTPHeaderField: "Authorization")

        let sanitized = NetworkManager.sanitizedRedirectRequest(
            request,
            originalURL: originalURL
        )

        XCTAssertEqual(
            sanitized.value(forHTTPHeaderField: "Authorization"),
            "Basic credential"
        )
    }

    func testCancellingSearchStopsSpinnerAndKeepsPartialResults() {
        let viewModel = SearchViewModel()
        let partialResult = Movie.Video(id: "partial", name: "已返回结果")
        viewModel.keyword = "测试"
        viewModel.results = [partialResult]
        viewModel.isSearching = true

        viewModel.cancelSearch()

        XCTAssertFalse(viewModel.isSearching)
        XCTAssertEqual(viewModel.keyword, "测试")
        XCTAssertEqual(viewModel.results, [partialResult])
    }
}
