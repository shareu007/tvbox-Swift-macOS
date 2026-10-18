#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import TVBox

@MainActor
final class DetailCinemaLayoutTests: XCTestCase {
    func testRenderWideDetailInBothAppearances() throws {
        for scheme in [ColorScheme.dark, .light] {
            try render(width: 1100, scheme: scheme)
        }
    }

    func testRenderCompactDetailWithMissingPosterAndLongTitle() throws {
        try render(width: 390, scheme: .light, missingPoster: true)
    }

    func testRenderPlaybackWithCompactHeader() throws {
        try render(width: 1100, scheme: .dark, playing: true)
    }

    func testRenderResumedEpisodeInSecondGroup() throws {
        try render(width: 390, scheme: .dark, playing: true, selectedIndex: 54, count: 100)
    }

    private func render(width: CGFloat, scheme: ColorScheme, missingPoster: Bool = false,
                        playing: Bool = false, selectedIndex: Int = 1, count: Int = 6) throws {
        var info = VodInfo(id: "detail-layout-preview")
        info.name = missingPoster ? "山海之间：一段漫长旅程与未完的故事 第二季" : "山海之间"
        info.year = "2026"
        info.area = "中国大陆"
        info.typeName = "剧情 / 悬疑"
        info.note = "全 \(count) 集"
        info.des = "越过山川与城市，寻找平凡生活里不曾停歇的光。一次偶然的重逢，让两段人生重新交汇。"
        info.director = "示例导演"
        info.actor = "示例演员"
        if !missingPoster {
            let url = URL(string: "https://example.com/detail-layout-poster.jpg")!
            let image = NSImage(size: NSSize(width: 300, height: 450), flipped: false) { bounds in
                NSGradient(starting: .systemTeal, ending: .black)!.draw(in: bounds, angle: -90)
                NSColor.systemTeal.withAlphaComponent(0.4).setFill()
                NSBezierPath(ovalIn: NSRect(x: 160, y: 240, width: 120, height: 120)).fill()
                return true
            }
            ImageCache.shared.set(image, for: url)
            info.pic = url.absoluteString
        }
        let episodes = (1...count).map { VodInfo.Episode(name: "第\($0)集", url: "") }
        let content = ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if playing {
                    Color.black.aspectRatio(16 / 9, contentMode: .fit)
                        .overlay(Image(systemName: "play.rectangle").font(.largeTitle).foregroundStyle(.white))
                }
                DetailCinemaHeader(info: info, compact: playing) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { self.actions(playing: playing) }
                        VStack(alignment: .leading, spacing: 10) { self.actions(playing: playing) }
                    }
                }
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("剧集").font(.title2.bold())
                        Text("共 \(count) 集").foregroundStyle(.secondary)
                        Spacer()
                        Text("线路一 ⌄").font(.subheadline)
                    }
                    EpisodeListView(episodes: episodes, selectedIndex: selectedIndex, onSelect: { _ in },
                                    layout: .cinema, isPlaying: playing)
                }.padding(.horizontal, 28)
                DetailCinemaAbout(info: info)
            }.padding(.bottom, 24)
        }
        .background(AppTheme.background)
        .environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 1040)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Detail \(Int(width)) \(scheme) \(playing ? "playing" : "overview") episode \(selectedIndex + 1)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @ViewBuilder
    private func actions(playing: Bool) -> some View {
        if !playing {
            Button {} label: { Label("立即播放", systemImage: "play.fill") }
                .buttonStyle(DetailCinemaActionStyle(prominent: true, onArtwork: true))
        }
        Button {} label: { Label("收藏", systemImage: "plus") }
            .buttonStyle(DetailCinemaActionStyle(onArtwork: !playing))
        Button {} label: { Label("下载", systemImage: "arrow.down.circle") }
            .buttonStyle(DetailCinemaActionStyle(onArtwork: !playing))
    }
}
#endif
