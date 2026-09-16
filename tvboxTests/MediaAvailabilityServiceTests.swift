import XCTest
@testable import TVBox

final class MediaAvailabilityServiceTests: XCTestCase {
    func testDirectSpiderMediaCanBeInspectedWithoutCallingPlayer() {
        XCTAssertTrue(MediaAvailabilityService.hasDirectMediaRoute(info(["https://example.com/video.mp4?token=test"])))
        XCTAssertFalse(MediaAvailabilityService.hasDirectMediaRoute(info(["opaque-player-id"])))
        XCTAssertFalse(MediaAvailabilityService.hasDirectMediaRoute(info(["https://example.com/share/abc"])))
    }

    func testTransportRequestsRangeAndBoundsBodyEvenWhenServerIgnoresRange() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MediaSampleURLProtocol.self]
        let (data, _) = try await MediaAvailabilityService.readSample(URL(string: "https://example.com/media")!, configuration: config)
        XCTAssertEqual(data.count, MediaAvailabilityService.maximumSampleBytes)
    }
    private func info(_ urls: [String]) -> VodInfo {
        let flags = urls.indices.map { "线路\($0)" }
        return VodInfo.from(video: Movie.Video(id: "test"), playFrom: flags.joined(separator: "$$$"),
                            playUrl: urls.map { "第1集$\($0)" }.joined(separator: "$$$"))
    }

    private var media: Data {
        Data([0, 0, 0, 32] + Array("ftypisom".utf8) + Array(repeating: 0, count: 32))
    }

    private func response(_ url: URL, status: Int = 200, mime: String = "application/octet-stream") -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime])!
    }

    func testWorkingManifestWithMissingSegmentIsNotPlayable() async throws {
        var requests = [String]()
        let service = MediaAvailabilityService { url in
            requests.append(url.path)
            if url.path.hasSuffix("m3u8") {
                return (Data("#EXTM3U\n#EXTINF:10,\nmissing.ts\n".utf8), self.response(url))
            }
            return (Data(), self.response(url, status: 404))
        }
        let result = try await service.verify(info: info(["https://example.com/list.m3u8"]), requiresPlayerResolution: false)
        XCTAssertTrue(result.isFailure)
        XCTAssertEqual(requests, ["/list.m3u8", "/missing.ts"])
    }

    func testMasterPlaylistResolvesRelativeVariantAndSamplesActualMedia() async throws {
        var requests = [String]()
        let service = MediaAvailabilityService { url in
            requests.append(url.path)
            let data: Data
            switch url.path {
            case "/master.m3u8": data = Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100\nhd/list.m3u8\n".utf8)
            case "/hd/list.m3u8": data = Data("#EXTM3U\n#EXTINF:10,\nclip.m4s\n".utf8)
            default: data = self.media
            }
            return (data, self.response(url))
        }
        let result = try await service.verify(info: info(["https://example.com/master.m3u8"]), requiresPlayerResolution: false)
        XCTAssertTrue(result.isVerified)
        XCTAssertEqual(requests, ["/master.m3u8", "/hd/list.m3u8", "/hd/clip.m4s"])
    }

    func testHTMLWithSuccessfulStatusAndVideoMimeIsNotPlayable() async throws {
        let service = MediaAvailabilityService { url in
            (Data("<!doctype html><html>资源已删除</html>".utf8), self.response(url, mime: "video/mp4"))
        }
        let result = try await service.verify(info: info(["https://example.com/video.mp4"]), requiresPlayerResolution: false)
        XCTAssertTrue(result.isFailure)
    }

    func testTriesAlternateRouteBeforeRejectingResource() async throws {
        var calls = 0
        let service = MediaAvailabilityService { url in
            calls += 1
            return url.path == "/bad.mp4" ? (Data(), self.response(url, status: 410)) : (self.media, self.response(url))
        }
        let result = try await service.verify(info: info(["https://example.com/bad.mp4", "https://example.com/good.mp4"]), requiresPlayerResolution: false)
        XCTAssertEqual(result, .verified(flag: "线路1", episode: "第1集"))
        XCTAssertEqual(calls, 2)
    }

    func testCloudVerificationDoesNotResolveOrTransferFiles() async throws {
        let service = MediaAvailabilityService { _ in
            XCTFail("Cloud resources must remain read-only without player calls")
            throw URLError(.cancelled)
        }
        let result = try await service.verify(info: info(["https://example.com/share"]), requiresPlayerResolution: true)
        if case .needsPlayback = result {} else { XCTFail("Cloud playback is not proven by its directory") }
    }

    func testAuthorizationAndEncryptedStreamsRemainPending() async throws {
        for encrypted in [false, true] {
            let service = MediaAvailabilityService { url in
                let data = Data("#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n#EXTINF:10,\nclip.ts\n".utf8)
                return (data, self.response(url, status: encrypted ? 200 : 403))
            }
            let result = try await service.verify(info: info(["https://example.com/list.m3u8"]), requiresPlayerResolution: false)
            if case .needsPlayback = result {} else { XCTFail("An authorization requirement is not expiry") }
        }
    }

    func testRouteAndPlaylistDepthAreBounded() async throws {
        var calls = 0
        let service = MediaAvailabilityService { url in
            calls += 1
            return (Data("#EXTM3U\nagain.m3u8\n".utf8), self.response(url))
        }
        _ = try await service.verify(info: info((0..<8).map { "https://example.com/\($0).m3u8" }), requiresPlayerResolution: false)
        XCTAssertEqual(calls, 9)
    }
}

private final class MediaSampleURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-8191")
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 0, count: 64 * 1024))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
