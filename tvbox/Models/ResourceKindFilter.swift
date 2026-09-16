import Foundation

enum ResourceKindFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case online = "在线影视"
    case cloud = "网盘分享"
    var id: Self { self }
    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .online: return "play.rectangle"
        case .cloud: return "externaldrive"
        }
    }

    func includes(_ video: Movie.Video, cloudSourceKeys: Set<String>) -> Bool {
        let isCloud = cloudSourceKeys.contains(video.sourceKey) || video.sourceKey == SourceBean.cloudPanKey
        switch self {
        case .all: return true
        case .online: return !isCloud
        case .cloud: return isCloud
        }
    }
}
