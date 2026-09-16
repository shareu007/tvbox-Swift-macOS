import Foundation

/// Spider Gateway 的持久化配置。
enum SpiderGatewaySettings {
    private struct RuntimeGateway {
        let baseURL: String
        let token: String
    }

    private static let runtimeLock = NSLock()
    private nonisolated(unsafe) static var runtimeGateway: RuntimeGateway?

    static var connection: (baseURL: String, token: String) {
        runtimeLock.lock()
        let embeddedGateway = runtimeGateway
        runtimeLock.unlock()
        if let embeddedGateway {
            return (embeddedGateway.baseURL, embeddedGateway.token)
        }
        return (savedBaseURL, savedToken)
    }

    static var baseURL: String {
        connection.baseURL
    }

    static var savedBaseURL: String {
        PrivateSettingsStore.value(
            for: .spiderGatewayURL,
            migratingLegacyKey: HawkConfig.SPIDER_GATEWAY_URL
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var isConfigured: Bool {
        guard let url = URL(string: baseURL), let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    static var token: String {
        connection.token
    }

    static var savedToken: String {
        PrivateSettingsStore.value(
            for: .spiderGatewayToken,
            migratingLegacyKey: HawkConfig.SPIDER_GATEWAY_TOKEN
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func save(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try PrivateSettingsStore.save(
                "",
                for: .spiderGatewayURL,
                legacyKey: HawkConfig.SPIDER_GATEWAY_URL
            )
            return
        }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host,
              !host.isEmpty else {
            throw SpiderGatewayError.invalidGatewayURL
        }
        if scheme == "http", !Self.isLoopbackHost(host) {
            throw SpiderGatewayError.insecureGatewayURL
        }
        try PrivateSettingsStore.save(
            trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            for: .spiderGatewayURL,
            legacyKey: HawkConfig.SPIDER_GATEWAY_URL
        )
    }

    static func saveToken(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        try PrivateSettingsStore.save(
            trimmed,
            for: .spiderGatewayToken,
            legacyKey: HawkConfig.SPIDER_GATEWAY_TOKEN
        )
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        if normalized == "localhost" || normalized == "::1" { return true }
        let components = normalized.split(separator: ".")
        return components.count == 4 && components.first == "127"
    }

    static func useEmbeddedGateway(at value: String?, token: String? = nil) {
        let trimmedURL = value?
            .trimmingCharacters(in: CharacterSet(charactersIn: " /")) ?? ""
        let trimmedToken = token?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        runtimeLock.lock()
        if trimmedURL.isEmpty || trimmedToken.isEmpty {
            runtimeGateway = nil
        } else {
            runtimeGateway = RuntimeGateway(baseURL: trimmedURL, token: trimmedToken)
        }
        runtimeLock.unlock()
    }
}

struct SpiderPlaybackQualityOption: Equatable {
    let name: String
    let url: String
}

struct SpiderPlaybackResult: Equatable {
    let url: String
    let headers: [String: String]
    let qualityOptions: [SpiderPlaybackQualityOption]
}

/// type=3 的远程执行客户端。响应体使用 Spider 标准 JSON。
final class SpiderGatewayService {
    static let shared = SpiderGatewayService()

    private let network = NetworkManager.shared

    private init() {}

    static func isCatVodBundleURL(_ value: String) -> Bool {
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return false
        }
        let path = url.path.lowercased()
        return path.hasSuffix(".js") || path.hasSuffix(".js.md5")
    }

    func catalog(bundleURL: String) async throws -> AppConfigData {
        try await prepareGatewayIfNeeded(
            bundleURL: bundleURL,
            replacingBundleAllowlist: true
        )
        guard SpiderGatewaySettings.isConfigured else { throw SpiderGatewayError.notConfigured }
        let connection = SpiderGatewaySettings.connection
        let endpoint = connection.baseURL + "/v1/catvod/catalog"
        let headers = connection.token.isEmpty
            ? nil
            : ["Authorization": "Bearer \(connection.token)"]
        let response: String
        do {
            response = try await network.postJSON(
                to: endpoint,
                body: CatVodCatalogRequest(bundle: bundleURL),
                headers: headers,
                maxRetries: 0
            )
        } catch NetworkError.serverError(_, let message) {
            throw SpiderGatewayError.remote(message)
        }
        guard let data = response.data(using: .utf8),
              let config = try? JSONDecoder().decode(AppConfigData.self, from: data),
              config.hasUsableContent else {
            throw SpiderGatewayError.invalidResponse
        }
        return config
    }

    func home(source: SourceBean) async throws -> (sorts: [MovieSort.SortData], homeVideos: [Movie.Video]) {
        let object = try await invoke(source: source, action: "home", arguments: [
            "filter": .bool(true)
        ])
        return (parseSorts(object), parseVideos(object, sourceKey: source.key))
    }

    func category(
        source: SourceBean,
        tid: String,
        page: Int,
        filters: [String: String]?
    ) async throws -> [Movie.Video] {
        let extend = (filters ?? [:]).mapValues(AnyCodableValue.string)
        let object = try await invoke(source: source, action: "category", arguments: [
            "tid": .string(tid),
            "page": .string(String(page)),
            "filter": .bool(source.isFilterable),
            "extend": .dict(extend)
        ])
        return parseVideos(object, sourceKey: source.key)
    }

    func detail(source: SourceBean, id: String, verifyResource: Bool = false) async throws -> VodInfo? {
        let object = try await invoke(source: source, action: "detail", arguments: [
            "ids": .array([.string(id)]),
            "verifyResource": .bool(verifyResource)
        ])
        guard let first = (object["list"] as? [[String: Any]])?.first,
              let data = try? JSONSerialization.data(withJSONObject: first),
              var video = try? JSONDecoder().decode(Movie.Video.self, from: data) else {
            return nil
        }
        video.sourceKey = source.key
        let playFrom = first["vod_play_from"] as? String ?? ""
        let playURL = first["vod_play_url"] as? String ?? ""
        return VodInfo.from(video: video, playFrom: playFrom, playUrl: playURL)
    }

    func search(source: SourceBean, keyword: String, page: Int = 1) async throws -> [Movie.Video] {
        let object = try await invoke(source: source, action: "search", arguments: [
            "keyword": .string(keyword),
            "quick": .bool(source.isQuickSearchEnabled),
            "page": .string(String(page))
        ])
        return parseVideos(object, sourceKey: source.key)
    }

    func player(source: SourceBean, flag: String, id: String) async throws -> SpiderPlaybackResult {
        let object = try await invoke(source: source, action: "player", arguments: [
            "flag": .string(flag),
            "id": .string(id),
            "vipFlags": .array([])
        ])
        let parse = flexibleInt(object["parse"])
        let jx = flexibleInt(object["jx"])
        guard parse != 1, jx != 1 else { throw SpiderGatewayError.parseNotSupported }

        let url: String
        if let string = object["url"] as? String {
            url = string
        } else if let urls = object["url"] as? [String] {
            url = urls.first ?? ""
        } else {
            url = ""
        }
        guard !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SpiderGatewayError.emptyPlayerURL
        }
        return SpiderPlaybackResult(
            url: url,
            headers: sanitizedHeaders(object["header"]),
            qualityOptions: Self.playbackQualityOptions(from: object)
        )
    }

    static func playbackQualityOptions(from object: [String: Any]) -> [SpiderPlaybackQualityOption] {
        guard let values = object["qualityOptions"] as? [[String: Any]] else { return [] }
        var seenURLs = Set<String>()
        return values.compactMap { value in
            guard let name = (value["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty,
                  let url = (value["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !url.isEmpty,
                  seenURLs.insert(url).inserted else {
                return nil
            }
            return SpiderPlaybackQualityOption(name: name, url: url)
        }
    }

    private func invoke(
        source: SourceBean,
        action: String,
        arguments: [String: AnyCodableValue]
    ) async throws -> [String: Any] {
        guard source.api.hasPrefix("csp_") || source.api.hasPrefix("/spider/") else {
            throw SpiderGatewayError.unsupportedAPI(source.api)
        }
        guard let jar = source.jar, !jar.isEmpty else { throw SpiderGatewayError.missingJar }
        try await prepareGatewayIfNeeded(bundleURL: jar)
        guard SpiderGatewaySettings.isConfigured else { throw SpiderGatewayError.notConfigured }

        let request = SpiderInvokeRequest(
            version: 1,
            action: action,
            site: .init(
                key: source.key,
                api: source.api,
                jar: jar,
                ext: source.ext ?? "",
                quickSearch: source.isQuickSearchEnabled
            ),
            arguments: .dict(arguments)
        )
        let connection = SpiderGatewaySettings.connection
        let endpoint = connection.baseURL + "/v1/spider/invoke"
        let headers = connection.token.isEmpty
            ? nil
            : ["Authorization": "Bearer \(connection.token)"]
        let response: String
        do {
            response = try await network.postJSON(
                to: endpoint,
                body: request,
                headers: headers,
                maxRetries: 0
            )
        } catch NetworkError.serverError(_, let message) {
            throw SpiderGatewayError.remote(message)
        }
        guard let data = response.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SpiderGatewayError.invalidResponse
        }
        if let message = object["message"] as? String, object["code"] != nil {
            throw SpiderGatewayError.remote(message)
        }
        return object
    }

    private func prepareGatewayIfNeeded(
        bundleURL: String? = nil,
        replacingBundleAllowlist: Bool = false
    ) async throws {
#if os(macOS)
        do {
            _ = try await EmbeddedSpiderGateway.shared.ensureStarted(
                allowedBundleURL: bundleURL,
                replacingAllowlist: replacingBundleAllowlist
            )
        } catch {
            // 开发或迁移场景仍可使用此前保存的外部 Gateway。
            guard !SpiderGatewaySettings.savedBaseURL.isEmpty else { throw error }
        }
#endif
    }

    private func parseSorts(_ object: [String: Any]) -> [MovieSort.SortData] {
        guard let values = object["class"] as? [[String: Any]] else { return [] }
        return SourceService.categoriesWithFilters(SourceService.leafCategories(from: values), object: object)
    }

    private func parseVideos(_ object: [String: Any], sourceKey: String) -> [Movie.Video] {
        guard let values = object["list"] as? [[String: Any]] else { return [] }
        return values.compactMap { item in
            guard let data = try? JSONSerialization.data(withJSONObject: item),
                  var video = try? JSONDecoder().decode(Movie.Video.self, from: data) else { return nil }
            video.sourceKey = sourceKey
            return video
        }
    }

    private func flexibleInt(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    private func sanitizedHeaders(_ value: Any?) -> [String: String] {
        guard let headers = value as? [String: String] else { return [:] }
        return Dictionary(uniqueKeysWithValues: headers.prefix(32).compactMap { name, value in
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty,
                  trimmedName.count <= 64,
                  value.count <= 8_192,
                  !trimmedName.contains("\r"), !trimmedName.contains("\n"),
                  !value.contains("\r"), !value.contains("\n") else {
                return nil
            }
            return (trimmedName, value)
        })
    }
}

private struct SpiderInvokeRequest: Encodable {
    struct Site: Encodable {
        let key: String
        let api: String
        let jar: String
        let ext: String
        let quickSearch: Bool
    }

    let version: Int
    let action: String
    let site: Site
    let arguments: AnyCodableValue
}

private struct CatVodCatalogRequest: Encodable {
    let bundle: String
}

enum SpiderGatewayError: LocalizedError {
    case notConfigured
    case invalidGatewayURL
    case insecureGatewayURL
    case missingJar
    case unsupportedAPI(String)
    case invalidResponse
    case emptyPlayerURL
    case parseNotSupported
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "请先在设置中配置 Spider Gateway"
        case .invalidGatewayURL: return "Spider Gateway 地址必须是 HTTP 或 HTTPS URL"
        case .insecureGatewayURL: return "远程 Spider Gateway 必须使用 HTTPS；HTTP 仅允许本机回环地址"
        case .missingJar: return "该 Spider 源没有配置运行包地址"
        case .unsupportedAPI(let api): return "Spider Gateway 不支持 API：\(api)"
        case .invalidResponse: return "Spider Gateway 返回了无效响应"
        case .emptyPlayerURL: return "Spider 没有返回可播放地址"
        case .parseNotSupported: return "该播放地址需要网页解析，当前版本暂不支持"
        case .remote(let message): return "Spider 执行失败：\(message)"
        }
    }
}
