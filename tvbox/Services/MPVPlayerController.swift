import Foundation
import Combine

#if os(macOS) && canImport(Libmpv)
import AppKit
import QuartzCore
import Libmpv

/// All libmpv access, including teardown, belongs to this queue. The layer remains
/// retained until the video output has stopped, even when SwiftUI removes a view.
private final class MPVSession: @unchecked Sendable {
    struct Snapshot {
        var time: Double = 0
        var duration: Double = 0
        var playing = false
        var loading = true
        var decoder = ""
        var tracks: [SubtitleTrack] = []
        var selectedID: Int?
    }
    enum Event { case snapshot(Snapshot), ended, failed(String) }
    private let queue = DispatchQueue(label: "com.tvbox.mpv.session", qos: .userInitiated)
    private var handle: OpaquePointer?
    private var timer: DispatchSourceTimer?
    private var loaded = false
    private var finished = false
    private let layer: CAMetalLayer
    private let receive: @Sendable (Event) -> Void

    init(layer: CAMetalLayer, receive: @escaping @Sendable (Event) -> Void) {
        self.layer = layer
        self.receive = receive
    }

    func start(url: URL, headers: [String: String], position: Double, mode: VideoDecodeMode, rate: Double, volume: Double) {
        queue.async { [self] in
            guard let mpv = mpv_create() else { receive(.failed("无法创建 mpv 播放器")); return }
            handle = mpv
            let options = ["config": "no", "load-scripts": "no", "ytdl": "no", "terminal": "no",
                           "input-default-bindings": "no", "input-vo-keyboard": "no", "input-media-keys": "no",
                           "vo": "gpu-next", "gpu-api": "vulkan", "gpu-context": "moltenvk",
                           "hwdec": mode.mpvHardwareDecodeOption, "hwdec-software-fallback": "yes",
                           "idle": "yes", "keep-open": "no", "sub-auto": "no", "audio-file-auto": "no",
                           "slang": "zh,chi,zho,zh-Hans,zh-Hant,en", "network-timeout": "20",
                           "start": String(max(0, position)), "speed": String(rate), "volume": String(volume)]
            for (name, value) in options {
                let result = mpv_set_option_string(mpv, name, value)
                if result < 0 { fail(result, operation: "初始化选项 \(name)"); return }
            }
            var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
            let surfaceResult = mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &wid)
            guard surfaceResult >= 0 else { fail(surfaceResult, operation: "设置视频画面"); return }
            let initialized = mpv_initialize(mpv)
            guard initialized >= 0 else { fail(initialized, operation: "初始化播放器"); return }
            guard setHeaders(headers) else { return }
            commandNow(["loadfile", url.absoluteString, "replace"])
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(250))
            source.setEventHandler { [weak self] in self?.poll() }
            timer = source
            source.resume()
        }
    }

    func property(_ name: String, _ value: String) {
        queue.async { [self] in
            guard let handle else { return }
            let code = mpv_set_property_string(handle, name, value)
            if code < 0 { receive(.failed("mpv 无法设置 \(name)")) }
        }
    }

    func command(_ arguments: [String]) { queue.async { [self] in commandNow(arguments) } }

    func close() { queue.async { [self] in destroy() } }

    private func destroy() {
        timer?.cancel()
        timer = nil
        if let handle { mpv_terminate_destroy(handle) }
        handle = nil
    }

    private func fail(_ code: Int32, operation: String) {
        receive(.failed("mpv \(operation)失败：\(String(cString: mpv_error_string(code)))"))
        destroy()
    }

    private func commandNow(_ arguments: [String]) {
        guard let handle else { return }
        let allocated = arguments.map { strdup($0) }
        defer { allocated.forEach { free($0) } }
        var pointers = allocated.map { $0.map { UnsafePointer($0) } } + [nil]
        let result = mpv_command(handle, &pointers)
        if result < 0 { receive(.failed("mpv 播放命令失败：\(String(cString: mpv_error_string(result)))")) }
    }

    // A node array preserves commas and backslashes in tokens/cookies without
    // mpv's string-list escaping rules. Header values never enter logs.
    private func setHeaders(_ headers: [String: String]) -> Bool {
        guard let handle else { return false }
        let values = MPVPlaybackOptions.headerFields(headers)
        let allocated = values.map { strdup($0) }
        defer { allocated.forEach { free($0) } }
        var nodes = allocated.map { ptr -> mpv_node in
            var node = mpv_node()
            node.format = MPV_FORMAT_STRING
            node.u.string = ptr
            return node
        }
        let result = nodes.withUnsafeMutableBufferPointer { buffer in
            var list = mpv_node_list()
            list.num = Int32(buffer.count)
            list.values = buffer.baseAddress
            return withUnsafeMutablePointer(to: &list) { pointer in
                var node = mpv_node()
                node.format = MPV_FORMAT_NODE_ARRAY
                node.u.list = pointer
                return mpv_set_property(handle, "http-header-fields", MPV_FORMAT_NODE, &node)
            }
        }
        guard result >= 0 else { fail(result, operation: "设置请求头"); return false }
        return true
    }

    private func string(_ name: String) -> String? {
        guard let handle, let value = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(value) }
        return String(cString: value)
    }

    private func number(_ name: String) -> Double {
        guard let handle else { return 0 }
        var value = Double(0)
        guard mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0, value.isFinite else { return 0 }
        return value
    }

    private func poll() {
        guard let handle else { return }
        while let event = mpv_wait_event(handle, 0), event.pointee.event_id != MPV_EVENT_NONE {
            switch event.pointee.event_id {
            case MPV_EVENT_FILE_LOADED: loaded = true
            case MPV_EVENT_START_FILE: loaded = false; finished = false
            case MPV_EVENT_END_FILE:
                loaded = false
                finished = true
                if let data = event.pointee.data?.assumingMemoryBound(to: mpv_event_end_file.self) {
                    if data.pointee.reason == MPV_END_FILE_REASON_EOF { receive(.ended) }
                    if data.pointee.reason == MPV_END_FILE_REASON_ERROR {
                        receive(.failed("mpv 无法播放此资源：\(String(cString: mpv_error_string(data.pointee.error)))"))
                    }
                }
            default: break
            }
        }
        var snapshot = Snapshot()
        snapshot.time = max(0, number("time-pos"))
        snapshot.duration = max(0, number("duration"))
        snapshot.loading = (!loaded && !finished) || string("paused-for-cache") == "yes"
        snapshot.playing = loaded && !snapshot.loading && string("pause") == "no" && string("core-idle") != "yes"
        snapshot.decoder = string("hwdec-current") ?? ""
        let count = min(256, max(0, Int(number("track-list/count"))))
        for index in 0..<count where string("track-list/\(index)/type") == "sub" {
            guard let id = Int(string("track-list/\(index)/id") ?? "") else { continue }
            let language = string("track-list/\(index)/lang")
            let title = string("track-list/\(index)/title") ?? language ?? "字幕轨道 \(id)"
            snapshot.tracks.append(.init(id: id, title: title, language: language,
                                         isForced: string("track-list/\(index)/forced") == "yes"))
        }
        snapshot.selectedID = Int(string("sid") ?? "")
        receive(.snapshot(snapshot))
    }
}

@MainActor
final class MPVPlayerController: ObservableObject {
    let subtitles = SubtitleState()
    @Published private(set) var isPlaying = false
    @Published private(set) var isPreparing = false
    @Published private(set) var currentTimeSeconds: Double = 0
    @Published private(set) var durationSeconds: Double = 0
    @Published private(set) var decoder = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var subtitleDelay: Double = 0
    @Published private(set) var playbackRate: Double = 1
    @Published private(set) var volume: Double = 100
    @Published private(set) var renderID = UUID()
    private(set) var canvas = MPVVideoCanvas(frame: .zero)
    private var session: MPVSession?
    private var identity: MPVPlaybackOptions.Identity?
    private var onProgressChanged: ((Double, Double?) -> Void)?
    private var onPlaybackEnded: (() -> Void)?
    private var onPlaybackFailed: (() -> Void)?
    var isActuallyPlaying: Bool { isPlaying }
    var decodeDescription: String {
        if decoder.isEmpty { return "正在检测解码方式" }
        return decoder == "no" ? "软件解码" : "VideoToolbox 硬件解码"
    }

    deinit { session?.close() }

    func play(url: URL, headers: [String: String] = [:], startPosition: Double = 0,
              isLive: Bool = false, decodeMode: VideoDecodeMode? = nil,
              onProgressChanged: ((Double, Double?) -> Void)? = nil,
              onPlaybackEnded: (() -> Void)? = nil, onPlaybackFailed: (() -> Void)? = nil) {
        self.onProgressChanged = onProgressChanged
        self.onPlaybackEnded = onPlaybackEnded
        self.onPlaybackFailed = onPlaybackFailed
        let mode = decodeMode ?? VideoDecodeMode.fromStoredValue(UserDefaults.standard.integer(forKey: HawkConfig.PLAY_DECODE_MODE))
        let key = MPVPlaybackOptions.Identity(url: url, headers: headers, isLive: isLive, decode: mode)
        guard key != identity || session == nil else { return }
        stop()
        identity = key
        isPreparing = true
        subtitles.reset()
        subtitleDelay = 0
        errorMessage = nil
        canvas = MPVVideoCanvas(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        let token = UUID()
        renderID = token
        playbackRate = MPVPlaybackOptions.rate(UserDefaults.standard.double(forKey: HawkConfig.PLAY_SPEED))
        volume = UserDefaults.standard.object(forKey: HawkConfig.PLAY_VOLUME) == nil ? 100 :
            min(200, max(0, UserDefaults.standard.double(forKey: HawkConfig.PLAY_VOLUME)))
        let core = MPVSession(layer: canvas.metalLayer) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.renderID == token else { return }
                self.receive(event)
            }
        }
        session = core
        core.start(url: url, headers: headers, position: isLive ? 0 : startPosition, mode: mode, rate: playbackRate, volume: volume)
    }

    private func receive(_ event: MPVSession.Event) {
        switch event {
        case .snapshot(let state):
            isPlaying = state.playing
            isPreparing = state.loading && errorMessage == nil
            currentTimeSeconds = state.time
            durationSeconds = state.duration
            decoder = state.decoder
            subtitles.isLoading = state.loading && state.tracks.isEmpty
            if subtitles.tracks != state.tracks {
                subtitles.tracks = state.tracks
                applySubtitleSelection()
            }
            subtitles.selectedTrackID = state.selectedID
            onProgressChanged?(state.time, state.duration > 0 ? state.duration : nil)
        case .ended:
            isPlaying = false
            isPreparing = false
            onPlaybackEnded?()
        case .failed(let message):
            isPlaying = false
            isPreparing = false
            errorMessage = message
            onPlaybackFailed?()
        }
    }

    func stop() {
        renderID = UUID()
        session?.close()
        session = nil
        identity = nil
        isPlaying = false
        isPreparing = false
        currentTimeSeconds = 0
        durationSeconds = 0
        decoder = ""
        subtitles.reset()
    }

    func togglePause() { session?.command(["cycle", "pause"]) }
    func pause(_ paused: Bool) { session?.property("pause", paused ? "yes" : "no") }
    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        session?.command(["seek", String(max(0, durationSeconds > 0 ? min(seconds, durationSeconds) : seconds)), "absolute+exact"])
    }
    func setRate(_ rate: Double) {
        playbackRate = MPVPlaybackOptions.rate(rate)
        session?.property("speed", String(playbackRate))
        UserDefaults.standard.set(playbackRate, forKey: HawkConfig.PLAY_SPEED)
    }
    func setVolume(_ value: Double) {
        guard value.isFinite else { return }
        volume = min(200, max(0, value))
        session?.property("volume", String(volume))
        UserDefaults.standard.set(volume, forKey: HawkConfig.PLAY_VOLUME)
    }
    func selectSubtitle(_ selection: SubtitleSelection) {
        subtitles.selection = selection
        applySubtitleSelection()
    }
    private func applySubtitleSelection() {
        let id = subtitles.desiredTrackID()
        session?.property("sid", id.map(String.init) ?? "no")
    }
    func setSubtitleDelay(_ seconds: Double) {
        guard seconds.isFinite else { return }
        subtitleDelay = min(60, max(-60, seconds))
        session?.property("sub-delay", String(subtitleDelay))
    }
}
#else
@MainActor
final class MPVPlayerController: ObservableObject {
    var isActuallyPlaying: Bool { false }
    func stop() {}
}
#endif

/// Pure configuration rules kept separate from the C API for regression tests.
enum MPVPlaybackOptions {
    struct Identity: Equatable {
        var url: URL
        var headers: [String: String]
        var isLive: Bool
        var decode: VideoDecodeMode
    }
    static func rate(_ value: Double) -> Double {
        value.isFinite && (0.25...4).contains(value) ? value : 1
    }
    static func headerFields(_ headers: [String: String]) -> [String] {
        headers.keys.sorted().compactMap { name in
            guard !name.isEmpty, !name.contains(":"), !name.contains(where: { $0.isNewline }),
                  let value = headers[name], !value.contains(where: { $0.isNewline }),
                  !name.contains("\0"), !value.contains("\0") else { return nil }
            return "\(name): \(value)"
        }
    }
}
