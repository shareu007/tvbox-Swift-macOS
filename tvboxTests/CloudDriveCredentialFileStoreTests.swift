import XCTest
@testable import TVBox

final class CloudDriveCredentialFileStoreTests: XCTestCase {
    private var testDirectory: URL!
    private var store: CloudDriveCredentialFileStore!

    override func setUpWithError() throws {
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tvbox-cloud-credentials-\(UUID().uuidString)", isDirectory: true)
        store = CloudDriveCredentialFileStore(
            fileURL: testDirectory.appendingPathComponent("private/credentials.json")
        )
    }

    override func tearDownWithError() throws {
        if let testDirectory {
            try? FileManager.default.removeItem(at: testDirectory)
        }
    }

    func testSavesUpdatesAndClearsCredentials() throws {
        try store.save(" cookie-value ", forKey: "quark-cookie")
        try store.save("token-value", forKey: "ali-refresh-token")

        XCTAssertEqual(store.values()["quark-cookie"], "cookie-value")
        XCTAssertEqual(store.values()["ali-refresh-token"], "token-value")

        try store.save("  ", forKey: "quark-cookie")

        XCTAssertNil(store.values()["quark-cookie"])
        XCTAssertEqual(store.values()["ali-refresh-token"], "token-value")
    }

    func testUsesOwnerOnlyDirectoryAndFilePermissions() throws {
        try store.save("secret", forKey: "quark-cookie")

        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: store.fileURL.deletingLastPathComponent().path
        )
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)

        XCTAssertEqual(directoryAttributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o700))
        XCTAssertEqual(fileAttributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
    }

    func testRejectsOversizedCredentialBeforeSaving() {
        let oversized = String(
            repeating: "x",
            count: CloudDriveCredentialStore.maximumCredentialBytes + 1
        )

        XCTAssertThrowsError(
            try CloudDriveCredentialStore.save(oversized, for: .quarkCookie)
        ) { error in
            guard case CloudDriveCredentialError.tooLarge(let maximumBytes) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(maximumBytes, CloudDriveCredentialStore.maximumCredentialBytes)
        }
    }

    func testSavesBothFieldsTogetherAndKeepsValuesAcrossReopening() throws {
        try store.save(["quark-cookie": " cookie-value ", "ali-refresh-token": " token-value "])
        let reopened = CloudDriveCredentialFileStore(fileURL: store.fileURL)
        XCTAssertEqual(reopened.values(), ["quark-cookie": "cookie-value", "ali-refresh-token": "token-value"])
        try reopened.save(["quark-cookie": "", "ali-refresh-token": "updated-token"])
        XCTAssertEqual(store.values(), ["ali-refresh-token": "updated-token"])
    }

    func testInvalidFormDoesNotPartiallyReplaceSavedCredentials() throws {
        try store.save(["quark-cookie": "previous-cookie", "ali-refresh-token": "previous-token"])
        let original = try Data(contentsOf: store.fileURL)
        XCTAssertThrowsError(try store.save([
            "quark-cookie": "new-cookie",
            "ali-refresh-token": String(repeating: "x", count: CloudDriveCredentialStore.maximumCredentialBytes + 1)
        ]))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
    }
}
