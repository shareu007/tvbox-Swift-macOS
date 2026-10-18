// 由 AppAppearanceTests 单独编译为真实 SwiftUI App，捕捉普通 NSHostingView 测不出的场景外观问题。
#if os(macOS) && APPEARANCE_SCENE_PROBE
import AppKit
import SwiftUI
import Darwin

@MainActor
final class SceneDriver {
    let suiteName = "tvbox-scene-probe-\(UUID().uuidString)"
    lazy var defaults = UserDefaults(suiteName: suiteName)!
    var scheme: ColorScheme?
    var started = false

    func control(in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl { return control }
        return view.subviews.lazy.compactMap { self.control(in: $0) }.first
    }

    func run() async {
        guard !started else { return }
        started = true
        for _ in 0..<100 {
            if NSApp.windows.contains(where: { $0.contentView.flatMap { control(in: $0) } != nil }) { break }
            try? await Task.sleep(for: .milliseconds(30))
        }
        let modes = Array(repeating: [AppAppearance.dark, .light, .dark, .system, .light, .dark, .system], count: 3).flatMap { $0 }
        for (step, mode) in modes.enumerated() {
            guard let window = NSApp.windows.first(where: { $0.contentView.flatMap { control(in: $0) } != nil }),
                  let root = window.contentView, let picker = control(in: root),
                  let index = AppAppearance.allCases.firstIndex(of: mode) else { finish(2); return }
            picker.selectedSegment = index
            _ = picker.sendAction(picker.action, to: picker.target)
            try? await Task.sleep(for: .milliseconds(400))
            let expected = mode.colorScheme ?? .light
            print("step=\(step) requested=\(mode.rawValue) stored=\(defaults.string(forKey: AppAppearance.storageKey) ?? "nil") window=\(window.effectiveAppearance.name.rawValue) content=\(String(describing: scheme)) expected=\(expected)")
            if scheme != expected || defaults.string(forKey: AppAppearance.storageKey) != mode.rawValue { finish(1); return }
        }
        // 自动模式还必须继续响应后续系统外观变化。
        for (name, expected) in [(NSAppearance.Name.darkAqua, ColorScheme.dark), (.aqua, .light)] {
            NSApp.appearance = NSAppearance(named: name)
            try? await Task.sleep(for: .milliseconds(400))
            guard scheme == expected else { finish(1); return }
        }
        finish(0)
    }

    func finish(_ status: Int32) {
        defaults.removePersistentDomain(forName: suiteName)
        fflush(stdout)
        exit(status)
    }
}

private struct SchemeProbe: View {
    @Environment(\.colorScheme) private var scheme
    let driver: SceneDriver
    var body: some View {
        Text("Appearance probe")
            .onAppear { driver.scheme = scheme }
            .onChange(of: scheme) { _, value in driver.scheme = value }
    }
}

@main
struct AppearanceSceneProbe: App {
    private let driver = SceneDriver()
    init() { NSApplication.shared.appearance = NSAppearance(named: .aqua) }
    var body: some Scene {
        WindowGroup {
            NavigationSplitView { Text("TVBox") } detail: {
                NavigationStack {
                    VStack {
                        AppearanceSettingsView()
                        SchemeProbe(driver: driver)
                    }
                }
            }
            .modifier(AppAppearanceModifier())
            .defaultAppStorage(driver.defaults)
            .task { await driver.run() }
        }
    }
}

#endif
