import Foundation
import SwiftUI
import Combine

/// 首页 ViewModel
@MainActor
class HomeViewModel: ObservableObject {
    /// 分类列表（包含手动注入的"推荐"分类）。
    @Published var sorts: [MovieSort.SortData] = []
    /// 当前选中的分类。
    @Published var selectedSort: MovieSort.SortData?
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
    
    /// 源数据访问服务。
    private let sourceService = SourceService.shared
    /// 标记上次加载是否因网络错误失败（用于网络恢复自动重试）。
    private var lastLoadFailedDueToNetwork = false
    private var networkRestoredCancellable: AnyCancellable?
    /// 当前分类请求。切换分类时主动取消，避免旧请求占用连接或覆盖新状态。
    private var categoryLoadTask: Task<Void, Never>?
    /// 分类请求代次。即使上游忽略取消，也只有最新一代可以回写界面。
    private var categoryRequestID = UUID()
    
    init() {
        setupNetworkRestoredAutoRetry()
    }
    
    /// 加载分类列表
    func loadSorts() async {
        guard let source = ApiConfig.shared.homeSourceBean else { return }
        isLoading = true
        errorMessage = nil
        
        do {
            // 首页存在多个同类影视源；首轮失败时立即切换，避免在失效域名上重复等待。
            let result = try await sourceService.getSort(sourceBean: source, maxRetries: 0)
            guard !result.sorts.isEmpty || !result.homeVideos.isEmpty else {
                throw SourceError.parseError("接口没有返回分类或影片")
            }
            applySortResult(result)
            lastLoadFailedDueToNetwork = false
        } catch {
            if let fallback = await firstAvailableFallback(excluding: source) {
                ApiConfig.shared.setHomeSource(fallback.source)
                applySortResult(fallback.result)
                lastLoadFailedDueToNetwork = false
            } else {
                errorMessage = error.localizedDescription
                lastLoadFailedDueToNetwork = error.isNetworkConnectionError
            }
        }
        
        isLoading = false
    }

    private func applySortResult(
        _ result: (sorts: [MovieSort.SortData], homeVideos: [Movie.Video])
    ) {
        // 只有上游确实返回首页内容时才显示“推荐”，避免默认落入空白页。
        var allSorts: [MovieSort.SortData] = result.homeVideos.isEmpty
            ? []
            : [MovieSort.SortData.home()]
        allSorts.append(contentsOf: result.sorts)

        sorts = allSorts
        homeVideos = result.homeVideos
        errorMessage = nil

        // 切源后尽量保留同名分类；若新源不存在该分类，则进入首个可用分类。
        selectedSort = selectedSort.flatMap { selected in
            allSorts.first(where: { $0.id == selected.id })
        } ?? allSorts.first
    }

    private func firstAvailableFallback(
        excluding failedSource: SourceBean
    ) async -> (
        source: SourceBean,
        result: (sorts: [MovieSort.SortData], homeVideos: [Movie.Video])
    )? {
        let candidates = ApiConfig.shared.sourceBeanList.filter {
            $0.key != failedSource.key
                && $0.isSupportedInSwift
                && [0, 1, 4].contains($0.type)
        }
        let nonBaofeng = candidates.filter {
            !$0.key.contains("暴風") && !$0.name.contains("暴風")
        }

        if let fallback = await firstSuccessfulSource(in: Array(nonBaofeng.prefix(6))) {
            return fallback
        }
        let baofeng = candidates.first {
            $0.key.contains("暴風") || $0.name.contains("暴風")
        }
        guard let baofeng else { return nil }
        return try? await loadFallback(baofeng)
    }

    private func firstSuccessfulSource(
        in candidates: [SourceBean]
    ) async -> (
        source: SourceBean,
        result: (sorts: [MovieSort.SortData], homeVideos: [Movie.Video])
    )? {
        await withTaskGroup(
            of: (SourceBean, (sorts: [MovieSort.SortData], homeVideos: [Movie.Video]))?.self
        ) { group in
            for source in candidates {
                group.addTask { [sourceService] in
                    try? await self.loadFallback(source, using: sourceService)
                }
            }
            for await fallback in group {
                if let fallback {
                    group.cancelAll()
                    return (fallback.0, fallback.1)
                }
            }
            return nil
        }
    }

    private func loadFallback(
        _ source: SourceBean,
        using service: SourceService? = nil
    ) async throws -> (
        SourceBean,
        (sorts: [MovieSort.SortData], homeVideos: [Movie.Video])
    ) {
        let result = try await (service ?? sourceService).getSort(sourceBean: source, maxRetries: 0)
        guard !result.sorts.isEmpty || !result.homeVideos.isEmpty else {
            throw SourceError.parseError("接口没有返回分类或影片")
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
    func selectSort(_ sort: MovieSort.SortData) {
        cancelCategoryLoad()
        // 切分类时先重置分页状态，避免旧分类残留数据闪烁。
        selectedSort = sort
        errorMessage = nil
        categoryVideos = []
        currentPage = 1
        hasMore = true
        
        if sort.isRecommendation {
            return
        } else {
            _ = beginCategoryLoad(page: 1, sort: sort)
        }
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
              let source = ApiConfig.shared.homeSourceBean else { return nil }
        // 分页触发可能由多个卡片同时到达列表尾部，只保留第一个。
        if page > 1, isLoading { return nil }

        categoryLoadTask?.cancel()
        let requestID = UUID()
        categoryRequestID = requestID
        isLoading = true

        let task = Task { @MainActor [weak self, sourceService] in
            guard let self else { return }
            await self.performCategoryLoad(
                page: page,
                sort: sort,
                source: source,
                requestID: requestID,
                service: sourceService
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
        service: SourceService
    ) async {
        defer {
            if categoryRequestID == requestID {
                isLoading = false
                categoryLoadTask = nil
            }
        }

        do {
            let videos = try await service.getList(
                sourceBean: source,
                sortData: sort,
                page: page
            )
            try Task.checkCancellation()
            
            // 分类或数据源切换过程中，丢弃旧请求结果。
            guard categoryRequestID == requestID,
                  selectedSort?.id == sort.id,
                  ApiConfig.shared.homeSourceBean?.key == source.key else { return }
            
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
        cancelCategoryLoad()
        // 全量刷新时重置分页与错误态，再重新拉分类与当前分类内容。
        currentPage = 1
        hasMore = true
        categoryVideos = []
        errorMessage = nil
        await loadSorts()
        
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
