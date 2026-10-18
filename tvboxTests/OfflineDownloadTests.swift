import XCTest
import AVFoundation
#if os(macOS)
import AppKit
import SwiftUI
#endif
@testable import TVBox

final class OfflineDownloadTests: XCTestCase {
    private var root: URL!
    private let base = URL(string: "https://example.com/media/")!
    private static let video = Data([0, 0, 0, 32] + Array("ftypisom".utf8) + Array(repeating: 42, count: 65536))

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TVBox-offline-test-\(UUID().uuidString)")
        try OfflineDownloadStore.makeDirectory(root)
        OfflineFixtureProtocol.reset()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private var client: OfflineHTTPClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OfflineFixtureProtocol.self]
        return OfflineHTTPClient(configuration: config)
    }

    func testMasterChoosesHighestBandwidthAndResolvesRelativePlaylist() throws {
        let text = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100,CODECS=\"avc1,mp4a\"\nlow/index.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nhigh/index.m3u8"
        guard case .variant(let url) = try OfflineHLSPlaylist.parse(Data(text.utf8), baseURL: base) else { return XCTFail() }
        XCTAssertEqual(url.absoluteString, "https://example.com/media/high/index.m3u8")
    }

    func testLocalHLSEngineFallbackPreservesNetworkAndExplicitPreferences() {
        let local = URL(fileURLWithPath: "/tmp/offline.m3u8")
        for preferred in [PlayerEngine.mpv, .vlc] {
            XCTAssertEqual(OfflinePlaybackPolicy.engine(for: local, preferred: preferred), preferred)
        }
        for preferred in PlayerEngine.availableEngines {
            XCTAssertEqual(OfflinePlaybackPolicy.engine(for: base.appendingPathComponent("online.m3u8"), preferred: preferred), preferred)
            XCTAssertEqual(OfflinePlaybackPolicy.engine(for: URL(fileURLWithPath: "/tmp/movie.mp4"), preferred: preferred), preferred)
        }
        let fallback: PlayerEngine = PlayerEngine.isMPVAvailable ? .mpv : (PlayerEngine.isVLCAvailable ? .vlc : .system)
        XCTAssertEqual(OfflinePlaybackPolicy.engine(for: local, preferred: .system), fallback)
        for suffix in ["mkv", "webm", "flv", "ts"] {
            XCTAssertEqual(OfflinePlaybackPolicy.engine(for: URL(fileURLWithPath: "/tmp/movie.\(suffix)"), preferred: .system), fallback)
        }
    }

    func testMediaPlaylistLocalizesKeysInitializationAndEverySegment() throws {
        let text = """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-MEDIA-SEQUENCE:42
        #EXT-X-KEY:METHOD=AES-128,URI="key?token=synthetic",IV=0x00000000000000000000000000000001
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:2.5,private segment title
        clip.m4s?signature=synthetic
        #EXT-X-DISCONTINUITY
        #EXT-X-KEY:METHOD=NONE
        #EXTINF:2,
        https://cdn.example/second.ts
        #EXT-X-ENDLIST
        """
        guard case .media(let plan) = try OfflineHLSPlaylist.parse(Data(text.utf8), baseURL: base) else { return XCTFail() }
        XCTAssertEqual(plan.assets.count, 4)
        XCTAssertTrue(plan.manifest.contains("URI=\"asset-0.key.ts\""))
        XCTAssertTrue(plan.manifest.contains("URI=\"asset-1.mp4\""))
        XCTAssertTrue(plan.manifest.contains("asset-2.m4s"))
        XCTAssertTrue(plan.manifest.contains("#EXT-X-MEDIA-SEQUENCE:42"))
        for secret in ["http", "signature", "token", "private segment"] { XCTAssertFalse(plan.manifest.contains(secret)) }
    }

    func testRejectsLiveDRMByteRangesAndExternalAudioRatherThanClaimingOfflineSupport() {
        let playlists = [
            "#EXTM3U\n#EXTINF:2,\na.ts",
            "#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"key\"\n#EXTINF:2,\na.ts\n#EXT-X-ENDLIST",
            "#EXTM3U\n#EXT-X-BYTERANGE:100@0\n#EXTINF:2,\na.ts\n#EXT-X-ENDLIST",
            "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",URI=\"audio.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=100,AUDIO=\"a\"\nv.m3u8"
        ]
        for text in playlists { XCTAssertThrowsError(try OfflineHLSPlaylist.parse(Data(text.utf8), baseURL: base)) }
    }

    func testRejectsLocalReferencesCredentialsDowngradeAndUnknownRemoteTags() {
        for address in ["file:///private/test.ts", "https://user:secret@example.com/a.ts", "http://example.com/a.ts", "{$host}/a.ts"] {
            let text = "#EXTM3U\n#EXTINF:2,\n\(address)\n#EXT-X-ENDLIST"
            XCTAssertThrowsError(try OfflineHLSPlaylist.parse(Data(text.utf8), baseURL: base))
        }
        let text = "#EXTM3U\n#EXT-X-UNKNOWN:URI=\"https://example.com/private\"\n#EXTINF:2,\na.ts\n#EXT-X-ENDLIST"
        XCTAssertThrowsError(try OfflineHLSPlaylist.parse(Data(text.utf8), baseURL: base))
    }

    func testDirectDownloadPreservesBytesAndDoesNotPersistHTTPHeaders() async throws {
        OfflineFixtureProtocol.handler = { _ in .init(body: Self.video) }
        let result = SpiderPlaybackResult(url: base.appendingPathComponent("movie.mp4").absoluteString,
                                         headers: ["Cookie": "fixture-only-cookie"], qualityOptions: [])
        let output = try await OfflineDownloadWorker(client: client).run(result: result, directory: root) { _ in }
        let name = output.fileName
        XCTAssertEqual(name, "media.mp4")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), Self.video)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("media.partial.resume.json").path))
        XCTAssertEqual(OfflineFixtureProtocol.requests.first?.value(forHTTPHeaderField: "Cookie"), "fixture-only-cookie")
        XCTAssertEqual(try permissions(root.appendingPathComponent(name)), 0o600)
    }

    func testRejectsHTTPFailuresEmptyBodiesTruncationAndWebpages() async throws {
        let fixtures: [OfflineFixtureProtocol.Reply] = [
            .init(status: 403, body: Data("denied".utf8)),
            .init(body: Data()),
            .init(headers: ["Content-Length": "999"], body: Data([1, 2, 3])),
            .init(headers: ["Content-Type": "text/html"], body: Data("<html>sign in</html>".utf8)),
            .init(body: Data("{\"url\":\"not a movie\"}".utf8))
        ]
        for (index, reply) in fixtures.enumerated() {
            OfflineFixtureProtocol.handler = { _ in reply }
            let directory = root.appendingPathComponent(String(index))
            try OfflineDownloadStore.makeDirectory(directory)
            do {
                _ = try await OfflineDownloadWorker(client: client).run(
                    result: SpiderPlaybackResult(url: base.appendingPathComponent("movie.mp4").absoluteString, headers: [:], qualityOptions: []),
                    directory: directory) { _ in }
                XCTFail("Invalid media must never be marked complete")
            } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("media.mp4").path))
        }
    }

    func testCancellationThenResumeUsesRangeAndProducesExactlyOneFile() async throws {
        let partial = root.appendingPathComponent("movie.partial")
        try await createPartial(at: partial)
        let size = OfflineDownloadStore.size(partial)
        XCTAssertGreaterThan(size, 0)
        XCTAssertLessThan(size, Int64(Self.video.count))
        OfflineFixtureProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=\(size)-")
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-Range"), "\"version1\"")
            return .init(status: 206, headers: ["ETag": "\"version1\"", "Content-Range": "bytes \(size)-\(Self.video.count - 1)/\(Self.video.count)"],
                         body: Self.video.subdata(in: Int(size)..<Self.video.count))
        }
        _ = try await client.download(base, headers: [:], to: partial)
        XCTAssertEqual(try Data(contentsOf: partial), Self.video)
    }

    func testServerIgnoringRangeRestartsInsteadOfAppending() async throws {
        let partial = root.appendingPathComponent("movie.partial")
        try await createPartial(at: partial)
        OfflineFixtureProtocol.handler = { request in
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Range"))
            return .init(headers: ["ETag": "\"version2\""], body: Self.video)
        }
        _ = try await client.download(base, headers: [:], to: partial)
        XCTAssertEqual(try Data(contentsOf: partial), Self.video)
    }

    func testBadRangeRetriesOnceWithCleanRequest() async throws {
        let partial = root.appendingPathComponent("movie.partial")
        try await createPartial(at: partial)
        OfflineFixtureProtocol.handler = { request in
            if request.value(forHTTPHeaderField: "Range") != nil {
                return .init(status: 416, body: Data())
            }
            return .init(body: Self.video)
        }
        let before = OfflineFixtureProtocol.requests.count
        _ = try await client.download(base, headers: [:], to: partial)
        XCTAssertEqual(OfflineFixtureProtocol.requests.count - before, 2)
        XCTAssertEqual(try Data(contentsOf: partial), Self.video)
    }

    func testChangedURLDoesNotReusePartialFromAnotherMovie() async throws {
        let partial = root.appendingPathComponent("movie.partial")
        try await createPartial(at: partial)
        OfflineFixtureProtocol.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Range"))
            return .init(body: Self.video)
        }
        _ = try await client.download(base.appendingPathComponent("different.mp4"), headers: [:], to: partial)
        XCTAssertEqual(try Data(contentsOf: partial), Self.video)
    }

    func testChangedCredentialsDoNotReuseAnotherAccountPartial() async throws {
        let partial = root.appendingPathComponent("movie.partial")
        try await createPartial(at: partial)
        OfflineFixtureProtocol.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Range"))
            return .init(body: Self.video)
        }
        _ = try await client.download(base, headers: ["Cookie": "different-fixture-account"], to: partial)
        XCTAssertEqual(try Data(contentsOf: partial), Self.video)
        XCTAssertFalse(try String(contentsOf: partial.appendingPathExtension("resume.json")).contains("different-fixture-account"))
    }

    func testDownloadLimitStopsBeforeWritingOversizedResponse() async throws {
        OfflineFixtureProtocol.handler = { _ in .init(body: Self.video) }
        do {
            _ = try await client.download(base, headers: [:], to: root.appendingPathComponent("large"), maximumBytes: 10)
            XCTFail()
        } catch {}
        XCTAssertEqual(OfflineDownloadStore.size(root.appendingPathComponent("large")), 0)
    }

    func testHLSDownloadCreatesSelfContainedPackageAndScopesCredentials() async throws {
        let playlist = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n#EXTINF:2,\na.ts\n#EXTINF:2,\nhttps://cdn.example/b.ts\n#EXT-X-ENDLIST\n"
        OfflineFixtureProtocol.handler = { request in
            if request.url?.path == "/media/movie.m3u8" { return .init(body: Data(playlist.utf8)) }
            if request.url?.lastPathComponent == "key" { return .init(body: Data(repeating: 7, count: 16)) }
            if request.url?.host == "cdn.example" { XCTAssertNil(request.value(forHTTPHeaderField: "Cookie")) }
            else { XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "fixture") }
            return .init(body: Data(repeating: 1, count: 188))
        }
        let output = try await OfflineDownloadWorker(client: client).run(
            result: SpiderPlaybackResult(url: base.appendingPathComponent("movie.m3u8").absoluteString, headers: ["Cookie": "fixture"], qualityOptions: []),
            directory: root) { _ in }
        let name = output.fileName
        XCTAssertEqual(name, "offline.m3u8")
        XCTAssertEqual(output.totalSegments, 3)
        XCTAssertEqual(output.receivedBytes, 16 + 188 * 2)
        let manifest = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
        XCTAssertFalse(manifest.contains("https:"))
        for file in ["asset-0.key.ts", "asset-1.ts", "asset-2.ts"] {
            XCTAssertGreaterThan(OfflineDownloadStore.size(root.appendingPathComponent(file)), 0)
        }
        XCTAssertEqual(OfflineFixtureProtocol.requests.count, 4)
        // Resuming an unchanged playlist reuses the verified complete assets.
        _ = try await OfflineDownloadWorker(client: client).run(
            result: SpiderPlaybackResult(url: base.appendingPathComponent("movie.m3u8").absoluteString, headers: ["Cookie": "fixture"], qualityOptions: []),
            directory: root) { _ in }
        XCTAssertEqual(OfflineFixtureProtocol.requests.count, 5)
    }

    func testHLSRetryRejectsOversizedReusableAssetsBeforeWritingCompletedManifest() async throws {
        let count = 201
        let playlist = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n" + (0..<count).map { "#EXTINF:2,\n\($0).ts\n" }.joined() + "#EXT-X-ENDLIST\n"
        OfflineFixtureProtocol.handler = { request in
            .init(body: request.url?.pathExtension == "m3u8" ? Data(playlist.utf8) : Data(repeating: 71, count: 188))
        }
        let worker = OfflineDownloadWorker(client: client)
        let result = SpiderPlaybackResult(url: base.appendingPathComponent("movie.m3u8").absoluteString, headers: [:], qualityOptions: [])
        _ = try await worker.run(result: result, directory: root) { _ in }
        let manifest = root.appendingPathComponent("offline.m3u8")
        try FileManager.default.removeItem(at: manifest)
        // Sparse files model a failed 100 GiB transfer without allocating its payload.
        for index in 0..<count {
            let handle = try FileHandle(forWritingTo: root.appendingPathComponent("asset-\(index).ts"))
            try handle.truncate(atOffset: 512 * 1024 * 1024)
            try handle.close()
        }
        do {
            _ = try await worker.run(result: result, directory: root) { _ in }
            XCTFail("A retry cannot turn an oversized package into a completed download")
        } catch OfflineDownloadError.tooLarge {
            // Expected for both downloaded and reused bytes.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.path))
    }

    func testHLSUsesFourConcurrentSegmentsAndInvalidatesCacheWhenCredentialsChange() async throws {
        let playlist = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n" + (0..<8).map { "#EXTINF:2,\n\($0).ts\n" }.joined() + "#EXT-X-ENDLIST\n"
        OfflineFixtureProtocol.handler = { request in
            if request.url?.pathExtension == "m3u8" { return .init(body: Data(playlist.utf8)) }
            return .init(body: Data(repeating: 71, count: 2048), split: true)
        }
        let worker = OfflineDownloadWorker(client: client)
        let address = base.appendingPathComponent("movie.m3u8").absoluteString
        _ = try await worker.run(result: .init(url: address, headers: ["Cookie": "one"], qualityOptions: []), directory: root) { _ in }
        XCTAssertEqual(OfflineFixtureProtocol.maximumActive, 4)
        let before = OfflineFixtureProtocol.requests.count
        OfflineFixtureProtocol.handler = { request in
            if request.url?.pathExtension == "m3u8" { return .init(body: Data(playlist.utf8)) }
            return .init(body: Data(repeating: 72, count: 2048))
        }
        _ = try await worker.run(result: .init(url: address, headers: ["Cookie": "two"], qualityOptions: []), directory: root) { _ in }
        XCTAssertEqual(OfflineFixtureProtocol.requests.count - before, 9, "A changed account cannot reuse old segments")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("asset-0.ts")).first, 72)
    }

    func testPrivateIndexRoundTripAndLocalPathValidation() throws {
        let store = OfflineDownloadStore(root: root)
        var item = Self.item()
        item.status = .completed
        item.localFileName = "media.mp4"
        let directory = try store.directory(for: item.id)
        try OfflineDownloadStore.writePrivate(Self.video, to: directory.appendingPathComponent("media.mp4"))
        try store.save([item])
        XCTAssertEqual(try store.load().first?.id, item.id)
        XCTAssertNotNil(store.localURL(for: item))
        XCTAssertEqual(try permissions(root), 0o700)
        XCTAssertEqual(try permissions(root.appendingPathComponent("index.json")), 0o600)
        XCTAssertFalse(try String(contentsOf: root.appendingPathComponent("index.json")).contains("fixture-secret"))
        item.localFileName = "../../private.mp4"
        XCTAssertNil(store.localURL(for: item))
        try store.save([item])
        XCTAssertThrowsError(try store.load())
    }

    func testDownloadedRealMP4IsReadableOfflineWithEmbeddedSubtitles() async throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "subtitles", withExtension: "mp4"))
        let bytes = try Data(contentsOf: source)
        OfflineFixtureProtocol.handler = { _ in .init(body: bytes) }
        let output = try await OfflineDownloadWorker(client: client).run(
            result: .init(url: base.appendingPathComponent("video.mp4").absoluteString, headers: [:], qualityOptions: []),
            directory: root) { _ in }
        OfflineFixtureProtocol.handler = { _ in XCTFail("Offline playback must not request the source"); return .init(status: 500, body: Data()) }
        let asset = AVURLAsset(url: root.appendingPathComponent(output.fileName))
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .subtitle)
        XCTAssertGreaterThan(duration.seconds, 0)
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(OfflineFixtureProtocol.requests.count, 1)
    }

    #if os(macOS)
    @MainActor
    func testRealDownloadedHLSPlaysLocally() async throws {
        try await verifyRealHLS(encrypted: false)
    }

    @MainActor
    func testRealAES128DownloadedHLSPlaysLocally() async throws {
        try await verifyRealHLS(encrypted: true)
    }

    @MainActor
    private func verifyRealHLS(encrypted: Bool) async throws {
        let ffmpeg = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        guard FileManager.default.isExecutableFile(atPath: ffmpeg.path) else { throw XCTSkip("ffmpeg is required to generate a synthetic HLS fixture") }
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "subtitles", withExtension: "mp4"))
        let remote = root.appendingPathComponent("remote")
        let offline = root.appendingPathComponent("offline")
        try OfflineDownloadStore.makeDirectory(remote)
        try OfflineDownloadStore.makeDirectory(offline)
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-hide_banner", "-loglevel", "error", "-i", source.path, "-an", "-sn", "-c:v", "copy",
                             "-hls_time", "2", "-hls_list_size", "0"]
        if encrypted {
            let key = remote.appendingPathComponent("key")
            try OfflineDownloadStore.writePrivate(Data(repeating: 3, count: 16), to: key)
            let keyInfo = remote.appendingPathComponent("key-info")
            try OfflineDownloadStore.writePrivate(Data("key\n\(key.path)\n".utf8), to: keyInfo)
            process.arguments?.append(contentsOf: ["-hls_key_info_file", keyInfo.path])
        }
        process.arguments?.append(remote.appendingPathComponent("index.m3u8").path)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        OfflineFixtureProtocol.handler = { request in
            .init(body: (try? Data(contentsOf: remote.appendingPathComponent(request.url!.lastPathComponent))) ?? Data())
        }
        let output = try await OfflineDownloadWorker(client: client).run(
            result: .init(url: base.appendingPathComponent("index.m3u8").absoluteString, headers: [:], qualityOptions: []),
            directory: offline) { _ in }
        try FileManager.default.removeItem(at: remote)
        OfflineFixtureProtocol.handler = { _ in XCTFail("Offline HLS must not contact the source"); return .init(status: 500, body: Data()) }
        let url = offline.appendingPathComponent(output.fileName)
        #if canImport(Libmpv)
        let controller = MPVPlayerController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360), styleMask: [.borderless], backing: .buffered, defer: false)
        controller.play(url: url, decodeMode: .hardware)
        window.contentView = controller.canvas
        defer { controller.stop(); window.contentView = nil }
        let deadline = Date().addingTimeInterval(8)
        while controller.currentTimeSeconds <= 0.3 && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertGreaterThan(controller.currentTimeSeconds, 0.3)
        XCTAssertGreaterThan(controller.durationSeconds, 0)
        XCTAssertEqual(controller.decoder, "videotoolbox")
        #endif
        // Record AVFoundation's local-playlist support as well; the user-facing
        // player must select a linked engine when AVPlayer cannot read file HLS.
        let native = AVURLAsset(url: url)
        let playable = (try? await native.load(.isPlayable)) ?? false
        if !playable { XCTAssertNotEqual(OfflinePlaybackPolicy.engine(for: url, preferred: .system), .system) }
    }
    #endif

    func testStoreRejectsSymlinkAndDuplicateTaskIDs() throws {
        let store = OfflineDownloadStore(root: root)
        let item = Self.item()
        try store.save([item, item])
        XCTAssertThrowsError(try store.load())
        let symlink = root.appendingPathComponent(item.id.uuidString)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: root)
        XCTAssertThrowsError(try store.directory(for: item.id))
    }

    private func createPartial(at file: URL) async throws {
        let firstChunk = expectation(description: "Partial bytes persisted")
        let lock = NSLock()
        var fulfilled = false
        OfflineFixtureProtocol.handler = { _ in .init(headers: ["ETag": "\"version1\""], body: Self.video, split: true) }
        let task = Task {
            try await client.download(base, headers: [:], to: file) { bytes, _ in
                lock.lock(); defer { lock.unlock() }
                if bytes > 0, !fulfilled { fulfilled = true; firstChunk.fulfill() }
            }
        }
        await fulfillment(of: [firstChunk], timeout: 3)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled transfer should not finish") } catch {}
    }

    private func permissions(_ url: URL) throws -> Int { (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue }

    fileprivate static func item() -> OfflineDownload {
        let video = Movie.Video(id: "offline-fixture", name: "测试影片", sourceKey: "fixture")
        let info = VodInfo.from(video: video, playFrom: "线路", playUrl: "第1集$opaque-id")
        let source = SourceBean(key: "fixture", api: "https://example.com/api", ext: "fixture-secret")
        return OfflineDownload(info: info, episode: info.currentEpisode!, flag: info.playFlag,
                               sourceIdentity: OfflineDownload.identity(configURL: "https://example.com/config", source: source))
    }
}

@MainActor
final class OfflineDownloadManagerTests: XCTestCase {
    private var root: URL!
    private let source = SourceBean(key: "fixture", api: "https://example.com/api")
    private var info: VodInfo {
        VodInfo.from(video: Movie.Video(id: "film", name: "测试影片", sourceKey: source.key),
                     playFrom: "线路", playUrl: "第1集$one#第2集$two#第3集$three")
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TVBox-queue-test-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testQueueDeduplicatesAndLimitsActiveJobs() async throws {
        let started = expectation(description: "Two active downloads")
        started.expectedFulfillmentCount = 2
        var continuations: [CheckedContinuation<Void, Never>] = []
        let manager = OfflineDownloadManager(store: .init(root: root), resolve: { _ in
            started.fulfill()
            await withCheckedContinuation { continuations.append($0) }
            throw CancellationError()
        })
        let first = try add(manager, index: 0)
        XCTAssertEqual(try add(manager, index: 0), first)
        _ = try add(manager, index: 1)
        _ = try add(manager, index: 2)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(manager.downloads.count, 3)
        XCTAssertEqual(manager.downloads.filter { $0.status == .queued }.count, 1)
        for item in manager.downloads { try manager.pause(item.id) }
        for continuation in continuations { continuation.resume() }
        for item in manager.downloads { try await manager.remove(item.id) }
        XCTAssertTrue(manager.downloads.isEmpty)
    }

    func testPauseDeleteAndLateProgressCannotResurrectTask() async throws {
        let started = expectation(description: "Runner started")
        var pending: CheckedContinuation<Void, Never>?
        var callback: ((OfflineDownloadProgress) -> Void)?
        let manager = OfflineDownloadManager(store: .init(root: root), resolve: { _ in
            SpiderPlaybackResult(url: "https://example.com/movie.mp4?token=fixture-secret", headers: ["Cookie": "fixture-secret"], qualityOptions: [])
        }, run: { _, _, progress in
            callback = progress
            started.fulfill()
            await withCheckedContinuation { pending = $0 }
            throw CancellationError()
        })
        let id = try add(manager, index: 0)
        await fulfillment(of: [started], timeout: 2)
        try manager.pause(id)
        callback?(.init(receivedBytes: 100, totalBytes: 200))
        await Task.yield()
        XCTAssertEqual(manager.downloads.first?.status, .paused)
        XCTAssertEqual(manager.downloads.first?.receivedBytes, 0)
        let saved = try String(contentsOf: root.appendingPathComponent("index.json"))
        XCTAssertFalse(saved.contains("fixture-secret"))
        pending?.resume()
        try await manager.remove(id)
        callback?(.init(receivedBytes: 200, totalBytes: 200))
        await Task.yield()
        XCTAssertTrue(manager.downloads.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(id.uuidString).path))
    }

    func testRestartPausesUnfinishedAndKeepsCompletedAvailableWithoutResolver() throws {
        let store = OfflineDownloadStore(root: root)
        var unfinished = OfflineDownloadTests.item()
        unfinished.status = .downloading
        var complete = OfflineDownloadTests.item()
        complete.status = .completed
        complete.localFileName = "media.mp4"
        let directory = try store.directory(for: complete.id)
        try OfflineDownloadStore.writePrivate(Data([1, 2, 3]), to: directory.appendingPathComponent("media.mp4"))
        try store.save([unfinished, complete])
        let manager = OfflineDownloadManager(store: store, resolve: { _ in XCTFail("Restart must not call provider"); throw CancellationError() })
        XCTAssertEqual(manager.downloads.map(\.status), [.paused, .completed])
        XCTAssertNotNil(manager.localURL(for: manager.downloads[1]))
    }

    func testMissingCompletedFileBecomesRetryableAndCorruptIndexIsPreserved() throws {
        let store = OfflineDownloadStore(root: root)
        var item = OfflineDownloadTests.item()
        item.status = .completed
        item.localFileName = "media.mp4"
        try store.save([item])
        XCTAssertEqual(OfflineDownloadManager(store: store).downloads.first?.status, .failed)
        let corrupt = Data("not JSON".utf8)
        try OfflineDownloadStore.writePrivate(corrupt, to: root.appendingPathComponent("index.json"))
        let manager = OfflineDownloadManager(store: store)
        XCTAssertNotNil(manager.storageError)
        XCTAssertThrowsError(try add(manager, index: 0))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("index.json")), corrupt)
    }

    func testProviderErrorsAreRedactedAndTaskCanRetry() async throws {
        let failed = expectation(description: "Task failed")
        let manager = OfflineDownloadManager(store: .init(root: root), resolve: { _ in
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "https://example.com?cookie=fixture-secret"])
        })
        let subscription = manager.$downloads.sink { tasks in if tasks.first?.status == .failed { failed.fulfill() } }
        let id = try add(manager, index: 0)
        await fulfillment(of: [failed], timeout: 2)
        subscription.cancel()
        XCTAssertFalse(manager.downloads.first?.errorMessage?.contains("fixture-secret") ?? true)
        try await manager.remove(id)
    }

    func testFastCompletionKeepsFinalCountsEvenWhenProgressArrivesLate() async throws {
        let complete = expectation(description: "Download completed")
        let manager = OfflineDownloadManager(store: .init(root: root), resolve: { _ in
            .init(url: "https://example.com/film.m3u8", headers: [:], qualityOptions: [])
        }, run: { _, directory, progress in
            try OfflineDownloadStore.writePrivate(Data("#EXTM3U".utf8), to: directory.appendingPathComponent("offline.m3u8"))
            progress(.init(receivedBytes: 1, totalBytes: nil, completedSegments: 0, totalSegments: 3))
            return .init(fileName: "offline.m3u8", receivedBytes: 300, totalSegments: 3)
        })
        let subscription = manager.$downloads.sink { if $0.first?.status == .completed { complete.fulfill() } }
        let id = try add(manager, index: 0)
        await fulfillment(of: [complete], timeout: 2)
        subscription.cancel()
        await Task.yield()
        XCTAssertEqual(manager.downloads.first?.receivedBytes, 300)
        XCTAssertEqual(manager.downloads.first?.completedSegments, 3)
        XCTAssertEqual(manager.downloads.first?.totalSegments, 3)
        try await manager.remove(id)
    }

    func testOversizedBatchAddsNothingAndDoesNotStartProvider() throws {
        let store = OfflineDownloadStore(root: root)
        let manager = OfflineDownloadManager(store: store, resolve: { _ in XCTFail("Rejected batch must not start downloads"); throw CancellationError() })
        let episodes = (0...OfflineDownloadStore.maximumTasks).map { VodInfo.Episode(name: "第\($0)集", url: "opaque-\($0)") }
        XCTAssertThrowsError(try manager.enqueue(info: info, episodes: episodes, flag: info.playFlag, source: source, configURL: "https://example.com/config"))
        XCTAssertTrue(manager.downloads.isEmpty)
        XCTAssertTrue(try store.load().isEmpty)
    }

    #if os(macOS)
    func testDownloadManagementLayoutAtCompactAndWideWidths() throws {
        var paused = OfflineDownloadTests.item()
        paused.status = .paused
        paused.receivedBytes = 120 * 1024 * 1024
        paused.totalBytes = 600 * 1024 * 1024
        var failed = OfflineDownloadTests.item()
        failed.status = .failed
        failed.errorMessage = "媒体授权已失效，请检查登录状态后重试"
        var complete = OfflineDownloadTests.item()
        complete.status = .completed
        complete.localFileName = "media.mp4"
        complete.receivedBytes = 600 * 1024 * 1024
        let store = OfflineDownloadStore(root: root)
        let directory = try store.directory(for: complete.id)
        try OfflineDownloadStore.writePrivate(Data([1]), to: directory.appendingPathComponent("media.mp4"))
        try store.save([paused, failed, complete])
        let manager = OfflineDownloadManager(store: store)
        for width in [440.0, 1000.0] {
            let host = NSHostingView(rootView: NavigationStack { DownloadsView(manager: manager) }.preferredColorScheme(.dark))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 520)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = NSImage(size: host.bounds.size)
            image.addRepresentation(bitmap)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Offline downloads \(Int(width))"
            attachment.lifetime = .keepAlways
            add(attachment)
            window.contentView = nil
        }
    }
    #endif

    private func add(_ manager: OfflineDownloadManager, index: Int) throws -> UUID {
        try manager.enqueue(info: info, episode: info.currentEpisodes[index], flag: info.playFlag, source: source, configURL: "https://example.com/config")
    }
}

private final class OfflineFixtureProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var body: Data
        var split = false
    }
    private static let lock = NSLock()
    private static var savedHandler: ((URLRequest) -> Reply)?
    private static var savedRequests: [URLRequest] = []
    private static var active = 0
    private static var peak = 0
    private let stateLock = NSLock()
    private var stopped = false
    private var counted = false

    static var handler: ((URLRequest) -> Reply)? {
        get { lock.lock(); defer { lock.unlock() }; return savedHandler }
        set { lock.lock(); defer { lock.unlock() }; savedHandler = newValue }
    }
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return savedRequests }
    static var maximumActive: Int { lock.lock(); defer { lock.unlock() }; return peak }
    static func reset() { lock.lock(); defer { lock.unlock() }; savedHandler = nil; savedRequests = []; active = 0; peak = 0 }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.savedRequests.append(request)
        Self.active += 1
        Self.peak = max(Self.peak, Self.active)
        counted = true
        let handler = Self.savedHandler
        Self.lock.unlock()
        guard let reply = handler?(request) else { finishCounting(); client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        var headers = reply.headers
        if headers["Content-Length"] == nil { headers["Content-Length"] = String(reply.body.count) }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if reply.split {
            client?.urlProtocol(self, didLoad: reply.body.prefix(1024))
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { [self] in
                stateLock.lock(); let active = !stopped; stateLock.unlock()
                guard active else { return }
                client?.urlProtocol(self, didLoad: reply.body.dropFirst(1024))
                finishCounting()
                client?.urlProtocolDidFinishLoading(self)
            }
        } else {
            client?.urlProtocol(self, didLoad: reply.body)
            finishCounting()
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock(); finishCounting() }
    private func finishCounting() {
        stateLock.lock()
        let wasCounted = counted
        counted = false
        stateLock.unlock()
        if wasCounted { Self.lock.lock(); Self.active -= 1; Self.lock.unlock() }
    }
}
