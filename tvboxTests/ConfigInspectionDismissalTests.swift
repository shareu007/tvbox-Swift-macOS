import XCTest
@testable import TVBox

@MainActor
final class ConfigInspectionDismissalTests: XCTestCase {
    private func result() -> VodConfigInspectionResult {
        .init(configurationProtocol: "TVBox JSON", sourceProtocols: ["JSON", "JAR"],
              compatibility: .partial, supportedSourceCount: 1, totalSourceCount: 2)
    }

    func testCompletingInspectionClearsResultBeforeInputCloses() {
        let model = SettingsViewModel()
        model.configInspectionResult = result()
        var inputIsPresented = true
        model.dismissConfigInspection {
            XCTAssertNil(model.configInspectionResult, "Consume the result before returning to the configuration list")
            inputIsPresented = false
        }

        XCTAssertFalse(inputIsPresented)
        XCTAssertNil(model.configInspectionResult)
    }

    func testNewImportClearsPreviousReportEvenWhenInputIsInvalid() async {
        let model = SettingsViewModel()
        model.configInspectionResult = result()
        model.vodApiUrl = " "
        await model.loadConfig(presentInspection: true)
        XCTAssertNil(model.configInspectionResult)
        XCTAssertNotNil(model.configError)
        XCTAssertFalse(model.isLoadingConfig)
    }

    func testDuplicateImportDoesNotReplaceCurrentReportOrStartAnotherLoad() async {
        let model = SettingsViewModel()
        let inspection = result()
        model.configInspectionResult = inspection
        model.isLoadingConfig = true
        model.vodApiUrl = " "
        await model.loadConfig(presentInspection: true)
        XCTAssertEqual(model.configInspectionResult?.id, inspection.id)
        XCTAssertTrue(model.isLoadingConfig)
    }

    func testRepeatedImportsEachConsumeTheirOwnResultExactlyOnce() {
        let model = SettingsViewModel()
        for _ in 0..<3 {
            let inspection = result()
            model.configInspectionResult = inspection
            XCTAssertEqual(model.configInspectionResult?.id, inspection.id)
            model.dismissConfigInspection()
            XCTAssertNil(model.configInspectionResult)
        }
        model.dismissConfigInspection()
        XCTAssertNil(model.configInspectionResult)
    }
}
