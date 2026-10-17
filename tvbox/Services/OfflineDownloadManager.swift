import Foundation
import Combine

/// App-scoped queue; leaving a detail page does not cancel its downloads.
@MainActor
final class OfflineDownloadManager: ObservableObject {
    typealias Resolver = (OfflineDownload) async throws -> SpiderPlaybackResult
    typealias Runner = (SpiderPlaybackResult, URL, @escaping (OfflineDownloadProgress) -> Void) async throws -> OfflineDownloadOutput

    static let shared = OfflineDownloadManager(store: OfflineDownloadStore(root: OfflineDownloadStore.defaultRoot))

    @Published private(set) var downloads: [OfflineDownload] = []
    @Published private(set) var speeds: [UUID: Double] = [:]
    @Published private(set) var removing: Set<UUID> = []
    @Published var storageError: String?
    private let store: OfflineDownloadStore
    private let resolve: Resolver
    private let run: Runner
    private let maximumConcurrent: Int
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var generations: [UUID: UUID] = [:]
    private var samples: [UUID: (Date, Int64)] = [:]
    private var lastSave = Date.distantPast

    init(store: OfflineDownloadStore, maximumConcurrent: Int = 2,
         resolve: @escaping Resolver = OfflineDownloadManager.resolveSource,
         run: @escaping Runner = { result, directory, progress in
             try await OfflineDownloadWorker().run(result: result, directory: directory, progress: progress)
         }) {
        self.store = store
        self.maximumConcurrent = max(1, maximumConcurrent)
        self.resolve = resolve
        self.run = run
        do {
            downloads = try store.load()
            for index in downloads.indices {
                // Restart is always explicit: opening TVBox must not silently
                // consume data or call an account provider for old tasks.
                if [.queued, .preparing, .downloading].contains(downloads[index].status) { downloads[index].status = .paused }
                else if downloads[index].status == .completed, store.localURL(for: downloads[index]) == nil {
                    downloads[index].status = .failed
                    downloads[index].errorMessage = "本地文件已被移除，请重新下载"
                }
            }
        } catch { storageError = "无法读取下载记录，原有文件已保留，请检查下载目录" }
    }

    @discardableResult
    func enqueue(info: VodInfo, episode: VodInfo.Episode, flag: String, source: SourceBean, configURL: String) throws -> UUID {
        try enqueue(info: info, episodes: [episode], flag: flag, source: source, configURL: configURL)[0]
    }

    @discardableResult
    func enqueue(info: VodInfo, episodes: [VodInfo.Episode], flag: String, source: SourceBean, configURL: String) throws -> [UUID] {
        guard storageError == nil else { throw OfflineDownloadError.storage }
        var next = downloads
        var identifiers: [UUID] = []
        let identity = OfflineDownload.identity(configURL: configURL, source: source)
        for episode in episodes {
            let item = OfflineDownload(info: info, episode: episode, flag: flag, sourceIdentity: identity)
            if let existing = next.first(where: { $0.matches(item) }) { identifiers.append(existing.id) }
            else { next.insert(item, at: 0); identifiers.append(item.id) }
        }
        // A batch is committed once: exceeding the limit cannot leave only the
        // first half of the selected season in the queue.
        try store.save(next)
        downloads = next
        pump()
        return identifiers
    }

    func pause(_ id: UUID) throws {
        guard let index = downloads.firstIndex(where: { $0.id == id }), !removing.contains(id),
              [.queued, .preparing, .downloading].contains(downloads[index].status) else { return }
        try update(id) { $0.status = .paused }
        jobs[id]?.cancel()
        speeds[id] = nil
    }

    func resume(_ id: UUID) throws {
        guard let item = downloads.first(where: { $0.id == id }), !removing.contains(id),
              [.paused, .failed].contains(item.status) || (item.status == .completed && store.localURL(for: item) == nil) else { return }
        try update(id) { $0.status = .queued; $0.errorMessage = nil }
        pump()
    }

    func remove(_ id: UUID) async throws {
        guard !removing.contains(id), downloads.contains(where: { $0.id == id }) else { return }
        removing.insert(id)
        defer { removing.remove(id) }
        // Wait for the last file write before deleting the directory. A cancelled
        // network response must never recreate a task the user just removed.
        let job = jobs[id]
        job?.cancel()
        if let job { await job.value }
        try store.remove(id)
        let next = downloads.filter { $0.id != id }
        try store.save(next)
        downloads = next
        speeds[id] = nil
    }

    func localURL(for item: OfflineDownload) -> URL? { store.localURL(for: item) }

    private func update(_ id: UUID, _ change: (inout OfflineDownload) -> Void) throws {
        guard let index = downloads.firstIndex(where: { $0.id == id }) else { return }
        var next = downloads
        change(&next[index])
        try store.save(next)
        downloads = next
    }

    private func pump() {
        guard storageError == nil else { return }
        for item in downloads.reversed() where item.status == .queued && jobs[item.id] == nil && !removing.contains(item.id) {
            guard jobs.count < maximumConcurrent else { break }
            let generation = UUID()
            generations[item.id] = generation
            jobs[item.id] = Task { [weak self] in
                guard let self else { return }
                await execute(item, generation: generation)
            }
        }
    }

    private func execute(_ item: OfflineDownload, generation: UUID) async {
        defer {
            jobs[item.id] = nil
            generations[item.id] = nil
            speeds[item.id] = nil
            samples[item.id] = nil
            pump()
        }
        do {
            try Task.checkCancellation()
            try update(item.id) { $0.status = .preparing; $0.errorMessage = nil }
            let result = try await resolve(item)
            try Task.checkCancellation()
            let directory = try store.directory(for: item.id)
            try update(item.id) { $0.status = .downloading }
            let output = try await run(result, directory) { [weak self] progress in
                Task { @MainActor in self?.receive(progress, id: item.id, generation: generation) }
            }
            try Task.checkCancellation()
            guard OfflineDownloadStore.isLocalMediaName(output.fileName), OfflineDownloadStore.size(directory.appendingPathComponent(output.fileName)) > 0 else {
                throw OfflineDownloadError.incomplete
            }
            try update(item.id) {
                $0.status = .completed
                $0.localFileName = output.fileName
                $0.errorMessage = nil
                $0.totalSegments = output.totalSegments
                $0.completedSegments = output.totalSegments
                $0.receivedBytes = output.receivedBytes
                $0.totalBytes = output.receivedBytes
            }
        } catch {
            guard let current = downloads.first(where: { $0.id == item.id }), !removing.contains(item.id) else { return }
            do {
                try update(item.id) {
                    if Task.isCancelled || current.status == .paused { $0.status = current.status == .queued ? .queued : .paused }
                    else { $0.status = .failed; $0.errorMessage = OfflineDownloadError.message(for: error) }
                }
            } catch { storageError = "无法保存下载状态，请检查磁盘空间和目录权限" }
        }
    }

    private func receive(_ progress: OfflineDownloadProgress, id: UUID, generation: UUID) {
        guard generations[id] == generation, !removing.contains(id),
              let index = downloads.firstIndex(where: { $0.id == id }), downloads[index].status == .downloading else { return }
        let now = Date()
        if let (date, bytes) = samples[id], now.timeIntervalSince(date) >= 0.2 {
            speeds[id] = max(0, Double(progress.receivedBytes - bytes) / now.timeIntervalSince(date))
            samples[id] = (now, progress.receivedBytes)
        } else if samples[id] == nil { samples[id] = (now, progress.receivedBytes) }
        downloads[index].receivedBytes = progress.receivedBytes
        downloads[index].totalBytes = progress.totalBytes
        downloads[index].completedSegments = progress.completedSegments
        downloads[index].totalSegments = progress.totalSegments
        if now.timeIntervalSince(lastSave) >= 2 {
            do { try store.save(downloads); lastSave = now }
            catch {
                storageError = "无法保存下载进度，请检查磁盘空间"
                for job in jobs.values { job.cancel() }
            }
        }
    }

    private static func resolveSource(_ item: OfflineDownload) async throws -> SpiderPlaybackResult {
        let config = ApiConfig.shared
        guard config.isLoaded, let source = config.getSource(key: item.sourceKey),
              OfflineDownload.identity(configURL: config.configUrl, source: source) == item.sourceIdentity else {
            throw OfflineDownloadError.sourceUnavailable
        }
        // Reuse the current account-aware resolver, including CatVod and cloud
        // providers. Downloading is an explicit user action, not a spider probe.
        return try await SourceService.shared.resolvePlayback(sourceBean: source, flag: item.flag, episodeID: item.episodeID)
    }
}
