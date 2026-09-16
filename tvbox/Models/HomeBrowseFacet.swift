import Foundation

/// 将不同来源的年份、地区参数映射为首页统一选项；未声明的参数只在已加载内容中筛选。
enum HomeBrowseFacet: String, CaseIterable {
    case year, area

    var title: String { self == .year ? "年份" : "国家/地区" }

    func recognizes(_ filter: MovieSort.SortFilter) -> Bool {
        switch self {
        case .year:
            return ["year", "vod_year"].contains(filter.key.lowercased()) || filter.name.contains("年份")
        case .area:
            return ["area", "country", "region", "vod_area"].contains(filter.key.lowercased())
                || ["地区", "地區", "国家", "國家"].contains(where: filter.name.contains)
        }
    }

    func normalized(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if self == .year {
            return value.hasSuffix("年") ? String(value.dropLast()) : value
        }
        switch value {
        case "大陆", "内地", "中国大陆", "中國大陸", "大陸": return "中国大陆"
        case "香港", "中国香港", "中國香港": return "中国香港"
        case "台湾", "台灣", "中国台湾", "中國台灣": return "中国台湾"
        default: return value
        }
    }

    func values(in video: Movie.Video) -> [String] {
        let raw = self == .year ? video.year : video.area
        return raw.components(separatedBy: CharacterSet(charactersIn: "/,，、;；|"))
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
        let sorted = values.sorted {
            self == .year ? $0.localizedStandardCompare($1) == .orderedDescending
                : $0.localizedStandardCompare($1) == .orderedAscending
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
}
