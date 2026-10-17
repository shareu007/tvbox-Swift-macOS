import SwiftUI
import XCTest
@testable import TVBox
#if os(macOS)
import AppKit
#endif

@MainActor
final class AppAppearanceTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "tvbox-appearance-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    func testNewInstallationFollowsSystemWithoutWritingAnOverride() {
        let storage = AppStorage(wrappedValue: AppAppearance.system, AppAppearance.storageKey, store: defaults)
        XCTAssertEqual(storage.wrappedValue, .system)
        XCTAssertNil(storage.wrappedValue.colorScheme)
        XCTAssertNil(defaults.object(forKey: AppAppearance.storageKey))
    }

    func testManualPreferencePersistsAndCanReturnToAutomatic() {
        let storage = AppStorage(wrappedValue: AppAppearance.system, AppAppearance.storageKey, store: defaults)
        for mode in [AppAppearance.dark, .light, .system] {
            storage.wrappedValue = mode
            let restored = AppStorage(wrappedValue: AppAppearance.system, AppAppearance.storageKey,
                                      store: UserDefaults(suiteName: suiteName))
            XCTAssertEqual(restored.wrappedValue, mode)
            XCTAssertEqual(defaults.string(forKey: AppAppearance.storageKey), mode.rawValue)
        }
    }

    func testUnknownSavedPreferenceFallsBackToAutomatic() {
        defaults.set("unknown-mode", forKey: AppAppearance.storageKey)
        let storage = AppStorage(wrappedValue: AppAppearance.system, AppAppearance.storageKey, store: defaults)
        XCTAssertNil(storage.wrappedValue.colorScheme)
    }

    func testPaletteChangesWithAppearanceAndKeepsTextReadable() {
        for scheme in [ColorScheme.light, .dark] {
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            let text = luminance(Color.primary.resolve(in: environment))
            for name in ["ThemeBackground", "ThemeGradientStart", "ThemeGradientMiddle", "ThemeGradientEnd"] {
                let background = luminance(Color(name).resolve(in: environment))
                if scheme == .light {
                    XCTAssertGreaterThan(background, 0.7, name)
                } else {
                    XCTAssertLessThan(background, 0.05, name)
                }
                let contrast = (max(text, background) + 0.05) / (min(text, background) + 0.05)
                XCTAssertGreaterThanOrEqual(contrast, 4.5, "\(name): \(scheme)")
            }
        }
    }

    private func luminance(_ color: Color.Resolved) -> Double {
        func linear(_ component: Float) -> Double {
            let value = Double(component)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    #if os(macOS)
    func testLivePreferenceAndSystemChangesPreserveViewIdentity() async throws {
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }
        NSApp.appearance = NSAppearance(named: .aqua)
        var observed: ColorScheme?
        var identities = Set<UUID>()
        let host = NSHostingView(rootView: AppearanceProbe { scheme, identity in
            observed = scheme
            identities.insert(identity)
        }
        .modifier(AppAppearanceModifier())
        .defaultAppStorage(defaults))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await waitForScheme(.light, observed: { observed })

        defaults.set(AppAppearance.dark.rawValue, forKey: AppAppearance.storageKey)
        try await waitForScheme(.dark, observed: { observed })
        defaults.set(AppAppearance.light.rawValue, forKey: AppAppearance.storageKey)
        try await waitForScheme(.light, observed: { observed })
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(observed, .light, "Manual mode must ignore system changes")
        defaults.set(AppAppearance.system.rawValue, forKey: AppAppearance.storageKey)
        try await waitForScheme(.dark, observed: { observed })
        NSApp.appearance = NSAppearance(named: .aqua)
        try await waitForScheme(.light, observed: { observed })
        XCTAssertEqual(identities.count, 1, "Appearance must preserve existing view state")
    }

    private func waitForScheme(_ expected: ColorScheme, observed: () -> ColorScheme?, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
            if observed() == expected { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(observed(), expected, file: file, line: line)
    }
    #endif
}

#if os(macOS)
private struct AppearanceProbe: View {
    @Environment(\.colorScheme) private var scheme
    @State private var identity = UUID()
    let changed: (ColorScheme, UUID) -> Void

    var body: some View {
        Text("Appearance")
            .onAppear { changed(scheme, identity) }
            .onChange(of: scheme) { _, newValue in changed(newValue, identity) }
    }
}
#endif
