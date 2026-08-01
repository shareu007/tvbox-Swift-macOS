import Foundation

/// 视频详情模型 - 对应 Android 版 VodInfo.java
struct VodInfo: Codable, Identifiable {
    /// 视频唯一 ID。
    var id: String
    /// 标题。
    var name: String = ""
    /// 海报地址。
    var pic: String = ""
    /// 备注（更新状态等）。
    var note: String = ""
    /// 年份。
    var year: String = ""
    /// 地区。
    var area: String = ""
    /// 类型名。
    var typeName: String = ""
    /// 导演。
    var director: String = ""
    /// 演员。
    var actor: String = ""
    /// 简介。
    var des: String = ""
    /// 来源站点 key。
    var sourceKey: String = ""
    
    /// 播放来源（线路）列表
    var playFlags: [String] = []
    /// key: flag名称, value: 剧集列表
    var playUrlMap: [String: [Episode]] = [:]
    
    /// 当前选中线路。
    var playFlag: String = ""
    /// 当前播放剧集索引。
    var playIndex: Int = 0
    
    /// 单集信息
    struct Episode: Codable, Identifiable, Hashable {
        var id: String { name }
        /// 集标题。
        let name: String
        /// 集播放地址。
        let url: String
        
        init(name: String, url: String) {
            self.name = name
            self.url = url
        }
    }
    
    /// 从 Movie.Video 和详情数据构建
    static func from(video: Movie.Video, playFrom: String, playUrl: String) -> VodInfo {
        var info = VodInfo(id: video.id)
        info.name = video.name
        info.pic = video.pic
        info.note = video.note
        info.year = video.year
        info.area = video.area
        info.typeName = video.type
        info.director = video.director
        info.actor = video.actor
        info.des = video.des.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        info.sourceKey = video.sourceKey
        
        // 解析播放列表：
        // playFrom 格式: "线路1$$$线路2$$$线路3"
        // playUrl  格式: "第1集$url1#第2集$url2$$$第1集$url3#第2集$url4"
        let flags = playFrom.components(separatedBy: "$$$").filter { !$0.isEmpty }
        let urls = playUrl.components(separatedBy: "$$$")
        var parsedRoutes: [(flag: String, episodes: [Episode], directScore: Int)] = []
        for (i, flag) in flags.enumerated() {
            if i < urls.count {
                let episodes = urls[i].components(separatedBy: "#").compactMap { item -> Episode? in
                    guard let separator = item.firstIndex(of: "$") else { return nil }
                    let name = String(item[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let url = String(item[item.index(after: separator)...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty, !url.isEmpty else { return nil }
                    return Episode(name: name, url: url)
                }
                parsedRoutes.append((
                    flag: flag,
                    episodes: episodes,
                    directScore: directPlaybackScore(flag: flag, episodes: episodes)
                ))
            }
        }

        // 资源站常把需要网页解析的 share 线路放在第一条、直连 m3u8 放在第二条。
        // macOS 端没有网页嗅探器；只要存在明确直连线路，就隐藏不可直接播放的线路。
        let directRoutes = parsedRoutes.filter { $0.directScore > 0 && !$0.episodes.isEmpty }
        let usableRoutes = directRoutes.isEmpty
            ? parsedRoutes.filter { !$0.episodes.isEmpty }
            : directRoutes.sorted { $0.directScore > $1.directScore }

        info.playFlags = usableRoutes.map(\.flag)
        for route in usableRoutes {
            info.playUrlMap[route.flag] = route.episodes
        }

        if let first = info.playFlags.first {
            info.playFlag = first
        }
        
        return info
    }

    private static func directPlaybackScore(flag: String, episodes: [Episode]) -> Int {
        let normalizedFlag = flag.lowercased()
        var score = 0
        if normalizedFlag.contains("m3u8") { score += 100 }
        if normalizedFlag.contains("mp4") { score += 90 }
        if normalizedFlag.contains("直连") || normalizedFlag.contains("direct") { score += 80 }

        let directExtensions = ["m3u8", "mp4", "m4v", "mov", "mkv", "flv", "mpd"]
        for episode in episodes.prefix(5) {
            guard let components = URLComponents(string: episode.url),
                  let scheme = components.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { continue }
            let pathExtension = (components.path as NSString).pathExtension.lowercased()
            if directExtensions.contains(pathExtension) { score += 20 }
        }
        return score
    }
    
    /// 当前线路下的剧集。
    var currentEpisodes: [Episode] {
        playUrlMap[playFlag] ?? []
    }
    
    /// 当前线路 + 当前索引对应的剧集对象。
    var currentEpisode: Episode? {
        let eps = currentEpisodes
        guard playIndex >= 0, playIndex < eps.count else { return nil }
        return eps[playIndex]
    }
}
