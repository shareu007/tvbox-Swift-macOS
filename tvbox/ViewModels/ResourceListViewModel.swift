import Foundation
import SwiftUI

enum ResourceStatusFilter: String, CaseIterable, Identifiable {
    case all = "全部状态"
    case ready = "已找到剧集"
    case playable = "抽检可用"
    case pending = "待确认"
    case issues = "检查未通过"
    var id: Self { self }

    func includes(_ state: ResourceCheckState?) -> Bool {
        switch self {
        case .all: return true
        case .ready: return state?.detail != nil
        case .playable: return state?.isPlayable == true
        case .pending:
            switch state {
            case nil, .checking: return true
            case .ready:
                if case .needsPlayback = state?.playback { return true }
                return state?.playback == .notChecked || (state?.playback.isVerified == true && state?.isPlayable != true)
            default: return false
            }
        case .issues:
            switch state {
            case .empty, .failed: return true
            default: return state?.playback.isFailure == true
            }
        }
    }
}

enum ResourceCheckState {
    case checking
    case ready(VodInfo, checkedAt: Date, playback: ResourcePlaybackVerification = .notChecked)
    case empty
    case failed(String)

    var detail: VodInfo? {
        if case .ready(let info, _, _) = self { return info }
        return nil
    }

    var checkedAt: Date? {
        if case .ready(_, let date, _) = self { return date }
        return nil
    }

    var playback: ResourcePlaybackVerification {
        if case .ready(_, _, let verification) = self { return verification }
        return .notChecked
    }

    var isPlayable: Bool { isPlayable(at: Date()) }

    func isPlayable(at date: Date) -> Bool {
        guard let checkedAt else { return false }
        return playback.isVerified && date.timeIntervalSince(checkedAt) < 60
    }

    func displayPriority(at date: Date) -> Int {
        if isPlayable(at: date) { return 0 }
        switch self {
        case .empty, .failed: return 2
        case .ready where playback.isFailure: return 2
        default: return 1
        }
    }

    var isComplete: Bool {
        if case .checking = self { return false }
        return true
    }

    var label: String {
        switch self {
        case .checking: return "正在检查剧集…"
        case .ready(let info, _, let verification):
            switch verification {
            case .notChecked: return "已找到剧集 · \(info.currentEpisodes.count) 集 · 尚未抽检播放"
            case .verified(let flag, let episode):
                return isPlayable ? "抽检可用 · \(flag) · \(episode)" : "抽检结果已过时，请重新检查"
            case .needsPlayback(let message): return "待播放确认：\(message)"
            case .failed(let message): return "播放抽检未通过：\(message)"
            }
        case .empty: return "未找到剧集，可重试或换一个资源"
        case .failed(let message): return "检查未通过：\(message)"
        }
    }
}

/// 仅检查用户打开的剧目，每次最多三路请求；读取目录不代表播放鉴权已通过。
@MainActor
final class ResourceListViewModel: ObservableObject {
    typealias DetailLoader = @MainActor (Movie.Video) async throws -> VodInfo?
    typealias PlaybackVerifier = @MainActor (VodInfo) async throws -> ResourcePlaybackVerification
    @Published private(set) var states: [String: ResourceCheckState] = [:]
    @Published private(set) var isChecking = false
    @Published private(set) var completedCount = 0
    @Published private(set) var totalCount = 0
    private let loadDetail: DetailLoader
    private let verify: PlaybackVerifier
    private let now: @MainActor () -> Date
    private var generation = UUID()
    private var ownedTask: Task<Void, Never>?

    init(now: @escaping @MainActor () -> Date = Date.init,
         verifyPlayback: @escaping PlaybackVerifier = ResourceListViewModel.verifyMedia,
         loadDetail: @escaping DetailLoader = ResourceListViewModel.fetchDetail) {
        self.loadDetail = loadDetail
        self.now = now
        self.verify = verifyPlayback
    }

    static func verifyMedia(_ info: VodInfo) async throws -> ResourcePlaybackVerification {
        guard let source = ApiConfig.shared.getSource(key: info.sourceKey) else {
            return .needsPlayback("来源配置已变化，请重新搜索")
        }
        return try await MediaAvailabilityService().verify(
            info: info, requiresPlayerResolution: source.isSearchOnly || (source.type == 3 && !MediaAvailabilityService.hasDirectMediaRoute(info))
        )
    }

    func playableCount(in resources: [Movie.Video], kind: ResourceKindFilter, cloudSourceKeys: Set<String>) -> Int {
        resources.filter {
            kind.includes($0, cloudSourceKeys: cloudSourceKeys) && states[$0.resourceID]?.isPlayable(at: now()) == true
        }.count
    }

    func sortedResources(_ resources: [Movie.Video]) -> [Movie.Video] {
        let date = now()
        return resources.enumerated().sorted { lhs, rhs in
            let left = states[lhs.element.resourceID]?.displayPriority(at: date) ?? 1
            let right = states[rhs.element.resourceID]?.displayPriority(at: date) ?? 1
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    func sortedGroups(_ groups: [SearchResultGroup], kind: ResourceKindFilter, cloudSourceKeys: Set<String>) -> [SearchResultGroup] {
        let date = now()
        let ranked = groups.enumerated().map { index, group in
            let rank = group.resources.filter { kind.includes($0, cloudSourceKeys: cloudSourceKeys) }
                .map { states[$0.resourceID]?.displayPriority(at: date) ?? 1 }.min() ?? 1
            return (index: index, group: group, rank: rank)
        }
        return ranked.sorted { $0.rank == $1.rank ? $0.index < $1.index : $0.rank < $1.rank }.map(\.group)
    }

    func startChecking(_ resources: [Movie.Video], refresh: Bool = false) {
        cancelChecking()
        ownedTask = Task { [weak self] in
            await self?.check(resources, refresh: refresh, verifyPlayback: true)
        }
    }

    func cancelChecking() {
        ownedTask?.cancel()
        ownedTask = nil
        generation = UUID()
        states = states.filter { $0.value.isComplete }
        isChecking = false
    }

    func retainResults(_ resources: [Movie.Video]) {
        if resources.isEmpty { cancelChecking() }
        let ids = Set(resources.map(\.resourceID))
        states = states.filter { ids.contains($0.key) }
    }

    static func fetchDetail(_ video: Movie.Video) async throws -> VodInfo? {
        guard let source = ApiConfig.shared.getSource(key: video.sourceKey) else {
            throw SourceError.parseError("该来源已移除，请重新搜索")
        }
        return try await SourceService.shared.getDetail(sourceBean: source, vodId: video.id, verifyResource: true)
    }

    func check(_ resources: [Movie.Video], refresh: Bool = false, verifyPlayback: Bool = false) async {
        guard !Task.isCancelled else { return }
        let token = UUID()
        generation = token
        isChecking = true
        var seen = Set<String>()
        let unique = resources.filter { seen.insert($0.resourceID).inserted }
        let previous = states
        let pending = unique.filter {
            guard !refresh, let state = states[$0.resourceID], let date = state.checkedAt else { return true }
            return self.now().timeIntervalSince(date) >= 60 || (verifyPlayback && !state.playback.wasChecked)
        }
        totalCount = unique.count
        completedCount = unique.count - pending.count
        for video in pending { states[video.resourceID] = .checking }
        let loader = loadDetail
        let now = now
        let verifier = verify
        await withTaskGroup(of: (String, ResourceCheckState).self) { group in
            var iterator = pending.makeIterator()
            func enqueue(_ video: Movie.Video) {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let cached = previous[video.resourceID]
                        let timestamp = await now()
                        let canReuse = !refresh && cached?.checkedAt.map { timestamp.timeIntervalSince($0) < 60 } == true
                        let info: VodInfo?
                        if canReuse { info = cached?.detail } else { info = try await loader(video) }
                        let state: ResourceCheckState
                        if var info, info.playFlags.contains(where: { !(info.playUrlMap[$0] ?? []).isEmpty }) {
                            let playback = verifyPlayback ? try await verifier(info) : (canReuse ? (cached?.playback ?? .notChecked) : .notChecked)
                            // 抽检备用线路成功时，详情页也应默认选择这条线路。
                            if case .verified(let flag, _) = playback, info.playFlags.contains(flag) {
                                info.playFlag = flag
                                info.playIndex = 0
                            }
                            state = .ready(info, checkedAt: await now(), playback: playback)
                        } else {
                            state = .empty
                        }
                        return (video.resourceID, state)
                    } catch {
                        // 超时、登录失效、提取码错误均不等同于分享过期。
                        return (video.resourceID, .failed(error.localizedDescription))
                    }
                }
            }
            for _ in 0..<3 {
                if let video = iterator.next() { enqueue(video) }
            }
            for await (id, state) in group {
                guard !Task.isCancelled, generation == token else {
                    group.cancelAll()
                    break
                }
                states[id] = state
                completedCount += 1
                if let video = iterator.next() { enqueue(video) }
            }
        }
        guard generation == token else { return }
        if Task.isCancelled {
            for video in pending {
                if case .checking = states[video.resourceID] { states[video.resourceID] = nil }
            }
        }
        isChecking = false
    }
}
