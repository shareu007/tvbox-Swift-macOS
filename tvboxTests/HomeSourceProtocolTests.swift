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

    func testXMLDetailMatchesHomeAndPreservesCDATAPlaybackURL() async throws {
        let xml = """
        <rss><list><video><id code="fixture">v-1</id><name>&#x7535;影 &amp; A</name>
        <des>简介<b>加粗</b>结尾</des><dl><dd flag="m3u8"><![CDATA[正片$https://video.example/a.m3u8?literal=&amp;]]></dd></dl>
        </video></list></rss>
        """
        let service = service { _ in xml }
        let source = SourceBean(key: "xml", api: "https://fixture.example/xml", type: 0)
        let home = try await service.getSort(sourceBean: source, maxRetries: 0)
        let result = try await service.getDetail(sourceBean: source, vodId: "v-1")
        let detail = try XCTUnwrap(result)
        XCTAssertEqual(detail.id, home.homeVideos.first?.id)
        XCTAssertEqual(detail.name, "电影 & A")
        XCTAssertEqual(detail.des, "简介加粗结尾")
        XCTAssertEqual(detail.playUrlMap["m3u8"]?.first?.url, "https://video.example/a.m3u8?literal=&amp;")
    }

    func testXMLRoutesRemainScopedToTheirVideoAndDecodeEntitiesOnce() throws {
        let xml = """
        <rss><list><video><id>a</id><name>A</name><dl>
        <dd flag='m3u8'>正片$https://video.example/a.m3u8?x=1&amp;y=&#50;</dd>
        <dd><![CDATA[备用$https://video.example/b.mp4]]></dd></dl></video>
        <video><id>b</id><name>B</name></video></list></rss>
        """
        let response = try CMSXMLResponseParser.parse(Data(xml.utf8), sourceKey: "xml")
        XCTAssertEqual(response.details.count, 2)
        XCTAssertEqual(response.details[0].playUrlMap["m3u8"]?.first?.url, "https://video.example/a.m3u8?x=1&y=2")
        XCTAssertEqual(response.details[0].playUrlMap["线路2"]?.first?.url, "https://video.example/b.mp4")
        XCTAssertTrue(response.details[1].playFlags.isEmpty)
        XCTAssertEqual(response.homeVideos.map(\.id), ["a", "b"])
    }

}
