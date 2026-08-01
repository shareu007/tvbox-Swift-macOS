# Repository Guidelines

## Project Structure & Module Organization

This is a SwiftUI multimedia app managed with XcodeGen. Main application code lives in `tvbox/`, organized by role: `Models/`, `ViewModels/`, `Views/`, `Services/`, `Persistence/`, and `Utils/`. Assets and app icons are in `tvbox/Assets.xcassets`, with app metadata in `tvbox/Info.plist` and macOS entitlements in `tvbox/tvbox-macOS.entitlements`.

Tests are split between `tvbox-Tests/` and `tvboxTests/`; keep new tests near related existing test files. `project.yml` is the source of truth for targets, dependencies, signing settings, and generated Xcode project structure.

## Build, Test, and Development Commands

- `xcodegen generate`: regenerates `tvbox.xcodeproj` from `project.yml`.
- `open tvbox.xcodeproj`: opens the generated project in Xcode for local development.
- `xcodebuild -project tvbox.xcodeproj -scheme tvbox -configuration Debug build`: builds the iOS app target.
- `xcodebuild -project tvbox.xcodeproj -scheme tvbox-macOS -configuration Debug build`: builds the macOS target.
- `xcodebuild test -project tvbox.xcodeproj -scheme tvbox -destination 'platform=iOS Simulator,name=iPhone 15'`: runs iOS unit tests on a simulator.
- `./package_ios.sh` and `./package_mac.sh`: create release archives/packages; iOS packaging uses Xcode automatic signing configured only in ignored files under `Config/Local/`.

## Coding Style & Naming Conventions

Use Swift 5.9 and SwiftUI conventions already present in the repository. Prefer four-space indentation, `PascalCase` for types, `camelCase` for properties/functions, and descriptive suffixes such as `View`, `ViewModel`, `Service`, and `Manager`. Keep UI code in `Views/`, state and business logic in `ViewModels/`, networking/config parsing in `Services/`, and shared extensions in `Utils/`.

## Testing Guidelines

The project uses XCTest. Name test files after the behavior under test, for example `PlayerGestureLayerZoomClampingTests.swift`, and name methods with explicit expected behavior. Add focused tests for gesture handling, parsing, persistence, and view model state changes when modifying those areas. Run the relevant `xcodebuild test` command before submitting.

## Commit & Pull Request Guidelines

Recent history uses short, imperative messages such as `fix bug`, `fix network`, and `feat: ...`. Prefer clearer conventional prefixes when possible: `fix:`, `feat:`, `test:`, or `chore:` followed by a concise summary.

When a coherent change is complete and has passed the relevant available verification, create a focused commit at an appropriate checkpoint. Do not leave verified implementation work uncommitted without a reason. Keep unrelated user changes out of the commit, and clearly report any verification that could not be run before committing.

Pull requests should include the user-visible change, affected platforms (`iOS`, `macOS`, or both), test results, and screenshots or screen recordings for UI changes. Note any signing, provisioning, or configuration requirements explicitly.

## Security & Configuration Tips

Do not commit signing certificates, provisioning profiles, `IOS-key/secrets.sh`, or files under `Config/Local/`. Keep source URLs and user-provided media configuration out of tests and fixtures unless they are safe, minimal, and non-sensitive. The iOS packaging script must not import certificates into the login keychain or unlock the keychain.
