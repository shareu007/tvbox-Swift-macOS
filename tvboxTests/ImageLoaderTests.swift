import XCTest
@testable import TVBox

@MainActor
final class ImageLoaderTests: XCTestCase {
    func testDiskCacheLivesInsideTheUserCachesDirectory() throws {
        let fileManager = FileManager.default
        let cachesDirectory = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ).standardizedFileURL
        let imageCacheDirectory = try ImageLoader.imageCacheDirectory(
            fileManager: fileManager
        ).standardizedFileURL

        XCTAssertTrue(
            imageCacheDirectory.path.hasPrefix(cachesDirectory.path + "/"),
            "Image cache must stay inside the user's caches directory"
        )
        XCTAssertNotEqual(imageCacheDirectory.path, "/image_cache")
    }

    func testImagePayloadLimitRejectsOversizedResponses() {
        XCTAssertNoThrow(
            try ImageLoader.validateImagePayload(
                expectedContentLength: Int64(ImageLoader.maximumImagePayloadBytes),
                actualByteCount: ImageLoader.maximumImagePayloadBytes
            )
        )
        XCTAssertThrowsError(
            try ImageLoader.validateImagePayload(
                expectedContentLength: Int64(ImageLoader.maximumImagePayloadBytes + 1),
                actualByteCount: 0
            )
        )
        XCTAssertThrowsError(
            try ImageLoader.validateImagePayload(
                expectedContentLength: -1,
                actualByteCount: ImageLoader.maximumImagePayloadBytes + 1
            )
        )
    }

    func testImageLoaderRejectsNonHTTPURLs() async {
        let loader = ImageLoader(configuration: .ephemeral)
        do {
            _ = try await loader.load(url: URL(fileURLWithPath: "/etc/passwd"))
            XCTFail("Expected invalid URL")
        } catch ImageLoadError.invalidURL {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPosterURLDoesNotSendSignedImageURLThroughThirdPartyProxy() throws {
        let signed = try XCTUnwrap(
            URL.posterURL(from: "https://img.picbf.com/poster.jpg?token=private")
        )
        let publicURL = try XCTUnwrap(
            URL.posterURL(from: "https://img.picbf.com/poster.jpg")
        )

        XCTAssertEqual(signed.host, "img.picbf.com")
        XCTAssertEqual(publicURL.host, "images.weserv.nl")
        XCTAssertNil(URL.posterURL(from: "file:///etc/passwd"))
    }

    func testCatVodImageProxyLoadsTheOriginalImageWithSourceHeaders() async throws {
        var proxy = try XCTUnwrap(URLComponents(string: "http://localhost/imageProxy"))
        proxy.queryItems = [
            URLQueryItem(name: "url", value: "https://image.example/poster.png?signature=fixture"),
            URLQueryItem(name: "cache", value: "86400"),
            URLQueryItem(name: "customHeaders", value: #"{"Referer":"https://catalog.example/","User-Agent":"source-agent","Host":"blocked.example"}"#)
        ]
        let requested = expectation(description: "Original image requested")
        ImageRequestStub.respond = { request in
            guard request.url?.host == "image.example" else { throw URLError(.cannotConnectToHost) }
            XCTAssertEqual(request.url?.query, "signature=fixture")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://catalog.example/")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "source-agent")
            XCTAssertNil(request.value(forHTTPHeaderField: "Host"))
            requested.fulfill()
            return Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!
        }
        defer { ImageRequestStub.respond = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageRequestStub.self]
        let image = try await ImageLoader(configuration: configuration).load(url: try XCTUnwrap(proxy.url))
        XCTAssertGreaterThan(image.size.width, 0)
        await fulfillment(of: [requested], timeout: 1)
    }

    func testRemoteImageProxyKeepsItsOriginalURL() throws {
        let url = try XCTUnwrap(URL(string: "https://proxy.example/imageProxy?url=https%3A%2F%2Fimage.example%2Fa.png"))
        XCTAssertEqual(try ImageLoader.makeImageRequest(url: url).url, url)
    }

    func testCatVodImageProxyRejectsInvalidTargetsAndCredentialBearingWrappers() throws {
        for target in ["file:///etc/passwd", "javascript:alert(1)", "http://localhost/imageProxy?url=x", ""] {
            var proxy = try XCTUnwrap(URLComponents(string: "http://127.0.0.1:80/imageProxy"))
            proxy.queryItems = [URLQueryItem(name: "url", value: target)]
            XCTAssertThrowsError(try ImageLoader.makeImageRequest(url: XCTUnwrap(proxy.url)))
        }
        let wrapper = try XCTUnwrap(URL(string: "http://demo:secret@localhost/imageProxy?url=https%3A%2F%2Fimage.example%2Fa.png"))
        XCTAssertThrowsError(try ImageLoader.makeImageRequest(url: wrapper))
    }

    func testCatVodImageProxyRejectsDuplicateTargetsAndMalformedHeaders() throws {
        var proxy = try XCTUnwrap(URLComponents(string: "http://localhost/imageProxy"))
        proxy.queryItems = [URLQueryItem(name: "url", value: "https://image.example/a.png"),
                            URLQueryItem(name: "url", value: "https://other.example/b.png")]
        XCTAssertThrowsError(try ImageLoader.makeImageRequest(url: XCTUnwrap(proxy.url)))
        proxy.queryItems = [URLQueryItem(name: "url", value: "https://image.example/a.png"),
                            URLQueryItem(name: "customHeaders", value: "invalid")]
        XCTAssertThrowsError(try ImageLoader.makeImageRequest(url: XCTUnwrap(proxy.url)))
    }

    func testDirectImageBasicAuthenticationRemainsScopedToItsTarget() throws {
        let url = try XCTUnwrap(URL(string: "https://demo:secret@image.example/a.png"))
        let request = try ImageLoader.makeImageRequest(url: url)
        XCTAssertEqual(request.url?.host, "image.example")
        XCTAssertNil(request.url?.user)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic ZGVtbzpzZWNyZXQ=")
    }
}

private final class ImageRequestStub: URLProtocol {
    nonisolated(unsafe) static var respond: ((URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.respond!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "image/png"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
