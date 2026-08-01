import Foundation

/// 分类排序模型 - 对应 Android 版 MovieSort.java
struct MovieSort: Codable {
    /// 分类列表（包含首页推荐、影视分类等）。
    var sortList: [SortData] = []
    
    /// 单个分类数据
    struct SortData: Codable, Identifiable, Hashable {
        /// App 内部使用的推荐分类 ID，避免与上游真实分类（例如 CatVod 的 `home`）冲突。
        static let recommendationID = "__tvbox_recommendation__"

        /// 分类唯一标识（接口字段通常为 type_id）。
        var id: String
        /// 分类显示名。
        var name: String = ""
        /// 标记位（不同源可定义不同语义，常用于首页/推荐标识）。
        var flag: String = ""
        /// 分类下可选筛选项（年份、地区、类型等）。
        var filters: [SortFilter] = []
        
        init(id: String = "", name: String = "", flag: String = "") {
            self.id = id
            self.name = name
            self.flag = flag
        }
        
        /// 生成首页推荐占位分类。
        /// 该分类不走常规分类接口，直接渲染首页推荐列表。
        static func home() -> SortData {
            SortData(id: recommendationID, name: "推荐", flag: "1")
        }

        var isRecommendation: Bool { id == Self.recommendationID }
    }
    
    /// 筛选条件
    struct SortFilter: Codable, Hashable {
        /// 接口参数键，例如 `year`、`area`。
        var key: String = ""
        /// UI 展示名称。
        var name: String = ""
        /// 可选值集合。
        var values: [SortFilterValue] = []
        
        struct SortFilterValue: Codable, Hashable {
            /// 展示名。
            var n: String = ""
            /// 真实参数值。
            var v: String = ""
        }
    }
}
