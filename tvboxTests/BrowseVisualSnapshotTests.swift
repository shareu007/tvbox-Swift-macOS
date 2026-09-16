#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import TVBox

/// 导出真实 SwiftUI 组件供人工检查，覆盖窄屏、长标题与失败提示换行。
@MainActor
final class BrowseVisualSnapshotTests: XCTestCase {
    func testRenderSavedInterfaceStartupBeforeConfigIsLoaded() throws {
        let state = AppState(savedConfiguration: ("https://example.com/config", "")) { _, _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        let host = NSHostingView(rootView: ContentView()
            .environmentObject(state)
            .environmentObject(NetworkMonitor.shared))
        host.frame = NSRect(x: 0, y: 0, width: 960, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(state.shouldShowMainInterface)
        XCTAssertFalse(state.isConfigLoaded)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Saved interface startup"
        attachment.lifetime = .keepAlways
        add(attachment)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/private/tmp/tvbox-saved-interface-startup.png"))
    }

    func testRenderGroupedCategoryNavigation() throws {
        let categories = ["喜剧片", "动作片", "爱情片", "电视剧", "综艺", "纪录片", "动画片"].map {
            MovieSort.SortData(id: $0, name: $0)
        }
        let groups = HomeCategoryGroup.groups(from: [.home()] + categories)
        let movies = try XCTUnwrap(groups.first { $0.title == "电影" })
        for width in [390.0, 820.0] {
            let content = VStack(alignment: .leading, spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(groups) { group in
                            BrowseChip(title: group.title, isSelected: group.id == movies.id)
                        }
                    }.padding(.horizontal, 16)
                }
                .frame(height: 52)
                HomeSubcategoryPicker(group: movies, selectedID: "动作片", select: { _ in })
                Text("动作片").font(.headline).foregroundStyle(.white).padding(.horizontal, 20)
            }
            .padding(.vertical, 16).frame(width: width)
            .background(AppTheme.primaryGradient).environment(\.colorScheme, .dark)
            let host = NSHostingView(rootView: content)
            host.frame = NSRect(x: 0, y: 0, width: width, height: 210)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = NSImage(size: host.bounds.size)
            image.addRepresentation(bitmap)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Grouped categories \(Int(width))"
            attachment.lifetime = .keepAlways
            add(attachment)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/private/tmp/tvbox-category-groups-\(Int(width)).png"))
        }
    }

    func testRenderRecommendationSections() throws {
        for width in [390.0, 820.0] {
            let videos = (0..<6).map { Movie.Video(id: "\($0)", name: "山海之间 第\($0 + 1)季", note: "更新至第12集") }
            var movie = MovieSort.SortData(id: "movie", name: "电影")
            movie.filters = [.init(key: "by", name: "排序", values: [.init(n: "热门", v: "hits")])]
            let popular = HomeRecommendationSection(sort: movie, filters: ["by": "hits"], videos: videos, isLoading: false)
            let unavailable = HomeRecommendationSection(sort: .init(id: "movie", name: "电影"), filters: [:], isLoading: false, errorMessage: "暂时无法加载，请重试或切换来源")
            let content = VStack(alignment: .leading, spacing: 24) {
                Text("发现好故事").font(.title2.bold()).foregroundStyle(.white).padding(.horizontal, 20)
                HomeBrowseFilterBar(filters: [
                    .init(key: "year", name: "年份", values: [.init(n: "2024", v: "2024")]),
                    .init(key: "area", name: "国家/地区", values: [.init(n: "中国大陆", v: "中国大陆")])
                ], selections: ["year": "2024", "area": "中国大陆"], select: { _, _ in }, clear: {})
                HomeRecommendationSectionView(section: popular, more: {}, retry: {})
                HomeRecommendationSectionView(section: unavailable, more: {}, retry: {})
            }
            .padding(.vertical, 20)
            .frame(width: width)
            .background(AppTheme.primaryGradient)
            .environment(\.colorScheme, .dark)
            // ImageRenderer 不会实例化屏外的惰性卡片，挂载真实视图后再截图。
            let host = NSHostingView(rootView: NavigationStack {
                ScrollView { content }.background(AppTheme.primaryGradient)
            })
            host.frame = NSRect(x: 0, y: 0, width: width, height: 600)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = NSImage(size: host.bounds.size)
            image.addRepresentation(bitmap)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Recommendations \(Int(width))"
            attachment.lifetime = .keepAlways
            add(attachment)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/private/tmp/tvbox-recommendations-\(Int(width)).png"))
        }
    }

    func testRenderCompactAndWideBrowseComponents() throws {
        for width in [390.0, 820.0] {
            let video = Movie.Video(id: "preview", name: "漫长的旅途：一部有较长标题的电视剧 第二季", note: "夸克网盘", sourceKey: "preview")
            let info = VodInfo.from(video: video, playFrom: "线路一", playUrl: "第1集$https://example.com/preview.mp4")
            let content = VStack(alignment: .leading, spacing: 18) {
                Text("发现好故事").font(.title.bold()).foregroundStyle(.white)
                HStack(spacing: 8) {
                    BrowseChip(title: "推荐")
                    BrowseChip(title: "电视剧", isSelected: true)
                    BrowseChip(title: "电影")
                }
                HStack(spacing: 8) {
                    BrowseChip(title: "年份 · 2024", icon: "line.3.horizontal.decrease", isSelected: true)
                    BrowseChip(title: "地区 · 全部")
                }
                HStack(alignment: .top, spacing: 16) {
                    VodCardView(video: Movie.Video(id: "one", name: video.name, note: "3 个资源"))
                    VodCardView(video: Movie.Video(id: "two", name: "山海之间", note: "更新至第12集"))
                    if width > 500 {
                        VodCardView(video: Movie.Video(id: "three", name: "城市漫游", note: "完结"))
                    }
                }
                Text("选择资源").font(.title2.bold()).foregroundStyle(.white)
                HStack(spacing: 8) {
                    BrowseChip(title: "全部", icon: "square.grid.2x2", isSelected: true)
                    BrowseChip(title: "在线影视", icon: "play.rectangle")
                    BrowseChip(title: "网盘分享", icon: "externaldrive")
                }
                ResourceRowView(video: video, sourceName: "在线来源", state: .ready(info, checkedAt: Date(), playback: .verified(flag: "线路一", episode: "第1集")))
                ResourceRowView(video: video, sourceName: "网盘聚合", state: .ready(info, checkedAt: Date(), playback: .needsPlayback("目录有效，需要登录或播放器解析后确认")))
                ResourceRowView(video: video, sourceName: "备用资源", state: .failed("连接超时，请重试或选择其他来源；不会因此判定分享已过期。"))
            }
            .padding(20)
            .frame(width: width)
            .background(AppTheme.primaryGradient)
            .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            let attachment = XCTAttachment(image: image)
            attachment.name = width < 500 ? "Browse compact" : "Browse wide"
            attachment.lifetime = .keepAlways
            add(attachment)
            let data = try XCTUnwrap(image.tiffRepresentation)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let name = width < 500 ? "compact" : "wide"
            try png.write(to: URL(fileURLWithPath: "/private/tmp/tvbox-browse-\(name).png"))
        }
    }
}
#endif
