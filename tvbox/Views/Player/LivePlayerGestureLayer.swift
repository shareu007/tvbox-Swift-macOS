#if os(iOS)
import SwiftUI

// MARK: - LivePlayerGestureLayer

/// 直播播放器手势交互层 - 专为直播场景设计
/// 直播不需要快进快退，仅支持：
/// - 单击：显示/隐藏控制层
/// - 双击：暂停/播放
/// - 右侧垂直滑动：调节音量
/// - 左侧垂直滑动：调节亮度
struct LivePlayerGestureLayer: View {
    // MARK: - Callbacks
    let onTogglePlayPause: () -> Void
    let onToggleControls: () -> Void
    let onVolumeChanged: (CGFloat) -> Void

    // MARK: - State
    @State private var gestureMode: LiveGestureMode = .none
    @State private var showIndicator = false
    @State private var dragStartX: CGFloat = 0
    @State private var accumulatedBrightnessDelta: CGFloat = 0
    @State private var accumulatedVolumeDelta: CGFloat = 0

    enum LiveGestureMode: Equatable {
        case none
        case adjustingBrightness(delta: CGFloat)
        case adjustingVolume(delta: CGFloat)
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(Rectangle())
                .gesture(dragGesture(in: geometry))
                .onTapGesture(count: 2) {
                    HapticManager.shared.lightImpact()
                    onTogglePlayPause()
                }
                .onTapGesture(count: 1) {
                    onToggleControls()
                }
                .overlay { gestureIndicatorOverlay }
        }
    }

    // MARK: - Drag Gesture

    private func dragGesture(in geometry: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 15)
            .onChanged { value in
                if gestureMode == .none {
                    dragStartX = value.startLocation.x
                    HapticManager.shared.lightImpact()
                }

                let absV = abs(value.translation.height)
                guard absV > 15 else { return }

                let isLeftHalf = dragStartX < geometry.size.width / 2
                let delta = -value.translation.height / 300.0

                if isLeftHalf {
                    gestureMode = .adjustingBrightness(delta: delta)
                    // Apply brightness directly
                    let newBrightness = max(0, min(1, UIScreen.main.brightness + (delta - accumulatedBrightnessDelta)))
                    UIScreen.main.brightness = newBrightness
                    accumulatedBrightnessDelta = delta
                } else {
                    gestureMode = .adjustingVolume(delta: delta)
                    let volumeDelta = delta - accumulatedVolumeDelta
                    onVolumeChanged(volumeDelta)
                    accumulatedVolumeDelta = delta
                }

                withAnimation(.easeInOut(duration: 0.2)) {
                    showIndicator = true
                }
            }
            .onEnded { _ in
                gestureMode = .none
                accumulatedBrightnessDelta = 0
                accumulatedVolumeDelta = 0
                withAnimation(.easeInOut(duration: 0.2)) {
                    showIndicator = false
                }
            }
    }

    // MARK: - Gesture Indicator Overlay

    @ViewBuilder
    private var gestureIndicatorOverlay: some View {
        if showIndicator {
            VStack(spacing: 8) {
                indicatorIcon
                indicatorText
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .opacity(showIndicator ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: showIndicator)
        }
    }

    @ViewBuilder
    private var indicatorIcon: some View {
        switch gestureMode {
        case .adjustingBrightness:
            Image(systemName: "sun.max.fill")
                .font(.title2)
                .foregroundColor(.yellow)
        case .adjustingVolume:
            Image(systemName: "speaker.wave.2.fill")
                .font(.title2)
                .foregroundColor(.white)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var indicatorText: some View {
        switch gestureMode {
        case .adjustingBrightness:
            let percentage = Int(UIScreen.main.brightness * 100)
            Text("\(percentage)%")
                .font(.caption)
                .foregroundColor(.white)
        case .adjustingVolume:
            Text("音量")
                .font(.caption)
                .foregroundColor(.white)
        case .none:
            EmptyView()
        }
    }
}
#endif
