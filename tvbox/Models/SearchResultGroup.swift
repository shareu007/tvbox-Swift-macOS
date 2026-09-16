import Foundation

extension Movie.Video {
    /// 接口 ID 只在单个来源内唯一，跨源列表必须同时使用 sourceKey。
    var resourceID: String { "\(sourceKey.utf8.count):\(sourceKey)\(id)" }
}

struct SearchResultGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let year: String
    var resources: [Movie.Video]

    var poster: Movie.Video {
        var video = resources.first(where: { !$0.pic.isEmpty }) ?? resources[0]
        video.name = title
        video.note = "\(resources.count) 个资源"
        video.type = year.isEmpty ? video.type : year
        return video
    }

    /// 只移除明确的画质、集数等尾缀，保留季数、续集编号和作品名标点。
    static func title(for name: String) -> String {
        let original = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var title = original.precomposedStringWithCanonicalMapping
        title = title.replacingOccurrences(of: "[《》]", with: "", options: .regularExpression)
        let suffix = #"(?i)[\s\[【(（·|_-]+(?:4k|8k|2160p|1080p|720p|蓝光|超清|高清|原盘|国语|粤语|中字|双语|无广告|全集|完结|全\s*\d+\s*集|更新至\s*第?\s*\d+\s*集)[\s\]】)）]*$"#
        while true {
            let cleaned = title.replacingOccurrences(of: suffix, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned == title || cleaned.isEmpty { break }
            title = cleaned
        }
        return title.isEmpty ? original : title
    }

    static func aggregate(_ videos: [Movie.Video]) -> [SearchResultGroup] {
        var seen = Set<String>()
        let unique = videos.filter { seen.insert($0.resourceID).inserted }
        let titles = unique.map { title(for: $0.name) }
        let keys = titles.map { $0.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
        var knownYears: [String: Set<String>] = [:]
        for (index, video) in unique.enumerated() where !video.year.isEmpty {
            knownYears[keys[index], default: []].insert(video.year)
        }
        var groups: [SearchResultGroup] = []
        var indices: [String: Int] = [:]
        for (index, video) in unique.enumerated() {
            let key = keys[index]
            let years = knownYears[key] ?? []
            // 年份缺失时，仅在不存在同名翻拍歧义的情况下合并。
            let year = video.year.isEmpty && years.count == 1 ? (years.first ?? "") : video.year
            let identity = key.isEmpty ? video.resourceID : "\(key.utf8.count):\(key)\(year)"
            if let existing = indices[identity] {
                groups[existing].resources.append(video)
            } else {
                indices[identity] = groups.count
                groups.append(SearchResultGroup(id: identity, title: titles[index], year: year, resources: [video]))
            }
        }
        return groups
    }
}
