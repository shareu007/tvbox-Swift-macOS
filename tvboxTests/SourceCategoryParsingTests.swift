import XCTest
@testable import TVBox

final class SourceCategoryParsingTests: XCTestCase {
    func testFilterParsingPreservesNumericValuesAndRemovesDuplicateOptions() {
        let object: [String: Any] = ["filters": ["drama": [
            ["key": "year", "name": "年份", "value": [
                ["n": "全部", "v": ""], ["n": "2024", "v": 2024], ["n": "重复", "v": "2024"]
            ]],
            ["key": "year", "name": "重复", "value": [["n": "2023", "v": "2023"]]],
            ["key": "area", "value": [["n": "缺少参数"]]]
        ]]]
        let categories = SourceService.categoriesWithFilters([.init(id: "drama", name: "电视剧")], object: object)
        XCTAssertEqual(categories[0].filters.count, 1)
        XCTAssertEqual(categories[0].filters[0].values.map(\.v), ["", "2024"])
    }

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

    func testParentIDsMapsChildToParentAndIgnoresRoots() {
        let classList: [[String: Any]] = [
            ["type_id": 1, "type_pid": 0, "type_name": "电影"],
            ["type_id": "6", "type_pid": "1", "type_name": "动作片"],
            ["type_id": 7, "type_pid": 1, "type_name": "喜剧片"]
        ]
        let parents = SourceService.parentIDs(from: classList)
        XCTAssertNil(parents["1"], "根分类没有父级")
        XCTAssertEqual(parents["6"], "1")
        XCTAssertEqual(parents["7"], "1")
    }

    func testLeafCategoryInheritsFiltersDeclaredOnParentCategory() {
        let classList: [[String: Any]] = [
            ["type_id": 1, "type_pid": 0, "type_name": "电影"],
            ["type_id": 6, "type_pid": 1, "type_name": "动作片"]
        ]
        let object: [String: Any] = ["filters": ["1": [
            ["key": "year", "name": "年份", "value": [["n": "全部", "v": ""], ["n": "2024", "v": "2024"]]],
            ["key": "area", "name": "地区", "value": [["n": "大陆", "v": "大陆"]]]
        ]]]
        let categories = SourceService.categoriesWithFilters(
            SourceService.leafCategories(from: classList),
            object: object,
            parentIDs: SourceService.parentIDs(from: classList)
        )
        let action = categories.first { $0.id == "6" }
        XCTAssertEqual(Set(action?.filters.map(\.key) ?? []), ["year", "area"], "叶子分类应继承父分类声明的年份/地区筛选")
        XCTAssertEqual(action?.filters.first { $0.key == "year" }?.values.map(\.v), ["", "2024"])
    }

    func testLeafOwnFiltersTakePrecedenceOverInheritedParentFilters() {
        let classList: [[String: Any]] = [
            ["type_id": 1, "type_pid": 0, "type_name": "电影"],
            ["type_id": 6, "type_pid": 1, "type_name": "动作片"]
        ]
        let object: [String: Any] = ["filters": [
            "6": [["key": "year", "name": "年份", "value": [["n": "2023", "v": "2023"]]]],
            "1": [["key": "year", "name": "年份", "value": [["n": "2024", "v": "2024"]]],
                  ["key": "area", "name": "地区", "value": [["n": "大陆", "v": "大陆"]]]]
        ]]
        let categories = SourceService.categoriesWithFilters(
            SourceService.leafCategories(from: classList),
            object: object,
            parentIDs: SourceService.parentIDs(from: classList)
        )
        let action = categories.first { $0.id == "6" }
        XCTAssertEqual(action?.filters.first { $0.key == "year" }?.values.map(\.v), ["2023"], "同名 key 以叶子自身声明为准")
        XCTAssertEqual(action?.filters.first { $0.key == "area" }?.values.map(\.v), ["大陆"], "叶子未声明的 key 从父级补充")
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
