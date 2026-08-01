#if os(macOS)
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
}
#endif
