import SwiftUI

/// 使用当前窗口的可用宽度，支持 iPad 分屏及窗口缩放。
enum AdaptiveMediaLayout {
    static func usesPlaybackColumns(width: CGFloat) -> Bool {
        width >= 900
    }

    static func channelPanelWidth(availableWidth: CGFloat) -> CGFloat {
        min(max(availableWidth - 24, 0), 640)
    }
}

/// 海报在 iPad 常规宽度下放大，紧凑窗口恢复手机的信息密度。
struct PosterGridMetrics {
    #if os(iOS)
    var isRegularWidth: Bool

    var columns: [GridItem] {
        [GridItem(.adaptive(minimum: isRegularWidth ? 150 : 100,
                            maximum: isRegularWidth ? 210 : 160), spacing: spacing)]
    }

    var spacing: CGFloat { isRegularWidth ? 18 : 12 }
    var shelfPosterWidth: CGFloat { isRegularWidth ? 164 : 136 }
    #else
    var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 16)]
    }

    var spacing: CGFloat { 16 }
    var shelfPosterWidth: CGFloat { 164 }
    #endif
}

/// 在布局变化时保持内容身份，避免旋转或分屏重建播放会话。
struct AdaptivePlaybackLayout<Playback: View, Episodes: View>: View {
    let availableWidth: CGFloat
    let isPlaying: Bool
    var allowsColumns = true
    @ViewBuilder let playback: () -> Playback
    @ViewBuilder let episodes: () -> Episodes

    private var usesColumns: Bool {
        allowsColumns && isPlaying && AdaptiveMediaLayout.usesPlaybackColumns(width: availableWidth)
    }

    var body: some View {
        let layout = usesColumns
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 0))
            : AnyLayout(VStackLayout(spacing: 0))
        layout {
            playback().frame(maxWidth: .infinity)
            episodes()
                .frame(width: usesColumns ? min(360, availableWidth * 0.36) : nil)
        }
    }
}
