import Foundation

/// 顶部展示内容大类；请求仍使用来源原始分类，避免把合成 ID 发给接口。
struct HomeCategoryGroup: Identifiable, Equatable {
    enum Family: String, CaseIterable {
        case movie, series, variety, documentary, animation, shortDrama, commentary

        var title: String {
            switch self {
            case .movie: return "电影"
            case .series: return "电视剧"
            case .variety: return "综艺"
            case .documentary: return "纪录片"
            case .animation: return "动漫"
            case .shortDrama: return "短剧"
            case .commentary: return "影视解说"
            }
        }

        static func matching(_ name: String) -> Family? {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            // 独立大类先匹配，避免“纪录电影”“动画片”等被归入普通电影。
            let aliases: [(Family, [String])] = [
                (.commentary, ["解说", "解說"]),
                (.documentary, ["纪录", "紀錄", "记录片", "記錄片"]),
                (.shortDrama, ["短剧", "短劇", "微剧", "微劇"]),
                (.animation, ["动漫", "動畫", "动画", "動漫"]),
                (.variety, ["综艺", "綜藝"]),
                (.movie, ["电影", "電影", "影片", "动作片", "動作片", "喜剧片", "喜劇片", "爱情片", "愛情片", "科幻片", "恐怖片", "惊悚片", "驚悚片", "剧情片", "劇情片", "战争片", "戰爭片", "犯罪片", "悬疑片", "懸疑片", "武侠片", "武俠片"]),
                (.series, ["电视剧", "電視劇", "连续剧", "連續劇", "剧集", "劇集", "国产剧", "國產劇", "欧美剧", "歐美劇", "日剧", "日劇", "韩剧", "韓劇", "韩国剧", "韓國劇", "日本剧", "日本劇", "港台剧", "港台劇", "香港剧", "香港劇", "台湾剧", "台灣劇", "泰剧", "泰劇", "海外剧", "海外劇", "日韩剧", "日韓劇"])
            ]
            return aliases.first { $0.1.contains(where: name.contains) }?.0
        }
    }

    let id: String
    let title: String
    let categories: [MovieSort.SortData]

    var defaultCategory: MovieSort.SortData? {
        categories.first { [title, "电影片", "連續劇", "连续剧", "动画", "動畫"].contains($0.name) }
            ?? categories.first
    }

    static func groups(from sorts: [MovieSort.SortData]) -> [HomeCategoryGroup] {
        var seen = Set<String>()
        let categories = sorts.filter { seen.insert($0.id).inserted }
        var groups: [HomeCategoryGroup] = []
        if let home = categories.first(where: \.isRecommendation) {
            groups.append(.init(id: "recommendation", title: home.name, categories: [home]))
        }
        for family in Family.allCases {
            let members = categories.filter { !$0.isRecommendation && Family.matching($0.name) == family }
            if !members.isEmpty {
                groups.append(.init(id: "family:\(family.rawValue)", title: family.title, categories: members))
            }
        }
        // 保留来源独有入口，例如最近更新、4K专区；不隐藏无法识别的分类。
        groups.append(contentsOf: categories.filter { !$0.isRecommendation && Family.matching($0.name) == nil }.map {
            .init(id: "category:\($0.id)", title: $0.name, categories: [$0])
        })
        return groups
    }
}
