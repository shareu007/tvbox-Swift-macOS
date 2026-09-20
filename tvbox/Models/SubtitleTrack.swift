import Foundation
import Combine

struct SubtitleTrack: Identifiable, Equatable {
    let id: Int
    let title: String
    var language: String? = nil
    var isForced = false

    static func preferred(in tracks: [SubtitleTrack], defaultID: Int? = nil,
                          languages: [String] = Locale.preferredLanguages) -> Int? {
        let preferredOrder = tracks.filter { !$0.isForced } + tracks.filter(\.isForced)
        if let chinese = preferredOrder.first(where: {
            let language = $0.language?.lowercased() ?? ""
            return language.hasPrefix("zh") || ["chi", "zho"].contains(language)
                || ["中文", "简体", "繁体", "chinese"].contains(where: $0.title.lowercased().contains)
        }) { return chinese.id }
        for language in languages {
            let prefix = language.lowercased().split(separator: "-").first.map(String.init) ?? language
            if let match = preferredOrder.first(where: { $0.language?.lowercased().hasPrefix(prefix) == true }) {
                return match.id
            }
        }
        return tracks.first(where: { $0.id == defaultID })?.id ?? tracks.first?.id
    }

    /// VLC 的禁用项和真实轨道共用数组；选择时必须使用轨道 ID，不能使用数组下标。
    static func vlcTracks(names: [String], indexes: [Int]) -> [SubtitleTrack] {
        var seen = Set<Int>()
        return indexes.enumerated().compactMap { offset, id in
            guard id >= 0, seen.insert(id).inserted else { return nil }
            let title = offset < names.count ? names[offset].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            return SubtitleTrack(id: id, title: title.isEmpty ? "字幕轨道 \(id)" : title)
        }
    }
}

enum SubtitleSelection: Equatable {
    case automatic
    case off
    case track(Int)
}

@MainActor
final class SubtitleState: ObservableObject {
    @Published var tracks: [SubtitleTrack] = []
    @Published var selection: SubtitleSelection = .automatic
    @Published var selectedTrackID: Int?
    @Published var isLoading = true
    @Published var unavailableMessage = "当前视频未提供可选字幕轨"

    func reset() {
        tracks = []
        selection = .automatic
        selectedTrackID = nil
        isLoading = true
        unavailableMessage = "当前视频未提供可选字幕轨"
    }

    func desiredTrackID(defaultID: Int? = nil) -> Int? {
        switch selection {
        case .automatic: return SubtitleTrack.preferred(in: tracks, defaultID: defaultID)
        case .off: return nil
        case .track(let id): return tracks.first { $0.id == id }?.id
        }
    }
}
