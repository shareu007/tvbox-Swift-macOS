import XCTest
@testable import TVBox

@MainActor
final class AppStartupRoutingTests: XCTestCase {
    func testSavedInterfaceShowsHomeBeforeAnyNetworkRequestCompletes() {
        let state = AppState(savedConfiguration: ("https://example.com/config.json", ""))
        XCTAssertFalse(state.isConfigLoaded)
        XCTAssertTrue(state.shouldShowMainInterface, "A saved interface must show the home shell on the first frame")
    }

    func testFirstLaunchStillShowsInterfaceSetup() {
        let state = AppState(savedConfiguration: (" \n", "https://example.com/live.m3u"))
        XCTAssertFalse(state.shouldShowMainInterface)
    }
    func testRestorationKeepsMainInterfaceVisibleAndCoalescesRepeatedAppearance() async {
        let started = expectation(description: "Restore started")
        var finish: CheckedContinuation<Void, Never>?
        var calls = 0
        let state = AppState(savedConfiguration: (" https://example.com/config.json ", "")) { vod, live in
            calls += 1
            XCTAssertEqual(vod, "https://example.com/config.json")
            XCTAssertEqual(live, vod)
            await withCheckedContinuation { finish = $0; started.fulfill() }
        }
        let restore = Task { await state.restoreSavedConfigurationIfNeeded() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(state.shouldShowMainInterface)
        XCTAssertTrue(state.isLoadingConfig)
        XCTAssertFalse(state.isConfigLoaded)
        await state.restoreSavedConfigurationIfNeeded()
        await state.retryConfig()
        XCTAssertEqual(calls, 1)
        finish?.resume()
        await restore.value
        XCTAssertTrue(state.isConfigLoaded)
        XCTAssertFalse(state.isLoadingConfig)
        await state.restoreSavedConfigurationIfNeeded()
        XCTAssertEqual(calls, 1)
    }

    func testFailureStaysOnHomeAndExplicitRetryUsesSavedLiveInterface() async {
        var calls = 0
        let state = AppState(savedConfiguration: ("https://example.com/vod", " https://example.com/live ")) { vod, live in
            XCTAssertEqual(vod, "https://example.com/vod")
            XCTAssertEqual(live, "https://example.com/live")
            calls += 1
            if calls == 1 { throw URLError(.notConnectedToInternet) }
        }
        await state.restoreSavedConfigurationIfNeeded()
        XCTAssertTrue(state.shouldShowMainInterface)
        XCTAssertFalse(state.isConfigLoaded)
        XCTAssertNotNil(state.configLoadError)
        XCTAssertFalse(state.isLoadingConfig)
        await state.restoreSavedConfigurationIfNeeded()
        XCTAssertEqual(calls, 1, "Appearance must not loop on failed restoration")
        await state.retryConfig()
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(state.isConfigLoaded)
        XCTAssertNil(state.configLoadError)
        XCTAssertFalse(state.isRetryingConfig)
    }

    func testNoSavedVodInterfaceDoesNotStartAutomaticLoading() async {
        var calls = 0
        let state = AppState(savedConfiguration: (" ", "https://example.com/live")) { _, _ in calls += 1 }
        await state.restoreSavedConfigurationIfNeeded()
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(state.shouldShowMainInterface)
        state.applyLoadedConfigState()
        XCTAssertTrue(state.shouldShowMainInterface, "Completing first-time setup enters the app")
    }

    func testCancelledRestorationCanResumeOnNextAppearance() async {
        let started = expectation(description: "Restore started")
        var finish: CheckedContinuation<Void, Never>?
        var calls = 0
        let state = AppState(savedConfiguration: ("https://example.com/config", "")) { _, _ in
            calls += 1
            if calls == 1 {
                await withCheckedContinuation { finish = $0; started.fulfill() }
            }
        }
        let restore = Task { await state.restoreSavedConfigurationIfNeeded() }
        await fulfillment(of: [started], timeout: 2)
        restore.cancel()
        finish?.resume()
        await restore.value
        XCTAssertTrue(state.shouldShowMainInterface)
        XCTAssertFalse(state.isConfigLoaded)
        XCTAssertFalse(state.isLoadingConfig)
        XCTAssertNil(state.configLoadError)
        await state.restoreSavedConfigurationIfNeeded()
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(state.isConfigLoaded)
    }

    func testLateRestorationFailureCannotOverrideConfigurationAppliedFromSettings() async {
        let started = expectation(description: "Restore started")
        var finish: CheckedContinuation<Void, Never>?
        let state = AppState(savedConfiguration: ("https://example.com/config", "")) { _, _ in
            await withCheckedContinuation { finish = $0; started.fulfill() }
            throw URLError(.timedOut)
        }
        let restore = Task { await state.restoreSavedConfigurationIfNeeded() }
        await fulfillment(of: [started], timeout: 2)
        state.applyLoadedConfigState()
        finish?.resume()
        await restore.value
        XCTAssertTrue(state.isConfigLoaded)
        XCTAssertFalse(state.isLoadingConfig)
        XCTAssertNil(state.configLoadError)
    }

}
