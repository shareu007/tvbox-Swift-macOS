import XCTest
@testable import TVBox

final class SourceCategoryParsingTests: XCTestCase {
    func testParentCategoriesWithChildrenAreNotShownAsPlayableCategories() {
        let categories: [[String: Any]] = [
            ["type_id": 1, "type_pid": 0, "type_name": "电影片"],
            ["type_id": 2, "type_pid": 0, "type_name": "连续剧"],
            ["type_id": 6, "type_pid": 1, "type_name": "动作片"],
            ["type_id": "7", "type_pid": "1", "type_name": "喜剧片"],
            ["type_id": 13, "type_pid": 2, "type_name": "国产剧"]
        ]

        let result = SourceService.leafCategories(from: categories)

        XCTAssertEqual(result.map(\.id), ["6", "7", "13"])
        XCTAssertEqual(result.map(\.name), ["动作片", "喜剧片", "国产剧"])
    }

    func testStandaloneRootCategoryIsPreserved() {
        let categories: [[String: Any]] = [
            ["type_id": 1, "type_pid": 0, "type_name": "电影片"],
            ["type_id": 6, "type_pid": 1, "type_name": "动作片"],
            ["type_id": 35, "type_pid": 0, "type_name": "电影解说"]
        ]

        let result = SourceService.leafCategories(from: categories)

        XCTAssertEqual(result.map(\.id), ["6", "35"])
        XCTAssertEqual(result.map(\.name), ["动作片", "电影解说"])
    }
}
