import Foundation
import SwiftUI

/// 设置 ViewModel
@MainActor
class SettingsViewModel: ObservableObject {
    /// 当输入地址是“多仓库入口”时，先弹出候选仓库供用户确认。
    struct PendingMultiRepoSelection: Identifiable {
        /// 当前待选择的是点播仓库还是直播仓库。
        enum Target {
            case vod
            case live
            
            var title: String {
                switch self {
                case .vod: return "点播"
                case .live: return "直播"
                }
            }
        }
        
        let id = UUID()
        /// 目标类型。
        let target: Target
        /// 用户原始输入地址（用于后续“是否联动 live 地址”判断）。
        let sourceUrl: String
        /// 可选仓库列表。
        let options: [ApiConfig.MultiRepoOption]
    }
    
    /// 点播配置地址。
    @Published var vodApiUrl: String = ""
    /// 直播配置地址。
    @Published var liveApiUrl: String = ""
    /// type=3 JAR/Spider 的远程执行服务地址。
    @Published var spiderGatewayUrl: String = ""
    /// Spider Gateway 的可选 Bearer Token。
    @Published var spiderGatewayToken: String = ""
    /// 配置加载中状态。
    @Published var isLoadingConfig = false
    /// 配置错误提示。
    @Published var configError: String?
    /// 配置是否加载成功（供 UI 执行后续跳转/收起流程）。
    @Published var configSuccess = false
    /// 多仓库待选状态，为 nil 表示无需弹窗。
    @Published var pendingMultiRepoSelection: PendingMultiRepoSelection?
    /// 最近输入过的 API 历史。
    @Published var apiHistory: [String] = []
    /// 用户成功加载过的点播配置列表，保存在本机私有设置文件中。
    @Published var savedVodConfigs: [SavedVodConfig] = []
    /// 最近一次配置协议与兼容性检测结果。
    @Published var configInspectionResult: VodConfigInspectionResult?
    /// 点播播放器内核选择。
    @Published var vodPlayerEngine: PlayerEngine = .system
    /// 直播播放器内核选择。
    @Published var livePlayerEngine: PlayerEngine = .system
    /// 解码模式选择。
    @Published var decodeMode: VideoDecodeMode = .auto
    /// VLC 缓冲策略。
    @Published var vlcBufferMode: VLCBufferMode = .defaultMode
    /// 快进/快退步长（秒）。
    @Published var playTimeStep: Int = 10
    /// 缓存占用展示文本。
    @Published var cacheSizeString: String = "0 KB"
    
    /// 快进步长候选项。
    let playTimeStepOptions: [Int] = [5, 10, 15, 30, 60]
    /// 当前构建可用播放器列表。
    let playerEngineOptions: [PlayerEngine] = PlayerEngine.availableEngines
    /// 解码模式候选。
    let decodeModeOptions: [VideoDecodeMode] = VideoDecodeMode.allCases
    /// VLC 缓冲模式候选。
    let vlcBufferModeOptions: [VLCBufferMode] = VLCBufferMode.allCases
    /// 随当前构建打包的候选配置；成功加载后也会加入用户的点播配置列表。
    let configPresets: [TVBoxConfigPreset] = TVBoxConfigPreset.all
    /// 多仓库选择前记录是否需要在最终加载后展示检测结果。
    private var presentsInspectionAfterPendingSelection = false

    /// 当前点播地址匹配到的用户配置。
    var selectedSavedVodConfig: SavedVodConfig? {
        Self.matchingSavedConfig(for: vodApiUrl, in: savedVodConfigs)
    }

    /// 设置页展示的当前点播配置名称。
    var currentVodConfigLabel: String {
        selectedSavedVodConfig?.name ?? (vodApiUrl.isEmpty ? "未配置" : "未加入列表")
    }
    
    /// 初始化时完成三件事：
    /// 1) 回填已保存的配置地址
    /// 2) 兼容老版本单一播放器字段到新字段
    /// 3) 回填播放/缓存相关设置
    init() {
        let defaults = UserDefaults.standard
        let savedVod = PrivateSettingsStore.value(
            for: .vodURL,
            migratingLegacyKey: HawkConfig.API_URL
        )
        vodApiUrl = savedVod
        spiderGatewayUrl = SpiderGatewaySettings.savedBaseURL
        spiderGatewayToken = SpiderGatewaySettings.savedToken
        liveApiUrl = PrivateSettingsStore.value(
            for: .liveURL,
            migratingLegacyKey: HawkConfig.LIVE_API_URL
        )
        loadSavedVodConfigs(migratingCurrentURL: savedVod)
        loadApiHistory()
        let hasLegacyPlayer = defaults.object(forKey: HawkConfig.PLAY_TYPE) != nil
        let legacyPlayerRaw = defaults.integer(forKey: HawkConfig.PLAY_TYPE)
        let defaultVodRaw = PlayerEngine.system.rawValue
        let defaultLiveRaw = PlayerEngine.isVLCAvailable
            ? PlayerEngine.vlc.rawValue
            : PlayerEngine.system.rawValue
        if defaults.object(forKey: HawkConfig.PLAY_TYPE_VOD) == nil {
            defaults.set(hasLegacyPlayer ? legacyPlayerRaw : defaultVodRaw, forKey: HawkConfig.PLAY_TYPE_VOD)
        }
        if defaults.object(forKey: HawkConfig.PLAY_TYPE_LIVE) == nil {
            defaults.set(hasLegacyPlayer ? legacyPlayerRaw : defaultLiveRaw, forKey: HawkConfig.PLAY_TYPE_LIVE)
        }
        vodPlayerEngine = PlayerEngine.fromStoredValue(
            defaults.integer(forKey: HawkConfig.PLAY_TYPE_VOD)
        )
        livePlayerEngine = PlayerEngine.fromStoredValue(
            defaults.integer(forKey: HawkConfig.PLAY_TYPE_LIVE)
        )
        decodeMode = VideoDecodeMode.fromStoredValue(
            defaults.integer(forKey: HawkConfig.PLAY_DECODE_MODE)
        )
        vlcBufferMode = VLCBufferMode.fromStoredValue(
            defaults.integer(forKey: HawkConfig.PLAY_VLC_BUFFER_MODE)
        )
        
        let savedStep = defaults.integer(forKey: HawkConfig.PLAY_TIME_STEP)
        playTimeStep = savedStep > 0 ? savedStep : 10
        refreshCacheSize()
    }

    /// 确认检测结果后，再执行输入窗口的关闭动作。
    func dismissConfigInspection(closeInput: () -> Void = {}) {
        // 结果只消费一次；先清空再离开结果页，重新打开输入窗口时不会带入旧结果。
        configInspectionResult = nil
        closeInput()
    }

    /// 保存 Spider Gateway 地址；空值表示关闭 type=3 支持。
    @discardableResult
    func saveSpiderGateway() -> Bool {
        do {
            try SpiderGatewaySettings.save(spiderGatewayUrl)
            try SpiderGatewaySettings.saveToken(spiderGatewayToken)
            spiderGatewayUrl = SpiderGatewaySettings.savedBaseURL
            spiderGatewayToken = SpiderGatewaySettings.savedToken
            if !SpiderGatewaySettings.isConfigured,
               ApiConfig.shared.homeSourceBean?.type == 3,
               let fallback = ApiConfig.shared.sourceBeanList.first(where: { $0.isSupportedInSwift }) {
                ApiConfig.shared.setHomeSource(fallback)
            }
            configError = nil
            return true
        } catch {
            configError = error.localizedDescription
            return false
        }
    }
    
    /// 加载配置
    func loadConfig(presentInspection: Bool = false) async {
        guard !isLoadingConfig else { return }
        configInspectionResult = nil
        let trimmedVod = vodApiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLive = liveApiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVod.isEmpty else {
            configError = "请输入点播接口地址"
            return
        }
        
        isLoadingConfig = true
        configError = nil
        configSuccess = false
        pendingMultiRepoSelection = nil
        
        do {
            let resolvedLive = trimmedLive.isEmpty ? trimmedVod : trimmedLive
            
            // 若探测到多仓库入口，先中断加载并弹出候选，让用户显式选定目标仓库。
            if let pending = try await detectPendingMultiRepoSelection(
                vodUrl: trimmedVod,
                liveUrl: resolvedLive
            ) {
                presentsInspectionAfterPendingSelection = presentInspection
                pendingMultiRepoSelection = pending
                isLoadingConfig = false
                return
            }
            
            try await ApiConfig.shared.loadConfigs(vodApiUrl: trimmedVod, liveApiUrl: resolvedLive)
            // URL 可能含 Basic Auth 或签名参数，只写入当前用户私有文件。
            try PrivateSettingsStore.save(
                trimmedVod,
                for: .vodURL,
                legacyKey: HawkConfig.API_URL
            )
            try PrivateSettingsStore.save(
                trimmedLive,
                for: .liveURL,
                legacyKey: HawkConfig.LIVE_API_URL
            )
            vodApiUrl = trimmedVod
            liveApiUrl = trimmedLive
            addToApiHistory(trimmedVod)
            addToApiHistory(resolvedLive)
            let inspection = Self.inspectLoadedConfig(
                entryURL: trimmedVod,
                sources: ApiConfig.shared.sourceBeanList
            )
            do {
                try saveLoadedVodConfig(url: trimmedVod, inspection: inspection)
                if presentInspection {
                    configInspectionResult = inspection
                }
            } catch {
                configError = "配置已加载，但无法保存到我的配置：\(error.localizedDescription)"
            }
            configSuccess = true
        } catch {
            configError = error.localizedDescription
        }
        
        isLoadingConfig = false
    }

    /// 选择候选配置并立即加载；成功后自动加入“我的点播配置”。
    /// 若加载失败，则恢复进入候选前的输入，避免未生效地址伪装成当前配置。
    func loadPreset(_ preset: TVBoxConfigPreset) async {
        guard preset.compatibility.isSelectable else { return }
        let previousVodUrl = vodApiUrl
        let previousLiveUrl = liveApiUrl
        vodApiUrl = preset.url
        liveApiUrl = ""
        await loadConfig(presentInspection: true)
        if !configSuccess, pendingMultiRepoSelection == nil {
            vodApiUrl = previousVodUrl
            liveApiUrl = previousLiveUrl
        }
    }

    /// 切换到用户已保存的点播配置。
    func loadSavedVodConfig(_ config: SavedVodConfig) async {
        guard !isLoadingConfig else { return }
        let previousVodUrl = vodApiUrl
        let previousLiveUrl = liveApiUrl
        vodApiUrl = config.url
        liveApiUrl = ""
        // 列表已展示检测报告；切换只更新行状态，避免向隐藏的设置页发送 Alert。
        await loadConfig(presentInspection: false)
        if !configSuccess, pendingMultiRepoSelection == nil {
            vodApiUrl = previousVodUrl
            liveApiUrl = previousLiveUrl
        }
    }

    /// 从“我的点播配置”移除一项；不会中断当前已经加载的播放配置。
    func removeSavedVodConfig(_ config: SavedVodConfig) {
        let previousConfigs = savedVodConfigs
        savedVodConfigs.removeAll { $0.id == config.id }
        do {
            try persistSavedVodConfigs()
            SourceVerificationStore.shared.remove(configURL: config.url)
            configError = nil
        } catch {
            savedVodConfigs = previousConfigs
            configError = error.localizedDescription
        }
    }

    /// 用规范化后的 URL 判断当前地址是否来自某个构建候选。
    static func matchingPreset(
        for url: String,
        in presets: [TVBoxConfigPreset]
    ) -> TVBoxConfigPreset? {
        let normalizedURL = ApiConfig.normalizeConfigUrl(url)
        guard !normalizedURL.isEmpty else { return nil }
        return presets.first {
            ApiConfig.normalizeConfigUrl($0.url) == normalizedURL
        }
    }

    /// 用规范化后的 URL 判断当前地址是否已保存在用户配置列表。
    static func matchingSavedConfig(
        for url: String,
        in configs: [SavedVodConfig]
    ) -> SavedVodConfig? {
        let normalizedURL = ApiConfig.normalizeConfigUrl(url)
        guard !normalizedURL.isEmpty else { return nil }
        return configs.first {
            ApiConfig.normalizeConfigUrl($0.url) == normalizedURL
        }
    }

    /// 根据已解析出的站点类型生成协议和兼容性结论。
    static func inspectLoadedConfig(
        entryURL: String,
        sources: [SourceBean]
    ) -> VodConfigInspectionResult {
        let configurationProtocol = inferredConfigurationProtocol(for: entryURL)
        let pointSources = sources.filter { !$0.isSearchOnly }
        let sourceProtocols = Array(Set(pointSources.map(\.typeDescription))).sorted()
        let supportedCount = pointSources.filter(\.isSupportedInSwift).count
        let compatibility: SavedVodConfig.Compatibility
        if pointSources.isEmpty || supportedCount == 0 {
            compatibility = .incompatible
        } else if supportedCount == pointSources.count {
            compatibility = .compatible
        } else {
            compatibility = .partial
        }
        return VodConfigInspectionResult(
            configurationProtocol: configurationProtocol,
            sourceProtocols: sourceProtocols,
            compatibility: compatibility,
            supportedSourceCount: supportedCount,
            totalSourceCount: pointSources.count
        )
    }

    /// 无需发起网络请求即可识别的配置入口协议。
    static func inferredConfigurationProtocol(for entryURL: String) -> String {
        SpiderGatewayService.isCatVodBundleURL(entryURL)
            ? "CatVod JavaScript"
            : "TVBox JSON"
    }

    /// 设置页出现时，用当前已经加载完成的数据补齐旧配置的协议和适配状态。
    func refreshCurrentVodConfigInspectionIfAvailable() {
        let apiConfig = ApiConfig.shared
        let normalizedCurrent = ApiConfig.normalizeConfigUrl(vodApiUrl)
        let normalizedLoaded = ApiConfig.normalizeConfigUrl(apiConfig.configUrl)
        guard apiConfig.isLoaded,
              !normalizedCurrent.isEmpty,
              normalizedCurrent == normalizedLoaded else {
            return
        }

        let inspection = Self.inspectLoadedConfig(
            entryURL: vodApiUrl,
            sources: apiConfig.sourceBeanList
        )
        do {
            try saveLoadedVodConfig(url: vodApiUrl, inspection: inspection)
            configError = nil
        } catch {
            configError = "无法更新点播配置状态：\(error.localizedDescription)"
        }
    }
    
    /// 处理多仓库弹窗选择结果，并继续走统一加载流程。
    func selectPendingMultiRepoOption(_ option: ApiConfig.MultiRepoOption) async {
        guard let pending = pendingMultiRepoSelection else { return }
        let normalizedSource = ApiConfig.normalizeConfigUrl(pending.sourceUrl)
        
        switch pending.target {
        case .vod:
            let normalizedLive = ApiConfig.normalizeConfigUrl(liveApiUrl)
            // 若 live 输入与原始 vod 相同，说明用户希望两者共用，选择后同步更新。
            let shouldSyncLive = !liveApiUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && normalizedLive == normalizedSource
            vodApiUrl = option.url
            if shouldSyncLive {
                liveApiUrl = option.url
            }
        case .live:
            liveApiUrl = option.url
        }
        
        pendingMultiRepoSelection = nil
        let presentInspection = presentsInspectionAfterPendingSelection
        presentsInspectionAfterPendingSelection = false
        await loadConfig(presentInspection: presentInspection)
    }
    
    /// 取消多仓库选择，恢复到普通待输入状态。
    func cancelPendingMultiRepoSelection() {
        pendingMultiRepoSelection = nil
        presentsInspectionAfterPendingSelection = false
        isLoadingConfig = false
    }
    
    /// 尝试识别输入地址是否为多仓库入口。
    /// - Returns: 需要弹窗选择时返回待选对象，否则返回 `nil`。
    private func detectPendingMultiRepoSelection(
        vodUrl: String,
        liveUrl: String
    ) async throws -> PendingMultiRepoSelection? {
        if let vodOptions = try await ApiConfig.shared.fetchMultiRepoOptions(from: vodUrl) {
            guard !vodOptions.isEmpty else {
                throw ConfigError.parseError("点播多仓库配置中没有可用地址")
            }
            return PendingMultiRepoSelection(
                target: .vod,
                sourceUrl: vodUrl,
                options: vodOptions
            )
        }
        
        let normalizedVod = ApiConfig.normalizeConfigUrl(vodUrl)
        let normalizedLive = ApiConfig.normalizeConfigUrl(liveUrl)
        guard normalizedLive != normalizedVod else {
            return nil
        }
        
        if let liveOptions = try await ApiConfig.shared.fetchMultiRepoOptions(from: liveUrl) {
            guard !liveOptions.isEmpty else {
                throw ConfigError.parseError("直播多仓库配置中没有可用地址")
            }
            return PendingMultiRepoSelection(
                target: .live,
                sourceUrl: liveUrl,
                options: liveOptions
            )
        }
        
        return nil
    }
    
    // MARK: - 用户点播配置

    /// 读取用户配置列表，并把升级前已经保存的当前点播地址纳入列表。
    private func loadSavedVodConfigs(migratingCurrentURL currentURL: String) {
        let stored = PrivateSettingsStore.value(for: .savedVodConfigs)
        savedVodConfigs = SavedVodConfig.decode(from: stored)
            .sorted { $0.lastUsedAt > $1.lastUsedAt }

        let trimmedURL = currentURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return }

        var needsPersistence = false
        for index in savedVodConfigs.indices
        where ["待检测", "待重新加载检测"].contains(
            savedVodConfigs[index].configurationProtocol
        ) {
            savedVodConfigs[index].configurationProtocol = Self.inferredConfigurationProtocol(
                for: savedVodConfigs[index].url
            )
            needsPersistence = true
        }

        if Self.matchingSavedConfig(for: trimmedURL, in: savedVodConfigs) == nil {
            savedVodConfigs.insert(
                SavedVodConfig(
                    name: SavedVodConfig.displayName(for: trimmedURL),
                    url: trimmedURL,
                    configurationProtocol: Self.inferredConfigurationProtocol(for: trimmedURL),
                    compatibility: .unknown
                ),
                at: 0
            )
            needsPersistence = true
        }

        if needsPersistence {
            try? persistSavedVodConfigs()
        }
    }

    /// 新增或更新配置检测信息，并将最近使用项放到列表首位。
    private func saveLoadedVodConfig(
        url: String,
        inspection: VodConfigInspectionResult
    ) throws {
        let existing = Self.matchingSavedConfig(for: url, in: savedVodConfigs)
        let item = SavedVodConfig(
            id: existing?.id ?? UUID(),
            name: existing?.name ?? SavedVodConfig.displayName(for: url),
            url: url,
            configurationProtocol: inspection.configurationProtocol,
            sourceProtocols: inspection.sourceProtocols,
            compatibility: inspection.compatibility,
            supportedSourceCount: inspection.supportedSourceCount,
            totalSourceCount: inspection.totalSourceCount,
            protocolCheckedAt: inspection.checkedAt,
            lastUsedAt: Date()
        )
        savedVodConfigs.removeAll {
            ApiConfig.normalizeConfigUrl($0.url) == ApiConfig.normalizeConfigUrl(url)
        }
        savedVodConfigs.insert(item, at: 0)
        if savedVodConfigs.count > 30 {
            savedVodConfigs = Array(savedVodConfigs.prefix(30))
        }
        try persistSavedVodConfigs()
        SourceVerificationStore.shared.register(configURL: url, sources: ApiConfig.shared.sourceBeanList)
    }

    private func persistSavedVodConfigs() throws {
        let encoded = try SavedVodConfig.encode(savedVodConfigs)
        try PrivateSettingsStore.save(encoded, for: .savedVodConfigs)
    }

    // MARK: - API 历史
    
    /// 读取 API 历史。
    private func loadApiHistory() {
        let defaults = UserDefaults.standard
        let stored = defaults.stringArray(forKey: "api_history") ?? []
        apiHistory = stored.filter { !SensitiveURLRedactor.containsSensitiveData($0) }
        // 升级时主动移除旧版留下的带凭据历史。
        if apiHistory != stored {
            defaults.set(apiHistory, forKey: "api_history")
        }
    }
    
    /// 新增历史并去重，最多保留 10 条。
    private func addToApiHistory(_ url: String) {
        guard !SensitiveURLRedactor.containsSensitiveData(url) else { return }
        apiHistory.removeAll { $0 == url }
        apiHistory.insert(url, at: 0)
        if apiHistory.count > 10 {
            apiHistory = Array(apiHistory.prefix(10))
        }
        UserDefaults.standard.set(apiHistory, forKey: "api_history")
    }
    
    /// 删除单条 API 历史。
    func removeApiHistory(_ url: String) {
        apiHistory.removeAll { $0 == url }
        UserDefaults.standard.set(apiHistory, forKey: "api_history")
    }
    
    /// 清除所有缓存
    func clearCache() {
        URLCache.shared.removeAllCachedResponses()
        ImageLoader.shared.clearCache()
        ImageCache.shared.clear()
        refreshCacheSize()
    }
    
    /// 设置快进步长
    func setPlayTimeStep(_ step: Int) {
        guard step > 0 else { return }
        playTimeStep = step
        UserDefaults.standard.set(step, forKey: HawkConfig.PLAY_TIME_STEP)
    }
    
    /// 设置点播播放器内核
    func setVodPlayerEngine(_ engine: PlayerEngine) {
        guard playerEngineOptions.contains(engine) else { return }
        vodPlayerEngine = engine
        UserDefaults.standard.set(engine.rawValue, forKey: HawkConfig.PLAY_TYPE_VOD)
    }
    
    /// 设置直播播放器内核
    func setLivePlayerEngine(_ engine: PlayerEngine) {
        guard playerEngineOptions.contains(engine) else { return }
        livePlayerEngine = engine
        UserDefaults.standard.set(engine.rawValue, forKey: HawkConfig.PLAY_TYPE_LIVE)
    }
    
    /// 设置视频解码模式
    func setDecodeMode(_ mode: VideoDecodeMode) {
        guard decodeModeOptions.contains(mode) else { return }
        decodeMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: HawkConfig.PLAY_DECODE_MODE)
    }

    /// 设置 VLC 缓冲策略
    func setVLCBufferMode(_ mode: VLCBufferMode) {
        guard vlcBufferModeOptions.contains(mode) else { return }
        vlcBufferMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: HawkConfig.PLAY_VLC_BUFFER_MODE)
    }
    
    /// 统计并刷新缓存占用展示（网络缓存 + 图片缓存磁盘占用）。
    private func refreshCacheSize() {
        let sharedDisk = URLCache.shared.currentDiskUsage
        let imageDisk = ImageLoader.shared.cacheUsage.disk
        cacheSizeString = Self.formatSize(bytes: sharedDisk + imageDisk)
    }
    
    /// 格式化字节大小。
    private static func formatSize(bytes: Int) -> String {
        let size = max(0, bytes)
        if size < 1024 * 1024 {
            return String(format: "%.1f KB", Double(size) / 1024.0)
        }
        return String(format: "%.1f MB", Double(size) / 1024.0 / 1024.0)
    }
}
