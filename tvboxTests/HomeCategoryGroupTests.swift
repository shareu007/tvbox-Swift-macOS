import XCTest
@testable import TVBox

@MainActor
final class HomeCategoryGroupTests: XCTestCase {
    private let source = SourceBean(key: "test", api: "https://example.com", type: 1)

    func testMixedSourceCategoriesBecomeDistinctTopLevelGroupsWithoutLosingEntries() {
        let names = ["最近更新", "喜剧片", "动作片", "爱情片", "纪录片", "动画片", "电视剧", "综艺", "4K专区"]
        let categories = names.enumerated().map { MovieSort.SortData(id: String($0.offset), name: $0.element) }
        let groups = HomeCategoryGroup.groups(from: [.home()] + categories)
        XCTAssertEqual(groups.map(\.title), ["推荐", "电影", "电视剧", "综艺", "纪录片", "动漫", "最近更新", "4K专区"])
        XCTAssertEqual(groups.first { $0.title == "电影" }?.categories.map(\.name), ["喜剧片", "动作片", "爱情片"])
        XCTAssertEqual(Set(groups.flatMap(\.categories).map(\.id)), Set(([.home()] + categories).map(\.id)))
        XCTAssertEqual(HomeViewModel.recommendationFamilyName(for: "纪录片"), "纪录片")
    }

    func testIndependentFamiliesTakePriorityOverMovieAndSeriesWords() {
        XCTAssertEqual(HomeCategoryGroup.Family.matching("纪录电影"), .documentary)
        XCTAssertEqual(HomeCategoryGroup.Family.matching("电影解说"), .commentary)
        XCTAssertEqual(HomeCategoryGroup.Family.matching("動畫電影"), .animation)
        XCTAssertEqual(HomeCategoryGroup.Family.matching("短剧"), .shortDrama)
        XCTAssertEqual(HomeCategoryGroup.Family.matching("日韓劇"), .series)
        XCTAssertEqual(HomeCategoryGroup.Family.matching("喜劇片"), .movie)
    }

    func testGroupPrefersSourceMovieCategoryWhenAvailableAndDoesNotDuplicateAliases() throws {
        let categories = ["动作片", "电影", "喜剧片"].map { MovieSort.SortData(id: $0, name: $0) }
        let groups = HomeCategoryGroup.groups(from: categories + [categories[0]])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].categories.count, 3)
        XCTAssertEqual(groups[0].defaultCategory?.id, "电影")
    }

    func testGroupAndSubcategoryRequestsUseOriginalIDsAndKeepYearFilterPagination() async throws {
        var action = MovieSort.SortData(id: "action-real-id", name: "动作片")
        action.filters = [.init(key: "year", name: "年份", values: [.init(n: "2024", v: "2024")])]
        let comedy = MovieSort.SortData(id: "comedy-real-id", name: "喜剧片")
        let documentary = MovieSort.SortData(id: "doc-real-id", name: "纪录片")
        var requests: [(String, Int, [String: String])] = []
        let model = HomeViewModel(currentSource: { self.source }) { _, sort, page, filters in
            requests.append((sort.id, page, filters))
            return [Movie.Video(id: "\(sort.id)-\(page)")]
        }
        model.sorts = [.home(), comedy, action, documentary]
        let movies = try XCTUnwrap(model.categoryGroups.first { $0.title == "电影" })
        await model.selectCategoryGroup(movies)?.value
        XCTAssertEqual(requests.last?.0, comedy.id)
        await model.selectSort(action)?.value
        XCTAssertEqual(model.selectedCategoryGroup?.title, "电影")
        XCTAssertNil(model.selectCategoryGroup(movies), "Reselecting the parent must preserve its selected child")
        await model.selectFilter(key: "year", value: "2024")?.value
        await model.loadMore()
        XCTAssertEqual(requests.last?.0, action.id)
        XCTAssertEqual(requests.last?.1, 2)
        XCTAssertEqual(requests.last?.2, ["year": "2024"])
        await model.selectCategoryGroup(try XCTUnwrap(model.categoryGroups.first { $0.title == "纪录片" }))?.value
        XCTAssertEqual(requests.last?.0, documentary.id)
        XCTAssertTrue(model.selectedFilters.isEmpty)
        XCTAssertEqual(model.selectedCategoryGroup?.title, "纪录片")
    }

    func testRecommendationMoreHighlightsItsParentGroup() async throws {
        let action = MovieSort.SortData(id: "action", name: "动作片")
        let model = HomeViewModel(currentSource: { self.source }) { _, _, _, _ in [] }
        model.sorts = [.home(), action]
        model.selectedSort = .home()
        await model.openRecommendation(.init(sort: action, filters: [:]))?.value
        XCTAssertEqual(model.selectedCategoryGroup?.title, "电影")
        XCTAssertEqual(model.selectedSort?.id, action.id)
    }
}
