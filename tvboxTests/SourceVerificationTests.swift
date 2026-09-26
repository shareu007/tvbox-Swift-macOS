import XCTest
@testable import TVBox

@MainActor
final class SourceVerificationTests: XCTestCase {
    private let url = "https://config.example/one.json"
    private func source(_ key: String, api: String = "https://source.example/api") -> SourceBean {
        .init(key: key, name: key, api: api, type: 1)
    }

    func testProtocolInspectionDoesNotClaimNetworkOrPlaybackAvailability() {
        let result = SettingsViewModel.inspectLoadedConfig(entryURL: url, sources: [source("one")])
        XCTAssertEqual(result.supportedSourceCount, 1)
        XCTAssertTrue(result.message.contains("协议支持：1 / 1"))
        XCTAssertTrue(result.message.contains("首页实测：未执行"))
        XCTAssertTrue(result.message.contains("播放实测：未执行"))
        XCTAssertFalse(result.message.contains("可用 1"))
    }

    func testOldSavedConfigurationDecodesWithoutNewTimestamp() throws {
        let config = SavedVodConfig(name: "Old", url: url, configurationProtocol: "TVBox JSON", compatibility: .compatible, supportedSourceCount: 29, totalSourceCount: 29)
        let encoded = try SavedVodConfig.encode([config])
        XCTAssertFalse(encoded.contains("protocolCheckedAt"))
        let old = try XCTUnwrap(SavedVodConfig.decode(from: encoded).first)
        XCTAssertEqual(old.supportedSourceCount, 29)
        XCTAssertNil(old.protocolCheckedAt)
        let store = SourceVerificationStore()
        store.register(configURL: url, sources: [source("one")])
        XCTAssertEqual(store.report(for: url)?.homeSummary, "首页实测：未检测")
        XCTAssertEqual(store.report(for: url)?.playbackSummary, "播放实测：未验证")
    }

    func testHomeEvidenceDoesNotImplyPlaybackAndRoundTripsWithoutURLs() throws {
        var persisted = ""
        let store = SourceVerificationStore(persist: { persisted = $0 })
        let one = source("one")
        let time = Date(timeIntervalSince1970: 123456)
        store.register(configURL: url, sources: [one, source("two")])
        store.recordHome(.content, context: store.context(configURL: url, source: one), at: time)
        let restored = SourceVerificationStore(persisted: persisted)
        let report = try XCTUnwrap(restored.report(for: url))
        XCTAssertEqual(report.contentCount, 1)
        XCTAssertEqual(report.checkedCount, 1)
        XCTAssertEqual(report.playedCount, 0)
        XCTAssertEqual(report.lastHomeCheck, time)
        XCTAssertTrue(report.homeSummary.contains("1 个未测"))
        XCTAssertFalse(persisted.contains("https://"))
    }

    func testEndpointChangeInvalidatesOldEvidenceAndLateResult() throws {
        let store = SourceVerificationStore()
        let old = source("same")
        store.register(configURL: url, sources: [old])
        let context = store.context(configURL: url, source: old)
        store.recordHome(.content, context: context)
        store.recordPlayback(context: context)
        store.register(configURL: url, sources: [source("same", api: "https://new.example/api")])
        store.recordHome(.content, context: context)
        store.recordPlayback(context: context)
        let report = try XCTUnwrap(store.report(for: url))
        XCTAssertEqual(report.checkedCount, 0)
        XCTAssertEqual(report.playedCount, 0)
    }

    func testPlaybackRemainsAttributedToCapturedConfiguration() {
        let store = SourceVerificationStore()
        let one = source("one")
        let otherURL = "https://config.example/two.json"
        store.register(configURL: url, sources: [one])
        let context = store.context(configURL: url, source: one)
        store.register(configURL: otherURL, sources: [one])
        store.recordPlayback(context: context)
        XCTAssertEqual(store.report(for: url)?.playedCount, 1)
        XCTAssertEqual(store.report(for: otherURL)?.playedCount, 0)
        XCTAssertEqual(store.report(for: url)?.checkedCount, 0)
    }

    func testProbeDistinguishesContentEmptyErrorAndTimeoutWithoutPlayback() async throws {
        let store = SourceVerificationStore()
        let sources = [source("good"), source("empty"), source("error"), source("timeout")]
        let probe = SourceVerificationProbe(store: store, home: { source in
            switch source.key {
            case "error": throw URLError(.badServerResponse)
            case "timeout": throw URLError(.timedOut)
            default: return ([.init(id: "movie", name: "电影")], [])
            }
        }, category: { source, _, _, _ in source.key == "good" ? [Movie.Video(id: "video")] : [] })
        await probe.check(configURL: url, sources: sources)
        let report = try XCTUnwrap(store.report(for: url))
        XCTAssertEqual(report.checkedCount, 4)
        XCTAssertEqual(report.contentCount, 1)
        XCTAssertEqual(report.playedCount, 0)
        XCTAssertEqual(report.evidence[SourceVerificationStore.sourceID(sources[1])]?.home, .empty)
        XCTAssertEqual(report.evidence[SourceVerificationStore.sourceID(sources[2])]?.home, .failed)
        XCTAssertEqual(report.evidence[SourceVerificationStore.sourceID(sources[3])]?.home, .timedOut)
        XCTAssertNil(probe.checkingConfigID)
    }

    func testStoppingProbeDoesNotConvertUnfinishedRequestsToFailures() async {
        let store = SourceVerificationStore()
        let started = expectation(description: "started")
        let probe = SourceVerificationProbe(store: store, home: { _ in
            started.fulfill()
            try await Task.sleep(for: .seconds(10))
            return ([], [])
        }, category: { _, _, _, _ in [] })
        let task = Task { await probe.check(configURL: url, sources: [source("slow")]) }
        await fulfillment(of: [started], timeout: 1)
        probe.stop()
        await task.value
        XCTAssertEqual(store.report(for: url)?.checkedCount, 0)
        XCTAssertNil(probe.checkingConfigID)
    }

    func testBudgetLeavesUnstartedSitesUntested() async {
        let store = SourceVerificationStore()
        let probe = SourceVerificationProbe(store: store, home: { _ in
            try await Task.sleep(for: .seconds(1))
            return ([], [])
        }, category: { _, _, _, _ in [] })
        await probe.check(configURL: url, sources: (0..<20).map { source("s\($0)") }, seconds: 0.03, requestSeconds: 1)
        XCTAssertEqual(store.report(for: url)?.checkedCount, 3)
        XCTAssertTrue(store.report(for: url)?.homeSummary.contains("17 个未测") == true)
    }

    func testPlaybackRequiresSustainedAdvancementAndDoesNotCountSeekOrPause() {
        var tracker = PlaybackProgressEvidence()
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertFalse(tracker.observe(playbackID: "one", seconds: 120, playing: true, at: start))
        XCTAssertFalse(tracker.observe(playbackID: "one", seconds: 500, playing: true, at: start.addingTimeInterval(1)))
        XCTAssertFalse(tracker.observe(playbackID: "one", seconds: 501, playing: false, at: start.addingTimeInterval(2)))
        for i in 0..<3 {
            XCTAssertFalse(tracker.observe(playbackID: "one", seconds: Double(501 + i), playing: true, at: start.addingTimeInterval(Double(3 + i))))
        }
        XCTAssertTrue(tracker.observe(playbackID: "one", seconds: 504, playing: true, at: start.addingTimeInterval(6)))
        XCTAssertFalse(tracker.observe(playbackID: "one", seconds: 505, playing: true, at: start.addingTimeInterval(7)))
        XCTAssertFalse(tracker.observe(playbackID: "two", seconds: 505, playing: true, at: start.addingTimeInterval(8)))
    }
}
