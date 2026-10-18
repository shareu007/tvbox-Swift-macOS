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

    func testWindowGroupRepeatedPickerChangesAndReturnToSystem() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let output = repository.appendingPathComponent("build/DerivedData/Verification/AppearanceSceneProbe.app/Contents")
        let executable = output.appendingPathComponent("MacOS/AppearanceSceneProbe")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.tvbox.appearance-scene-probe",
            "CFBundleExecutable": "AppearanceSceneProbe",
            "CFBundleName": "AppearanceSceneProbe",
            "CFBundlePackageType": "APPL",
            "LSUIElement": true,
            "NSHighResolutionCapable": true
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: output.appendingPathComponent("Info.plist"))
        #if arch(arm64)
        let target = "arm64-apple-macos14.0"
        #else
        let target = "x86_64-apple-macos14.0"
        #endif
        let sources = ["tvbox/Models/AppAppearance.swift", "tvbox/Utils/AppAppearanceModifier.swift",
                       "tvbox/Views/Settings/AppearanceSettingsView.swift", "tvboxTests/Fixtures/AppearanceSceneProbe.swift"]
        let arguments = ["swiftc", "-parse-as-library", "-swift-version", "5", "-target", target,
                         "-D", "APPEARANCE_SCENE_PROBE", "-module-cache-path",
                         repository.appendingPathComponent("build/DerivedData/ModuleCache.noindex/AppearanceProbe").path]
            + sources.map { repository.appendingPathComponent($0).path } + ["-o", executable.path]
        let compileLog = repository.appendingPathComponent("build/DerivedData/Logs/appearance-scene-test-compile.log")
        try FileManager.default.createDirectory(at: compileLog.deletingLastPathComponent(), withIntermediateDirectories: true)
        let compileStatus = try await runProbeProcess(URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: arguments, log: compileLog)
        guard compileStatus == 0 else {
            let output = try String(contentsOf: compileLog, encoding: .utf8)
            return XCTFail(output)
        }
        let runLog = repository.appendingPathComponent("build/DerivedData/Logs/appearance-scene-test-run.log")
        let status = try await runProbeProcess(executable, arguments: [], log: runLog)
        let runOutput = try String(contentsOf: runLog, encoding: .utf8)
        XCTAssertEqual(status, 0, runOutput)
    }

    private func runProbeProcess(_ executable: URL, arguments: [String], log: URL) async throws -> Int32 {
        try Data().write(to: log)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // 子进程运行自己的 WindowGroup，不继承 XCTest 对测试宿主的注入。
        process.environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("XCTest") && !$0.key.hasPrefix("XCInject") && $0.key != "DYLD_INSERT_LIBRARIES"
        }
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        guard !process.isRunning else {
            XCTFail("Appearance scene probe timed out")
            return -1
        }
        return process.terminationStatus
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
