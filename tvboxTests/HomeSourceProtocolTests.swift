import XCTest
@testable import TVBox

private final class HomeProtocolStub: URLProtocol {
    nonisolated(unsafe) static var respond: ((URLRequest) throws -> String)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let text = try Self.respond!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
final class HomeSourceProtocolTests: XCTestCase {
    private func service(_ respond: @escaping (URLRequest) throws -> String) -> SourceService {
        HomeProtocolStub.respond = respond
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HomeProtocolStub.self]
        return SourceService(network: NetworkManager(configuration: configuration))
    }

    func testRemoteHomepageSupplementPreservesSourceExtension() async throws {
        var requestCount = 0
        let source = SourceBean(key: "remote", api: "https://fixture.example/api", type: 4, ext: "site-fixture")
        let service = service { request in
            requestCount += 1
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "extend" }?.value, "site-fixture")
            if query.contains(where: { $0.name == "ac" }) {
                return #"{"list":[{"vod_id":"one","vod_name":"影片"}]}"#
            }
            return #"{"class":[{"type_id":"movie","type_name":"电影"}],"list":[]}"#
        }
        let result = try await service.getSort(sourceBean: source, maxRetries: 0)
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(result.homeVideos.map(\.id), ["one"])
    }

    func testXMLHomeReadsVideosWithOptionalFieldsAndCDATA() async throws {
        let service = service { _ in
            """
            <rss><class><ty id='movie'><![CDATA[电影 & 剧集]]></ty></class><list>
            <video><name>影片 &amp; A</name><pic>https://image.example/a.jpg</pic><id>v-1</id><year>2024</year><area>中国</area></video>
            <video><id>2</id><name><![CDATA[影片 B]]></name><note><![CDATA[完结]]></note></video>
            </list></rss>
            """
        }
        let result = try await service.getSort(sourceBean: SourceBean(key: "xml", api: "https://fixture.example/xml", type: 0), maxRetries: 0)
        XCTAssertEqual(result.sorts.map(\.name), ["电影 & 剧集"])
        XCTAssertEqual(result.homeVideos.map(\.id), ["v-1", "2"])
        XCTAssertEqual(result.homeVideos.first?.name, "影片 & A")
        XCTAssertEqual(result.homeVideos.first?.year, "2024")
        XCTAssertEqual(result.homeVideos.first?.area, "中国")
        XCTAssertEqual(result.homeVideos.first?.sourceKey, "xml")
    }

    func testXMLCategoryDoesNotRequirePosterOrRemarks() async throws {
        let service = service { _ in "<rss><list><video><id>abc</id><name>影片</name></video></list></rss>" }
        let videos = try await service.getList(sourceBean: SourceBean(key: "xml", api: "https://fixture.example/xml", type: 0), sortData: .init(id: "movie", name: "电影"))
        XCTAssertEqual(videos.map(\.id), ["abc"])
    }
    func testJSONCategoryRetriesDetailWithCategoryAndFilters() async throws {
        let service = service { request in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(items.first { $0.name == "t" }?.value, "movie")
            XCTAssertEqual(items.first { $0.name == "year" }?.value, "2024")
            XCTAssertEqual(items.first { $0.name == "pg" }?.value, "2")
            if items.first(where: { $0.name == "ac" })?.value == "videolist" { return "unsupported action" }
            return #"{"list":[{"vod_id":"detail-film","vod_name":"影片"}]}"#
        }
        let videos = try await service.getList(sourceBean: SourceBean(key: "json", api: "https://fixture.example/api", type: 1), sortData: .init(id: "movie", name: "电影"), page: 2, filters: ["year": "2024"])
        XCTAssertEqual(videos.map(\.id), ["detail-film"])
    }

}
