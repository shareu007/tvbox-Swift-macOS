#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import TVBox

@MainActor
final class SubtitleControlsSnapshotTests: XCTestCase {
    func testRenderSystemAndVLCSubtitleControls() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "subtitles", withExtension: "mp4"))
        try snapshot(AVPlayerContentView(urlString: url.absoluteString,
                                        onToggleFullScreen: {}, canPlayNext: true, onPlayNext: {}), name: "system")
        #if canImport(Libmpv)
        try snapshot(MPVPlayerView(urlString: url.absoluteString,
                                  onToggleFullScreen: {}, canPlayNext: true, onPlayNext: {}), name: "mpv")
        #endif
        #if canImport(VLCKitSPM)
        try snapshot(VLCVodPlayerView(urlString: url.absoluteString,
                                     onToggleFullScreen: {}, canPlayNext: true, onPlayNext: {}), name: "vlc")
        #endif
    }

    private func snapshot<V: View>(_ view: V, name: String) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.frame = NSRect(x: 0, y: 0, width: 960, height: 540)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = "\(name) subtitle controls"
        attachment.lifetime = .keepAlways
        add(attachment)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/private/tmp/tvbox-subtitle-\(name).png"))
    }
}
#endif
