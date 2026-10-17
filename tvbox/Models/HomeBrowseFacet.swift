import Foundation

/// 将不同来源的年份、地区、类型参数映射为首页统一选项；未声明的参数只在已加载内容中筛选。
enum HomeBrowseFacet: String, CaseIterable {
    case year, area, genre

    var title: String {
        switch self {
        case .year: return "年份"
        case .area: return "国家/地区"
        case .genre: return "类型"
        }
    }

    func recognizes(_ filter: MovieSort.SortFilter) -> Bool {
        let key = filter.key.lowercased()
        switch self {
        case .year:
            return ["year", "years", "vod_year", "syear", "releaseyear", "release_year", "nianfen"].contains(key)
                || ["年份", "年代"].contains(where: filter.name.contains)
        case .area:
            return ["area", "country", "region", "vod_area", "nation", "diqu"].contains(key)
                || ["地区", "地區", "国家", "國家", "区域", "區域"].contains(where: filter.name.contains)
        case .genre:
            return ["class", "classes", "genre", "genres", "type", "tag", "vod_class", "vod_tag", "vod_type", "leixing"].contains(key)
                || ["类型", "類型", "题材", "題材", "剧情", "劇情"].contains(where: filter.name.contains)
        }
    }

    func normalized(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .year:
            return value.hasSuffix("年") ? String(value.dropLast()) : value
        case .area:
            switch value {
            case "大陆", "内地", "中国大陆", "中國大陸", "大陸": return "中国大陆"
            case "香港", "中国香港", "中國香港": return "中国香港"
            case "台湾", "台灣", "中国台湾", "中國台灣": return "中国台湾"
            default: return value
            }
        case .genre:
            return Self.canonicalGenre(value)
        }
    }

    func values(in video: Movie.Video) -> [String] {
        let raw: String
        let separators: CharacterSet
        switch self {
        case .year:
            raw = video.year
            separators = CharacterSet(charactersIn: "/,，、;；|")
        case .area:
            raw = video.area
            separators = CharacterSet(charactersIn: "/,，、;；|")
        case .genre:
            raw = video.type
            separators = CharacterSet(charactersIn: "/,，、;；|· ").union(.whitespaces)
        }
        return raw.components(separatedBy: separators)
            .map(normalized).filter { !$0.isEmpty }
    }

    func sourceSelection(in sort: MovieSort.SortData, value: String) -> (key: String, value: String)? {
        for filter in sort.filters where recognizes(filter) {
            if let option = filter.values.first(where: { !$0.v.isEmpty && normalized($0.n) == value }) {
                return (filter.key, option.v)
            }
        }
        return nil
    }

    func filter(sorts: [MovieSort.SortData], videos: [Movie.Video], selected: String?) -> MovieSort.SortFilter {
        var values = Set(videos.flatMap { self.values(in: $0) })
        for filter in sorts.flatMap(\.filters) where recognizes(filter) {
            values.formUnion(filter.values.filter { !$0.v.isEmpty }.map { normalized($0.n) })
        }
        if let selected, !selected.isEmpty { values.insert(selected) }
        values.subtract(["", "全部", "不限"])
        let sorted = values.sorted { left, right in
            switch self {
            case .year:
                return left.localizedStandardCompare(right) == .orderedDescending
            case .area:
                return left.localizedStandardCompare(right) == .orderedAscending
            case .genre:
                let leftRank = Self.genreOrder.firstIndex(of: left) ?? Int.max
                let rightRank = Self.genreOrder.firstIndex(of: right) ?? Int.max
                if leftRank != rightRank { return leftRank < rightRank }
                return left.localizedStandardCompare(right) == .orderedAscending
            }
        }
        return .init(key: rawValue, name: title, values: sorted.map { .init(n: $0, v: $0) })
    }

    static func matching(_ videos: [Movie.Video], selections: [String: String]) -> [Movie.Video] {
        videos.filter { video in
            allCases.allSatisfy { facet in
                guard let value = selections[facet.rawValue], !value.isEmpty else { return true }
                return facet.values(in: video).contains(facet.normalized(value))
            }
        }
    }

    // MARK: - 类型归一化（参考 Netflix 的中文类型分类）

    /// 常见类型别名归一化，键为简体形式（输入先做繁转简）。
    private static let genreSynonyms: [String: String] = [
        "记录片": "纪录片", "纪实": "纪录片",
        "动漫": "动画", "卡通": "动画",
        "言情": "爱情", "浪漫": "爱情",
        "搞笑": "喜剧", "幽默": "喜剧",
        "惊险": "惊悚", "惊栗": "惊悚",
        "侦探": "悬疑", "推理": "悬疑",
        "警匪": "犯罪", "黑帮": "犯罪", "刑侦": "犯罪",
        "抗战": "战争",
        "功夫": "动作", "格斗": "动作",
        "魔幻": "奇幻", "玄幻": "奇幻", "穿越": "奇幻",
        "亲子": "家庭",
        "歌舞": "音乐",
        "体育": "运动",
        "校园": "青春",
        "宫廷": "古装",
        "职场": "都市", "商战": "都市",
        "访谈": "脱口秀",
    ]

    /// Netflix 风格类型排序：常见类型固定在前，其余按字典序补充。
    private static let genreOrder: [String] = [
        "动作", "冒险", "动画", "喜剧", "犯罪", "纪录片", "剧情", "家庭",
        "奇幻", "历史", "恐怖", "音乐", "悬疑", "爱情", "科幻", "惊悚",
        "战争", "西部", "武侠", "古装", "谍战", "军旅", "都市", "青春",
        "偶像", "灾难", "运动", "传记", "儿童", "短片", "真人秀", "脱口秀",
        "综艺", "短剧", "解说",
    ]

    /// 将来源给出的类型文本归一化为统一名称，例如「驚悚片」→「惊悚」。
    static func canonicalGenre(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let simplified = toSimplified(trimmed)
        if let mapped = genreSynonyms[simplified] { return mapped }
        if genreOrder.contains(simplified) { return simplified }
        // 「动作片」「喜剧片」等去掉尾缀后即为标准类型名；「纪录片」等整词已在上方保留。
        if simplified.count >= 3, simplified.hasSuffix("片") {
            let stem = String(simplified.dropLast())
            return genreSynonyms[stem] ?? stem
        }
        return simplified
    }

    /// 繁转简，使繁体来源的类型也能命中以简体为键的同义词表。
    private static func toSimplified(_ text: String) -> String {
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, "Hant-Hans" as CFString, false)
        return mutable as String
    }
}
