import XCTest
@testable import TVBox

@MainActor
final class SavedConfigSwitchTests: XCTestCase {
    private class Loader: SettingsViewModel {
        var requests: [(String, String, Bool)] = []
        var succeeds = true
        override func loadConfig(presentInspection: Bool = false) async {
            requests.append((vodApiUrl, liveApiUrl, presentInspection))
            configSuccess = succeeds
            pendingMultiRepoSelection = nil
        }
    }

    private var target: SavedVodConfig {
        .init(name: "Fixture", url: "https://example.com/new.json",
              configurationProtocol: "TVBox JSON", compatibility: .compatible)
    }

    func testSavedConfigSwitchLoadsTargetWithoutAlertOnHiddenSettingsPage() async {
        let model = Loader()
        model.vodApiUrl = "https://example.com/old.json"
        model.liveApiUrl = "https://example.com/live"
        await model.loadSavedVodConfig(target)
        XCTAssertEqual(model.requests.count, 1)
        XCTAssertEqual(model.requests.first?.0, target.url)
        XCTAssertEqual(model.requests.first?.1, "")
        XCTAssertEqual(model.requests.first?.2, false)
        XCTAssertEqual(model.vodApiUrl, target.url)
        XCTAssertTrue(model.configSuccess)
    }

    func testFailedSwitchRestoresPreviousConfiguration() async {
        let model = Loader()
        model.succeeds = false
        model.vodApiUrl = "https://example.com/old.json"
        model.liveApiUrl = "https://example.com/live"
        await model.loadSavedVodConfig(target)
        XCTAssertEqual(model.vodApiUrl, "https://example.com/old.json")
        XCTAssertEqual(model.liveApiUrl, "https://example.com/live")
        XCTAssertFalse(model.configSuccess)
    }

    func testClickWhileLoadingDoesNotReplaceInFlightConfiguration() async {
        let model = Loader()
        model.vodApiUrl = "https://example.com/loading.json"
        model.isLoadingConfig = true
        await model.loadSavedVodConfig(target)
        XCTAssertTrue(model.requests.isEmpty)
        XCTAssertEqual(model.vodApiUrl, "https://example.com/loading.json")
    }
}
