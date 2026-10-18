import Foundation

/// type=4 源的 extend 内容缓存：同一 URL 在 TTL 内只下载一次，
/// 避免每次 getList/search 都重新拉取。只缓存成功结果，失败回源。
actor ExtendContentCache {
    static let shared = ExtendContentCache()

    private struct Entry {
        let content: String
        let expiresAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let ttl: TimeInterval = 600
    private let maximumEntries = 32

    func cachedContent(for url: String, now: Date = Date()) -> String? {
        guard let entry = entries[url], entry.expiresAt > now else { return nil }
        return entry.content
    }

    func store(_ content: String, for url: String, now: Date = Date()) {
        if entries.count >= maximumEntries, entries[url] == nil {
            if let oldest = entries.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
                entries.removeValue(forKey: oldest)
            }
        }
        entries[url] = Entry(content: content, expiresAt: now.addingTimeInterval(ttl))
    }
}

/// 视频源数据服务 - 对应 Android 版 SourceViewModel.java
/// 负责从各视频源获取分类、列表、详情和搜索数据
class SourceService {
    static let shared = SourceService()

    private let network: NetworkManager

    init(network: NetworkManager = .shared) {
        self.network = network
    }
    
    // MARK: - 获取分类列表
    
    /// 获取指定源的分类列表和首页推荐
    func getSort(
        sourceBean: SourceBean,
        maxRetries: Int = NetworkManager.defaultMaxRetries
    ) async throws -> (sorts: [MovieSort.SortData], homeVideos: [Movie.Video]) {
        if sourceBean.type == 3 {
            return try await SpiderGatewayService.shared.home(source: sourceBean)
        }
        let api = sourceBean.api
        guard !api.isEmpty else {
            throw SourceError.emptyApi
        }
        
        // 未识别的其他协议类型不进入 CMS 请求路径。
        guard sourceBean.isSupportedInSwift else {
            throw SourceError.unsupportedType(sourceBean.typeDescription)
        }
        
        // 确保 api 是有效的 HTTP URL
        guard sourceBean.isHttpApi else {
            throw SourceError.invalidApiUrl(api)
        }
        
        let resolvedExtend = sourceBean.type == 4 ? await resolveExtend(sourceBean.ext ?? "") : ""
        let jsonStr: String
        // ac=class 响应通常没有带海报的推荐列表；与分类请求并发预取列表接口，
        // 需要兜底时直接复用结果，减少一次串行等待。
        var speculativeListURL: String?
        var speculativeListTask: Task<[Movie.Video]?, Never>?
        defer { speculativeListTask?.cancel() }
        if sourceBean.type == 4 {
            // Type 4: 远程接口，需要 extend 和 filter 参数
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "filter", value: "true")
            ]
            if !resolvedExtend.isEmpty {
                queryItems.append(URLQueryItem(name: "extend", value: resolvedExtend))
            }
            let url = try buildURL(base: api, queryItems: queryItems)
            // type=4 列表用 ac=detail 格式，与 getList 保持一致
            let ext = Data("{}".utf8).base64EncodedString()
            speculativeListURL = try buildURL(
                base: api,
                queryItems: [
                    URLQueryItem(name: "ac", value: "detail"),
                    URLQueryItem(name: "filter", value: "true"),
                    URLQueryItem(name: "pg", value: "1"),
                    URLQueryItem(name: "ext", value: ext),
                    URLQueryItem(name: "extend", value: resolvedExtend)
                ]
            )
            let listURL = speculativeListURL!
            speculativeListTask = Task { try? await self.loadVideoList(url: listURL, source: sourceBean, maxRetries: 0) }
            jsonStr = try await network.getString(from: url, maxRetries: maxRetries)
        } else if sourceBean.type == 0 {
            // XML 接口
            jsonStr = try await network.getString(from: api, maxRetries: maxRetries)
        } else {
            // JSON 接口 (type=1)
            let url = try buildURL(
                base: api,
                queryItems: [URLQueryItem(name: "ac", value: "class")]
            )
            // type=1 列表用 ac=videolist 格式
            let listURL = try buildURL(
                base: api,
                queryItems: [
                    URLQueryItem(name: "ac", value: "videolist"),
                    URLQueryItem(name: "pg", value: "1")
                ]
            )
            speculativeListURL = listURL
            speculativeListTask = Task { try? await self.loadVideoList(url: listURL, source: sourceBean, maxRetries: 0) }
            jsonStr = try await network.getString(from: url, maxRetries: maxRetries)
        }

        var (sorts, homeVideos) = try parseSort(jsonStr, sourceBean: sourceBean)

        // 当大多数推荐视频的 vod_pic 为空时（ac=class 接口常见情况），
        // 使用列表接口获取带完整海报的推荐视频
        let picMissingCount = homeVideos.filter { $0.pic.trimmingCharacters(in: .whitespaces).isEmpty }.count
        let needsFallback = homeVideos.isEmpty || picMissingCount > homeVideos.count / 2

        if needsFallback, let listURL = speculativeListURL {
            let speculative: [Movie.Video]?
            if let task = speculativeListTask {
                speculative = await withTaskCancellationHandler {
                    await task.value
                } onCancel: {
                    task.cancel()
                }
            } else { speculative = nil }
            try Task.checkCancellation()
            if let speculative, !speculative.isEmpty {
                homeVideos = speculative
            } else if let fallback = try? await loadVideoList(url: listURL, source: sourceBean, maxRetries: maxRetries), !fallback.isEmpty {
                homeVideos = fallback
            }
        }

        try Task.checkCancellation()
        return (sorts, homeVideos)
    }
    
    private func parseSort(_ jsonStr: String, sourceBean: SourceBean) throws -> (sorts: [MovieSort.SortData], homeVideos: [Movie.Video]) {
        guard let data = jsonStr.data(using: .utf8) else {
            throw SourceError.parseError("无法解析数据")
        }
        
        var sorts: [MovieSort.SortData] = []
        var homeVideos: [Movie.Video] = []
        
        if sourceBean.type == 0 {
            // XML 格式
            let response = try CMSXMLResponseParser.parse(data, sourceKey: sourceBean.key)
            return (response.sorts, response.homeVideos)
        } else {
            // JSON 格式 (type=1, type=4)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // 解析分类
                if let classList = json["class"] as? [[String: Any]] {
                    sorts = Self.categoriesWithFilters(
                        Self.leafCategories(from: classList),
                        object: json,
                        parentIDs: Self.parentIDs(from: classList)
                    )
                }
                
                // 解析首页推荐视频
                if let list = json["list"] as? [[String: Any]] {
                    for item in list {
                        let decoder = JSONDecoder()
                        if let itemData = try? JSONSerialization.data(withJSONObject: item),
                           var video = try? decoder.decode(Movie.Video.self, from: itemData) {
                            video.sourceKey = sourceBean.key
                            homeVideos.append(video)
                        }
                    }
                }
            }
        }
        
        return (sorts, homeVideos)
    }

    /// CMS 常同时返回父分类和子分类，但父 ID 往往不能直接查询影片。
    /// 保留叶子分类，以及没有任何子分类的独立根分类。
    static func leafCategories(from classList: [[String: Any]]) -> [MovieSort.SortData] {
        let categories = classList.compactMap { item -> (id: String, parentID: String, name: String)? in
            let id = flexibleString(item["type_id"])
            guard !id.isEmpty else { return nil }
            return (
                id: id,
                parentID: flexibleString(item["type_pid"]),
                name: item["type_name"] as? String ?? ""
            )
        }
        let parentIDs = Set(categories.compactMap { category in
            let parentID = category.parentID
            return parentID.isEmpty || parentID == "0" ? nil : parentID
        })
        return categories.compactMap { category in
            guard !parentIDs.contains(category.id) else { return nil }
            return MovieSort.SortData(id: category.id, name: category.name)
        }
    }

    private static func flexibleString(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }

    /// 提取 type_id → type_pid 的映射，用于子分类沿父链继承筛选声明。
    static func parentIDs(from classList: [[String: Any]]) -> [String: String] {
        var parents: [String: String] = [:]
        for item in classList {
            let id = flexibleString(item["type_id"])
            let pid = flexibleString(item["type_pid"])
            guard !id.isEmpty, !pid.isEmpty, pid != "0" else { continue }
            parents[id] = pid
        }
        return parents
    }

    /// TVBox 的筛选值可能是数字；保留接口参数，并去掉会造成重复控件的键和值。
    /// CMS 常把年份/地区筛选声明在父分类 ID 上，叶子分类需沿父链继承（最多 6 层，防环）。
    static func categoriesWithFilters(_ categories: [MovieSort.SortData], object: [String: Any], parentIDs: [String: String] = [:]) -> [MovieSort.SortData] {
        let filtersByID = object["filters"] as? [String: Any] ?? [:]
        return categories.map { category in
            var category = category
            category.filters = declaredFilters(for: category.id, filtersByID: filtersByID, parentIDs: parentIDs)
            return category
        }
    }

    private static func declaredFilters(for id: String, filtersByID: [String: Any], parentIDs: [String: String]) -> [MovieSort.SortFilter] {
        var keys = Set<String>()
        var filters: [MovieSort.SortFilter] = []
        var currentID = id
        var visited = Set<String>()
        while !currentID.isEmpty, visited.insert(currentID).inserted, visited.count <= 6 {
            let rawFilters = filtersByID[currentID] as? [[String: Any]] ?? []
            for raw in rawFilters {
                let key = flexibleString(raw["key"])
                guard !key.isEmpty, keys.insert(key).inserted else { continue }
                var values = Set<String>()
                let options = (raw["value"] as? [[String: Any]] ?? []).compactMap { option -> MovieSort.SortFilter.SortFilterValue? in
                    guard option["v"] != nil else { return nil }
                    let value = flexibleString(option["v"])
                    let name = flexibleString(option["n"])
                    guard !name.isEmpty, values.insert(value).inserted else { return nil }
                    return .init(n: name, v: value)
                }
                guard !options.isEmpty else { continue }
                filters.append(MovieSort.SortFilter(key: key, name: flexibleString(raw["name"]), values: options))
            }
            currentID = parentIDs[currentID] ?? ""
        }
        return filters
    }
    
    // MARK: - 获取分类视频列表
    
    /// 获取分类下的视频列表
    func getList(sourceBean: SourceBean, sortData: MovieSort.SortData, page: Int = 1, filters: [String: String]? = nil) async throws -> [Movie.Video] {
        if sourceBean.type == 3 {
            return try await SpiderGatewayService.shared.category(
                source: sourceBean,
                tid: sortData.id,
                page: page,
                filters: filters
            )
        }
        let api = sourceBean.api
        guard !api.isEmpty else { throw SourceError.emptyApi }
        guard sourceBean.isSupportedInSwift else { throw SourceError.unsupportedType(sourceBean.typeDescription) }
        guard sourceBean.isHttpApi else { throw SourceError.invalidApiUrl(api) }
        
        let url: String
        if sourceBean.type == 0 {
            // XML 接口
            url = try buildURL(
                base: api,
                queryItems: [
                    URLQueryItem(name: "ac", value: "videolist"),
                    URLQueryItem(name: "t", value: sortData.id),
                    URLQueryItem(name: "pg", value: String(page))
                ]
            )
        } else if sourceBean.type == 4 {
            // Type 4: 远程接口
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "ac", value: "detail"),
                URLQueryItem(name: "filter", value: "true"),
                URLQueryItem(name: "t", value: sortData.id),
                URLQueryItem(name: "pg", value: String(page))
            ]
            
            // 附加筛选参数（base64 编码）
            if let filters = filters, !filters.isEmpty {
                if let filterData = try? JSONSerialization.data(withJSONObject: filters),
                   let filterStr = String(data: filterData, encoding: .utf8) {
                    let ext = Data(filterStr.utf8).base64EncodedString()
                    queryItems.append(URLQueryItem(name: "ext", value: ext))
                }
            } else {
                let ext = Data("{}".utf8).base64EncodedString()
                queryItems.append(URLQueryItem(name: "ext", value: ext))
            }
            
            // 加载 extend
            if let ext = sourceBean.ext, !ext.isEmpty {
                let extend = await resolveExtend(ext)
                if !extend.isEmpty {
                    queryItems.append(URLQueryItem(name: "extend", value: extend))
                }
            }
            url = try buildURL(base: api, queryItems: queryItems)
        } else {
            // JSON 接口 (type=1)
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "ac", value: "videolist"),
                URLQueryItem(name: "t", value: sortData.id),
                URLQueryItem(name: "pg", value: String(page))
            ]
            
            // 附加筛选参数
            if let filters = filters {
                for (key, value) in filters {
                    queryItems.append(URLQueryItem(name: key, value: value))
                }
            }
            url = try buildURL(base: api, queryItems: queryItems)
        }
        
        return try await loadVideoList(url: url, source: sourceBean)
    }
    
    /// Some JSON CMS servers implement ac=detail but reject ac=videolist.
    private func loadVideoList(url: String, source: SourceBean, maxRetries: Int = NetworkManager.defaultMaxRetries) async throws -> [Movie.Video] {
        var originalError: Error?
        do {
            let text = try await network.getString(from: url, maxRetries: maxRetries)
            let videos = try parseVideoList(text, sourceKey: source.key, type: source.type)
            if !videos.isEmpty || source.type != 1 { return videos }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard source.type == 1 else { throw error }
            originalError = error
        }
        try Task.checkCancellation()
        guard var components = URLComponents(string: url) else { throw SourceError.invalidApiUrl(url) }
        components.queryItems = (components.queryItems ?? []).map {
            $0.name == "ac" ? URLQueryItem(name: "ac", value: "detail") : $0
        }
        guard let alternate = components.url?.absoluteString else { throw SourceError.invalidApiUrl(url) }
        do {
            let text = try await network.getString(from: alternate, maxRetries: maxRetries)
            return try parseVideoList(text, sourceKey: source.key, type: source.type)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw originalError ?? error
        }
    }

    private func parseVideoList(_ jsonStr: String, sourceKey: String, type: Int) throws -> [Movie.Video] {
        guard let data = jsonStr.data(using: .utf8) else {
            throw SourceError.parseError("无法解析数据")
        }
        
        var videos: [Movie.Video] = []
        
        if type == 0 {
            videos = try CMSXMLResponseParser.parse(data, sourceKey: sourceKey).homeVideos
        } else {
            // JSON 格式 (type=1, type=4)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = json["list"] as? [[String: Any]] {
                let decoder = JSONDecoder()
                for item in list {
                    if let itemData = try? JSONSerialization.data(withJSONObject: item),
                       var video = try? decoder.decode(Movie.Video.self, from: itemData) {
                        video.sourceKey = sourceKey
                        videos.append(video)
                    }
                }
            }
        }
        
        return videos
    }
    
    // MARK: - 获取详情
    
    /// 获取视频详情
    func getDetail(sourceBean: SourceBean, vodId: String, verifyResource: Bool = false) async throws -> VodInfo? {
        if sourceBean.type == 3 {
            return try await SpiderGatewayService.shared.detail(source: sourceBean, id: vodId, verifyResource: verifyResource)
        }
        let api = sourceBean.api
        guard !api.isEmpty else { throw SourceError.emptyApi }
        guard sourceBean.isSupportedInSwift else { throw SourceError.unsupportedType(sourceBean.typeDescription) }
        guard sourceBean.isHttpApi else { throw SourceError.invalidApiUrl(api) }
        
        let url: String
        if sourceBean.type == 0 {
            url = try buildURL(
                base: api,
                queryItems: [
                    URLQueryItem(name: "ac", value: "videolist"),
                    URLQueryItem(name: "ids", value: vodId)
                ]
            )
        } else if sourceBean.type == 4 {
            // Type 4: 远程接口
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "ac", value: "detail"),
                URLQueryItem(name: "ids", value: vodId)
            ]
            
            // 加载 extend
            if let ext = sourceBean.ext, !ext.isEmpty {
                let extend = await resolveExtend(ext)
                if !extend.isEmpty {
                    queryItems.append(URLQueryItem(name: "extend", value: extend))
                }
            }
            url = try buildURL(base: api, queryItems: queryItems)
        } else {
            // JSON 接口 (type=1)
            url = try buildURL(
                base: api,
                queryItems: [
                    URLQueryItem(name: "ac", value: "detail"),
                    URLQueryItem(name: "ids", value: vodId)
                ]
            )
        }
        
        let jsonStr = try await network.getString(from: url)
        return try parseDetail(jsonStr, sourceKey: sourceBean.key, type: sourceBean.type)
    }
    
    private func parseDetail(_ jsonStr: String, sourceKey: String, type: Int) throws -> VodInfo? {
        if type == 0 {
            return try CMSXMLResponseParser.parse(Data(jsonStr.utf8), sourceKey: sourceKey).details.first
        }
        
        guard let data = jsonStr.data(using: .utf8) else {
            throw SourceError.parseError("无法解析数据")
        }
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = json["list"] as? [[String: Any]],
           let first = list.first {
            
            let decoder = JSONDecoder()
            if let itemData = try? JSONSerialization.data(withJSONObject: first),
               var video = try? decoder.decode(Movie.Video.self, from: itemData) {
                video.sourceKey = sourceKey
                
                let playFrom = first["vod_play_from"] as? String ?? ""
                let playUrl = first["vod_play_url"] as? String ?? ""
                
                return VodInfo.from(video: video, playFrom: playFrom, playUrl: playUrl)
            }
        }
        
        return nil
    }
    
    // MARK: - 搜索
    
    /// 在指定源中搜索
    func search(sourceBean: SourceBean, keyword: String) async throws -> [Movie.Video] {
        if sourceBean.type == 3 {
            return try await SpiderGatewayService.shared.search(source: sourceBean, keyword: keyword)
        }
        let api = sourceBean.api
        guard !api.isEmpty else { throw SourceError.emptyApi }
        guard sourceBean.isSupportedInSwift else { throw SourceError.unsupportedType(sourceBean.typeDescription) }
        guard sourceBean.isHttpApi else { throw SourceError.invalidApiUrl(api) }
        
        let url: String
        if sourceBean.type == 0 {
            url = try buildURL(
                base: api,
                queryItems: [URLQueryItem(name: "wd", value: keyword)]
            )
        } else if sourceBean.type == 4 {
            // Type 4: 远程接口
            let quickValue = sourceBean.isQuickSearchEnabled ? "true" : "false"
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "wd", value: keyword),
                URLQueryItem(name: "ac", value: "detail"),
                URLQueryItem(name: "quick", value: quickValue)
            ]
            
            // 加载 extend
            if let ext = sourceBean.ext, !ext.isEmpty {
                let extend = await resolveExtend(ext)
                if !extend.isEmpty {
                    queryItems.append(URLQueryItem(name: "extend", value: extend))
                }
            }
            url = try buildURL(base: api, queryItems: queryItems)
        } else {
            // JSON 接口 (type=1)
            url = try buildURL(
                base: api,
                queryItems: [URLQueryItem(name: "wd", value: keyword)]
            )
        }
        
        // 搜索是交互操作：失败时由其他来源补充结果，不做指数退避重试。
        let jsonStr = try await network.getString(from: url, maxRetries: 0)
        let videos = try parseVideoList(jsonStr, sourceKey: sourceBean.key, type: sourceBean.type)
        return filterSearchResults(videos, keyword: keyword)
    }
    
    /// 多源并发搜索
    func searchAll(
        keyword: String,
        onPartialResults: @escaping @MainActor ([Movie.Video]) -> Void = { _ in }
    ) async -> [Movie.Video] {
        let searchableSources = await ApiConfig.shared.getSearchableSources()
        let homeSource = await ApiConfig.shared.homeSourceBean
        let sources = Self.prioritizedSearchSources(searchableSources, homeSource: homeSource)

        return await withTaskGroup(of: [Movie.Video].self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask { [self] in
                    // 仅对 Spider 源抢跑：同一 CatVod bundle 经网关串行，避免请求乱序排队。
                    // 普通 HTTP 源相互独立，无需人为延迟，直接并发以加快搜索。
                    if index > 0, source.type == 3 {
                        try? await Task.sleep(nanoseconds: 120_000_000)
                    }
                    return await self.searchWithTimeout(source: source, keyword: keyword)
                }
            }
            
            var allResults: [Movie.Video] = []
            for await results in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }
                guard !results.isEmpty else { continue }
                allResults.append(contentsOf: results)
                await onPartialResults(allResults)
            }
            return allResults
        }
    }

    /// 主页源优先，并在网盘源与在线影视源之间保留搜索名额，避免任一类型挤满并发队列。
    static func prioritizedSearchSources(
        _ sources: [SourceBean],
        homeSource: SourceBean?,
        limit: Int = 12
    ) -> [SourceBean] {
        let maximumCount = max(1, limit)
        let eligible = sources.enumerated().filter {
            $0.element.isSearchable && $0.element.isSupportedInSwift && ($0.element.type == 3 || $0.element.isHttpApi)
        }
        let homeKey = homeSource?.key
        var selected: [SourceBean] = []
        if let home = eligible.first(where: { $0.element.key == homeKey })?.element {
            selected.append(home)
        }

        let remaining = eligible.filter { $0.element.key != homeKey }
        let panSources = remaining.filter(\.element.isSearchOnly).sorted { left, right in
            let leftPriority = panSearchPriority(left.element)
            let rightPriority = panSearchPriority(right.element)
            if leftPriority != rightPriority {
                return leftPriority < rightPriority
            }
            return left.offset < right.offset
        }
        let regularSources = remaining.filter { !$0.element.isSearchOnly }.sorted { left, right in
            if left.element.isQuickSearchEnabled != right.element.isQuickSearchEnabled {
                return left.element.isQuickSearchEnabled
            }
            return left.offset < right.offset
        }

        // 分享目录与网盘聚合不同：它们可提供首页，但仍依赖网盘登录。
        // 若配置将大量分享目录排在前面，按 2:1 取普通影视与分享目录，
        // 避免 12 个搜索名额全部落到同一类需要登录的资源上。
        let shareCatalogs = regularSources.filter(\.element.isCloudShareCatalog)
        let streamingSources = regularSources.filter { !$0.element.isCloudShareCatalog }
        var balancedRegularSources: [SourceBean] = []
        for index in 0..<max(shareCatalogs.count, (streamingSources.count + 1) / 2) {
            for streamingIndex in (index * 2)..<(index * 2 + 2) where streamingIndex < streamingSources.count {
                balancedRegularSources.append(streamingSources[streamingIndex].element)
            }
            if index < shareCatalogs.count { balancedRegularSources.append(shareCatalogs[index].element) }
        }

        var available = maximumCount - selected.count
        guard available > 0 else { return Array(selected.prefix(maximumCount)) }

        // 正常的 12 路扇出最多先给网盘源 1/3；极小 limit 下仍保证至少有一个网盘入口。
        let initialPanCount = panSources.isEmpty ? 0 : min(panSources.count, max(1, available / 3))
        selected.append(contentsOf: panSources.prefix(initialPanCount).map(\.element))
        available = maximumCount - selected.count
        selected.append(contentsOf: balancedRegularSources.prefix(available))
        available = maximumCount - selected.count
        if available > 0 {
            selected.append(
                contentsOf: panSources.dropFirst(initialPanCount).prefix(available).map(\.element)
            )
        }
        return selected
    }

    private static func panSearchPriority(_ source: SourceBean) -> Int {
        if source.key == SourceBean.cloudPanKey { return 0 }
        if source.key == SourceBean.kkPanSearchKey { return 1 }
        return 2
    }

    /// 普通慢源最多占用 8 秒；网盘聚合服务需要等待异步插件汇总，单独放宽到 20 秒。
    private func searchWithTimeout(source: SourceBean, keyword: String) async -> [Movie.Video] {
        await withTaskGroup(of: [Movie.Video].self) { group in
            group.addTask { [self] in
                do {
                    return try await search(sourceBean: source, keyword: keyword)
                } catch {
                    return []
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: Self.searchTimeoutNanoseconds(for: source))
                return []
            }
            let result = await group.next() ?? []
            group.cancelAll()
            return result
        }
    }

    static func searchTimeoutNanoseconds(for source: SourceBean) -> UInt64 {
        source.isSearchOnly ? 20_000_000_000 : 8_000_000_000
    }

    /// type=3 剧集在播放前调用 Spider playerContent；其他类型保持原地址。
    func resolvePlayback(sourceBean: SourceBean, flag: String, episodeID: String) async throws -> SpiderPlaybackResult {
        if sourceBean.type == 3 {
            return try await SpiderGatewayService.shared.player(
                source: sourceBean,
                flag: flag,
                id: episodeID
            )
        }
        return SpiderPlaybackResult(url: episodeID, headers: [:], qualityOptions: [])
    }
    
    /// 对源返回结果做本地关键词过滤，规避部分接口返回推荐/无关内容。
    private func filterSearchResults(_ videos: [Movie.Video], keyword: String) -> [Movie.Video] {
        let tokens = keyword
            .split(whereSeparator: \.isWhitespace)
            .map { normalizeSearchText(String($0)) }
            .filter { !$0.isEmpty }
        
        guard !tokens.isEmpty else { return videos }
        
        return videos.filter { video in
            let searchableText = normalizeSearchText([
                video.name,
                video.note,
                video.actor,
                video.director,
                video.type,
                video.area,
                video.year
            ].joined(separator: " "))
            guard !searchableText.isEmpty else { return false }
            return tokens.allSatisfy { searchableText.contains($0) }
        }
    }
    
    private func normalizeSearchText(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        let scalars = folded.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
            !CharacterSet.punctuationCharacters.contains(scalar) &&
            !CharacterSet.symbols.contains(scalar)
        }
        return String(String.UnicodeScalarView(scalars)).lowercased()
    }
    
    // MARK: - Extend 解析
    
    /// 解析 extend 参数（对应 Android 端 getFixUrl）
    /// 如果 extend 是 HTTP URL，则下载其内容作为 extend 值
    /// 如果 extend 是普通字符串，则直接返回
    private func resolveExtend(_ extend: String) async -> String {
        guard !extend.isEmpty else { return "" }
        
        // 非 HTTP URL 直接返回
        guard extend.hasPrefix("http://") || extend.hasPrefix("https://") else {
            return extend
        }

        // TTL 内复用已下载的 extend 内容，避免重复网络请求
        if let cached = await ExtendContentCache.shared.cachedContent(for: extend) {
            return cached
        }

        // 从 HTTP URL 加载 extend 内容
        do {
            let content = try await network.getString(from: extend)
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            // 如果内容过长（>2500），回退到使用原始 URL
            if trimmed.count > 2500 { return extend }
            await ExtendContentCache.shared.store(trimmed, for: extend)
            return trimmed
        } catch {
            return extend
        }
    }

    private func buildURL(base: String, queryItems: [URLQueryItem]) throws -> String {
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmedBase) else {
            throw SourceError.invalidApiUrl(base)
        }
        
        let mergedQueryItems = Self.mergingQueryItems(
            existing: components.queryItems ?? [],
            incoming: queryItems
        )
        components.queryItems = mergedQueryItems
        
        guard let url = components.url else {
            throw SourceError.invalidApiUrl(base)
        }
        return url.absoluteString
    }

    /// 请求参数覆盖配置 URL 中的同名默认值，避免产生 `ac=list&ac=class`。
    static func mergingQueryItems(
        existing: [URLQueryItem],
        incoming: [URLQueryItem]
    ) -> [URLQueryItem] {
        let replacedNames = Set(incoming.map(\.name))
        return existing.filter { !replacedNames.contains($0.name) } + incoming
    }
}

enum SourceError: LocalizedError {
    case emptyApi
    case parseError(String)
    case unsupportedType(String)
    case invalidApiUrl(String)
    
    var errorDescription: String? {
        switch self {
        case .emptyApi: return "接口地址为空"
        case .parseError(let msg): return "数据解析错误: \(msg)"
        case .unsupportedType(let type): return "暂不支持 \(type) 类型的数据源，请切换其他源"
        case .invalidApiUrl(let url):
            return "无效的接口地址: \(SensitiveURLRedactor.redact(url))"
        }
    }
}
