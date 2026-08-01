import XCTest
@testable import TVBox

final class VodInfoPlaybackRouteTests: XCTestCase {
    func testDirectHLSRouteIsPreferredOverSharePageRoute() {
        let info = VodInfo.from(
            video: Movie.Video(id: "1"),
            playFrom: "liangzi$$$lzm3u8",
            playUrl: "第1集$https://example.com/share/abc$$$第1集$https://cdn.example.com/video/index.m3u8"
        )

        XCTAssertEqual(info.playFlags, ["lzm3u8"])
        XCTAssertEqual(info.playFlag, "lzm3u8")
        XCTAssertEqual(info.currentEpisode?.url, "https://cdn.example.com/video/index.m3u8")
    }

    func testUnknownOnlyRouteIsPreserved() {
        let info = VodInfo.from(
            video: Movie.Video(id: "1"),
            playFrom: "default",
            playUrl: "第1集$https://example.com/play/opaque-id"
        )

        XCTAssertEqual(info.playFlags, ["default"])
        XCTAssertEqual(info.currentEpisode?.url, "https://example.com/play/opaque-id")
    }

    func testDollarCharactersInsidePlaybackURLArePreserved() {
        let info = VodInfo.from(
            video: Movie.Video(id: "1"),
            playFrom: "m3u8",
            playUrl: "第1集$https://example.com/index.m3u8?token=a$b$c"
        )

        XCTAssertEqual(info.currentEpisode?.url, "https://example.com/index.m3u8?token=a$b$c")
    }
}
