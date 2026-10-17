import SwiftUI
#if os(macOS)
import AppKit
#endif

/// 只在窗口根视图应用偏好，切换主题不会重建导航或播放器状态。
struct AppAppearanceModifier: ViewModifier {
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system

    func body(content: Content) -> some View {
        #if os(macOS)
        // preferredColorScheme 从手动模式切回 nil 时可能保留旧的窗口外观。
        // 显式清除窗口偏好，让后续系统外观变化继续传入 SwiftUI。
        content.background(WindowAppearanceView(mode: appearance))
        #else
        content.preferredColorScheme(appearance.colorScheme)
        #endif
    }
}

#if os(macOS)
private struct WindowAppearanceView: NSViewRepresentable {
    let mode: AppAppearance

    func makeNSView(context: Context) -> AppearanceView {
        let view = AppearanceView()
        view.mode = mode
        return view
    }

    func updateNSView(_ nsView: AppearanceView, context: Context) {
        nsView.mode = mode
        nsView.applyAppearance()
    }

    final class AppearanceView: NSView {
        var mode: AppAppearance = .system

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyAppearance()
        }

        func applyAppearance() {
            switch mode {
            case .system: window?.appearance = nil
            case .light: window?.appearance = NSAppearance(named: .aqua)
            case .dark: window?.appearance = NSAppearance(named: .darkAqua)
            }
        }
    }
}
#endif
