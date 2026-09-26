import Foundation
import Combine
import CryptoKit

/// Evidence is local and keyed by configuration plus full source identity; URLs/media titles are not stored.
@MainActor
final class SourceVerificationStore: ObservableObject {
    enum HomeState: String, Codable {
        case content, empty, timedOut, failed
        var title: String {
            switch self {
            case .content: return "首页有内容"
            case .empty: return "抽查未返回内容"
            case .timedOut: return "检测超时"
            case .failed: return "请求失败"
            }
        }
    }
    struct Context: Equatable { let configID: String; let sourceID: String }
    struct Site: Codable, Identifiable { let id: String; let name: String }
    struct Evidence: Codable {
        var home: HomeState?
        var homeCheckedAt: Date?
        var playedAt: Date?
    }
    struct Report: Codable {
        let configID: String
        var sites: [Site]
        var evidence: [String: Evidence]
        var updatedAt: Date
        var checkedCount: Int { evidence.values.filter { $0.home != nil }.count }
        var contentCount: Int { evidence.values.filter { $0.home == .content }.count }
        var playedCount: Int { evidence.values.filter { $0.playedAt != nil }.count }
        var lastHomeCheck: Date? { evidence.values.compactMap(\.homeCheckedAt).max() }
        var lastPlayback: Date? { evidence.values.compactMap(\.playedAt).max() }
        var homeSummary: String {
            guard checkedCount > 0 else { return "首页实测：未检测" }
            return "首页实测：\(contentCount) 个有内容 / 已测 \(checkedCount)，\(max(0, sites.count - checkedCount)) 个未测"
        }
        var playbackSummary: String {
            playedCount == 0 ? "播放实测：未验证" : "播放实测：\(playedCount) 个站点曾有成功样本（非全片库）"
        }
    }

    static let shared = SourceVerificationStore(
        persisted: PrivateSettingsStore.value(for: .sourceVerification),
        persist: { try PrivateSettingsStore.save($0, for: .sourceVerification) })
    @Published private(set) var reports: [Report]
    @Published private(set) var persistenceFailed = false
    private let persist: ((String) throws -> Void)?

    init(persisted: String = "", persist: ((String) throws -> Void)? = nil) {
        reports = (try? JSONDecoder().decode([Report].self, from: Data(persisted.utf8))) ?? []
        self.persist = persist
    }

    static func configID(_ url: String) -> String { digest(Data(ApiConfig.normalizeConfigUrl(url).utf8)) }
    static func sourceID(_ source: SourceBean) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return digest((try? encoder.encode(source)) ?? Data())
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func report(for url: String) -> Report? { reports.first { $0.configID == Self.configID(url) } }

    /// Updating the catalog retains evidence only for unchanged sources.
    func register(configURL: String, sources: [SourceBean]) {
        guard !configURL.isEmpty else { return }
        let id = Self.configID(configURL)
        var seen = Set<String>()
        let sites = sources.filter(\.isHomeEligible).compactMap { source -> Site? in
            let id = Self.sourceID(source)
            return seen.insert(id).inserted ? Site(id: id, name: source.name) : nil
        }
        let old = report(for: configURL)
        let valid = Set(sites.map(\.id))
        let evidence = (old?.evidence ?? [:]).filter { valid.contains($0.key) }
        let report = Report(configID: id, sites: sites, evidence: evidence, updatedAt: old?.updatedAt ?? Date())
        reports.removeAll { $0.configID == id }
        reports.insert(report, at: 0)
        save()
    }

    func context(configURL: String, source: SourceBean) -> Context {
        .init(configID: Self.configID(configURL), sourceID: Self.sourceID(source))
    }

    func recordHome(_ state: HomeState, context: Context, at date: Date = Date()) {
        update(context, at: date) { evidence in
            evidence.home = state
            evidence.homeCheckedAt = date
        }
    }

    func recordPlayback(context: Context, at date: Date = Date()) {
        update(context, at: date) { $0.playedAt = date }
    }

    func remove(configURL: String) {
        reports.removeAll { $0.configID == Self.configID(configURL) }
        save()
    }

    private func update(_ context: Context, at date: Date, mutate: (inout Evidence) -> Void) {
        guard let index = reports.firstIndex(where: { $0.configID == context.configID }),
              reports[index].sites.contains(where: { $0.id == context.sourceID }) else { return }
        var evidence = reports[index].evidence[context.sourceID] ?? Evidence()
        mutate(&evidence)
        reports[index].evidence[context.sourceID] = evidence
        reports[index].updatedAt = date
        save()
    }

    private func save() {
        guard let persist else { return }
        reports = Array(reports.prefix(8))
        do {
            var data = try JSONEncoder().encode(reports)
            while data.count > 60 * 1024, !reports.isEmpty {
                reports.removeLast()
                data = try JSONEncoder().encode(reports)
            }
            try persist(String(decoding: data, as: UTF8.self))
            persistenceFailed = false
        } catch { persistenceFailed = true }
    }
}

/// A seek/resume position, paused callback or resolved URL alone is not playback evidence.
struct PlaybackProgressEvidence {
    private var playbackID: String?
    private var previous: (seconds: Double, date: Date)?
    private var advancingSeconds: Double = 0
    private var elapsedSeconds: Double = 0
    private var recorded = false

    mutating func observe(playbackID: String, seconds: Double, playing: Bool, at date: Date = Date()) -> Bool {
        if self.playbackID != playbackID {
            self = Self()
            self.playbackID = playbackID
        }
        guard !recorded else { return false }
        guard playing, seconds.isFinite, seconds >= 0 else {
            previous = nil; advancingSeconds = 0; elapsedSeconds = 0
            return false
        }
        defer { previous = (seconds, date) }
        guard let previous else { return false }
        let elapsed = date.timeIntervalSince(previous.date)
        let delta = seconds - previous.seconds
        guard elapsed > 0, elapsed <= 3, delta > 0, delta <= elapsed * 4 + 0.5 else {
            advancingSeconds = 0; elapsedSeconds = 0
            return false
        }
        advancingSeconds += delta
        elapsedSeconds += elapsed
        if advancingSeconds >= 3, elapsedSeconds >= 2 {
            recorded = true
            return true
        }
        return false
    }
}
