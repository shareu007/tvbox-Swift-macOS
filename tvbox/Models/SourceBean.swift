import Foundation

/// 视频源站点配置 - 对应 Android 版 SourceBean.java
struct SourceBean: Codable, Identifiable, Hashable {
    /// 以源 key 作为稳定标识。
    var id: String { key }
    
    /// 源唯一键。
    let key: String
    /// 源显示名。
    let name: String
    /// 源接口地址。
    let api: String
    /// 搜索开关：0 关闭，1 开启。
    let searchable: Int
    /// 是否允许出现在首页分类：0 不可选，1 可选。
    let filterable: Int
    /// 快速搜索开关：0 关闭，1 开启（主要用于 remote 源 quick 参数）。
    let quickSearch: Int
    /// 源声明的播放器类型（历史字段，Swift 端目前主要走统一播放器策略）。
    let playerType: Int
    /// 源协议类型：0 XML，1 JSON，3 JAR，4 Remote。
    let type: Int
    /// 扩展参数（remote 源常用）。
    let ext: String?
    /// type=3 Spider 使用的 JAR 地址（已应用顶层 spider 默认值）。
    let jar: String?
    
    init(key: String = "", name: String = "", api: String = "",
         searchable: Int = 1, filterable: Int = 1, quickSearch: Int = 0,
         playerType: Int = 0, type: Int = 1, ext: String? = nil,
         jar: String? = nil) {
        self.key = key
        self.name = name
        self.api = api
        self.searchable = searchable
        self.filterable = filterable
        self.quickSearch = quickSearch
        self.playerType = playerType
        self.type = type
        self.ext = ext
        self.jar = jar
    }
    
    var isSearchable: Bool { searchable == 1 }
    var isFilterable: Bool { filterable == 1 }
    var isQuickSearchEnabled: Bool { quickSearch == 1 }
    var isSearchOnly: Bool {
        key == Self.cloudPanKey || api == Self.panSearchAPI
    }
    var isHomeEligible: Bool { isSupportedInSwift && !isSearchOnly }

    static let cloudPanKey = "builtin_cloudpan"
    static let kkPanSearchKey = "builtin_kkpans"
    static let cloudPanBundleURL = "https://raw.githubusercontent.com/qist/tvbox/master/cat/dist/index.js"
    static let panSearchAPI = "/spider/pansearch/3"

    static var cloudPan: SourceBean {
        SourceBean(
            key: cloudPanKey,
            name: "☁️ 网盘聚合",
            api: "/spider/cloudpan/3",
            searchable: 1,
            filterable: 0,
            quickSearch: 1,
            type: 3,
            jar: cloudPanBundleURL
        )
    }

    static var kkPanSearch: SourceBean {
        SourceBean(
            key: kkPanSearchKey,
            name: "🔎 KK网盘｜夸克",
            api: panSearchAPI,
            searchable: 1,
            filterable: 0,
            quickSearch: 1,
            type: 3,
            ext: #"{"engine":"kkpans"}"#,
            jar: cloudPanBundleURL
        )
    }

    /// Gateway 支持 Android Worker 的 csp_* JAR，以及原生 Node 的 CatVod `/spider/` 接口。
    var isSpiderGatewayCompatible: Bool {
        type == 3
            && (api.hasPrefix("csp_") || api.hasPrefix("/spider/"))
            && !(jar?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// 将已验证的 Guard、盘搜 JAR 与 DRPY 脚本协议替换为纯 Node 实现。
    func applyingNodeCompatibility(baseConfigURL: String? = nil) -> SourceBean {
        guard type == 3 else { return self }
        if api == "csp_YpanSoGuard" || api == "csp_MIPanSoGuard" {
            return nodeCompatiblePanSearch(engine: "kuafu")
        }
        if api == "csp_S_zpsGuard"
            || api == "csp_PanSearchGuard"
            || api == "csp_QuarkPanso" {
            return nodeCompatiblePanSearch(engine: "pansou")
        }
        if api == "csp_Funletu" || isDRPYScript(named: "funletu.js") {
            return nodeCompatiblePanSearch(engine: "funletu")
        }
        if isDRPYScript(named: "yyets.js") {
            return nodeCompatiblePanSearch(engine: "yyets")
        }
        if isDRPYScript(named: "kkpans.js") {
            return nodeCompatiblePanSearch(engine: "kkpans")
        }
        if api == "csp_QuarkShare",
           let listURL = resolvedQuarkShareListURL(baseConfigURL: baseConfigURL) {
            return nodeCompatiblePanSearch(
                engine: "quarkshare",
                additionalValues: ["listURL": listURL]
            )
        }
        guard api == "csp_SixVGuard" else { return self }
        return SourceBean(
            key: key,
            name: name,
            api: "/spider/xb6v/3",
            searchable: searchable,
            filterable: filterable,
            quickSearch: quickSearch,
            playerType: playerType,
            type: type,
            ext: ext ?? "https://www.xb6v.com/",
            jar: "https://raw.githubusercontent.com/qist/tvbox/master/cat/dist/index.js"
        )
    }

    private func isDRPYScript(named scriptName: String) -> Bool {
        guard api.lowercased().contains("drpy"),
              let path = ext?.split(separator: "$", maxSplits: 1).first else {
            return false
        }
        let normalizedPath = String(path).lowercased()
        let normalizedName = scriptName.lowercased()
        return normalizedPath.hasSuffix("/\(normalizedName)")
            || normalizedPath == normalizedName
    }

    private func resolvedQuarkShareListURL(baseConfigURL: String?) -> String? {
        guard let ext else { return nil }
        let candidates = ext
            .components(separatedBy: "$$$")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let rawPath = candidates.last else { return nil }
        if rawPath.hasPrefix("http://") || rawPath.hasPrefix("https://") {
            return rawPath
        }
        guard let baseConfigURL,
              let baseURL = URL(string: baseConfigURL),
              let resolved = URL(string: rawPath, relativeTo: baseURL)?.absoluteURL,
              ["http", "https"].contains(resolved.scheme?.lowercased() ?? "") else {
            return nil
        }
        return resolved.absoluteString
    }

    private func nodeCompatiblePanSearch(
        engine: String,
        additionalValues: [String: Any] = [:]
    ) -> SourceBean {
        var values: [String: Any] = ["engine": engine]
        values.merge(additionalValues) { _, new in new }
        if let ext,
           let data = ext.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            values.merge(object) { current, _ in current }
        }
        let resolvedExt = (try? JSONSerialization.data(withJSONObject: values))
            .flatMap { String(data: $0, encoding: .utf8) }
        return SourceBean(
            key: key,
            name: name,
            api: Self.panSearchAPI,
            searchable: searchable,
            filterable: 0,
            quickSearch: quickSearch,
            playerType: playerType,
            type: type,
            ext: resolvedExt,
            jar: Self.cloudPanBundleURL
        )
    }
    
    /// 是否在当前 Swift 构建中可用。macOS 的 Node type=3 由内置运行组件提供。
    var isSupportedInSwift: Bool {
        if type == 0 || type == 1 || type == 4 { return true }
        guard isSpiderGatewayCompatible else { return false }
#if os(macOS)
        if api.hasPrefix("/spider/") { return true }
        return !SpiderGatewaySettings.savedBaseURL.isEmpty
#else
        return SpiderGatewaySettings.isConfigured
#endif
    }
    
    /// 类型描述
    var typeDescription: String {
        switch type {
        case 0: return "XML"
        case 1: return "JSON"
        case 3: return api.hasPrefix("/spider/") ? "Node" : "JAR"
        case 4: return "Remote"
        default: return "未知"
        }
    }
    
    /// api 字段是否为有效 HTTP URL
    var isHttpApi: Bool {
        return api.hasPrefix("http://") || api.hasPrefix("https://")
    }
}
