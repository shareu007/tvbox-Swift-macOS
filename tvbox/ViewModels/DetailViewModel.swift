import Foundation
import SwiftUI

struct PlaybackQualityOption: Identifiable, Hashable {
    /// “自动”选项固定标识。
    static let autoIdentifier = "auto"
    /// 选项唯一标识（这里直接使用播放地址或固定 auto id）。
    let id: String
    /// UI 展示名（如 1080p / 720p / 自动）。
    let name: String
    /// 对应播放地址。
    let url: String
    
    var isAuto: Bool {
        id == Self.autoIdentifier
    }
    
    static func auto(url: String) -> PlaybackQualityOption {
        PlaybackQualityOption(id: autoIdentifier, name: "自动", url: url)
    }
}

/// 详情页 ViewModel
@MainActor
class DetailViewModel: ObservableObject {
    /// 详情信息主体。
    @Published var vodInfo: VodInfo?
    /// 加载状态。
    @Published var isLoading = false
    /// 错误提示。
    @Published var errorMessage: String?
    /// 当前选中线路。
    @Published var selectedFlag: String = ""
    /// 当前选中剧集索引。
    @Published var selectedEpisodeIndex: Int = 0
    /// 是否处于播放态。
    @Published var isPlaying = false
    /// 当前实际播放地址（可能是原始地址，也可能是清晰度切换后的子流地址）。
    @Published var playUrl: String?
    /// Spider playerContent 返回的播放请求头，供播放器适配层使用。
    @Published var playbackHeaders: [String: String] = [:]
    /// 续播起始位置（秒）。
    @Published var resumeSeconds: Double = 0
    /// 当前可选清晰度列表。
    @Published var qualityOptions: [PlaybackQualityOption] = []
    /// 当前选中的清晰度 id。
    @Published var selectedQualityId: String = PlaybackQualityOption.autoIdentifier
    /// 播放器高频回调进度，不直接绑定 UI，避免高频刷新引发性能问题。
    private var realtimeProgressSeconds: Double = 0
    private var verificationContext: SourceVerificationStore.Context?
    private var playbackEvidence = PlaybackProgressEvidence()

    
    /// 数据服务与网络服务。
    private let sourceService = SourceService.shared
    private let network = NetworkManager.shared
    /// 当前清晰度列表对应的基础剧集地址。
    private var qualityBaseEpisodeURL: String = ""
    /// 清晰度解析缓存，key 为原始剧集 URL。
    private var qualityOptionCache: [String: [PlaybackQualityOption]] = [:]
    /// 清晰度解析任务，用于取消旧请求。
    private var qualityResolveTask: Task<Void, Never>?
    /// Spider 播放地址解析任务。
    private var playbackResolveTask: Task<Void, Never>?
    private var playbackResolveToken = UUID()
    /// 解析令牌，防止异步结果回写到过期状态。
    private var qualityResolveToken = UUID()
    
    /// 加载视频详情
    func loadDetail(video: Movie.Video, initialInfo: VodInfo? = nil) async {
        verificationContext = nil
        playbackEvidence = PlaybackProgressEvidence()
        let config = ApiConfig.shared
        if config.isLoaded, !config.configUrl.isEmpty, let source = config.getSource(key: video.sourceKey) {
            let store = SourceVerificationStore.shared
            store.register(configURL: config.configUrl, sources: config.sourceBeanList)
            verificationContext = store.context(configURL: config.configUrl, source: source)
        }
        isLoading = true
        errorMessage = nil
        vodInfo = nil
        defer { isLoading = false }
        
        do {
            let detail: VodInfo?
            if let initialInfo {
                detail = initialInfo
            } else {
                guard let source = ApiConfig.shared.getSource(key: video.sourceKey) else {
                    errorMessage = "该来源已移除，请重新搜索并选择其他资源"
                    return
                }
                detail = try await sourceService.getDetail(sourceBean: source, vodId: video.id)
            }
            guard !Task.isCancelled else { return }
            if let info = detail {
                self.vodInfo = info
                self.selectedFlag = info.playFlag
                self.selectedEpisodeIndex = info.playIndex
                self.resumeSeconds = 0
                self.realtimeProgressSeconds = 0
                if let episode = info.currentEpisode {
                    updateQualityOptions(for: episode.url, resetSelection: true)
                } else {
                    resetQualityState()
                    errorMessage = "该资源未返回剧集，请返回资源列表重试或选择其他来源"
                }
            } else {
                errorMessage = "未找到资源详情，请返回资源列表选择其他来源"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        
    }
    
    /// 选择线路
    func selectFlag(_ flag: String) {
        guard selectedFlag != flag else { return }
        let currentIndex = selectedEpisodeIndex
        
        selectedFlag = flag
        vodInfo?.playFlag = flag
        resumeSeconds = 0
        realtimeProgressSeconds = 0
        
        let episodes = vodInfo?.playUrlMap[flag] ?? []
        guard !episodes.isEmpty else {
            selectedEpisodeIndex = 0
            vodInfo?.playIndex = 0
            resetQualityState()
            return
        }
        
        let targetIndex = min(max(currentIndex, 0), episodes.count - 1)
        selectedEpisodeIndex = targetIndex
        vodInfo?.playIndex = targetIndex
        let episodeURL = episodes[targetIndex].url
        updateQualityOptions(for: episodeURL, resetSelection: true)
        
        // 播放中切线路时，立即切换到新线路对应剧集
        if isPlaying {
            beginPlayback(episodeID: episodeURL, flag: flag)
        }
    }
    
    /// 选择剧集并播放
    func selectEpisode(index: Int) {
        guard selectedEpisodeIndex != index || !isPlaying else { return }
        selectedEpisodeIndex = index
        vodInfo?.playIndex = index
        resumeSeconds = 0
        realtimeProgressSeconds = 0
        
        if let episode = vodInfo?.currentEpisode {
            // 仅当剧集 URL 变化时重置清晰度选择。
            let shouldResetQuality = qualityBaseEpisodeURL != episode.url
            updateQualityOptions(for: episode.url, resetSelection: shouldResetQuality)
            isPlaying = true
            beginPlayback(episodeID: episode.url, flag: selectedFlag)
        }
    }
    
    /// 应用历史续播状态并自动继续播放
    func applyPlaybackState(_ state: VodPlaybackState) {
        guard let info = vodInfo, !info.playFlags.isEmpty else { return }
        
        let fallbackFlag = info.playFlag.isEmpty ? info.playFlags[0] : info.playFlag
        let targetFlag = info.playFlags.contains(state.flag) ? state.flag : fallbackFlag
        
        selectedFlag = targetFlag
        vodInfo?.playFlag = targetFlag
        
        let episodes = vodInfo?.playUrlMap[targetFlag] ?? []
        guard !episodes.isEmpty else { return }
        
        let targetIndex = min(max(state.episodeIndex, 0), episodes.count - 1)
        selectedEpisodeIndex = targetIndex
        vodInfo?.playIndex = targetIndex
        
        let progress = max(0, state.progressSeconds)
        resumeSeconds = progress
        realtimeProgressSeconds = progress
        let episodeURL = episodes[targetIndex].url
        updateQualityOptions(for: episodeURL, resetSelection: true)
        isPlaying = true
        beginPlayback(episodeID: episodeURL, flag: targetFlag)
    }
    
    /// 选择清晰度
    func selectQuality(_ option: PlaybackQualityOption) {
        guard qualityOptions.contains(option) else { return }
        selectedQualityId = option.id
        guard isPlaying else { return }
        
        // “自动”使用基础剧集地址；其他选项使用对应变体地址。
        let targetURL = option.url.isEmpty ? qualityBaseEpisodeURL : option.url
        guard !targetURL.isEmpty, playUrl != targetURL else { return }
        
        let progress = max(currentPlaybackSeconds(), 0)
        resumeSeconds = progress
        realtimeProgressSeconds = progress
        playUrl = targetURL
    }
    
    /// 播放器时间回调
    func observePlaybackEvidence(seconds: Double, playing: Bool) {
        guard let context = verificationContext, let url = playUrl, !url.isEmpty else { return }
        let identity = "\(selectedFlag)|\(selectedEpisodeIndex)|\(url)"
        if playbackEvidence.observe(playbackID: identity, seconds: seconds, playing: playing) {
            SourceVerificationStore.shared.recordPlayback(context: context)
        }
    }

    func updatePlaybackProgress(seconds: Double) {
        guard seconds.isFinite else { return }
        realtimeProgressSeconds = max(seconds, 0)
    }
    
    /// 当前实时进度（不触发 UI 高频刷新）
    func currentPlaybackSeconds() -> Double {
        max(realtimeProgressSeconds, resumeSeconds)
    }
    
    /// 仅在必要时同步快照到可观察状态
    func commitPlaybackProgressSnapshot() {
        let snapshot = max(realtimeProgressSeconds, 0)
        if abs(snapshot - resumeSeconds) >= 1 {
            resumeSeconds = snapshot
        }
    }
    
    /// 播放下一集
    func playNext() -> Bool {
        guard let info = vodInfo else { return false }
        let episodes = info.currentEpisodes
        if selectedEpisodeIndex + 1 < episodes.count {
            selectEpisode(index: selectedEpisodeIndex + 1)
            return true
        }
        return false
    }
    
    /// 播放上一集
    func playPrevious() -> Bool {
        if selectedEpisodeIndex > 0 {
            selectEpisode(index: selectedEpisodeIndex - 1)
            return true
        }
        return false
    }
    
    /// 当前剧集列表
    var currentEpisodes: [VodInfo.Episode] {
        vodInfo?.playUrlMap[selectedFlag] ?? []
    }
    
    /// 可选线路列表
    var flags: [String] {
        vodInfo?.playFlags ?? []
    }
    
    /// 是否存在可选清晰度
    var hasQualityChoices: Bool {
        qualityOptions.count > 1
    }
    
    private func selectedPlayableURL(fallback: String) -> String {
        // 若当前清晰度存在有效 URL，则优先使用；否则回退剧集原始地址。
        let selected = qualityOptions.first(where: { $0.id == selectedQualityId })?.url
        if let selected, !selected.isEmpty {
            return selected
        }
        return fallback
    }

    /// 把 Spider 的剧集 id 解析为真实媒体地址；普通源保持原有直连行为。
    private func beginPlayback(episodeID: String, flag: String) {
        playbackResolveTask?.cancel()
        let token = UUID()
        playbackResolveToken = token
        errorMessage = nil

        guard let sourceKey = vodInfo?.sourceKey,
              let source = ApiConfig.shared.getSource(key: sourceKey) else {
            playbackHeaders = [:]
            playUrl = selectedPlayableURL(fallback: episodeID)
            return
        }

        if source.type != 3 {
            playbackHeaders = [:]
            playUrl = selectedPlayableURL(fallback: episodeID)
            return
        }

        playUrl = nil
        playbackResolveTask = Task { [source, episodeID, flag] in
            do {
                let result = try await sourceService.resolvePlayback(
                    sourceBean: source,
                    flag: flag,
                    episodeID: episodeID
                )
                guard !Task.isCancelled, playbackResolveToken == token else { return }
                playbackHeaders = result.headers
                if result.qualityOptions.count > 1 {
                    applySpiderQualityOptions(result.qualityOptions, automaticURL: result.url)
                } else {
                    updateQualityOptions(for: result.url, resetSelection: true)
                }
                playUrl = result.url
            } catch {
                guard !Task.isCancelled, playbackResolveToken == token else { return }
                playbackHeaders = [:]
                playUrl = nil
                isPlaying = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func applySpiderQualityOptions(
        _ options: [SpiderPlaybackQualityOption],
        automaticURL: String
    ) {
        qualityResolveTask?.cancel()
        qualityResolveTask = nil
        qualityResolveToken = UUID()
        qualityBaseEpisodeURL = automaticURL
        selectedQualityId = PlaybackQualityOption.autoIdentifier

        var merged = [PlaybackQualityOption.auto(url: automaticURL)]
        merged.append(contentsOf: options.enumerated().map { index, option in
            PlaybackQualityOption(
                id: "spider-quality-\(index)-\(option.url)",
                name: option.name,
                url: option.url
            )
        })
        qualityOptions = merged
    }
    
    /// 重置清晰度解析与选择状态。
    private func resetQualityState() {
        qualityResolveTask?.cancel()
        qualityResolveTask = nil
        qualityBaseEpisodeURL = ""
        qualityOptions = []
        selectedQualityId = PlaybackQualityOption.autoIdentifier
        qualityResolveToken = UUID()
    }
    
    private func updateQualityOptions(for episodeURL: String, resetSelection: Bool) {
        let trimmedEpisodeURL = episodeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEpisodeURL.isEmpty else {
            resetQualityState()
            return
        }
        
        // 切换剧集时先取消旧任务，避免异步回写错位。
        qualityResolveTask?.cancel()
        qualityResolveTask = nil
        
        let autoOption = PlaybackQualityOption.auto(url: trimmedEpisodeURL)
        let previousSelected = selectedQualityId
        
        qualityBaseEpisodeURL = trimmedEpisodeURL
        if resetSelection {
            selectedQualityId = PlaybackQualityOption.autoIdentifier
        }
        
        qualityOptions = [autoOption]
        
        if let cached = qualityOptionCache[trimmedEpisodeURL] {
            // 缓存命中时直接复用，避免重复网络解析。
            qualityOptions = cached
            if resetSelection || !cached.contains(where: { $0.id == selectedQualityId }) {
                selectedQualityId = PlaybackQualityOption.autoIdentifier
            } else if previousSelected != selectedQualityId && cached.contains(where: { $0.id == previousSelected }) {
                selectedQualityId = previousSelected
            }
            return
        }
        
        let token = UUID()
        qualityResolveToken = token
        qualityResolveTask = Task { [trimmedEpisodeURL, resetSelection, previousSelected] in
            let resolved = await resolveQualityOptions(for: trimmedEpisodeURL)
            guard !Task.isCancelled else { return }
            guard qualityResolveToken == token, qualityBaseEpisodeURL == trimmedEpisodeURL else { return }
            guard !resolved.isEmpty else { return }
            
            qualityOptionCache[trimmedEpisodeURL] = resolved
            qualityOptions = resolved
            
            if resetSelection {
                selectedQualityId = PlaybackQualityOption.autoIdentifier
            } else if resolved.contains(where: { $0.id == selectedQualityId }) {
                // 当前选择仍有效，保持不变
            } else if resolved.contains(where: { $0.id == previousSelected }) {
                selectedQualityId = previousSelected
            } else {
                selectedQualityId = PlaybackQualityOption.autoIdentifier
            }
        }
    }
    
    /// 尝试从 HLS 主播放列表解析多清晰度选项。
    private func resolveQualityOptions(for episodeURL: String) async -> [PlaybackQualityOption] {
        guard let url = URL(string: episodeURL), Self.looksLikeHLSURL(url) else { return [] }
        guard let playlist = try? await network.getString(from: episodeURL) else { return [] }
        return Self.parseMasterPlaylist(playlist, masterURL: url)
    }
    
    /// HLS 变体流中间模型。
    private struct HLSVariant {
        let url: String
        let name: String?
        let height: Int?
        let bandwidth: Int?
    }
    
    /// 轻量判断 URL 是否可能是 HLS 播放列表。
    private static func looksLikeHLSURL(_ url: URL) -> Bool {
        let lowercased = url.absoluteString.lowercased()
        if lowercased.contains(".m3u8") { return true }
        let ext = url.pathExtension.lowercased()
        return ext == "m3u8" || ext == "m3u"
    }
    
    /// 解析 HLS 主播放列表并生成清晰度选项。
    /// 仅当解析出 2 个及以上有效变体时才返回（否则不显示清晰度切换）。
    private static func parseMasterPlaylist(_ content: String, masterURL: URL) -> [PlaybackQualityOption] {
        guard content.localizedCaseInsensitiveContains("#EXT-X-STREAM-INF") else { return [] }
        
        let lines = content.components(separatedBy: .newlines)
        var variants: [HLSVariant] = []
        var index = 0
        
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("#EXT-X-STREAM-INF:") else {
                index += 1
                continue
            }
            
            let attributeString = String(line.dropFirst("#EXT-X-STREAM-INF:".count))
            let attributes = parseAttributeMap(attributeString)
            
            var uri: String?
            var nextIndex = index + 1
            while nextIndex < lines.count {
                let candidate = lines[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                if candidate.isEmpty {
                    nextIndex += 1
                    continue
                }
                if candidate.hasPrefix("#") {
                    nextIndex += 1
                    continue
                }
                uri = candidate
                break
            }
            
            if let uri, !uri.isEmpty {
                let resolvedURL = URL(string: uri, relativeTo: masterURL)?.absoluteURL.absoluteString ?? uri
                let name = attributes["NAME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                let bandwidth = attributes["BANDWIDTH"].flatMap(Int.init)
                let height: Int?
                if let resolution = attributes["RESOLUTION"] {
                    let parts = resolution.split(separator: "x")
                    if parts.count == 2 {
                        height = Int(parts[1])
                    } else {
                        height = nil
                    }
                } else {
                    height = nil
                }
                
                variants.append(HLSVariant(
                    url: resolvedURL,
                    name: name?.isEmpty == true ? nil : name,
                    height: height,
                    bandwidth: bandwidth
                ))
            }
            
            index = nextIndex + 1
        }
        
        guard !variants.isEmpty else { return [] }
        
        var seenURLs = Set<String>()
        let deduped = variants.filter { variant in
            let inserted = seenURLs.insert(variant.url).inserted
            return inserted
        }
        
        let sorted = deduped.sorted { lhs, rhs in
            let lhsHeight = lhs.height ?? -1
            let rhsHeight = rhs.height ?? -1
            if lhsHeight != rhsHeight {
                return lhsHeight > rhsHeight
            }
            let lhsBandwidth = lhs.bandwidth ?? -1
            let rhsBandwidth = rhs.bandwidth ?? -1
            if lhsBandwidth != rhsBandwidth {
                return lhsBandwidth > rhsBandwidth
            }
            return lhs.url < rhs.url
        }
        
        let masterURLString = masterURL.absoluteString
        var displayNameCount: [String: Int] = [:]
        let options = sorted.enumerated().map { offset, variant -> PlaybackQualityOption in
            let baseName: String
            if let name = variant.name, !name.isEmpty {
                baseName = name
            } else if let height = variant.height {
                baseName = "\(height)p"
            } else if let bandwidth = variant.bandwidth, bandwidth > 0 {
                baseName = "\(bandwidth / 1000)K"
            } else {
                baseName = "清晰度\(offset + 1)"
            }
            
            let newCount = (displayNameCount[baseName] ?? 0) + 1
            displayNameCount[baseName] = newCount
            let finalName = newCount > 1 ? "\(baseName) \(newCount)" : baseName
            
            return PlaybackQualityOption(id: variant.url, name: finalName, url: variant.url)
        }.filter { !$0.url.isEmpty && $0.url != masterURLString }
        
        guard options.count >= 2 else { return [] }
        
        var merged = [PlaybackQualityOption.auto(url: masterURLString)]
        merged.append(contentsOf: options)
        return merged
    }
    
    /// 解析 `EXT-X-STREAM-INF` 的属性串为键值字典。
    private static func parseAttributeMap(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        let pairs = splitAttributes(raw)
        for pair in pairs {
            let components = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard components.count == 2 else { continue }
            let key = String(components[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            var value = String(components[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }
            if !key.isEmpty {
                result[key] = value
            }
        }
        return result
    }
    
    /// 按逗号分隔属性，但保留引号内逗号。
    private static func splitAttributes(_ raw: String) -> [String] {
        var parts: [String] = []
        var buffer = ""
        var inQuotes = false
        
        for char in raw {
            if char == "\"" {
                inQuotes.toggle()
                buffer.append(char)
                continue
            }
            
            if char == "," && !inQuotes {
                let item = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !item.isEmpty {
                    parts.append(item)
                }
                buffer.removeAll(keepingCapacity: true)
                continue
            }
            
            buffer.append(char)
        }
        
        let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            parts.append(tail)
        }
        return parts
    }
}
