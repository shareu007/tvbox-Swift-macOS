import Foundation
import SwiftUI
import Combine

struct HomeRecommendationSection: Identifiable {
    let sort: MovieSort.SortData
    let filters: [String: String]
    var videos: [Movie.Video] = []
    var isLoading = true
    var errorMessage: String?
    var id: String { sort.id }
    var isPopular: Bool {
        let popular = HomeViewModel.popularFilters(for: sort)
        return !popular.isEmpty && popular.allSatisfy { filters[$0.key] == $0.value }
    }
    var title: String {
        let name = HomeViewModel.recommendationFamilyName(for: sort.name) ?? sort.name
        return isPopular ? "热门\(name)" : "\(name)推荐"
    }
    var subtitle: String { "\(sort.name) · " + (isPopular ? "按当前来源提供的热度排序" : "来自当前来源的分类内容") }
}

/// 首页 ViewModel
@MainActor
class HomeViewModel: ObservableObject {
    /// 分类列表（包含手动注入的"推荐"分类）。
    @Published var sorts: [MovieSort.SortData] = []
    /// 当前选中的分类。
    @Published var selectedSort: MovieSort.SortData?
    var categoryGroups: [HomeCategoryGroup] { HomeCategoryGroup.groups(from: sorts) }
    var selectedCategoryGroup: HomeCategoryGroup? {
        categoryGroups.first { group in group.categories.contains { $0.id == selectedSort?.id } }
    }

    @discardableResult
    func selectCategoryGroup(_ group: HomeCategoryGroup) -> Task<Void, Never>? {
        guard selectedCategoryGroup?.id != group.id, let category = group.defaultCategory else { return nil }
        return selectSort(category)
    }

    /// 首页推荐内容（对应"推荐"分类）。
    @Published var homeVideos: [Movie.Video] = []
    /// 普通分类的视频列表（分页加载）。
    @Published var categoryVideos: [Movie.Video] = []
    /// 页面加载状态（分类加载与分页共用）。
    @Published var isLoading = false
    /// 当前分类的分页页码。
    @Published var currentPage = 1
    /// 是否还有下一页。
    @Published var hasMore = true
    /// 错误提示文案。
    @Published var errorMessage: String?
    @Published private(set) var selectedFilters: [String: String] = [:]
    @Published private(set) var recommendationSections: [HomeRecommendationSection] = []
    @Published private(set) var isLoadingRecommendations = false
    @Published private(set) var recommendationFilters: [String: String] = [:]
    @Published private(set) var sourceRecoveryMessage: String?
    private var lastSuccessfulSource: SourceBean?
    private var unavailableSource: SourceBean?
    var activeFilters: [String: String] {
        selectedSort?.isRecommendation == true ? recommendationFilters : selectedFilters
    }
    var filteredHomeVideos: [Movie.Video] {
        HomeBrowseFacet.matching(homeVideos, selections: recommendationFilters)
    }
    var visibleRecommendationSections: [HomeRecommendationSection] {
        recommendationSections.map { section in
            var section = section
            section.videos = HomeBrowseFacet.matching(section.videos, selections: localRecommendationFilters(for: section.sort))
            return section
        }
    }
    var displayedVideos: [Movie.Video] {
        selectedSort?.isRecommendation == true
            ? Self.uniqueVideos(filteredHomeVideos + visibleRecommendationSections.flatMap(\.videos))
            : HomeBrowseFacet.matching(categoryVideos, selections: localCategoryFilters)
    }
    var browseFilters: [MovieSort.SortFilter] {
        if selectedSort?.isRecommendation == true {
            let videos = homeVideos + recommendationSections.flatMap(\.videos)
            return HomeBrowseFacet.allCases.map { $0.filter(sorts: sorts, videos: videos, selected: recommendationFilters[$0.rawValue]) }
        }
        guard let sort = selectedSort else { return [] }
        var filters = sort.filters
        for facet in HomeBrowseFacet.allCases {
            if let value = selectedFilters[facet.rawValue],
               !sort.filters.contains(where: { facet.recognizes($0) && $0.key == facet.rawValue && $0.values.contains(where: { $0.v == value }) }) {
                filters.removeAll(where: facet.recognizes)
            }
            if !filters.contains(where: facet.recognizes) {
                filters.append(facet.filter(sorts: [], videos: categoryVideos, selected: selectedFilters[facet.rawValue]))
            }
        }
        return filters
    }
    var filterScopeMessage: String {
        if selectedSort?.isRecommendation == true {
            if !isLoadingRecommendations, browseFilters.allSatisfy({ $0.values.isEmpty }) {
                return "当前来源未提供年份和国家/地区信息，可切换其他来源使用筛选。"
            }
            return "来源支持时筛选片库，其余仅筛选已加载影片；缺少信息的影片不计入结果。"
        }
        return localCategoryFilters.isEmpty ? "" : "当前条件仅筛选已加载影片，可继续加载更多；缺少信息的影片不计入结果。"
    }
    private var localCategoryFilters: [String: String] {
        guard let sort = selectedSort else { return [:] }
        var local: [String: String] = [:]
        for facet in HomeBrowseFacet.allCases {
            if let value = selectedFilters[facet.rawValue],
               !sort.filters.contains(where: { facet.recognizes($0) && $0.key == facet.rawValue && $0.values.contains(where: { $0.v == value }) }) {
                local[facet.rawValue] = value
            } else if let declared = sort.filters.first(where: facet.recognizes) {
                if currentSource()?.type == 0, let value = selectedFilters[declared.key],
                   let option = declared.values.first(where: { $0.v == value }) {
                    local[facet.rawValue] = facet.normalized(option.n)
                }
            } else if let value = selectedFilters[facet.rawValue] {
                local[facet.rawValue] = value
            }
        }
        return local
    }
    private func localRecommendationFilters(for sort: MovieSort.SortData) -> [String: String] {
        recommendationFilters.filter { key, value in
            guard let facet = HomeBrowseFacet(rawValue: key) else { return false }
            return currentSource()?.type == 0 || facet.sourceSelection(in: sort, value: value) == nil
        }
    }
    private func recommendationSourceFilters(for sort: MovieSort.SortData) -> [String: String] {
        guard currentSource()?.type != 0 else { return [:] }
        var filters = Self.popularFilters(for: sort)
        for facet in HomeBrowseFacet.allCases {
            if let value = recommendationFilters[facet.rawValue], let selection = facet.sourceSelection(in: sort, value: value) {
                filters[selection.key] = selection.value
            }
        }
        return filters
    }
    typealias SortLoader = @MainActor (SourceBean) async throws -> (sorts: [MovieSort.SortData], homeVideos: [Movie.Video])
    typealias ListLoader = @MainActor (SourceBean, MovieSort.SortData, Int, [String: String]) async throws -> [Movie.Video]
    private let sortLoader: SortLoader
    private let listLoader: ListLoader
    private let currentSource: @MainActor () -> SourceBean?
    private let fallbackSources: @MainActor () -> [SourceBean]
    private let selectHomeSource: @MainActor (SourceBean) -> Void
    private var loadedSourceKey: String?
    private var homeRequestID = UUID()
    private var recommendationRequestID = UUID()
    private var refreshRequestID = UUID()
    
    /// 标记上次加载是否因网络错误失败（用于网络恢复自动重试）。
    private var lastLoadFailedDueToNetwork = false
    private var networkRestoredCancellable: AnyCancellable?
    /// 当前分类请求。切换分类时主动取消，避免旧请求占用连接或覆盖新状态。
    private var categoryLoadTask: Task<Void, Never>?
    /// 分类请求代次。即使上游忽略取消，也只有最新一代可以回写界面。
    private var categoryRequestID = UUID()
    
    init(
        currentSource: @escaping @MainActor () -> SourceBean? = { ApiConfig.shared.homeSourceBean },
        fallbackSources: @escaping @MainActor () -> [SourceBean] = { ApiConfig.shared.sourceBeanList.filter { $0.isHomeEligible } },
        selectHomeSource: @escaping @MainActor (SourceBean) -> Void = { ApiConfig.shared.setHomeSource($0) },
        sortLoader: @escaping SortLoader = { try await SourceService.shared.getSort(sourceBean: $0, maxRetries: 0) },
        listLoader: @escaping ListLoader = { source, sort, page, filters in
            try await SourceService.shared.getList(sourceBean: source, sortData: sort, page: page, filters: filters)
        }
    ) {
        self.currentSource = currentSource
        self.fallbackSources = fallbackSources
        self.selectHomeSource = selectHomeSource
        self.sortLoader = sortLoader
        self.listLoader = listLoader
        setupNetworkRestoredAutoRetry()
    }
    
    /// 保留普通页面返回时的选择；设置页更换来源后必须重新加载分类。
    func refreshIfNeeded() async {
        guard sorts.isEmpty || loadedSourceKey != currentSource()?.key else { return }
        await refresh()
    }

    /// 加载分类列表
    func loadSorts() async {
        let requestID = UUID()
        homeRequestID = requestID
        recommendationRequestID = UUID()
        isLoadingRecommendations = false
        sourceRecoveryMessage = nil
        unavailableSource = nil
        guard let source = currentSource() else {
            sorts = []
            selectedSort = nil
            homeVideos = []
            recommendationSections = []
            recommendationFilters = [:]
            selectedFilters = [:]
            isLoading = false
            errorMessage = "请先在设置中配置首页来源"
            return
        }
        if loadedSourceKey != source.key {
            if loadedSourceKey != nil { selectedSort = .home() }
            selectedFilters = [:]
            recommendationFilters = [:]
            homeVideos = []
            recommendationSections = []
            sorts = []
        }
        isLoading = true
        defer { if homeRequestID == requestID, categoryLoadTask == nil { isLoading = false } }
        errorMessage = nil
        
        do {
            // 首页存在多个同类影视源；首轮失败时立即切换，避免在失效域名上重复等待。
            let result = try await sortLoader(source)
            guard homeRequestID == requestID, currentSource()?.key == source.key, !Task.isCancelled else { return }
            guard !result.sorts.isEmpty || !result.homeVideos.isEmpty else {
                throw SourceError.parseError("接口没有返回分类或影片")
            }
            applySortResult(result, sourceKey: source.key)
            lastLoadFailedDueToNetwork = false
        } catch {
            guard homeRequestID == requestID, currentSource()?.key == source.key, !Task.isCancelled else { return }
            await recoverUnavailableSource(source, homeRequest: requestID, reason: error.localizedDescription)
            lastLoadFailedDueToNetwork = errorMessage != nil && error.isNetworkConnectionError
            return
        }
        
        isLoading = false
        if errorMessage == nil, selectedSort?.isRecommendation == true { await loadRecommendations() }
    }

    private func applySortResult(
        _ result: (sorts: [MovieSort.SortData], homeVideos: [Movie.Video]),
        sourceKey: String
    ) {
        // 上游没有首页影片时，从分类补充内容，仍可进入推荐页。
        var allSorts = [MovieSort.SortData.home()]
        allSorts.append(contentsOf: result.sorts.filter { !$0.isRecommendation })

        sorts = allSorts
        homeVideos = Self.uniqueVideos(result.homeVideos)
        recommendationSections = []
        errorMessage = nil

        // 切源后尽量保留同名分类；若新源不存在该分类，则进入首个可用分类。
        selectedSort = Self.preferredSort(previous: selectedSort, available: allSorts, sameSource: loadedSourceKey == sourceKey)
        if loadedSourceKey != sourceKey {
            selectedFilters = [:]
            recommendationFilters = [:]
        }
        selectedFilters = selectedFilters.filter { key, value in
            browseFilters.contains { $0.key == key && $0.values.contains { $0.v == value } }
        }
        loadedSourceKey = sourceKey
    }

    /// 只使用上游明确声明的热度筛选，不向不支持的接口猜测参数。
    nonisolated static func popularFilters(for sort: MovieSort.SortData) -> [String: String] {
        for filter in sort.filters where ["by", "sort", "order", "orderby"].contains(filter.key.lowercased()) || filter.name.contains("排序") {
            if let hot = filter.values.first(where: { value in
                !value.v.isEmpty && (["热门", "热度", "人气", "点击", "播放", "最热"].contains { value.n.contains($0) }
                    || ["hits", "hits_day", "hits_week", "hits_month", "hot", "popularity"].contains(value.v.lowercased()))
            }) { return [filter.key: hot.v] }
        }
        return [:]
    }

    nonisolated static func recommendationFamilyName(for name: String) -> String? {
        HomeCategoryGroup.Family.matching(name)?.title
    }

    static func recommendationCategories(from sorts: [MovieSort.SortData]) -> [MovieSort.SortData] {
        var seen = Set<String>()
        let categories = sorts.filter { !$0.isRecommendation && seen.insert($0.id).inserted }
        // 电影优先；来源只提供叶子分类时也能识别动作片、喜剧片等电影内容。
        var selected: [MovieSort.SortData] = []
        for family in ["电影", "电视剧", "动漫", "综艺"] {
            let candidates = categories.filter { recommendationFamilyName(for: $0.name) == family }
            let match = candidates.first { [family, "连续剧", "动画", "影片"].contains($0.name) } ?? candidates.first
            if let match { selected.append(match) }
        }
        selected.append(contentsOf: categories.filter { category in !selected.contains { $0.id == category.id } })
        return Array(selected.prefix(4))
    }

    /// 每次最多三路分类请求；小分页额外补一页，总量有界且不执行播放/网盘转存。
    func loadRecommendations() async {
        guard let source = currentSource(), loadedSourceKey == source.key else { return }
        let requestID = UUID()
        recommendationRequestID = requestID
        let plans = Self.recommendationCategories(from: sorts).map {
            HomeRecommendationSection(sort: $0, filters: recommendationSourceFilters(for: $0))
        }
        recommendationSections = plans
        isLoadingRecommendations = !plans.isEmpty
        let loader = listLoader
        await withTaskGroup(of: HomeRecommendationSection.self) { group in
            var iterator = plans.makeIterator()
            func enqueue(_ plan: HomeRecommendationSection) {
                group.addTask { @MainActor in
                    var section = plan
                    do {
                        try Task.checkCancellation()
                        section.videos = Self.uniqueVideos(try await loader(source, plan.sort, 1, plan.filters))
                        if !section.videos.isEmpty, section.videos.count < 12 {
                            do {
                                try Task.checkCancellation()
                                guard self.recommendationRequestID == requestID, self.currentSource()?.key == source.key else {
                                    throw CancellationError()
                                }
                                let more = try await loader(source, plan.sort, 2, plan.filters)
                                section.videos = Self.uniqueVideos(section.videos + more)
                            } catch is CancellationError { throw CancellationError() }
                            catch { section.errorMessage = "部分内容未能加载，可重试或进入分类查看更多" }
                        }
                        section.videos = Array(section.videos.prefix(24))
                    } catch is CancellationError {
                        section.errorMessage = "加载已取消，请重试"
                    } catch {
                        section.errorMessage = "暂时无法加载，请重试或切换来源"
                    }
                    section.isLoading = false
                    return section
                }
            }
            for _ in 0..<3 { if let plan = iterator.next() { enqueue(plan) } }
            for await section in group {
                guard recommendationRequestID == requestID, currentSource()?.key == source.key, !Task.isCancelled else {
                    group.cancelAll()
                    break
                }
                if let index = recommendationSections.firstIndex(where: { $0.id == section.id }) {
                    recommendationSections[index] = section
                }
                if let plan = iterator.next() { enqueue(plan) }
            }
        }
        guard recommendationRequestID == requestID else { return }
        isLoadingRecommendations = false
        for index in recommendationSections.indices where recommendationSections[index].isLoading {
            recommendationSections[index].isLoading = false
            recommendationSections[index].errorMessage = "加载已取消，请重试"
        }
        guard !Task.isCancelled, currentSource()?.key == source.key else { return }
        if !homeVideos.isEmpty || recommendationSections.contains(where: { !$0.videos.isEmpty }) {
            lastSuccessfulSource = source
        } else if recommendationFilters.isEmpty, selectedSort?.isRecommendation == true {
            await recoverUnavailableSource(source, homeRequest: homeRequestID, recommendationRequest: requestID,
                                           reason: "来源未返回影片，首页和分类内容均不可用")
        }
    }

    @discardableResult
    func openRecommendation(_ section: HomeRecommendationSection) -> Task<Void, Never>? {
        guard let sort = sorts.first(where: { $0.id == section.sort.id }) else { return nil }
        selectedSort = sort
        selectedFilters = section.filters
        for (key, value) in localRecommendationFilters(for: sort) {
            selectedFilters[key] = value
        }
        return reloadSelectedCategory()
    }

    static func preferredSort(previous: MovieSort.SortData?, available: [MovieSort.SortData], sameSource: Bool) -> MovieSort.SortData? {
        guard let previous else { return available.first }
        if sameSource, let sameID = available.first(where: { $0.id == previous.id }) { return sameID }
        return available.first { $0.name == previous.name } ?? available.first
    }

    /// 空分类占位不代表来源可用；失败时只切换到实际返回影片的来源。
    private func recoverUnavailableSource(
        _ failedSource: SourceBean,
        homeRequest: UUID,
        recommendationRequest: UUID? = nil,
        reason: String
    ) async {
        guard homeRequestID == homeRequest, currentSource()?.key == failedSource.key, !Task.isCancelled else { return }
        isLoading = true
        sourceRecoveryMessage = "\(failedSource.name)暂时没有可用首页，正在尝试其他来源…"
        let fallback = await firstAvailableFallback(excluding: failedSource)
        guard homeRequestID == homeRequest, currentSource()?.key == failedSource.key, !Task.isCancelled,
              recommendationRequest == nil || recommendationRequestID == recommendationRequest else { return }
        isLoading = false
        guard let fallback else {
            sourceRecoveryMessage = nil
            errorMessage = "\(failedSource.name)暂时无法提供首页内容。\(reason)。请重试或切换其他来源。"
            if sorts.isEmpty { sorts = [.home()] }
            selectedSort = .home()
            return
        }
        selectHomeSource(fallback.source)
        selectedSort = .home()
        applySortResult(fallback.result, sourceKey: fallback.source.key)
        unavailableSource = failedSource
        sourceRecoveryMessage = "\(failedSource.name)暂时不可用，已切换到\(fallback.source.name)"
        lastLoadFailedDueToNetwork = false
        lastSuccessfulSource = fallback.source
        await loadRecommendations()
    }

    func retryUnavailableSource() async {
        guard let source = unavailableSource else { return }
        selectHomeSource(source)
        await refresh()
    }

    private typealias FallbackResult = (source: SourceBean, result: (sorts: [MovieSort.SortData], homeVideos: [Movie.Video]))

    private func firstAvailableFallback(excluding failedSource: SourceBean) async -> FallbackResult? {
        var tried = Set([failedSource.key])
        // 优先恢复用户刚才已经成功浏览的来源。
        if let previous = lastSuccessfulSource, tried.insert(previous.key).inserted {
            if let result = try? await loadFallback(previous) { return result }
        }
        guard !Task.isCancelled else { return nil }
        let candidates = fallbackSources().filter { tried.insert($0.key).inserted }
        // 可用来源可能位于配置末尾；限制并发数，而不是截断候选列表。
        // firstSuccessfulSource 最多同时检查三个来源，找到影片后取消其余请求。
        return await firstSuccessfulSource(in: candidates)
    }

    private func firstSuccessfulSource(in candidates: [SourceBean]) async -> FallbackResult? {
        await withTaskGroup(of: FallbackResult?.self) { group in
            var iterator = candidates.makeIterator()
            func enqueue(_ source: SourceBean) {
                group.addTask { try? await self.loadFallback(source) }
            }
            for _ in 0..<3 { if let source = iterator.next() { enqueue(source) } }
            for await fallback in group {
                if Task.isCancelled { group.cancelAll(); break }
                if let fallback {
                    group.cancelAll()
                    return fallback
                }
                if let source = iterator.next() { enqueue(source) }
            }
            return nil
        }
    }

    private func loadFallback(_ source: SourceBean) async throws -> FallbackResult {
        try Task.checkCancellation()
        var result = try await sortLoader(source)
        try Task.checkCancellation()
        if result.homeVideos.isEmpty {
            // 部分 Spider 首页只返回分类；验证前两个代表分类，不接受只有占位分类的空响应。
            for sort in Self.recommendationCategories(from: result.sorts).prefix(2) {
                try Task.checkCancellation()
                let filters = source.type == 0 ? [:] : Self.popularFilters(for: sort)
                if let videos = try? await listLoader(source, sort, 1, filters), !videos.isEmpty {
                    result.homeVideos = Array(Self.uniqueVideos(videos).prefix(24))
                    break
                }
            }
        }
        try Task.checkCancellation()
        guard !result.homeVideos.isEmpty else {
            throw SourceError.parseError("来源未返回可用影片")
        }
        return (source, result)
    }

    /// 网络恢复时，若上次因网络错误导致首页为空，自动重新加载。
    private func setupNetworkRestoredAutoRetry() {
        networkRestoredCancellable = NetworkMonitor.shared.networkRestoredPublisher
            .sink { [weak self] in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.lastLoadFailedDueToNetwork || (self.sorts.isEmpty && self.homeVideos.isEmpty) else { return }
                    await self.refresh()
                }
            }
    }
    
    /// 选择分类
    @discardableResult
    func selectSort(_ sort: MovieSort.SortData) -> Task<Void, Never>? {
        guard selectedSort?.id != sort.id else { return nil }
        cancelCategoryLoad()
        // 切分类时先重置分页状态，避免旧分类残留数据闪烁。
        selectedSort = sort
        selectedFilters = [:]
        errorMessage = nil
        categoryVideos = []
        currentPage = 1
        hasMore = true
        
        if sort.isRecommendation {
            guard recommendationSections.isEmpty else { return nil }
            return Task { await loadRecommendations() }
        } else {
            return beginCategoryLoad(page: 1, sort: sort)
        }
    }

    @discardableResult
    func selectFilter(key: String, value: String) -> Task<Void, Never>? {
        guard let sort = selectedSort,
              let filter = browseFilters.first(where: { $0.key == key }),
              value.isEmpty || filter.values.contains(where: { $0.v == value }),
              (activeFilters[key] ?? "") != value else { return nil }
        if sort.isRecommendation {
            recommendationFilters[key] = value.isEmpty ? nil : value
            return reloadRecommendations()
        }
        let previousLocal = localCategoryFilters
        selectedFilters[key] = value.isEmpty ? nil : value
        let isDeclaredValue = sort.filters.contains { $0.key == key && $0.values.contains { $0.v == value } }
        if (previousLocal[key] != nil && (value.isEmpty || !isDeclaredValue))
            || !sort.filters.contains(where: { $0.key == key }) { return nil }
        return reloadSelectedCategory()
    }

    @discardableResult
    func clearFilters() -> Task<Void, Never>? {
        guard !activeFilters.isEmpty else { return nil }
        if selectedSort?.isRecommendation == true {
            recommendationFilters = [:]
            return reloadRecommendations()
        }
        let onlyLocal = selectedFilters.keys.allSatisfy { localCategoryFilters[$0] != nil }
        selectedFilters = [:]
        return onlyLocal ? nil : reloadSelectedCategory()
    }

    private func reloadRecommendations() -> Task<Void, Never>? {
        if !recommendationSections.isEmpty,
           recommendationSections.allSatisfy({ $0.filters == recommendationSourceFilters(for: $0.sort) }) {
            return nil
        }
        recommendationRequestID = UUID()
        isLoading = false
        sourceRecoveryMessage = nil
        recommendationSections = []
        isLoadingRecommendations = true
        return Task { await loadRecommendations() }
    }

    private func reloadSelectedCategory() -> Task<Void, Never>? {
        guard let sort = selectedSort, !sort.isRecommendation else { return nil }
        cancelCategoryLoad()
        categoryVideos = []
        currentPage = 1
        hasMore = true
        errorMessage = nil
        return beginCategoryLoad(page: 1, sort: sort)
    }

    func retryCategoryPage() async {
        guard !isLoading, let sort = selectedSort else { return }
        errorMessage = nil
        hasMore = true
        await loadCategoryVideos(page: categoryVideos.isEmpty ? 1 : currentPage + 1, sort: sort)
    }

    private func cancelCategoryLoad() {
        categoryRequestID = UUID()
        categoryLoadTask?.cancel()
        categoryLoadTask = nil
        isLoading = false
    }

    @discardableResult
    private func beginCategoryLoad(
        page: Int,
        sort: MovieSort.SortData
    ) -> Task<Void, Never>? {
        guard !sort.isRecommendation,
              let source = currentSource() else { return nil }
        // 分页触发可能由多个卡片同时到达列表尾部，只保留第一个。
        if page > 1, isLoading { return nil }

        categoryLoadTask?.cancel()
        let requestID = UUID()
        categoryRequestID = requestID
        isLoading = true

        // 只把接口声明过的条件发给来源；合成的年份/地区选项在本地匹配。
        let filters = currentSource()?.type == 0 ? [:] : selectedFilters.filter { key, value in
            sort.filters.contains { $0.key == key && $0.values.contains { $0.v == value } }
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performCategoryLoad(
                page: page,
                sort: sort,
                source: source,
                requestID: requestID,
                filters: filters
            )
        }
        categoryLoadTask = task
        return task
    }
    
    /// 加载分类视频列表
    private func loadCategoryVideos(page: Int, sort: MovieSort.SortData) async {
        guard let task = beginCategoryLoad(page: page, sort: sort) else { return }
        await task.value
    }

    private func performCategoryLoad(
        page: Int,
        sort: MovieSort.SortData,
        source: SourceBean,
        requestID: UUID,
        filters: [String: String]
    ) async {
        defer {
            if categoryRequestID == requestID {
                isLoading = false
                categoryLoadTask = nil
            }
        }

        do {
            let videos = try await listLoader(source, sort, page, filters)
            try Task.checkCancellation()
            
            // 分类或数据源切换过程中，丢弃旧请求结果。
            guard categoryRequestID == requestID,
                  selectedSort?.id == sort.id,
                  currentSource()?.key == source.key else { return }
            
            if !videos.isEmpty { lastSuccessfulSource = source }
            if page == 1 {
                categoryVideos = Self.uniqueVideos(videos)
            } else {
                let existingIDs = Set(categoryVideos.map(\.id))
                let newVideos = videos.filter { !existingIDs.contains($0.id) }
                categoryVideos.append(contentsOf: Self.uniqueVideos(newVideos))
                // 接口忽略页码并重复返回同一页时，及时停止继续触底请求。
                if newVideos.isEmpty {
                    hasMore = false
                    return
                }
            }
            currentPage = page
            hasMore = !videos.isEmpty
        } catch is CancellationError {
            // 切换分类是正常取消，不展示错误。
        } catch {
            guard categoryRequestID == requestID,
                  selectedSort?.id == sort.id else { return }
            hasMore = false
            errorMessage = error.localizedDescription
        }
    }

    private static func uniqueVideos(_ videos: [Movie.Video]) -> [Movie.Video] {
        var seen = Set<String>()
        return videos.filter { video in
            let key = video.id.trimmingCharacters(in: .whitespacesAndNewlines)
            // 空 ID 无法安全判重，保留交给视图展示。
            return key.isEmpty || seen.insert(key).inserted
        }
    }
    
    /// 加载下一页
    func loadMore() async {
        guard let lastItem = categoryVideos.last else { return }
        await loadMoreIfNeeded(currentItem: lastItem)
    }
    
    /// 当最后一个元素出现时触发加载下一页
    func loadMoreIfNeeded(currentItem: Movie.Video) async {
        guard selectedSort?.isRecommendation != true else { return }
        guard hasMore, !isLoading else { return }
        guard categoryVideos.last?.id == currentItem.id else { return }
        guard let sort = selectedSort else { return }
        
        let nextPage = currentPage + 1
        await loadCategoryVideos(page: nextPage, sort: sort)
    }
    
    /// 刷新
    func refresh() async {
        let requestID = UUID()
        refreshRequestID = requestID
        cancelCategoryLoad()
        // 全量刷新时重置分页与错误态，再重新拉分类与当前分类内容。
        currentPage = 1
        hasMore = true
        categoryVideos = []
        errorMessage = nil
        await loadSorts()
        guard refreshRequestID == requestID, !Task.isCancelled else { return }
        // 用户已在推荐加载期间进入分类时，不重复覆盖正在浏览的分页结果。
        guard categoryLoadTask == nil, categoryVideos.isEmpty else { return }
        
        guard let sort = selectedSort else { return }
        if sort.isRecommendation { return }
        
        if let matchedSort = sorts.first(where: { $0.id == sort.id }) {
            selectedSort = matchedSort
            await loadCategoryVideos(page: 1, sort: matchedSort)
        } else if let firstCategory = sorts.first(where: { !$0.isRecommendation }) {
            selectedSort = firstCategory
            await loadCategoryVideos(page: 1, sort: firstCategory)
        }
    }
}
