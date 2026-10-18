import SwiftUI
import XCTest
#if os(macOS)
import AppKit
#else
import UIKit
#endif
@testable import TVBox

@MainActor
final class AdaptiveMediaLayoutTests: XCTestCase {
    func testWidePlaybackPlacesEpisodesBesideVideo() throws {
        let model = LayoutProbeModel(width: 1024)
        try withHost(model: model) {
            let playback = try XCTUnwrap(model.frames["playback"])
            let episodes = try XCTUnwrap(model.frames["episodes"])
            XCTAssertEqual(playback.minY, episodes.minY, accuracy: 1)
            XCTAssertGreaterThanOrEqual(episodes.minX, playback.maxX - 1)
            XCTAssertGreaterThanOrEqual(playback.width, 600)
            XCTAssertLessThanOrEqual(episodes.maxX, 1025)
        }
    }

    func testResizingToSplitScreenStacksEpisodesWithoutRecreatingPlayback() throws {
        let model = LayoutProbeModel(width: 1024)
        try withHost(model: model) {
            let playbackIdentity = try XCTUnwrap(model.playbackIdentity)
            model.width = 390
            settleLayout()

            let playback = try XCTUnwrap(model.frames["playback"])
            let episodes = try XCTUnwrap(model.frames["episodes"])
            XCTAssertEqual(playback.width, 390, accuracy: 1)
            XCTAssertGreaterThanOrEqual(episodes.minY, playback.maxY - 1)
            XCTAssertLessThanOrEqual(episodes.maxX, 391)
            XCTAssertEqual(model.playbackIdentity, playbackIdentity)
        }
    }

    func testOverviewKeepsEpisodesBelowInformationOnWideWindows() throws {
        let model = LayoutProbeModel(width: 1024, isPlaying: false)
        try withHost(model: model) {
            let playback = try XCTUnwrap(model.frames["playback"])
            let episodes = try XCTUnwrap(model.frames["episodes"])
            XCTAssertGreaterThanOrEqual(episodes.minY, playback.maxY - 1)
            XCTAssertEqual(playback.width, 1024, accuracy: 1)
        }
    }

    func testChannelPanelFitsSmallPhonesAndDoesNotStretchAcrossIPad() {
        XCTAssertEqual(AdaptiveMediaLayout.channelPanelWidth(availableWidth: 320), 296)
        XCTAssertEqual(AdaptiveMediaLayout.channelPanelWidth(availableWidth: 1024), 640)
    }

    private func settleLayout() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    }

    private func withHost(model: LayoutProbeModel, check: () throws -> Void) throws {
        let content = LayoutProbe(model: model)
        #if os(macOS)
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(x: 0, y: 0, width: 1100, height: 800)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        #else
        let host = UIHostingController(rootView: content)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1100, height: 800))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        #endif
        settleLayout()
        try check()
    }
}

@MainActor
private final class LayoutProbeModel: ObservableObject {
    @Published var width: CGFloat
    let isPlaying: Bool
    var frames: [String: CGRect] = [:]
    var playbackIdentity: UUID?

    init(width: CGFloat, isPlaying: Bool = true) {
        self.width = width
        self.isPlaying = isPlaying
    }
}

private struct LayoutProbe: View {
    @ObservedObject var model: LayoutProbeModel

    var body: some View {
        AdaptivePlaybackLayout(availableWidth: model.width, isPlaying: model.isPlaying) {
            PlaybackIdentityProbe { model.playbackIdentity = $0 }
                .background(frameProbe("playback"))
        } episodes: {
            Color.orange.frame(height: 200)
                .background(frameProbe("episodes"))
        }
        .frame(width: model.width)
        .coordinateSpace(name: "playback-layout")
        .onPreferenceChange(LayoutFramesKey.self) { model.frames = $0 }
    }

    private func frameProbe(_ key: String) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: LayoutFramesKey.self,
                                   value: [key: geometry.frame(in: .named("playback-layout"))])
        }
    }
}

private struct PlaybackIdentityProbe: View {
    @State private var identity = UUID()
    let observe: (UUID) -> Void

    var body: some View {
        Color.black.frame(height: 220)
            .onAppear { observe(identity) }
    }
}

private struct LayoutFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}
