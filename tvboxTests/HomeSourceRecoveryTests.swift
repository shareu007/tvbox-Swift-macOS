import XCTest
@testable import TVBox

@MainActor
final class HomeSourceRecoveryTests: XCTestCase {
    private func source(_ key: String) -> SourceBean {
        SourceBean(key: key, name: key, api: "/spider/fixture/3", type: 3)
    }

    func testEmptySourceHomepageRecoversToSpiderSourceWithVerifiedMovies() async {
        let empty = source("empty")
        let usable = source("usable")
        var current = empty
        let model = HomeViewModel(currentSource: { current }, fallbackSources: { [empty, usable] }, selectHomeSource: { current = $0 }, sortLoader: { source in
            ([.init(id: "movie", name: "电影")], [])
        }) { source, _, _, _ in
            source.key == usable.key ? [Movie.Video(id: "movie-1", sourceKey: source.key)] : []
        }
        await model.refresh()
        XCTAssertEqual(current.key, usable.key)
        XCTAssertEqual(model.displayedVideos.map(\.sourceKey), [usable.key])
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.sourceRecoveryMessage?.contains(usable.name) == true)
    }

    func testSwitchingFromLoadedSourceToEmptySourceRestoresPreviousSource() async {
        let good = source("good")
        let empty = source("empty")
        var current = good
        let model = HomeViewModel(currentSource: { current }, fallbackSources: { [] }, selectHomeSource: { current = $0 }, sortLoader: { _ in
            ([.init(id: "movie", name: "电影")], [])
        }) { source, _, _, _ in
            source.key == good.key ? [Movie.Video(id: "good-movie", sourceKey: source.key)] : []
        }
        await model.refresh()
        current = empty
        await model.refresh()
        XCTAssertEqual(current.key, good.key)
        XCTAssertEqual(model.displayedVideos.map(\.id), ["good-movie"])
        XCTAssertTrue(model.selectedSort?.isRecommendation == true)
    }
    func testCandidatesWithOnlyEmptyCategoriesAreRejectedWithRetryableError() async {
        let empty = source("empty")
        let alsoEmpty = source("also-empty")
        var current = empty
        let model = HomeViewModel(currentSource: { current }, fallbackSources: { [alsoEmpty] }, selectHomeSource: { current = $0 }, sortLoader: { _ in
            ([.init(id: "recent", name: "最近更新")], [])
        }) { _, _, _, _ in [] }
        await model.refresh()
        XCTAssertEqual(current.key, empty.key)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.selectedSort?.isRecommendation == true)
    }

    func testFallbackChecksAnotherCategoryWhenItsFirstCategoryIsEmpty() async {
        let empty = source("empty")
        let usable = source("usable")
        var current = empty
        let model = HomeViewModel(currentSource: { current }, fallbackSources: { [usable] }, selectHomeSource: { current = $0 }, sortLoader: { _ in
            ([.init(id: "movie", name: "电影"), .init(id: "drama", name: "电视剧")], [])
        }) { source, sort, _, _ in
            source.key == usable.key && sort.id == "drama" ? [Movie.Video(id: "drama", sourceKey: source.key)] : []
        }
        await model.refresh()
        XCTAssertEqual(current.key, usable.key)
        XCTAssertEqual(model.displayedVideos.map(\.id), ["drama"])
    }

    func testEmptyFilteredRecommendationsDoNotSwitchAwayFromUserSource() async {
        let current = source("current")
        var sort = MovieSort.SortData(id: "movie", name: "电影")
        sort.filters = [.init(key: "year", name: "年份", values: [.init(n: "2024", v: "2024")])]
        var fallbackCalls = 0
        let model = HomeViewModel(currentSource: { current }, fallbackSources: { fallbackCalls += 1; return [] }, selectHomeSource: { _ in XCTFail("Must keep filtered source") }, sortLoader: { _ in
            ([sort], [])
        }) { _, _, _, filters in
            filters.isEmpty ? [Movie.Video(id: "movie")] : []
        }
        await model.refresh()
        await model.selectFilter(key: "year", value: "2024")?.value
        XCTAssertTrue(model.displayedVideos.isEmpty)
        XCTAssertEqual(fallbackCalls, 0)
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.sourceRecoveryMessage)
    }

    func testLateFallbackCannotOverrideAnotherSourceSelectedByUser() async {
        let empty = source("empty")
        let fallback = source("fallback")
        let chosen = source("chosen")
        var current = empty
        let started = expectation(description: "Fallback probe started")
        var finish: CheckedContinuation<Void, Never>?
        let model = HomeViewModel(currentSource: { current }, fallbackSources: { [fallback] }, selectHomeSource: { current = $0 }, sortLoader: { source in
            if source.key == fallback.key {
                await withCheckedContinuation { finish = $0; started.fulfill() }
            }
            return ([.init(id: "movie", name: "电影")], [])
        }) { source, _, _, _ in
            source.key == empty.key ? [] : [Movie.Video(id: source.key, sourceKey: source.key)]
        }
        let old = Task { await model.refresh() }
        await fulfillment(of: [started], timeout: 2)
        current = chosen
        await model.refresh()
        finish?.resume()
        await old.value
        XCTAssertEqual(current.key, chosen.key)
        XCTAssertEqual(model.displayedVideos.map(\.id), [chosen.key])
        XCTAssertNil(model.sourceRecoveryMessage)
        XCTAssertFalse(model.isLoading)
    }

    func testChangingSourceFromFilteredCategoryOpensNewHomepage() async throws {
        let first = source("first")
        let second = source("second")
        var current = first
        var sort = MovieSort.SortData(id: "movie", name: "电影")
        sort.filters = [.init(key: "year", name: "年份", values: [.init(n: "2024", v: "2024")])]
        let model = HomeViewModel(currentSource: { current }, fallbackSources: { [] }, selectHomeSource: { current = $0 }, sortLoader: { _ in ([sort], []) }) { source, _, _, _ in
            [Movie.Video(id: source.key, sourceKey: source.key)]
        }
        await model.refresh()
        await model.selectSort(sort)?.value
        await model.selectFilter(key: "year", value: "2024")?.value
        current = second
        await model.refresh()
        XCTAssertTrue(model.selectedSort?.isRecommendation == true)
        XCTAssertTrue(model.selectedFilters.isEmpty)
        XCTAssertEqual(model.displayedVideos.map(\.sourceKey), [second.key])
    }

}
