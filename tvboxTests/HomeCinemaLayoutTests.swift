#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import TVBox

/// 使用本地绘制的海报验证首页布局，不请求影片接口或保存用户配置。
@MainActor
final class HomeCinemaLayoutTests: XCTestCase {
    func testRenderWideDarkHome() throws {
        try render(width: 1180, scheme: .dark)
    }

    func testRenderWideLightHome() throws {
        try render(width: 1180, scheme: .light)
    }

    func testRenderCompactHomeWithLongTitleAndMissingArtwork() throws {
        try render(width: 390, scheme: .dark, missingArtwork: true)
    }

    private func render(width: CGFloat, scheme: ColorScheme, missingArtwork: Bool = false) throws {
        let videos = makeVideos(missingArtwork: missingArtwork)
        let content = NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HStack {
                        Spacer()
                        Text("精选片库").font(.caption).foregroundStyle(.secondary)
                    }.padding(.horizontal, 28).padding(.top, 16)
                    HStack(spacing: 8) {
                        ForEach(["推荐", "电影", "电视剧", "综艺"], id: \.self) { title in
                            HomeCinemaCategoryLabel(title: title, isSelected: title == "推荐")
                        }
                    }.padding(.horizontal, 12)
                    HomeCinemaShelf(title: "为你精选", videos: videos)
                    HomeCinemaShelf(title: "电影推荐", videos: Array(videos.reversed()), more: {})
                }
                .padding(.bottom, 24)
            }
            .background(AppTheme.background)
            .navigationDestination(for: Movie.Video.self) { video in Text(video.name) }
        }
        .environment(\.colorScheme, scheme)

        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 1040)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        // CachedAsyncImage 从内存读取海报的 .task 需要一次主线程调度。
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Cinema home \(Int(width)) \(scheme == .dark ? "dark" : "light")"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func makeVideos(missingArtwork: Bool) -> [Movie.Video] {
        let names = ["山海之间", "午夜来信", "漫游宇宙", "夏日终曲", "风起之时", "远方的灯塔"]
        let colors: [NSColor] = [.systemTeal, .systemPurple, .systemIndigo, .systemOrange, .systemBrown, .systemCyan]
        return names.enumerated().map { index, name in
            let url = URL(string: "https://example.com/cinema-preview-\(index).jpg")!
            ImageCache.shared.set(poster(title: name, color: colors[index], index: index), for: url)
            var video = Movie.Video(id: "preview-\(index)", name: name, pic: url.absoluteString,
                                    note: index == 0 ? "全 12 集" : "高清", sourceKey: "layout-preview")
            video.year = "2026"
            video.area = "中国大陆"
            video.type = "剧情"
            video.des = "越过山川与城市，寻找平凡生活里不曾停歇的光。一次偶然的重逢，让两段人生重新交汇。"
            if missingArtwork && index == 0 {
                video.pic = ""
                video.name = "山海之间：一段漫长旅程与未完的故事 第二季"
            }
            return video
        }
    }

    private func poster(title: String, color: NSColor, index: Int) -> NSImage {
        NSImage(size: NSSize(width: 300, height: 450), flipped: false) { _ in
            NSGraphicsContext.current?.cgContext.scaleBy(x: 0.5, y: 0.5)
            let bounds = NSRect(x: 0, y: 0, width: 600, height: 900)
            NSGradient(starting: color.blended(withFraction: 0.4, of: .black)!, ending: .black)!
                .draw(in: bounds, angle: -90)
            color.withAlphaComponent(0.5).setFill()
            NSBezierPath(ovalIn: NSRect(x: 280, y: 490, width: 260, height: 260)).fill()
            for layer in 0..<4 {
                let path = NSBezierPath()
                path.move(to: .zero)
                for step in 0...12 {
                    let x = CGFloat(step) * 50
                    let y = CGFloat(180 + layer * 75) + sin(CGFloat(step + index) * 0.8) * 65
                    path.line(to: NSPoint(x: x, y: y))
                }
                path.line(to: NSPoint(x: 600, y: 0))
                path.close()
                NSColor.black.withAlphaComponent(0.15 + CGFloat(layer) * 0.12).setFill()
                path.fill()
            }
            (title as NSString).draw(in: NSRect(x: 36, y: 110, width: 540, height: 100), withAttributes: [
                .font: NSFont.systemFont(ofSize: 60, weight: .heavy), .foregroundColor: NSColor.white
            ])
            return true
        }
    }
}
#endif
