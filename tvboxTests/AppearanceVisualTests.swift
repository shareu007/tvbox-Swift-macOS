#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import TVBox

/// 挂载真实组件检查浅色/深色在窄屏和宽屏上的文字、选集与设置控件。
@MainActor
final class AppearanceVisualTests: XCTestCase {
    func testRenderSettingsAndBrowsingInBothAppearances() throws {
        let suiteName = "tvbox-appearance-visual-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let episodes = (1...6).map { VodInfo.Episode(name: "第\($0)集", url: "") }
        for scheme in [ColorScheme.light, .dark] {
            for width in [390.0, 820.0] {
                let content = VStack(alignment: .leading, spacing: 20) {
                    Text("外观与浏览").font(.title.bold()).foregroundStyle(.primary)
                    SectionCard(title: "外观") { AppearanceSettingsView() }
                    HStack(alignment: .top, spacing: 16) {
                        VodCardView(video: Movie.Video(id: "one", name: "山海之间", note: "更新至12集"))
                            .frame(width: 160)
                            .clipped()
                        VodCardView(video: Movie.Video(id: "two", name: "城市漫游：第二季", note: "完结"))
                            .frame(width: 160)
                            .clipped()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 300)
                    SectionCard(title: "播放设置") {
                        SettingsRow(icon: "play.rectangle", title: "点播播放器", value: "系统播放器", action: {})
                    }
                    Text("选集播放").font(.headline).foregroundStyle(.primary)
                    EpisodeListView(episodes: episodes, selectedIndex: 1, onSelect: { _ in })
                    Spacer(minLength: 0)
                }
                .padding(20)
                .frame(width: width, height: 800)
                .background(AppTheme.primaryGradient)
                .environment(\.colorScheme, scheme)
                .defaultAppStorage(defaults)
                let host = NSHostingView(rootView: content)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 800)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let name = "tvbox-appearance-\(scheme)-\(Int(width))"
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = name
                attachment.lifetime = .keepAlways
                add(attachment)
                let output = URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("build/DerivedData/AppearanceSnapshots", isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try png.write(to: output.appendingPathComponent(name + ".png"))
                window.contentView = nil
            }
        }
    }
}
#endif
