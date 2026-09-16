import XCTest
@testable import TVBox

final class SearchResultGroupTests: XCTestCase {
    func testGroupsOnlineAndCloudVariantsButKeepsDistinctSeasons() {
        let videos = [
            Movie.Video(id: "1", name: "测试剧", sourceKey: "online"),
            Movie.Video(id: "1", name: "《测试剧》 [4K] 全24集", sourceKey: "cloud"),
            Movie.Video(id: "2", name: "测试剧 第二季", sourceKey: "cloud")
        ]
        let groups = SearchResultGroup.aggregate(videos)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].resources.count, 2)
        XCTAssertNotEqual(videos[0].resourceID, videos[1].resourceID)
    }

    func testDeduplicatesOnlyWithinSameSource() {
        let video = Movie.Video(id: "1", name: "测试剧", sourceKey: "a")
        var anotherSource = video
        anotherSource.sourceKey = "b"
        XCTAssertEqual(SearchResultGroup.aggregate([video, video, anotherSource])[0].resources.count, 2)
    }

    func testDoesNotMergeRemakesOrAmbiguousMissingYears() {
        var first = Movie.Video(id: "1", name: "测试剧", sourceKey: "a")
        first.year = "2020"
        var remake = Movie.Video(id: "2", name: "测试剧", sourceKey: "b")
        remake.year = "2024"
        let unknown = Movie.Video(id: "3", name: "测试剧", sourceKey: "c")
        XCTAssertEqual(SearchResultGroup.aggregate([first, remake, unknown]).count, 3)
        XCTAssertEqual(SearchResultGroup.aggregate([first, unknown]).count, 1)
    }

    func testPreservesSequelNumbersAndMeaningfulTitleWords() {
        for title in ["测试剧2", "测试剧 第2季", "1984", "完结", "4K", "测试剧：归来"] {
            XCTAssertEqual(SearchResultGroup.title(for: title), title)
        }
    }
}
