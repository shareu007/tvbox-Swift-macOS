import AVFoundation
import XCTest
@testable import TVBox

@MainActor
final class SubtitleSelectionTests: XCTestCase {
    private let english = SubtitleTrack(id: 4, title: "English", language: "en")
    private let chinese = SubtitleTrack(id: 9, title: "简体中文", language: "zh-Hans")

    func testAutomaticPrefersChineseEvenWhenAnotherTrackIsDefault() {
        XCTAssertEqual(SubtitleTrack.preferred(in: [english, chinese], defaultID: 4, languages: ["en"]), 9)
        XCTAssertEqual(SubtitleTrack.preferred(in: [.init(id: 8, title: "Chinese")]), 8)
        XCTAssertEqual(SubtitleTrack.preferred(in: [.init(id: 1, title: "Chinese Forced", language: "zh", isForced: true), chinese]), 9)
    }

    func testVLCUsesTrackIDsAndExcludesDisabledPseudoTrack() {
        let tracks = SubtitleTrack.vlcTracks(names: ["Disable", "English", "中文", "duplicate"], indexes: [-1, 4, 9, 9])
        XCTAssertEqual(tracks.map(\.id), [4, 9])
        XCTAssertEqual(tracks.map(\.title), ["English", "中文"])
        XCTAssertEqual(SubtitleTrack.vlcTracks(names: [], indexes: [7]).first?.title, "字幕轨道 7")
    }

    func testOffAndManualChoicesSurviveLateTrackDiscoveryUntilNewMedia() {
        let state = SubtitleState()
        state.selection = .off
        state.tracks = [english, chinese]
        XCTAssertNil(state.desiredTrackID())
        state.selection = .track(4)
        XCTAssertEqual(state.desiredTrackID(), 4)
        state.tracks.append(.init(id: 20, title: "繁体中文"))
        XCTAssertEqual(state.desiredTrackID(), 4)
        state.reset()
        XCTAssertEqual(state.selection, .automatic)
        XCTAssertTrue(state.tracks.isEmpty)
        XCTAssertNil(state.selectedTrackID)
    }

    func testEmptyTracksDoNotInventSubtitleOption() {
        XCTAssertNil(SubtitleTrack.preferred(in: []))
        let state = SubtitleState()
        state.selection = .track(123)
        XCTAssertNil(state.desiredTrackID())
    }

    func testSystemPlayerSelectsRealTracksAndPreservesChoiceWhenReboundForFullscreen() async throws {
        let item = AVPlayerItem(url: try fixtureURL())
        let player = AVPlayer(playerItem: item)
        let controller = SystemSubtitleController()
        defer { controller.reset(); player.replaceCurrentItem(with: nil) }
        controller.bind(to: item)
        try await waitUntil { !controller.state.isLoading }
        let loadedGroup = try await item.asset.loadMediaSelectionGroup(for: .legible)
        let group = try XCTUnwrap(loadedGroup)
        XCTAssertGreaterThanOrEqual(controller.state.tracks.count, 2)
        let englishID = try XCTUnwrap(controller.state.tracks.first { $0.language?.hasPrefix("en") == true }?.id)
        let chineseID = try XCTUnwrap(controller.state.tracks.first { $0.language?.hasPrefix("zh") == true }?.id)
        XCTAssertEqual(controller.state.selectedTrackID, chineseID)
        XCTAssertFalse(try XCTUnwrap(item.currentMediaSelection.selectedMediaOption(in: group)).hasMediaCharacteristic(.containsOnlyForcedSubtitles))
        controller.select(.track(englishID))
        XCTAssertEqual(item.currentMediaSelection.selectedMediaOption(in: group)?.extendedLanguageTag, "en")
        controller.bind(to: item)
        XCTAssertEqual(controller.state.selection, .track(englishID))
        controller.select(.off)
        XCTAssertNil(item.currentMediaSelection.selectedMediaOption(in: group))
        controller.bind(to: item)
        XCTAssertEqual(controller.state.selection, .off)
        controller.select(.automatic)
        XCTAssertEqual(controller.state.selectedTrackID, chineseID)
    }

    func testSystemNewItemClearsTracksAndIgnoresOldAsyncLoads() async throws {
        let controller = SystemSubtitleController()
        controller.bind(to: AVPlayerItem(url: try fixtureURL()))
        controller.reset()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(controller.state.tracks.isEmpty)
        XCTAssertNil(controller.state.selectedTrackID)
    }

    func testSystemNewEpisodeResetsChoiceAndSubtitleFreeAssetHasNoTracks() async throws {
        let controller = SystemSubtitleController()
        defer { controller.reset() }
        controller.bind(to: AVPlayerItem(url: try fixtureURL()))
        try await waitUntil { !controller.state.isLoading }
        controller.select(.off)
        controller.bind(to: AVPlayerItem(asset: AVMutableComposition()))
        XCTAssertEqual(controller.state.selection, .automatic)
        XCTAssertTrue(controller.state.tracks.isEmpty)
        try await waitUntil { !controller.state.isLoading }
        XCTAssertTrue(controller.state.tracks.isEmpty)
        XCTAssertNil(controller.state.selectedTrackID)
    }

    #if canImport(VLCKitSPM)
    func testVLCDiscoversRealTracksSelectsAndDisablesWithoutLosingFullscreenChoice() async throws {
        let controller = VLCPlayerController()
        defer { controller.stop() }
        let url = try fixtureURL()
        controller.play(url: url, startPosition: 0, isLive: false,
                        onProgressChanged: nil, onPlaybackEnded: nil, onPlaybackFailed: nil)
        try await waitUntil { controller.subtitles.tracks.count == 2 }
        let chineseID = try XCTUnwrap(controller.subtitles.tracks.first { $0.title.lowercased().contains("chinese") }?.id)
        XCTAssertEqual(Int(controller.mediaPlayer.currentVideoSubTitleIndex), chineseID)
        let englishID = try XCTUnwrap(controller.subtitles.tracks.first { $0.id != chineseID }?.id)
        controller.selectSubtitle(.track(englishID))
        XCTAssertEqual(Int(controller.mediaPlayer.currentVideoSubTitleIndex), englishID)
        controller.play(url: url, startPosition: 0, isLive: false,
                        onProgressChanged: nil, onPlaybackEnded: nil, onPlaybackFailed: nil)
        XCTAssertEqual(controller.subtitles.selection, .track(englishID))
        controller.selectSubtitle(.off)
        XCTAssertEqual(controller.mediaPlayer.currentVideoSubTitleIndex, -1)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(controller.mediaPlayer.currentVideoSubTitleIndex, -1)
        controller.selectSubtitle(.automatic)
        XCTAssertEqual(Int(controller.mediaPlayer.currentVideoSubTitleIndex), chineseID)
        controller.stop()
        XCTAssertTrue(controller.subtitles.tracks.isEmpty)
    }
    #endif

    private func fixtureURL() throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: "subtitles", withExtension: "mp4"))
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for subtitle tracks")
    }
}
