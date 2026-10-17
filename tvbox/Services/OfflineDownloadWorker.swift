import Foundation

struct OfflineDownloadWorker {
    let client: OfflineHTTPClient

    init(client: OfflineHTTPClient = OfflineHTTPClient()) { self.client = client }

    func run(result: SpiderPlaybackResult, directory: URL,
             progress: @escaping (OfflineDownloadProgress) -> Void) async throws -> OfflineDownloadOutput {
        guard let url = URL(string: result.url), SourceSubtitleParser.isRemoteURL(url) else { throw OfflineDownloadError.invalidURL }
        let partial = directory.appendingPathComponent("media.partial")
        let response = try await client.download(url, headers: result.headers, to: partial,
            maximumBytes: url.pathExtension.lowercased() == "m3u8" ? OfflineHLSPlaylist.maximumPlaylistBytes : 100 * 1024 * 1024 * 1024,
            resume: url.pathExtension.lowercased() != "m3u8") {
                progress(OfflineDownloadProgress(receivedBytes: $0, totalBytes: $1))
            }
        try Task.checkCancellation()
        let reader = try FileHandle(forReadingFrom: partial)
        let prefix = try reader.read(upToCount: 8192) ?? Data()
        try reader.close()
        let text = String(decoding: prefix, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#EXTM3U") {
            guard OfflineDownloadStore.size(partial) <= OfflineHLSPlaylist.maximumPlaylistBytes else { throw OfflineDownloadError.tooLarge }
            return try await downloadHLS(data: Data(contentsOf: partial), baseURL: response.url ?? url,
                                         origin: url, headers: result.headers, directory: directory, progress: progress)
        }
        guard MediaAvailabilityService.hasMediaSignature(prefix) else { throw OfflineDownloadError.notMedia }
        let bytes = [UInt8](prefix.prefix(8))
        let suffix: String
        if bytes.starts(with: [0x1a, 0x45, 0xdf, 0xa3]) { suffix = "mkv" }
        else if bytes.starts(with: [0x46, 0x4c, 0x56]) { suffix = "flv" }
        else if bytes.first == 0x47 { suffix = "ts" }
        else { suffix = "mp4" }
        let name = "media.\(suffix)"
        let target = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.moveItem(at: partial, to: target)
        try? FileManager.default.removeItem(at: partial.appendingPathExtension("resume.json"))
        return OfflineDownloadOutput(fileName: name, receivedBytes: OfflineDownloadStore.size(target))
    }

    private func downloadHLS(data: Data, baseURL: URL, origin: URL, headers: [String: String], directory: URL,
                             progress: @escaping (OfflineDownloadProgress) -> Void) async throws -> OfflineDownloadOutput {
        var data = data
        var base = baseURL
        var plan: OfflineHLSPlaylist.Plan?
        for depth in 0..<4 {
            try Task.checkCancellation()
            switch try OfflineHLSPlaylist.parse(data, baseURL: base) {
            case .variant(let url):
                guard depth < 3 else { throw OfflineDownloadError.invalidResponse }
                let file = directory.appendingPathComponent("playlist.tmp")
                let response = try await client.download(url, headers: scoped(headers, origin: origin, target: url), to: file,
                                                        maximumBytes: OfflineHLSPlaylist.maximumPlaylistBytes, resume: false)
                data = try Data(contentsOf: file)
                base = response.url ?? url
            case .media(let parsed): plan = parsed
            }
            if plan != nil { break }
        }
        guard let plan else { throw OfflineDownloadError.invalidResponse }
        let fingerprint = OfflineDownload.digest(plan.fingerprint + OfflineDownload.requestIdentity(url: origin, headers: headers))
        let fingerprintURL = directory.appendingPathComponent("hls-fingerprint")
        let previous = try? String(contentsOf: fingerprintURL, encoding: .utf8)
        if previous != fingerprint {
            // Only reuse segments when the full resolved playlist is identical.
            // Refreshed signed URLs or a changed source must not mix two movies.
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where file.lastPathComponent.hasPrefix("asset-") || file.lastPathComponent == "offline.m3u8" {
                try FileManager.default.removeItem(at: file)
            }
            try OfflineDownloadStore.writePrivate(Data(fingerprint.utf8), to: fingerprintURL)
        }
        var existing: [String: Int64] = [:]
        for asset in plan.assets {
            let size = OfflineDownloadStore.size(directory.appendingPathComponent(asset.name))
            if size > 0 { existing[asset.name] = size }
        }
        let tracker = OfflineHLSProgress(existing: existing, total: plan.assets.count, progress: progress)
        await tracker.report()
        let pending = plan.assets.filter { existing[$0.name] == nil }
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = pending.makeIterator()
            func add(_ asset: OfflineHLSPlaylist.Asset) {
                group.addTask {
                    let file = directory.appendingPathComponent(asset.name)
                    let partial = file.appendingPathExtension("partial")
                    _ = try await client.download(asset.url, headers: scoped(headers, origin: origin, target: asset.url),
                        to: partial, maximumBytes: asset.kind == .key ? 16 : 512 * 1024 * 1024) { bytes, _ in
                            Task { await tracker.update(asset.name, bytes: bytes) }
                        }
                    try Task.checkCancellation()
                    if asset.kind == .key, OfflineDownloadStore.size(partial) != 16 { throw OfflineDownloadError.invalidResponse }
                    try FileManager.default.moveItem(at: partial, to: file)
                    try? FileManager.default.removeItem(at: partial.appendingPathExtension("resume.json"))
                    try await tracker.complete(asset.name, bytes: OfflineDownloadStore.size(file))
                }
            }
            for _ in 0..<4 { if let asset = iterator.next() { add(asset) } }
            while try await group.next() != nil { if let asset = iterator.next() { add(asset) } }
        }
        try Task.checkCancellation()
        try OfflineDownloadStore.writePrivate(Data(plan.manifest.utf8), to: directory.appendingPathComponent("offline.m3u8"))
        for name in ["media.partial", "media.partial.resume.json", "playlist.tmp", "playlist.tmp.resume.json"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        return OfflineDownloadOutput(fileName: "offline.m3u8", receivedBytes: await tracker.totalBytes, totalSegments: plan.assets.count)
    }

    private func scoped(_ headers: [String: String], origin: URL, target: URL) -> [String: String] {
        SourceSubtitleParser.sameOrigin(origin, target) ? SourceSubtitleParser.safeHeaders(headers) : [:]
    }
}

private actor OfflineHLSProgress {
    private var sizes: [String: Int64]
    private var completed: Set<String>
    private let total: Int
    private let progress: (OfflineDownloadProgress) -> Void
    private var lastReport = Date.distantPast
    var totalBytes: Int64 { sizes.values.reduce(0, +) }

    init(existing: [String: Int64], total: Int, progress: @escaping (OfflineDownloadProgress) -> Void) {
        sizes = existing
        completed = Set(existing.keys)
        self.total = total
        self.progress = progress
    }

    func update(_ name: String, bytes: Int64) {
        guard !completed.contains(name) else { return }
        sizes[name] = bytes
        if Date().timeIntervalSince(lastReport) >= 0.25 { report() }
    }

    func complete(_ name: String, bytes: Int64) throws {
        sizes[name] = bytes
        completed.insert(name)
        guard sizes.values.reduce(0, +) <= 100 * 1024 * 1024 * 1024 else { throw OfflineDownloadError.tooLarge }
        if completed.count == total || Date().timeIntervalSince(lastReport) >= 0.25 { report() }
    }

    func report() {
        lastReport = Date()
        progress(OfflineDownloadProgress(receivedBytes: sizes.values.reduce(0, +), totalBytes: nil,
                                         completedSegments: completed.count, totalSegments: total))
    }
}
