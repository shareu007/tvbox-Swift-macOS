import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#endif

/// 详情页 - 对应 Android 版 DetailActivity
struct DetailView: View {
    let video: Movie.Video
    var initialInfo: VodInfo? = nil
    var initialInfoCheckedAt: Date? = nil
    var preferredPlaybackFlag: String? = nil
    @StateObject private var viewModel = DetailViewModel()
    @StateObject private var sharedSystemController = SystemPlayerSessionController()
    @StateObject private var sharedVLCController = VLCPlayerController()
    @StateObject private var sharedMPVController = MPVPlayerController()
    @EnvironmentObject var appState: AppState
    @Environment(\.modelContext) private var modelContext
    @State private var showFullScreen = false
    /// VLC 全屏退出动画期间为 true，防止内联播放器与全屏播放器同时争抢 drawable
    @State private var isFullScreenDismissing = false
    #if os(macOS)
    @State private var pendingMacWindowFullScreen = false
    #endif
    @State private var lastPersistedProgress: Double = 0
    @State private var isCollected = false
    @State private var showDownloadSelection = false
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 0).id("detail-top")
                    if viewModel.isLoading {
                        ProgressView("正在读取剧集…").padding()
                    }
                    // 播放器区域
                    if !showFullScreen, !isFullScreenDismissing, viewModel.isPlaying, let url = viewModel.playUrl {
                        PlayerView(
                            urlString: url,
                            headers: viewModel.playbackHeaders,
                            sourceSubtitles: viewModel.sourceSubtitles,
                            startPosition: viewModel.currentPlaybackSeconds(),
                            onProgressChanged: handlePlaybackProgress,
                            onPlaybackEnded: playNextEpisodeIfNeeded,
                            onToggleFullScreen: {
                                openFullScreenPlayer()
                            },
                            canPlayNext: canPlayNextEpisode,
                            onPlayNext: playNextEpisodeIfNeeded,
                            systemController: sharedSystemController,
                            vlcController: sharedVLCController,
                            mpvController: sharedMPVController
                        )
                            .id("\(viewModel.selectedFlag)-\(viewModel.selectedEpisodeIndex)-\(url)")
                            .aspectRatio(16/9, contentMode: .fit)
                            .background(Color.black)
                            .onTapGesture(count: 2) {
                                openFullScreenPlayer()
                            }
                    }

                    if let error = viewModel.errorMessage, !error.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(error)
                                .font(.callout)
                        }
                        .foregroundColor(.red.opacity(0.9))
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                
                    // 视频信息
                    videoInfoSection
                
                    if let notice = viewModel.playbackNotice, viewModel.isPlaying {
                        Label(notice.message, systemImage: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                    }

                    // 剧集列表
                    if !viewModel.currentEpisodes.isEmpty {
                        episodeSection
                    }
                
                    if let info = viewModel.vodInfo,
                       !info.des.isEmpty || !info.director.isEmpty || !info.actor.isEmpty {
                        Divider().padding(.horizontal, 28).padding(.vertical, 20)
                        DetailCinemaAbout(info: info)
                    }
                }
                .padding(.bottom, 40)
            }
            .onChange(of: viewModel.playUrl) { _, url in
                if url != nil { proxy.scrollTo("detail-top", anchor: .top) }
            }
        }
        .background(AppTheme.background)
        .navigationTitle(video.name)
        .sheet(isPresented: $showDownloadSelection) {
            if let info = viewModel.vodInfo {
                DownloadSelectionView(info: info, flag: viewModel.selectedFlag,
                                      selectedIndex: viewModel.selectedEpisodeIndex, manager: .shared)
            }
        }
        #if os(macOS)
        .toolbar((showFullScreen || pendingMacWindowFullScreen) ? .hidden : .visible, for: .windowToolbar)
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: "\(video.sourceKey)-\(video.id)") {
            let freshInfo = initialInfoCheckedAt.map { Date().timeIntervalSince($0) < 60 } == true
                ? initialInfo : nil
            await viewModel.loadDetail(video: video, initialInfo: freshInfo)
            restorePlaybackFromHistory()
            refreshCollectState()
        }
        .onDisappear {
            viewModel.commitPlaybackProgressSnapshot()
            persistHistoryIfNeeded(force: true)
            showFullScreen = false
            sharedSystemController.stop()
            sharedVLCController.stop()
            sharedMPVController.stop()
            #if os(macOS)
            pendingMacWindowFullScreen = false
            appState.exitPlayerFullScreen()
            #endif
        }
        #if os(macOS)
        .overlay {
            if showFullScreen, let url = viewModel.playUrl {
                FullScreenPlayerView(
                    urlString: url,
                    headers: viewModel.playbackHeaders,
                    sourceSubtitles: viewModel.sourceSubtitles,
                    startPosition: viewModel.currentPlaybackSeconds(),
                    onProgressChanged: handlePlaybackProgress,
                    onPlaybackEnded: playNextEpisodeIfNeeded,
                    canPlayNext: canPlayNextEpisode,
                    onPlayNext: playNextEpisodeIfNeeded,
                    systemController: sharedSystemController,
                    vlcController: sharedVLCController,
                    mpvController: sharedMPVController,
                    onCloseRequested: closeMacFullScreenOverlay
                )
                .ignoresSafeArea()
                .transition(.opacity)
                .zIndex(2)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            guard pendingMacWindowFullScreen else { return }
            pendingMacWindowFullScreen = false
            showFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            pendingMacWindowFullScreen = false
            if showFullScreen {
                showFullScreen = false
            }
            appState.exitPlayerFullScreen()
        }
        #endif
        #if os(iOS)
        .fullScreenCover(isPresented: $showFullScreen, onDismiss: {
            isFullScreenDismissing = false
        }) {
            if let url = viewModel.playUrl {
                FullScreenPlayerView(
                    urlString: url,
                    headers: viewModel.playbackHeaders,
                    sourceSubtitles: viewModel.sourceSubtitles,
                    startPosition: viewModel.currentPlaybackSeconds(),
                    onProgressChanged: handlePlaybackProgress,
                    onPlaybackEnded: playNextEpisodeIfNeeded,
                    canPlayNext: canPlayNextEpisode,
                    onPlayNext: playNextEpisodeIfNeeded,
                    systemController: sharedSystemController,
                    vlcController: sharedVLCController,
                    mpvController: sharedMPVController,
                    onCloseRequested: {
                        isFullScreenDismissing = true
                        showFullScreen = false
                    }
                )
            }
        }
        #endif
    }
    
    // MARK: - 影片信息与操作

    private var displayInfo: VodInfo {
        var info = viewModel.vodInfo ?? VodInfo.from(video: video, playFrom: "", playUrl: "")
        if info.name.isEmpty { info.name = video.name }
        if info.pic.isEmpty { info.pic = video.pic }
        return info
    }

    private var videoInfoSection: some View {
        DetailCinemaHeader(info: displayInfo, compact: viewModel.isPlaying) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { playButton; collectButton; downloadButton }
                VStack(alignment: .leading, spacing: 10) {
                    playButton
                    HStack(spacing: 10) { collectButton; downloadButton }
                }
            }
        }
    }

    @ViewBuilder
    private var playButton: some View {
        if !viewModel.isPlaying {
            Button {
                viewModel.selectEpisode(index: 0)
                saveHistoryForCurrentEpisode()
            } label: {
                Label("立即播放", systemImage: "play.fill")
            }
            .buttonStyle(DetailCinemaActionStyle(prominent: true, onArtwork: true))
            .disabled(viewModel.currentEpisodes.isEmpty)
        }
    }

    private var downloadButton: some View {
        Button { showDownloadSelection = true } label: {
            Label("下载", systemImage: "arrow.down.circle")
        }
        .buttonStyle(DetailCinemaActionStyle(onArtwork: !viewModel.isPlaying))
        .disabled(viewModel.currentEpisodes.isEmpty)
    }

    private var collectButton: some View {
        Button { toggleCollect() } label: {
            Label(isCollected ? "已收藏" : "收藏", systemImage: isCollected ? "checkmark" : "plus")
        }
        .buttonStyle(DetailCinemaActionStyle(onArtwork: !viewModel.isPlaying))
    }

    // MARK: - 线路选择
    
    private var flagSelector: some View {
        Menu {
            ForEach(viewModel.flags, id: \.self) { flag in
                Button {
                    viewModel.selectFlag(flag)
                    if viewModel.isPlaying { saveHistoryForCurrentEpisode() }
                } label: {
                    if viewModel.selectedFlag == flag {
                        Label(flag, systemImage: "checkmark")
                    } else { Text(flag) }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Text("线路").foregroundStyle(.secondary)
                Text(viewModel.selectedFlag).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: 320, alignment: .trailing)
        .accessibilityLabel("播放线路：\(viewModel.selectedFlag)")
    }

    // MARK: - 清晰度选择
    
    private var qualitySelector: some View {
        HStack(spacing: 12) {
            Text("清晰度").font(.subheadline).foregroundStyle(.secondary)
            Menu {
                ForEach(viewModel.qualityOptions) { option in
                    Button {
                        viewModel.selectQuality(option)
                        if viewModel.isPlaying { saveHistoryForCurrentEpisode() }
                    } label: {
                        if viewModel.selectedQualityId == option.id {
                            Label(option.name, systemImage: "checkmark")
                        } else { Text(option.name) }
                    }
                }
            } label: {
                Label(viewModel.qualityOptions.first { $0.id == viewModel.selectedQualityId }?.name ?? "自动",
                      systemImage: "chevron.down")
                    .font(.subheadline).frame(minHeight: 44)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer(minLength: 0)
        }
        .accessibilityLabel("视频清晰度")
    }

    // MARK: - 剧集列表
    
    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    episodeHeading
                    Spacer(minLength: 16)
                    if viewModel.flags.count > 1 { flagSelector }
                }
                VStack(alignment: .leading, spacing: 12) {
                    episodeHeading
                    if viewModel.flags.count > 1 { flagSelector }
                }
            }
            if viewModel.hasQualityChoices { qualitySelector }
            EpisodeListView(
                episodes: viewModel.currentEpisodes,
                selectedIndex: viewModel.selectedEpisodeIndex,
                onSelect: { index in
                    viewModel.selectEpisode(index: index)
                    saveHistoryForCurrentEpisode()
                },
                layout: .cinema,
                isPlaying: viewModel.isPlaying
            )
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
    }

    private var episodeHeading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(viewModel.currentEpisodes.count > 1 ? "剧集" : "播放资源")
                .font(.title2.bold())
            if viewModel.currentEpisodes.count > 1 {
                Text("共 \(viewModel.currentEpisodes.count) 集")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var canPlayNextEpisode: Bool {
        viewModel.selectedEpisodeIndex + 1 < viewModel.currentEpisodes.count
    }
    
    private func saveHistoryForCurrentEpisode(progressOverride: Double? = nil) {
        let episodeName = viewModel.vodInfo?.currentEpisode?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let episodeLabel = episodeName.isEmpty ? "第\(viewModel.selectedEpisodeIndex + 1)集" : episodeName
        let progress = max(progressOverride ?? viewModel.currentPlaybackSeconds(), 0)
        let timeLabel = progress > 0 ? Int(progress).durationString : ""
        let playNote = timeLabel.isEmpty ? episodeLabel : "\(episodeLabel) \(timeLabel)"
        
        let playbackState = VodPlaybackState(
            flag: viewModel.selectedFlag,
            episodeIndex: viewModel.selectedEpisodeIndex,
            progressSeconds: progress
        )
        
        Task { @MainActor in
            CacheStore.shared.addRecord(
                video,
                playNote: playNote,
                playbackState: playbackState,
                context: modelContext
            )
        }
    }
    
    private func handlePlaybackProgress(_ seconds: Double, _: Double?) {
        viewModel.observePlaybackEvidence(seconds: seconds, playing: sharedSystemController.isActuallyPlaying || sharedVLCController.isActuallyPlaying || sharedMPVController.isActuallyPlaying)
        viewModel.updatePlaybackProgress(seconds: seconds)
        persistHistoryIfNeeded(force: false, currentProgress: seconds)
    }
    
    private func persistHistoryIfNeeded(force: Bool, currentProgress: Double? = nil) {
        guard viewModel.isPlaying else { return }
        let progress = max(currentProgress ?? viewModel.currentPlaybackSeconds(), 0)
        guard progress.isFinite else { return }
        
        if !force && abs(progress - lastPersistedProgress) < 20 {
            return
        }
        
        lastPersistedProgress = progress
        saveHistoryForCurrentEpisode(progressOverride: progress)
    }
    
    private func restorePlaybackFromHistory() {
        guard var playbackState = CacheStore.shared.getPlaybackState(
            vodId: video.id,
            sourceKey: video.sourceKey,
            context: modelContext
        ) else { return }
        if let preferredPlaybackFlag,
           initialInfoCheckedAt.map({ Date().timeIntervalSince($0) < 60 }) == true,
           viewModel.flags.contains(preferredPlaybackFlag) {
            playbackState.flag = preferredPlaybackFlag
        }
        
        viewModel.applyPlaybackState(playbackState)
        lastPersistedProgress = max(playbackState.progressSeconds, 0)
    }
    
    private func refreshCollectState() {
        isCollected = CacheStore.shared.isCollected(
            vodId: video.id,
            sourceKey: video.sourceKey,
            context: modelContext
        )
    }
    
    private func toggleCollect() {
        if isCollected {
            CacheStore.shared.removeCollect(
                vodId: video.id,
                sourceKey: video.sourceKey,
                context: modelContext
            )
        } else {
            CacheStore.shared.addCollect(video, context: modelContext)
        }
        refreshCollectState()
    }
    
    private func playNextEpisodeIfNeeded() {
        var moved = false
        withAnimation {
            moved = viewModel.playNext()
        }
        
        if moved {
            saveHistoryForCurrentEpisode()
        }
    }
    
    private func openFullScreenPlayer() {
        #if os(iOS)
        showFullScreen = true
        #else
        guard viewModel.playUrl != nil else { return }
        appState.enterPlayerFullScreen()
        
        if let window = NSApp.keyWindow ?? NSApp.mainWindow,
           window.styleMask.contains(.fullScreen) {
            showFullScreen = true
            return
        }
        
        pendingMacWindowFullScreen = requestMacWindowFullScreen(enter: true)
        if !pendingMacWindowFullScreen {
            showFullScreen = true
        }
        #endif
    }
    
    #if os(macOS)
    @discardableResult
    private func requestMacWindowFullScreen(enter: Bool) -> Bool {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return false }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        guard enter != isFullScreen else { return false }
        window.toggleFullScreen(nil)
        return true
    }
    
    private func closeMacFullScreenOverlay() {
        pendingMacWindowFullScreen = false
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        if window?.styleMask.contains(.fullScreen) == true {
            requestMacWindowFullScreen(enter: false)
            return
        }
        showFullScreen = false
        appState.exitPlayerFullScreen()
    }
    #endif
}

/// 全屏播放器
struct FullScreenPlayerView: View {
    let urlString: String
    var headers: [String: String] = [:]
    var sourceSubtitles: [SourceSubtitle] = []
    var startPosition: Double = 0
    var onProgressChanged: ((Double, Double?) -> Void)? = nil
    var onPlaybackEnded: (() -> Void)? = nil
    var canPlayNext: Bool = false
    var onPlayNext: (() -> Void)? = nil
    var systemController: SystemPlayerSessionController? = nil
    var vlcController: VLCPlayerController? = nil
    var mpvController: MPVPlayerController? = nil
    var onCloseRequested: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            PlayerView(
                urlString: urlString,
                headers: headers,
                sourceSubtitles: sourceSubtitles,
                startPosition: startPosition,
                onProgressChanged: onProgressChanged,
                onPlaybackEnded: onPlaybackEnded,
                onToggleFullScreen: {
                    if let onCloseRequested {
                        onCloseRequested()
                    } else {
                        dismiss()
                    }
                },
                canPlayNext: canPlayNext,
                onPlayNext: onPlayNext,
                systemController: systemController,
                vlcController: vlcController,
                mpvController: mpvController
            )
                .ignoresSafeArea()
            
            VStack {
                HStack {
                    Button {
                        if let onCloseRequested {
                            onCloseRequested()
                        } else {
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    Spacer()
                }
                .padding()
                Spacer()
            }
        }
    }
}
