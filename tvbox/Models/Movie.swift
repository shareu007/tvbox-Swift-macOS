import Foundation

/// 电影/视频数据模型 - 对应 Android 版 Movie.java
struct Movie: Codable {
    /// 列表数据主体。
    var videoList: [Video] = []
    /// 总页数。
    var pagecount: Int = 0
    /// 当前页码。
    var page: Int = 0
    /// 总条数。
    var total: Int = 0
    /// 每页条数。
    var limit: Int = 0
    
    /// 单个视频条目
    struct Video: Codable, Identifiable, Hashable {
        /// 视频唯一 ID（接口可能返回 Int 或 String，见自定义解码）。
        var id: String
        /// 片名。
        var name: String = ""
        /// 海报地址。
        var pic: String = ""
        /// 备注（如“更新至第20集”）。
        var note: String = ""
        /// 年份。
        var year: String = ""
        /// 地区。
        var area: String = ""
        /// 类型/分类名。
        var type: String = ""
        /// 导演。
        var director: String = ""
        /// 演员。
        var actor: String = ""
        /// 简介。
        var des: String = ""
        /// 来源站点 key，用于跨源隔离收藏与历史。
        var sourceKey: String = ""
        /// 分类 ID。
        var tid: String = ""
        /// 最后更新时间。
        var last: String = ""
        /// 播放来源信息（部分接口会复用该字段）。
        var dt: String = ""
        
        init(id: String = UUID().uuidString, name: String = "", pic: String = "",
             note: String = "", sourceKey: String = "") {
            self.id = id
            self.name = name
            self.pic = pic
            self.note = note
            self.sourceKey = sourceKey
        }
        
        enum CodingKeys: String, CodingKey {
            case id = "vod_id"
            case name = "vod_name"
            case pic = "vod_pic"
            case note = "vod_remarks"
            case year = "vod_year"
            case area = "vod_area"
            case type = "type_name"
            case director = "vod_director"
            case actor = "vod_actor"
            case des = "vod_content"
            case tid = "type_id"
            case last = "vod_time"
            case dt = "vod_play_from"
            case sourceKey
        }
        
        /// 自定义解码以兼容多源字段类型差异（如 `vod_id` / `type_id` 可能是 Int 或 String）。
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // 支持 String 或 Int 类型的 id
            if let intId = try? container.decode(Int.self, forKey: .id) {
                self.id = String(intId)
            } else {
                self.id = (try? container.decode(String.self, forKey: .id)) ?? UUID().uuidString
            }
            self.name = (try? container.decode(String.self, forKey: .name)) ?? ""
            self.pic = (try? container.decode(String.self, forKey: .pic)) ?? ""
            self.note = (try? container.decode(String.self, forKey: .note)) ?? ""
            self.year = (try? container.decode(String.self, forKey: .year))
                ?? (try? container.decode(Int.self, forKey: .year)).map(String.init) ?? ""
            self.area = (try? container.decode(String.self, forKey: .area)) ?? ""
            self.type = (try? container.decode(String.self, forKey: .type))
                ?? Self.decodeFallbackType(from: decoder)
                ?? ""
            self.director = (try? container.decode(String.self, forKey: .director)) ?? ""
            self.actor = (try? container.decode(String.self, forKey: .actor)) ?? ""
            self.des = (try? container.decode(String.self, forKey: .des)) ?? ""
            self.tid = {
                if let intTid = try? container.decode(Int.self, forKey: .tid) {
                    return String(intTid)
                }
                return (try? container.decode(String.self, forKey: .tid)) ?? ""
            }()
            self.last = (try? container.decode(String.self, forKey: .last)) ?? ""
            self.dt = (try? container.decode(String.self, forKey: .dt)) ?? ""
            self.sourceKey = (try? container.decode(String.self, forKey: .sourceKey)) ?? ""
        }

        /// 部分源用 `vod_class`（如「动作,喜剧」）承载类型，而不填 `type_name`。
        /// 单独用兜底 key 解码，避免污染 CodingKeys 影响合成的 encode。
        private enum FallbackKeys: String, CodingKey {
            case vodClass = "vod_class"
            case vodTag = "vod_tag"
        }

        private static func decodeFallbackType(from decoder: Decoder) -> String? {
            guard let fallback = try? decoder.container(keyedBy: FallbackKeys.self) else { return nil }
            if let value = try? fallback.decode(String.self, forKey: .vodClass), !value.isEmpty {
                return value
            }
            return try? fallback.decode(String.self, forKey: .vodTag)
        }
    }
}
