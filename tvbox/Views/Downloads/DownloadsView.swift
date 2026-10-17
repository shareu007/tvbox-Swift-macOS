import SwiftUI

struct DownloadsView: View {
    @ObservedObject var manager: OfflineDownloadManager
    @State private var pendingRemoval: OfflineDownload?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if manager.downloads.isEmpty {
                ContentUnavailableView("还没有下载", systemImage: "arrow.down.circle",
                    description: Text("在影片详情页选择线路和剧集，然后点击“下载”即可离线观看。"))
            } else {
                List {
                    ForEach(manager.downloads) { item in
                        row(item)
                            .padding(.vertical, 8)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("下载管理")
        .safeAreaInset(edge: .bottom) {
            if let error = manager.storageError {
                Text(error).font(.callout).foregroundStyle(.red).padding()
            } else {
                Text("下载保存在此设备；退出应用会暂停任务。")
                    .font(.caption).foregroundStyle(.secondary).padding(10)
            }
        }
        .background(AppTheme.primaryGradient.ignoresSafeArea())
        .confirmationDialog("删除这份下载及其本地文件？", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), titleVisibility: .visible) {
            if let item = pendingRemoval {
                Button("删除下载", role: .destructive) {
                    Task {
                        do { try await manager.remove(item.id) }
                        catch { errorMessage = OfflineDownloadError.message(for: error) }
                    }
                }
            }
        }
        .alert("下载提示", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func row(_ item: OfflineDownload) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: item.status == .completed ? "checkmark.circle.fill" : "arrow.down.circle")
                    .font(.title2).foregroundStyle(item.status == .completed ? .green : .orange)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title).font(.headline).lineLimit(2)
                    Text("\(item.episodeName) · \(item.flag)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                actions(item)
            }
            if item.status != .completed {
                if let fraction = item.fractionCompleted { ProgressView(value: fraction).tint(.orange) }
                else if [.preparing, .downloading].contains(item.status) { ProgressView().controlSize(.small) }
            }
            HStack {
                Text(item.errorMessage ?? item.status.title).foregroundStyle(item.status == .failed ? .red : .secondary)
                Spacer()
                if item.totalSegments > 0 { Text("\(item.completedSegments)/\(item.totalSegments) 片段") }
                Text(byteLabel(item))
                if let speed = manager.speeds[item.id], speed > 0 {
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file))/s")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(manager.removing.contains(item.id))
    }

    private func byteLabel(_ item: OfflineDownload) -> String {
        func format(_ bytes: Int64) -> String { bytes == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        let downloaded = format(item.receivedBytes)
        if item.status != .completed, let total = item.totalBytes, total > 0 { return "\(downloaded) / \(format(total))" }
        return downloaded
    }

    private func actions(_ item: OfflineDownload) -> some View {
        HStack(spacing: 14) {
            switch item.status {
            case .completed:
                if let url = manager.localURL(for: item) {
                    NavigationLink {
                        OfflinePlaybackView(url: url, title: "\(item.title) · \(item.episodeName)")
                    } label: { Label("播放", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent).tint(.orange)
                } else {
                    Button("重新下载") { perform { try manager.resume(item.id) } }
                }
            case .queued, .preparing, .downloading:
                Button { perform { try manager.pause(item.id) } } label: { Image(systemName: "pause.fill") }
                    .help("暂停下载").accessibilityLabel("暂停下载")
            case .paused, .failed:
                Button { perform { try manager.resume(item.id) } } label: {
                    Image(systemName: item.status == .failed ? "arrow.clockwise" : "play.fill")
                }.help("继续下载").accessibilityLabel("继续下载")
            }
            Button(role: .destructive) { pendingRemoval = item } label: { Image(systemName: "trash") }
                .help("删除下载").accessibilityLabel("删除下载")
        }
        .buttonStyle(.borderless)
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = OfflineDownloadError.message(for: error) }
    }
}

private struct OfflinePlaybackView: View {
    let url: URL
    let title: String
    @StateObject private var system = SystemPlayerSessionController()
    @StateObject private var vlc = VLCPlayerController()
    @StateObject private var mpv = MPVPlayerController()
    #if os(iOS)
    @State private var fullScreen = false
    #endif

    var body: some View {
        Group {
            #if os(iOS)
            if fullScreen { Color.black }
            else { player }
            #else
            player
            #endif
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .navigationTitle(title)
            .onDisappear {
                #if os(iOS)
                guard !fullScreen else { return }
                #endif
                system.stop(); vlc.stop(); mpv.stop()
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $fullScreen) {
                FullScreenPlayerView(urlString: url.absoluteString, systemController: system,
                                     vlcController: vlc, mpvController: mpv)
            }
            #endif
    }

    private var player: some View {
        PlayerView(urlString: url.absoluteString, onToggleFullScreen: toggleFullScreen,
                   systemController: system, vlcController: vlc, mpvController: mpv)
    }

    private func toggleFullScreen() {
        #if os(macOS)
        (NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil)
        #else
        fullScreen = true
        #endif
    }
}
