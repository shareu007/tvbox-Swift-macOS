import SwiftUI
#if os(macOS)
import AppKit
#endif

/// 只在窗口根视图应用偏好，切换主题不会重建导航或播放器状态。
struct AppAppearanceModifier: ViewModifier {
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system
    #if os(macOS)
    @StateObject private var systemAppearance = SystemAppearanceObserver()
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        // WindowGroup 切回 nil 时可能保留旧的 SwiftUI 外观环境。
        // 始终提交明确的场景偏好；自动模式由 AppKit 的系统外观变化驱动。
        content.preferredColorScheme(appearance.colorScheme ?? systemAppearance.colorScheme)
        #else
        content.preferredColorScheme(appearance.colorScheme)
        #endif
    }
}

#if os(macOS)
@MainActor
private final class SystemAppearanceObserver: ObservableObject {
    @Published private(set) var colorScheme: ColorScheme
    private var observation: NSKeyValueObservation?

    init() {
        let application = NSApplication.shared
        colorScheme = Self.colorScheme(for: application.effectiveAppearance)
        // 观察应用继承的系统外观，避免把窗口自己的手动偏好当作系统值。
        observation = application.observe(\.effectiveAppearance, options: [.new]) { [weak self] application, _ in
            let colorScheme = Self.colorScheme(for: application.effectiveAppearance)
            Task { @MainActor [weak self] in
                self?.colorScheme = colorScheme
            }
        }
    }

    private nonisolated static func colorScheme(for appearance: NSAppearance) -> ColorScheme {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
}
#endif
