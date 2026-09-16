import Foundation

/// 视频源数据服务 - 对应 Android 版 SourceViewModel.java
/// 负责从各视频源获取分类、列表、详情和搜索数据
class SourceService {
    static let shared = SourceService()
    
    private let network = NetworkManager.shared
    
    private init() {}
    
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
        
        let jsonStr: String
        if sourceBean.type == 0 {
            // XML 接口
            jsonStr = try await network.getString(from: api, maxRetries: maxRetries)
        } else if sourceBean.type == 4 {
            // Type 4: 远程接口，需要 extend 和 filter 参数
            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "filter", value: "true")
            ]
            // 加载 extend
            if let ext = sourceBean.ext, !ext.isEmpty {
                let extend = await resolveExtend(ext)
                if !extend.isEmpty {
                    queryItems.append(URLQueryItem(name: "extend", value: extend))
                }
            }
            let url = try buildURL(base: api, queryItems: queryItems)
            jsonStr = try await network.getString(from: url, maxRetries: maxRetries)
        } else {
            // JSON 接口 (type=1)
            let url = try buildURL(
                base: api,
                queryItems: [URLQueryItem(name: "ac", value: "class")]
            )
            jsonStr = try await network.getString(from: url, maxRetries: maxRetries)
        }
        
        var (sorts, homeVideos) = try parseSort(jsonStr, sourceBean: sourceBean)
        
        // 当大多数推荐视频的 vod_pic 为空时（ac=class 接口常见情况），
        // 额外请求列表接口获取带完整海报的推荐视频
        let picMissingCount = homeVideos.filter { $0.pic.trimmingCharacters(in: .whitespaces).isEmpty }.count
        let needsFallback = homeVideos.isEmpty || picMissingCount > homeVideos.count / 2
        
        if needsFallback && (sourceBean.type == 1 || sourceBean.type == 4) {
            let listUrl: String
            if sourceBean.type == 4 {
                // type=4 用 ac=detail 格式，与 getList 保持一致
                let ext = Data("{}".utf8).base64EncodedString()
                listUrl = try buildURL(
                    base: api,
                    queryItems: [
                        URLQueryItem(name: "ac", value: "detail"),
                        URLQueryItem(name: "filter", value: "true"),
                        URLQueryItem(name: "pg", value: "1"),
                        URLQueryItem(name: "ext", value: ext)
                    ]
                )
            } else {
                // type=1 用 ac=videolist 格式
                listUrl = try buildURL(
                    base: api,
                    queryItems: [
                        URLQueryItem(name: "ac", value: "videolist"),
                        URLQueryItem(name: "pg", value: "1")
                    ]
                )
            }
            if let listStr = try? await network.getString(from: listUrl, maxRetries: maxRetries) {
                let fallback = (try? parseVideoList(listStr, sourceKey: sourceBean.key, type: sourceBean.type)) ?? []
                if !fallback.isEmpty {
                    homeVideos = fallback
                }
            }
        }
        
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
            sorts = parseXMLCategories(from: jsonStr)
        } else {
            // JSON 格式 (type=1, type=4)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // 解析分类
                if let classList = json["class"] as? [[String: Any]] {
                    sorts = Self.categoriesWithFilters(Self.leafCategories(from: classList), object: json)
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

    /// TVBox 的筛选值可能是数字；保留接口参数，并去掉会造成重复控件的键和值。
    static func categoriesWithFilters(_ categories: [MovieSort.SortData], object: [String: Any]) -> [MovieSort.SortData] {
        let filtersByID = object["filters"] as? [String: Any] ?? [:]
        return categories.map { category in
            var category = category
            var keys = Set<String>()
            category.filters = (filtersByID[category.id] as? [[String: Any]] ?? []).compactMap { raw in
                let key = flexibleString(raw["key"])
                guard !key.isEmpty, keys.insert(key).inserted else { return nil }
                var values = Set<String>()
                let options = (raw["value"] as? [[String: Any]] ?? []).compactMap { option -> MovieSort.SortFilter.SortFilterValue? in
                    guard option["v"] != nil else { return nil }
                    let value = flexibleString(option["v"])
                    let name = flexibleString(option["n"])
                    guard !name.isEmpty, values.insert(value).inserted else { return nil }
                    return .init(n: name, v: value)
                }
                guard !options.isEmpty else { return nil }
                return MovieSort.SortFilter(key: key, name: flexibleString(raw["name"]), values: options)
            }
            return category
        }
    }
    
    private func parseXMLCategories(from xml: String) -> [MovieSort.SortData] {
        // 简化的 XML 分类解析
        var sorts: [MovieSort.SortData] = []
        let pattern = "<ty id=\"(\\d+)\"[^>]*>([^<]+)</ty>"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
            for match in matches {
                if let idRange = Range(match.range(at: 1), in: xml),
                   let nameRange = Range(match.range(at: 2), in: xml) {
                    let id = String(xml[idRange])
                    let name = String(xml[nameRange])
                    sorts.append(MovieSort.SortData(id: id, name: name))
                }
            }
        }
        return sorts
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
        
        let jsonStr = try await network.getString(from: url)
        return try parseVideoList(jsonStr, sourceKey: sourceBean.key, type: sourceBean.type)
    }
    
    private func parseVideoList(_ jsonStr: String, sourceKey: String, type: Int) throws -> [Movie.Video] {
        guard let data = jsonStr.data(using: .utf8) else {
            throw SourceError.parseError("无法解析数据")
        }
        
        var videos: [Movie.Video] = []
        
        if type == 0 {
            videos = parseXMLVideoList(from: jsonStr, sourceKey: sourceKey)
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
    
    private func parseXMLVideoList(from xml: String, sourceKey: String) -> [Movie.Video] {
        // 简化 XML 视频列表解析
        var videos: [Movie.Video] = []
        let pattern = "<video>.*?<id>(\\d+)</id>.*?<name><!\\[CDATA\\[(.+?)\\]\\]></name>.*?<pic>(.*?)</pic>.*?<note><!\\[CDATA\\[(.*?)\\]\\]></note>.*?</video>"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) {
            let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
            for match in matches {
                var video = Movie.Video()
                if let r = Range(match.range(at: 1), in: xml) { video.id = String(xml[r]) }
                if let r = Range(match.range(at: 2), in: xml) { video.name = String(xml[r]) }
                if let r = Range(match.range(at: 3), in: xml) { video.pic = String(xml[r]) }
                if let r = Range(match.range(at: 4), in: xml) { video.note = String(xml[r]) }
                video.sourceKey = sourceKey
                videos.append(video)
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
            return parseXMLDetail(jsonStr, sourceKey: sourceKey)
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
                    // 给主页源一个很短的抢跑窗口，避免同一 CatVod bundle 的请求乱序排队。
                    if index > 0 {
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
            $0.element.isSupportedInSwift && ($0.element.type == 3 || $0.element.isHttpApi)
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

        var available = maximumCount - selected.count
        guard available > 0 else { return Array(selected.prefix(maximumCount)) }

        // 正常的 12 路扇出最多先给网盘源 1/3；极小 limit 下仍保证至少有一个网盘入口。
        let initialPanCount = panSources.isEmpty ? 0 : min(panSources.count, max(1, available / 3))
        selected.append(contentsOf: panSources.prefix(initialPanCount).map(\.element))
        available = maximumCount - selected.count
        selected.append(contentsOf: regularSources.prefix(available).map(\.element))
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
        
        // 从 HTTP URL 加载 extend 内容
        do {
            let content = try await network.getString(from: extend)
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            // 如果内容过长（>2500），回退到使用原始 URL
            if trimmed.count > 2500 { return extend }
            return trimmed
        } catch {
            return extend
        }
    }

    private func parseXMLDetail(_ xml: String, sourceKey: String) -> VodInfo? {
        guard let videoBlock = firstMatch(
            pattern: #"<video[\s\S]*?</video>"#,
            in: xml
        ) else {
            return nil
        }
        
        let vodId = extractXMLTag("id", in: videoBlock)
        guard !vodId.isEmpty else { return nil }
        
        var video = Movie.Video(id: vodId)
        video.name = extractXMLTag("name", in: videoBlock)
        video.pic = extractXMLTag("pic", in: videoBlock)
        video.note = extractXMLTag("note", in: videoBlock)
        video.year = extractXMLTag("year", in: videoBlock)
        video.area = extractXMLTag("area", in: videoBlock)
        video.type = extractXMLTag("type", in: videoBlock)
        video.director = extractXMLTag("director", in: videoBlock)
        video.actor = extractXMLTag("actor", in: videoBlock)
        video.des = extractXMLTag("des", in: videoBlock)
        video.sourceKey = sourceKey
        
        let ddNodes = extractXMLDDNodes(from: videoBlock)
        let playFrom: String
        let playUrl: String
        
        if ddNodes.isEmpty {
            playFrom = "默认"
            playUrl = ""
        } else {
            playFrom = ddNodes.map { $0.flag }.joined(separator: "$$$")
            playUrl = ddNodes.map { $0.url }.joined(separator: "$$$")
        }
        
        return VodInfo.from(video: video, playFrom: playFrom, playUrl: playUrl)
    }
    
    private func extractXMLDDNodes(from block: String) -> [(flag: String, url: String)] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<dd([^>]*)>([\s\S]*?)</dd>"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }
        
        let nsRange = NSRange(block.startIndex..<block.endIndex, in: block)
        let matches = regex.matches(in: block, range: nsRange)
        var result: [(flag: String, url: String)] = []
        
        for (index, match) in matches.enumerated() {
            guard match.numberOfRanges >= 3 else { continue }
            guard let attrRange = Range(match.range(at: 1), in: block),
                  let valueRange = Range(match.range(at: 2), in: block) else {
                continue
            }
            
            let attrs = String(block[attrRange])
            let rawUrl = decodeXMLText(String(block[valueRange]))
            guard !rawUrl.isEmpty else { continue }
            
            let flag = firstMatch(
                pattern: #"flag\s*=\s*["']([^"']+)["']"#,
                in: attrs,
                captureGroup: 1
            ) ?? "线路\(index + 1)"
            result.append((flag: decodeXMLText(flag), url: rawUrl))
        }
        
        return result
    }
    
    private func extractXMLTag(_ tag: String, in content: String) -> String {
        let escapedTag = NSRegularExpression.escapedPattern(for: tag)
        let pattern = "<\(escapedTag)>\\s*([\\s\\S]*?)\\s*</\(escapedTag)>"
        let value = firstMatch(pattern: pattern, in: content, captureGroup: 1) ?? ""
        return decodeXMLText(value)
    }
    
    private func firstMatch(pattern: String, in content: String, captureGroup: Int = 0) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        guard let match = regex.firstMatch(in: content, options: [], range: range),
              match.numberOfRanges > captureGroup,
              let subRange = Range(match.range(at: captureGroup), in: content) else {
            return nil
        }
        return String(content[subRange])
    }
    
    private func decodeXMLText(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("<![CDATA["), value.hasSuffix("]]>"), value.count >= 12 {
            value.removeFirst(9)
            value.removeLast(3)
        }
        value = value.replacingOccurrences(of: "&amp;", with: "&")
        value = value.replacingOccurrences(of: "&lt;", with: "<")
        value = value.replacingOccurrences(of: "&gt;", with: ">")
        value = value.replacingOccurrences(of: "&quot;", with: "\"")
        value = value.replacingOccurrences(of: "&#39;", with: "'")
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
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
