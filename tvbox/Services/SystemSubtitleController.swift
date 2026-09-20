import AVFoundation

/// 跟随 AVPlayerItem 的字幕会话，内联与全屏共用，异步结果不能覆盖下一集。
@MainActor
final class SystemSubtitleController {
    let state = SubtitleState()
    private var item: AVPlayerItem?
    private var group: AVMediaSelectionGroup?
    private var options: [AVMediaSelectionOption] = []
    private var loadTask: Task<Void, Never>?
    private var statusObserver: NSKeyValueObservation?
    private var selectionObserver: NSObjectProtocol?
    private var generation = UUID()

    deinit {
        loadTask?.cancel()
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
    }

    func bind(to item: AVPlayerItem) {
        guard self.item !== item else { return }
        reset()
        self.item = item
        statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .readyToPlay else { return }
            Task { @MainActor [weak self] in
                guard self?.item === item else { return }
                self?.scheduleRefresh()
            }
        }
        selectionObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateSelectedTrack() }
        }
        scheduleRefresh()
    }

    func reset() {
        generation = UUID()
        loadTask?.cancel()
        loadTask = nil
        statusObserver = nil
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        selectionObserver = nil
        item = nil
        group = nil
        options = []
        state.reset()
    }

    func select(_ selection: SubtitleSelection) {
        if case .track(let id) = selection, !state.tracks.contains(where: { $0.id == id }) { return }
        state.selection = selection
        applySelection()
    }

    private func scheduleRefresh() {
        loadTask?.cancel()
        guard let item else { return }
        let generation = generation
        loadTask = Task { [weak self] in
            do {
                let group = try await item.asset.loadMediaSelectionGroup(for: .legible)
                guard let self, !Task.isCancelled, self.generation == generation, self.item === item else { return }
                self.group = group
                self.options = group?.options.filter(\.isPlayable) ?? []
                self.state.tracks = self.options.enumerated().map { index, option in
                    SubtitleTrack(id: index, title: option.displayName,
                                  language: option.extendedLanguageTag ?? option.locale?.identifier,
                                  isForced: option.hasMediaCharacteristic(.containsOnlyForcedSubtitles))
                }
                self.state.isLoading = false
                self.applySelection()
            } catch {
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                self.state.isLoading = false
                self.state.unavailableMessage = "无法读取字幕轨，可尝试切换 VLC 播放器"
            }
        }
    }

    private func applySelection() {
        guard let item, let group else { return }
        let defaultID = group.defaultOption.flatMap { options.firstIndex(of: $0) }
        let id = state.desiredTrackID(defaultID: defaultID)
        item.select(id.flatMap { options.indices.contains($0) ? options[$0] : nil }, in: group)
        updateSelectedTrack()
    }

    private func updateSelectedTrack() {
        guard let item, let group else { return }
        state.selectedTrackID = item.currentMediaSelection.selectedMediaOption(in: group)
            .flatMap { options.firstIndex(of: $0) }
    }
}
