import Foundation
import Combine

/// Read-only sampling; never switches configuration, resolves playback or auto-plays media.
@MainActor
final class SourceVerificationProbe: ObservableObject {
    @Published private(set) var checkingConfigID: String?
    @Published private(set) var completedCount = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var message: String?
    private let store: SourceVerificationStore
    private let home: HomeViewModel.SortLoader
    private let category: HomeViewModel.ListLoader
    private var budget: HomeLoadBudget?
    private var generation = UUID()

    init(store: SourceVerificationStore = .shared,
         home: @escaping HomeViewModel.SortLoader = { try await SourceService.shared.getSort(sourceBean: $0, maxRetries: 0) },
         category: @escaping HomeViewModel.ListLoader = { source, sort, page, filters in
             try await SourceService.shared.getList(sourceBean: source, sortData: sort, page: page, filters: filters)
         }) {
        self.store = store; self.home = home; self.category = category
    }

    func stop() {
        generation = UUID()
        budget?.cancel()
        budget = nil
        checkingConfigID = nil
        message = "已停止检测，已完成结果已保留"
    }

    func check(configURL: String, sources: [SourceBean], seconds: Double = 30, requestSeconds: Double = 6) async {
        stop()
        let token = UUID()
        generation = token
        let budget = HomeLoadBudget(seconds: seconds, requestSeconds: requestSeconds)
        self.budget = budget
        checkingConfigID = SourceVerificationStore.configID(configURL)
        completedCount = 0
        var seen = Set<String>()
        let candidates = sources.filter { $0.isHomeEligible && seen.insert(SourceVerificationStore.sourceID($0)).inserted }
        totalCount = candidates.count
        message = nil
        store.register(configURL: configURL, sources: sources)
        await withTaskGroup(of: (SourceBean, SourceVerificationStore.HomeState).self) { group in
            var iterator = candidates.makeIterator()
            func enqueue(_ source: SourceBean) {
                group.addTask { (source, await self.inspect(source, budget: budget)) }
            }
            for _ in 0..<3 { if let source = iterator.next() { enqueue(source) } }
            for await (source, state) in group {
                guard generation == token, !Task.isCancelled else { group.cancelAll(); break }
                store.recordHome(state, context: store.context(configURL: configURL, source: source))
                completedCount += 1
                if !budget.isFinished, let source = iterator.next() { enqueue(source) }
            }
        }
        guard generation == token else { return }
        let expired = budget.isExpired
        budget.cancel()
        self.budget = nil
        checkingConfigID = nil
        message = expired ? "已到检测时限；尚未检测的站点保留为未检测，可再次检测" : "检测结束；仅抽查首页及前三个分类，不代表全部影片均可播放"
    }

    private func inspect(_ source: SourceBean, budget: HomeLoadBudget) async -> SourceVerificationStore.HomeState {
        do {
            let result = try await budget.run { try await self.home(source) }
            if !result.homeVideos.isEmpty { return .content }
            var lastFailure: SourceVerificationStore.HomeState?
            for sort in result.sorts.filter({ !$0.isRecommendation }).prefix(3) {
                do {
                    let videos = try await budget.run { try await self.category(source, sort, 1, [:]) }
                    if !videos.isEmpty { return .content }
                } catch { lastFailure = Self.failureState(error) }
                if budget.isFinished { break }
            }
            return lastFailure ?? .empty
        } catch { return Self.failureState(error) }
    }

    private static func failureState(_ error: Error) -> SourceVerificationStore.HomeState {
        if error is HomeLoadBudget.Failure || (error as? URLError)?.code == .timedOut { return .timedOut }
        return .failed
    }
}
