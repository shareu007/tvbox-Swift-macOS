import XCTest
@testable import TVBox

@MainActor
final class HomeBrowseFilterTests: XCTestCase {
    func testRecommendationCategoriesPreferDifferentFamiliesAndRecognizeAliases() {
        let categories = ["动作电影", "喜剧电影", "电影", "连续剧", "动画", "综艺"].map {
            MovieSort.SortData(id: $0, name: $0)
        }
        XCTAssertEqual(HomeViewModel.recommendationCategories(from: [.home()] + categories).map(\.name),
                       ["电影", "连续剧", "动画", "综艺"])
    }

    func testEmptySourceHomepageIsFilledFromCategoriesWithDeduplicatedBoundedPages() async {
        let source = SourceBean(key: "test", api: "https://example.com", type: 1)
        var pages: [Int] = []
        let model = HomeViewModel(currentSource: { source }, sortLoader: { _ in ([self.category], []) }) { _, _, page, _ in
            pages.append(page)
            return [Movie.Video(id: "shared"), Movie.Video(id: "page-\(page)")]
        }
        await model.refresh()
        XCTAssertTrue(model.selectedSort?.isRecommendation == true)
        XCTAssertEqual(pages, [1, 2])
        XCTAssertEqual(model.displayedVideos.map(\.id), ["shared", "page-1", "page-2"])
        XCTAssertEqual(model.recommendationSections.first?.title, "电视剧推荐")
        XCTAssertFalse(model.isLoadingRecommendations)
    }

    func testPopularRecommendationsAndMoreUseOnlyDeclaredHotFilter() async throws {
        let source = SourceBean(key: "test", api: "https://example.com", type: 1)
        var sort = category
        sort.filters.append(.init(key: "by", name: "排序", values: [.init(n: "最近更新", v: "time"), .init(n: "本周热门", v: "hits_week")]))
        var requests: [(Int, [String: String])] = []
        let model = HomeViewModel(currentSource: { source }, sortLoader: { _ in ([sort], []) }) { _, _, page, filters in
            requests.append((page, filters))
            return [Movie.Video(id: "\(page)")]
        }
        await model.refresh()
        let section = try XCTUnwrap(model.recommendationSections.first)
        XCTAssertEqual(section.title, "热门电视剧")
        XCTAssertTrue(requests.allSatisfy { $0.1 == ["by": "hits_week"] })
        await model.openRecommendation(section)?.value
        XCTAssertEqual(model.selectedSort?.id, sort.id)
        XCTAssertEqual(model.selectedFilters, ["by": "hits_week"])
        XCTAssertEqual(requests.last?.0, 1)
        XCTAssertEqual(requests.last?.1, ["by": "hits_week"])
        XCTAssertTrue(HomeViewModel.popularFilters(for: category).isEmpty)
        var unrelated = category
        unrelated.filters = [.init(key: "area", name: "地区", values: [.init(n: "热门地区", v: "hot")])]
        XCTAssertTrue(HomeViewModel.popularFilters(for: unrelated).isEmpty)
    }

    func testRecommendationFailureKeepsOtherSectionsAndRetryRecovers() async {
        let source = SourceBean(key: "test", api: "https://example.com", type: 1)
        var fail = true
        let model = HomeViewModel(currentSource: { source }, sortLoader: { _ in
            ([self.category, .init(id: "movie", name: "电影")], [Movie.Video(id: "featured")])
        }) { _, sort, page, _ in
            if sort.id == "drama", fail { throw URLError(.timedOut) }
            return (0..<12).map { Movie.Video(id: "\(sort.id)-\(page)-\($0)") }
        }
        await model.refresh()
        XCTAssertNotNil(model.recommendationSections.first { $0.sort.id == "drama" }?.errorMessage)
        XCTAssertEqual(model.recommendationSections.first { $0.sort.id == "movie" }?.videos.count, 12)
        XCTAssertEqual(model.homeVideos.first?.id, "featured")
        XCTAssertNil(model.errorMessage)
        fail = false
        await model.loadRecommendations()
        XCTAssertTrue(model.recommendationSections.allSatisfy { $0.errorMessage == nil && !$0.videos.isEmpty })
    }

    func testLateRecommendationsCannotOverwriteNewSource() async {
        var source = SourceBean(key: "old", api: "https://example.com", type: 1)
        let started = expectation(description: "Old recommendation request started")
        var finish: CheckedContinuation<Void, Never>?
        let model = HomeViewModel(currentSource: { source }, sortLoader: { _ in ([self.category], []) }) { source, _, _, _ in
            if source.key == "old" {
                await withCheckedContinuation { continuation in
                    finish = continuation
                    started.fulfill()
                }
            }
            return (0..<12).map { Movie.Video(id: "\(source.key)-\($0)", sourceKey: source.key) }
        }
        let old = Task { await model.refresh() }
        await fulfillment(of: [started], timeout: 2)
        source = SourceBean(key: "new", api: "https://example.com", type: 1)
        await model.refresh()
        finish?.resume()
        await old.value
        XCTAssertEqual(Set(model.displayedVideos.map(\.sourceKey)), ["new"])
        XCTAssertFalse(model.isLoadingRecommendations)
    }

    func testCancelledRecommendationsLeaveRetryableStateAndKeepFeaturedVideos() async {
        let source = SourceBean(key: "test", api: "https://example.com", type: 1)
        let started = expectation(description: "Recommendation started")
        var finish: CheckedContinuation<Void, Never>?
        let model = HomeViewModel(currentSource: { source }, sortLoader: { _ in
            ([self.category], [Movie.Video(id: "featured")])
        }) { _, _, _, _ in
            await withCheckedContinuation { continuation in
                finish = continuation
                started.fulfill()
            }
            return [Movie.Video(id: "late")]
        }
        let task = Task { await model.refresh() }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        finish?.resume()
        await task.value
        XCTAssertEqual(model.displayedVideos.map(\.id), ["featured"])
        XCTAssertFalse(model.isLoadingRecommendations)
        XCTAssertFalse(model.isLoading)
        XCTAssertNotNil(model.recommendationSections.first?.errorMessage)
    }

    func testCategoryRefreshDoesNotWaitForRecommendationsAndHomeLoadsOnSelection() async {
        let source = SourceBean(key: "test", api: "https://example.com", type: 1)
        var calls = 0
        let model = HomeViewModel(currentSource: { source }, sortLoader: { _ in ([self.category], []) }) { _, _, _, _ in
            calls += 1
            return (0..<12).map { Movie.Video(id: "\($0)") }
        }
        model.selectedSort = category
        await model.refresh()
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(model.recommendationSections.isEmpty)
        await model.selectSort(.home())?.value
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(model.displayedVideos.count, 12)
    }

    func testRecommendationRequestsAreBoundedAndDoNotFetchSecondLargePage() async {
        let source = SourceBean(key: "test", api: "https://example.com", type: 1)
        var active = 0
        var maximum = 0
        var calls = 0
        let categories = (0..<10).map { MovieSort.SortData(id: "\($0)", name: "分类\($0)") }
        let model = HomeViewModel(currentSource: { source }, sortLoader: { _ in (categories, []) }) { _, _, page, _ in
            calls += 1
            active += 1
            maximum = max(maximum, active)
            defer { active -= 1 }
            try await Task.sleep(nanoseconds: 10_000_000)
            XCTAssertEqual(page, 1)
            return (0..<50).map { Movie.Video(id: "\($0)") }
        }
        await model.refresh()
        XCTAssertEqual(calls, 4)
        XCTAssertLessThanOrEqual(maximum, 3)
        XCTAssertTrue(model.recommendationSections.allSatisfy { $0.videos.count == 24 })
    }

    func testPartialPageFailurePreservesFirstPageAndRepeatedPageIsDeduplicated() async {
        let source = SourceBean(key: "test", api: "https://example.com", type: 1)
        var fail = true
        let model = HomeViewModel(currentSource: { source }, sortLoader: { _ in ([self.category], []) }) { _, _, page, _ in
            if page == 2, fail { throw URLError(.timedOut) }
            return [Movie.Video(id: "same")]
        }
        await model.refresh()
        XCTAssertEqual(model.displayedVideos.count, 1)
        XCTAssertNotNil(model.recommendationSections.first?.errorMessage)
        fail = false
        await model.loadRecommendations()
        XCTAssertEqual(model.displayedVideos.count, 1)
        XCTAssertNil(model.recommendationSections.first?.errorMessage)
    }

    func testNumericYearMetadataCanBeFiltered() throws {
        let data = Data(#"{"vod_id":1,"vod_year":2024,"vod_area":"大陆/美国"}"#.utf8)
        let video = try JSONDecoder().decode(Movie.Video.self, from: data)
        XCTAssertEqual(HomeBrowseFacet.matching([video], selections: ["year": "2024", "area": "中国大陆"]).count, 1)
        XCTAssertTrue(HomeBrowseFacet.matching([video], selections: ["year": "2023"]).isEmpty)
    }

    func testVodClassFillsTypeWhenTypeNameMissing() throws {
        let video = try JSONDecoder().decode(Movie.Video.self, from: Data(#"{"vod_id":1,"vod_class":"动作,喜剧"}"#.utf8))
        XCTAssertEqual(video.type, "动作,喜剧")
        XCTAssertEqual(Set(HomeBrowseFacet.genre.values(in: video)), ["动作", "喜剧"])
        let preferred = try JSONDecoder().decode(Movie.Video.self, from: Data(#"{"vod_id":1,"type_name":"剧情","vod_class":"动作"}"#.utf8))
        XCTAssertEqual(preferred.type, "剧情", "type_name 优先于 vod_class")
    }

    func testGenreFacetNormalizesAliasesTraditionalAndSuffixes() {
        XCTAssertEqual(HomeBrowseFacet.canonicalGenre("驚悚片"), "惊悚")
        XCTAssertEqual(HomeBrowseFacet.canonicalGenre("动作片"), "动作")
        XCTAssertEqual(HomeBrowseFacet.canonicalGenre("纪录片"), "纪录片", "整词类型不应被剥掉「片」尾缀")
        XCTAssertEqual(HomeBrowseFacet.canonicalGenre("動漫"), "动画")
        XCTAssertEqual(HomeBrowseFacet.canonicalGenre("搞笑"), "喜剧")
        var video = Movie.Video(id: "v")
        video.type = "动作 / 喜剧片 · 科幻"
        XCTAssertEqual(HomeBrowseFacet.genre.values(in: video), ["动作", "喜剧", "科幻"])
    }

    func testGenreFacetSortsCanonicalGenresBeforeAlphabeticalTail() {
        var action = Movie.Video(id: "a"); action.type = "动作"
        var comedy = Movie.Video(id: "c"); comedy.type = "喜剧"
        var obscure = Movie.Video(id: "o"); obscure.type = "黑色电影"
        let filter = HomeBrowseFacet.genre.filter(sorts: [], videos: [obscure, comedy, action], selected: nil)
        XCTAssertEqual(filter.values.map(\.n).prefix(2), ["动作", "喜剧"], "常见类型按 Netflix 风格顺序排前")
        XCTAssertTrue(filter.values.map(\.n).contains("黑色电影"))
    }

    func testYearFacetRecognizesEraNamedAndKeyedFilters() {
        XCTAssertTrue(HomeBrowseFacet.year.recognizes(.init(key: "nianfen", name: "年代", values: [])))
        XCTAssertTrue(HomeBrowseFacet.year.recognizes(.init(key: "release_year", name: "上映", values: [])))
        XCTAssertFalse(HomeBrowseFacet.area.recognizes(.init(key: "nianfen", name: "年代", values: [])))
        XCTAssertTrue(HomeBrowseFacet.area.recognizes(.init(key: "region", name: "区域", values: [])))
        XCTAssertTrue(HomeBrowseFacet.genre.recognizes(.init(key: "class", name: "剧情", values: [])))
    }

    func testFacetsWithoutAnyValuesAreHiddenFromBrowseFilters() async {
        let source = SourceBean(key: "test", api: "https://example.com", type: 1)
        let movie = MovieSort.SortData(id: "movie", name: "电影")
        let model = HomeViewModel(currentSource: { source }, sortLoader: { _ in ([movie], []) }) { _, _, _, _ in
            [Movie.Video(id: "v")]
        }
        await model.refresh()
        XCTAssertTrue(model.browseFilters.isEmpty, "无年份/地区/类型信息时不应渲染空的筛选控件")
    }

    func testLeafMovieCategoriesProduceMovieRecommendationBeforeOtherFamilies() async {
        let source = SourceBean(key: "test", api: "https://example.com", type: 1)
        let categories = ["国产剧", "欧美剧", "动漫", "综艺", "动作片", "喜剧片"].map {
            MovieSort.SortData(id: $0, name: $0)
        }
        let model = HomeViewModel(currentSource: { source }, sortLoader: { _ in (categories, []) }) { _, sort, _, _ in
            [Movie.Video(id: sort.id)]
        }
        await model.refresh()
        XCTAssertEqual(model.recommendationSections.map(\.title), ["电影推荐", "电视剧推荐", "动漫推荐", "综艺推荐"])
        XCTAssertEqual(model.recommendationSections.first?.videos.first?.id, "动作片")
        XCTAssertTrue(model.recommendationSections.first?.subtitle.contains("动作片") == true)
    }

    func testHomeYearAndCountryMapDeclaredValuesAndMoreRetainsBothFilters() async throws {
        let source = SourceBean(key: "test", api: "https://example.com", type: 1)
        var movie = MovieSort.SortData(id: "movie", name: "电影")
        movie.filters = [
            .init(key: "release", name: "年份", values: [.init(n: "2024年", v: "y24")]),
            .init(key: "country", name: "国家", values: [.init(n: "内地", v: "cn")]),
            .init(key: "by", name: "排序", values: [.init(n: "热门", v: "hits")])
        ]
        var requests: [[String: String]] = []
        let model = HomeViewModel(currentSource: { source }, sortLoader: { _ in ([movie], []) }) { _, _, _, filters in
            requests.append(filters)
            return [Movie.Video(id: "movie")]
        }
        await model.refresh()
        XCTAssertEqual(model.browseFilters.map(\.name), ["年份", "国家/地区"])
        await model.selectFilter(key: "year", value: "2024")?.value
        await model.selectFilter(key: "area", value: "中国大陆")?.value
        XCTAssertEqual(requests.last, ["release": "y24", "country": "cn", "by": "hits"])
        XCTAssertEqual(model.displayedVideos.count, 1, "Server-filtered lists need not repeat metadata")
        let section = try XCTUnwrap(model.visibleRecommendationSections.first)
        await model.openRecommendation(section)?.value
        XCTAssertEqual(model.selectedFilters, ["release": "y24", "country": "cn", "by": "hits"])
        await model.loadMore()
        XCTAssertEqual(requests.last, ["release": "y24", "country": "cn", "by": "hits"])
        await model.selectSort(.home())?.value
        XCTAssertEqual(model.activeFilters, ["year": "2024", "area": "中国大陆"])
        await model.clearFilters()?.value
        XCTAssertEqual(requests.last, ["by": "hits"])
    }

    func testUndeclaredHomeFiltersMatchLoadedMetadataWithoutSendingGuessedParameters() async throws {
        let source = SourceBean(key: "test", api: "https://example.com", type: 1)
        let movie = MovieSort.SortData(id: "movie", name: "电影")
        var matching = Movie.Video(id: "matching")
        matching.year = "2024"; matching.area = "大陆 / 美国"
        var older = Movie.Video(id: "older")
        older.year = "2023"; older.area = "美国"
        let unknown = Movie.Video(id: "unknown")
        var requests: [[String: String]] = []
        let model = HomeViewModel(currentSource: { source }, sortLoader: { _ in ([movie], [older, unknown]) }) { _, _, _, filters in
            requests.append(filters)
            return [matching, older, unknown]
        }
        await model.refresh()
        let calls = requests.count
        await model.selectFilter(key: "year", value: "2024")?.value
        await model.selectFilter(key: "area", value: "中国大陆")?.value
        XCTAssertEqual(requests.count, calls)
        XCTAssertEqual(model.displayedVideos.map(\.id), ["matching"])
        XCTAssertTrue(model.filteredHomeVideos.isEmpty)
        XCTAssertFalse(model.visibleRecommendationSections[0].isPopular)
        await model.openRecommendation(try XCTUnwrap(model.visibleRecommendationSections.first))?.value
        XCTAssertEqual(model.activeFilters, ["year": "2024", "area": "中国大陆"])
        XCTAssertEqual(model.displayedVideos.map(\.id), ["matching"])
        XCTAssertTrue(requests.allSatisfy(\.isEmpty))
        await model.clearFilters()?.value
        XCTAssertEqual(model.displayedVideos.count, 3)
    }

    func testMoreKeepsLocalSelectionWhenCategoryDeclaresDifferentYearOptions() async throws {
        let source = SourceBean(key: "test", api: "https://example.com", type: 1)
        var movie = MovieSort.SortData(id: "movie", name: "电影")
        movie.filters = [.init(key: "year", name: "年份", values: [.init(n: "2023", v: "2023")])]
        var matching = Movie.Video(id: "matching")
        matching.year = "2024"
        let model = HomeViewModel(currentSource: { source }, sortLoader: { _ in ([movie], []) }) { _, _, _, filters in
            XCTAssertTrue(filters.isEmpty)
            return [matching, Movie.Video(id: "unknown")]
        }
        await model.refresh()
        await model.selectFilter(key: "year", value: "2024")?.value
        await model.openRecommendation(try XCTUnwrap(model.visibleRecommendationSections.first))?.value
        XCTAssertEqual(model.displayedVideos.map(\.id), ["matching"])
        XCTAssertEqual(model.browseFilters.first?.values.map(\.v), ["2024"])
    }

    func testLateYearResponseCannotReplaceNewerHomeFilter() async {
        let source = SourceBean(key: "test", api: "https://example.com", type: 1)
        var movie = MovieSort.SortData(id: "movie", name: "电影")
        movie.filters = [.init(key: "year", name: "年份", values: [.init(n: "2023", v: "2023"), .init(n: "2024", v: "2024")])]
        let started = expectation(description: "Old filter request started")
        var finish: CheckedContinuation<Void, Never>?
        let model = HomeViewModel(currentSource: { source }, sortLoader: { _ in ([movie], []) }) { _, _, _, filters in
            if filters["year"] == "2023" {
                await withCheckedContinuation { finish = $0; started.fulfill() }
            }
            return (0..<12).map { Movie.Video(id: "\(filters["year"] ?? "all")-\($0)") }
        }
        await model.refresh()
        let old = model.selectFilter(key: "year", value: "2023")
        await fulfillment(of: [started], timeout: 2)
        await model.selectFilter(key: "year", value: "2024")?.value
        finish?.resume()
        await old?.value
        XCTAssertTrue(model.displayedVideos.allSatisfy { $0.id.hasPrefix("2024-") })
        XCTAssertEqual(model.activeFilters, ["year": "2024"])
        XCTAssertFalse(model.isLoadingRecommendations)
    }

    private var category: MovieSort.SortData {
        var sort = MovieSort.SortData(id: "drama", name: "电视剧")
        sort.filters = [.init(key: "year", name: "年份", values: [.init(n: "2024", v: "2024")])]
        return sort
    }

    func testFilterIsPassedToEveryPageAndResetStartsAtPageOne() async {
        let source = SourceBean(key: "test", name: "Test", api: "https://example.com", type: 1)
        var requests: [(Int, [String: String])] = []
        let model = HomeViewModel(currentSource: { source }) { _, _, page, filters in
            requests.append((page, filters))
            return [Movie.Video(id: "page-\(page)")]
        }
        await model.selectSort(category)?.value
        await model.selectFilter(key: "year", value: "2024")?.value
        await model.loadMore()
        XCTAssertEqual(requests.map(\.0), [1, 1, 2])
        XCTAssertEqual(requests.last?.1, ["year": "2024"])
        XCTAssertEqual(model.categoryVideos.count, 2)
        await model.clearFilters()?.value
        XCTAssertEqual(requests.last?.0, 1)
        XCTAssertEqual(requests.last?.1, [:])
        XCTAssertEqual(model.categoryVideos.count, 1)
    }

    func testReselectingCategoryOrInvalidFilterDoesNotMakeRequests() async {
        let source = SourceBean(key: "test", api: "https://example.com", type: 1)
        var calls = 0
        let model = HomeViewModel(currentSource: { source }) { _, _, _, _ in
            calls += 1
            return [Movie.Video(id: "1")]
        }
        await model.selectSort(category)?.value
        XCTAssertNil(model.selectSort(category))
        XCTAssertNil(model.selectFilter(key: "unknown", value: "2024"))
        XCTAssertNil(model.selectFilter(key: "year", value: "1900"))
        XCTAssertEqual(calls, 1)
        await model.selectFilter(key: "year", value: "2024")?.value
        await model.selectSort(.init(id: "movie", name: "电影"))?.value
        XCTAssertTrue(model.selectedFilters.isEmpty)
    }

    func testSourceChangeMatchesCategoryNameInsteadOfUnrelatedReusedID() {
        let previous = MovieSort.SortData(id: "1", name: "电视剧")
        let categories = [MovieSort.SortData(id: "1", name: "电影"), MovieSort.SortData(id: "2", name: "电视剧")]
        XCTAssertEqual(HomeViewModel.preferredSort(previous: previous, available: categories, sameSource: false)?.id, "2")
    }

    func testCategoryLoadingUsesCurrentCategoryInsteadOfRecommendationContent() {
        let model = HomeViewModel()
        model.homeVideos = [Movie.Video(id: "home")]
        model.selectedSort = category
        XCTAssertTrue(model.displayedVideos.isEmpty)
        model.selectedSort = .home()
        XCTAssertEqual(model.displayedVideos.first?.id, "home")
    }

    func testRetryKeepsExistingPageAndRequestsFailedNextPage() async {
        let source = SourceBean(key: "test", api: "https://example.com", type: 1)
        var failNext = true
        var pages: [Int] = []
        let model = HomeViewModel(currentSource: { source }) { _, _, page, _ in
            pages.append(page)
            if page == 2 && failNext { throw URLError(.timedOut) }
            return [Movie.Video(id: "page-\(page)")]
        }
        await model.selectSort(category)?.value
        await model.loadMore()
        XCTAssertEqual(model.categoryVideos.count, 1)
        XCTAssertNotNil(model.errorMessage)
        failNext = false
        await model.retryCategoryPage()
        XCTAssertEqual(pages, [1, 2, 2])
        XCTAssertEqual(model.categoryVideos.count, 2)
        XCTAssertNil(model.errorMessage)
    }
}
