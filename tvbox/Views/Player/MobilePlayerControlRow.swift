#if os(iOS)
import SwiftUI

/// 手机将跳转操作收进菜单，平板宽窗口直接显示；所有按钮至少 44 点。
struct MobilePlayerControlRow<Rate: View, Subtitles: View>: View {
    let availableWidth: CGFloat
    let isPlaying: Bool
    let seekStep: Double
    let canPlayNext: Bool
    let onSeek: (Double) -> Void
    let onTogglePlayback: () -> Void
    var onPlayNext: (() -> Void)?
    var onToggleFullScreen: (() -> Void)?
    @ViewBuilder let rate: () -> Rate
    @ViewBuilder let subtitles: () -> Subtitles

    var body: some View {
        HStack(spacing: 0) {
            rate().frame(minWidth: 44, minHeight: 44)
            subtitles().frame(minWidth: 44, minHeight: 44)
            Spacer(minLength: 0)
            if availableWidth >= 480 {
                seekButton(forward: false)
            }
            Button(action: onTogglePlayback) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .bold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(isPlaying ? "暂停" : "播放")
            if availableWidth >= 480 {
                seekButton(forward: true)
                if let onPlayNext {
                    Button(action: onPlayNext) {
                        Image(systemName: "forward.end.fill").frame(width: 44, height: 44)
                    }
                    .disabled(!canPlayNext)
                    .accessibilityLabel("下一集")
                }
            } else {
                Menu {
                    Button("后退 \(Int(seekStep)) 秒", systemImage: "gobackward") { onSeek(-seekStep) }
                    Button("前进 \(Int(seekStep)) 秒", systemImage: "goforward") { onSeek(seekStep) }
                    if let onPlayNext {
                        Button("下一集", systemImage: "forward.end.fill", action: onPlayNext)
                            .disabled(!canPlayNext)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
                }
                .accessibilityLabel("播放操作")
            }
            Spacer(minLength: 0)
            if let onToggleFullScreen {
                Button(action: onToggleFullScreen) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("切换全屏")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func seekButton(forward: Bool) -> some View {
        Button { onSeek(forward ? seekStep : -seekStep) } label: {
            Image(systemName: forward ? "goforward" : "gobackward")
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("\(forward ? "前进" : "后退") \(Int(seekStep)) 秒")
    }
}
#endif
