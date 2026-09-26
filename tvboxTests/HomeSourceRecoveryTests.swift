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
        let model = HomeViewModel(currentSource: { current }, fallbackSources: { [good, empty] }, selectHomeSource: { current = $0 }, sortLoader: { _ in
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

    func testRecoveryReachesUsableSourceAfterFirstSixEmptyCandidates() async {
        let empty = source("empty")
        let unavailable = (1...7).map { source("unavailable-\($0)") }
        let usable = source("usable")
        var current = empty
        var probedKeys = Set<String>()
        let model = HomeViewModel(
            currentSource: { current },
            fallbackSources: { [empty] + unavailable + [usable] },
            selectHomeSource: { current = $0 },
            sortLoader: { candidate in
                probedKeys.insert(candidate.key)
                return ([.init(id: "recent", name: "最近更新")], [])
            },
            listLoader: { candidate, _, _, _ in
                candidate.key == usable.key ? [Movie.Video(id: "movie", sourceKey: candidate.key)] : []
            }
        )

        await model.refresh()

        XCTAssertTrue(probedKeys.contains(usable.key))
        XCTAssertEqual(current.key, usable.key)
        XCTAssertEqual(model.displayedVideos.map(\.id), ["movie"])
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.sourceRecoveryMessage?.contains(usable.name) == true)
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

    func testLaterPopulatedCategoryKeepsSelectedSource() async {
        let current = source("current")
        let categories = (1...5).map { MovieSort.SortData(id: "c\($0)", name: "栏目\($0)") }
        let model = HomeViewModel(currentSource: { current }, fallbackSources: { [] }, selectHomeSource: { _ in XCTFail("Must keep source") }, sortLoader: { _ in (categories, []) }) { _, sort, _, _ in
            sort.id == "c5" ? [Movie.Video(id: "fifth")] : []
        }
        await model.refresh()
        XCTAssertEqual(model.displayedVideos.map(\.id), ["fifth"])
        XCTAssertNil(model.errorMessage)
    }

    func testEmptyPopularOrderRetriesDefaultList() async {
        let current = source("current")
        var category = MovieSort.SortData(id: "movie", name: "电影")
        category.filters = [.init(key: "by", name: "排序", values: [.init(n: "热门", v: "hits")])]
        let model = HomeViewModel(currentSource: { current }, fallbackSources: { [] }, selectHomeSource: { _ in XCTFail("Must keep source") }, sortLoader: { _ in ([category], []) }) { _, _, _, filters in
            filters["by"] == nil ? [Movie.Video(id: "latest")] : []
        }
        await model.refresh()
        XCTAssertEqual(model.displayedVideos.map(\.id), ["latest"])
        XCTAssertEqual(model.recommendationSections.first?.isPopular, false)
        XCTAssertNil(model.errorMessage)
    }

    func testSameSourceKeyWithNewEndpointReloadsHomepage() async {
        var current = SourceBean(key: "same", api: "https://first.example/api", type: 1)
        let model = HomeViewModel(currentSource: { current }, fallbackSources: { [] }, selectHomeSource: { _ in }, sortLoader: { source in
            ([], [Movie.Video(id: source.api)])
        }, listLoader: { _, _, _, _ in [] })
        await model.refresh()
        current = SourceBean(key: "same", api: "https://second.example/api", type: 1)
        await model.refreshIfNeeded()
        XCTAssertEqual(model.displayedVideos.map(\.id), [current.api])
    }

    func testRecoveryDoesNotReuseSourceFromPreviousConfiguration() async {
        let old = source("old")
        let empty = source("empty")
        var current = old
        let model = HomeViewModel(currentSource: { current }, fallbackSources: { [empty] }, selectHomeSource: { current = $0 }, sortLoader: { candidate in
            ([], candidate == old ? [Movie.Video(id: "old-video")] : [])
        }, listLoader: { _, _, _, _ in [] })
        await model.refresh()
        current = empty
        await model.refresh()
        XCTAssertEqual(current, empty)
        XCTAssertTrue(model.displayedVideos.isEmpty)
        XCTAssertNotNil(model.errorMessage)
    }

    func testDefaultOrderRetryRetainsSelectedYear() async {
        let current = source("current")
        var category = MovieSort.SortData(id: "movie", name: "电影")
        category.filters = [
            .init(key: "by", name: "排序", values: [.init(n: "热门", v: "hits")]),
            .init(key: "year", name: "年份", values: [.init(n: "2024", v: "2024")])
        ]
        var requests: [[String: String]] = []
        let model = HomeViewModel(currentSource: { current }, fallbackSources: { [] }, selectHomeSource: { _ in XCTFail("Must keep source") }, sortLoader: { _ in ([category], []) }) { _, _, _, filters in
            requests.append(filters)
            if filters["by"] != nil { throw URLError(.badServerResponse) }
            var video = Movie.Video(id: "film")
            video.year = "2024"
            return [video]
        }
        await model.refresh()
        requests = []
        await model.selectFilter(key: "year", value: "2024")?.value
        XCTAssertTrue(requests.contains(["by": "hits", "year": "2024"]))
        XCTAssertTrue(requests.contains(["year": "2024"]))
        XCTAssertTrue(requests.allSatisfy { $0["year"] == "2024" })
        XCTAssertEqual(model.recommendationSections.first?.filters, ["year": "2024"])
    }

    func testMovieRecommendationMixesLeafCategoriesWithoutDuplicates() async {
        let current = source("mixed")
        let categories = [MovieSort.SortData(id: "action", name: "动作片"), .init(id: "comedy", name: "喜剧片"), .init(id: "romance", name: "爱情片")]
        let model = HomeViewModel(currentSource: { current }, fallbackSources: { [] }, selectHomeSource: { _ in }, sortLoader: { _ in (categories, []) }) { _, sort, _, _ in
            [Movie.Video(id: "shared")] + (0..<12).map { Movie.Video(id: "\(sort.id)-\($0)") }
        }
        await model.refresh()
        let videos = model.recommendationSections.first?.videos ?? []
        XCTAssertTrue(videos.contains { $0.id.hasPrefix("comedy-") })
        XCTAssertTrue(videos.contains { $0.id.hasPrefix("romance-") })
        XCTAssertEqual(videos.count, Set(videos.map(\.id)).count)
        XCTAssertLessThanOrEqual(videos.count, 24)
    }

    func testMixedMovieCategoriesKeepRemoteAndLocalYearFilteringSeparate() async {
        let current = source("mixed-filter")
        var action = MovieSort.SortData(id: "action", name: "动作片")
        action.filters = [.init(key: "release", name: "年份", values: [.init(n: "2024", v: "y24")])]
        let comedy = MovieSort.SortData(id: "comedy", name: "喜剧片")
        var filteredRequests: [[String: String]] = []
        let model = HomeViewModel(currentSource: { current }, fallbackSources: { [] }, selectHomeSource: { _ in },
            sortLoader: { _ in ([action, comedy], []) }) { _, sort, _, filters in
                if sort.id == "action" {
                    filteredRequests.append(filters)
                    return [Movie.Video(id: "remote-without-metadata")]
                }
                var current = Movie.Video(id: "comedy-2024")
                current.year = "2024"
                var old = Movie.Video(id: "comedy-2023")
                old.year = "2023"
                return [current, old]
            }
        await model.refresh()
        await model.selectFilter(key: "year", value: "2024")?.value
        XCTAssertTrue(filteredRequests.contains(["release": "y24"]))
        XCTAssertEqual(Set(model.displayedVideos.map(\.id)), ["remote-without-metadata", "comedy-2024"])
    }

}
