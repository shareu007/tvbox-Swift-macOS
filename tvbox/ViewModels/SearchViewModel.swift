import Foundation
import SwiftUI

/// 搜索 ViewModel
@MainActor
class SearchViewModel: ObservableObject {
    /// 搜索关键词输入。
    @Published var keyword: String = ""
    /// 当前结果列表。
    @Published var results: [Movie.Video] = [] {
        didSet { groupedResults = SearchResultGroup.aggregate(results) }
    }
    @Published private(set) var groupedResults: [SearchResultGroup] = []
    @Published var resourceKind: ResourceKindFilter = .all
    var filteredGroups: [SearchResultGroup] {
        let cloudKeys = Set(ApiConfig.shared.sourceBeanList.filter(\.isSearchOnly).map(\.key))
        return groupedResults.filter { group in
            group.resources.contains { resourceKind.includes($0, cloudSourceKeys: cloudKeys) }
        }
    }
    /// 搜索加载状态，用于控制进度指示器。
    @Published var isSearching = false
    /// 本地搜索历史（最近在前）。
    @Published var searchHistory: [String] = []
    /// 搜索失败或空结果提示。
    @Published var errorMessage: String?
    
    /// 源数据服务（负责多源并发搜索）。
    private let sourceService = SourceService.shared
    /// 搜索请求序号（用于丢弃过期异步结果）。
    private var latestSearchRequestId: UUID = UUID()
    /// 当前搜索任务；新搜索会取消旧任务，避免后台继续占用连接。
    private var searchTask: Task<Void, Never>?
    
    /// 初始化时同步加载本地历史记录，确保搜索页首次渲染即可展示。
    init() {
        loadSearchHistory()
    }

    /// 提交搜索并取消尚未完成的旧请求。
    func submitSearch() {
        latestSearchRequestId = UUID()
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            await self?.search()
        }
    }
    
    /// 执行搜索
    func search() async {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let requestId = UUID()
        latestSearchRequestId = requestId
        
        isSearching = true
        errorMessage = nil
        results = []
        resourceKind = .all
        
        // 搜索一旦触发就先落历史，保持行为与移动端常见搜索体验一致。
        addToHistory(trimmed)
        
        // 走多源并发搜索，返回聚合后的影片列表。
        let videos = await sourceService.searchAll(keyword: trimmed) { [weak self] partialResults in
            guard let self, requestId == self.latestSearchRequestId else { return }
            self.results = partialResults
        }
        guard requestId == latestSearchRequestId else { return }
        self.results = videos
        
        if videos.isEmpty {
            errorMessage = "未找到相关内容"
        }
        
        isSearching = false
    }

    /// 清空当前搜索，并立即取消慢源任务。
    func clearSearch() {
        cancelSearch()
        keyword = ""
        results = []
        errorMessage = nil
    }

    /// 页面离开或用户清空输入时停止所有慢源请求，同时保留已经到达的结果。
    func cancelSearch() {
        latestSearchRequestId = UUID()
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }
    
    /// 在指定源搜索
    func searchInSource(_ source: SourceBean) async {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let requestId = UUID()
        latestSearchRequestId = requestId
        
        isSearching = true
        errorMessage = nil
        
        do {
            let videos = try await sourceService.search(sourceBean: source, keyword: trimmed)
            guard requestId == latestSearchRequestId else { return }
            self.results = videos
        } catch {
            guard requestId == latestSearchRequestId else { return }
            errorMessage = error.localizedDescription
        }
        
        isSearching = false
    }
    
    // MARK: - 搜索历史
    
    /// 从本地读取历史。
    private func loadSearchHistory() {
        searchHistory = UserDefaults.standard.stringArray(forKey: HawkConfig.SEARCH_HISTORY) ?? []
    }
    
    /// 新增历史项并去重，最多保留 20 条。
    private func addToHistory(_ keyword: String) {
        searchHistory.removeAll { $0 == keyword }
        searchHistory.insert(keyword, at: 0)
        if searchHistory.count > 20 {
            searchHistory = Array(searchHistory.prefix(20))
        }
        UserDefaults.standard.set(searchHistory, forKey: HawkConfig.SEARCH_HISTORY)
    }
    
    /// 清空历史。
    func clearHistory() {
        searchHistory = []
        UserDefaults.standard.removeObject(forKey: HawkConfig.SEARCH_HISTORY)
    }
    
    /// 删除单条历史。
    func removeFromHistory(_ keyword: String) {
        searchHistory.removeAll { $0 == keyword }
        UserDefaults.standard.set(searchHistory, forKey: HawkConfig.SEARCH_HISTORY)
    }
}
