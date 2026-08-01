import XCTest
@testable import TVBox

@MainActor
final class ImageLoaderTests: XCTestCase {
    func testDiskCacheLivesInsideTheUserCachesDirectory() throws {
        let fileManager = FileManager.default
        let cachesDirectory = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ).standardizedFileURL
        let imageCacheDirectory = try ImageLoader.imageCacheDirectory(
            fileManager: fileManager
        ).standardizedFileURL

        XCTAssertTrue(
            imageCacheDirectory.path.hasPrefix(cachesDirectory.path + "/"),
            "Image cache must stay inside the user's caches directory"
        )
        XCTAssertNotEqual(imageCacheDirectory.path, "/image_cache")
    }

    func testImagePayloadLimitRejectsOversizedResponses() {
        XCTAssertNoThrow(
            try ImageLoader.validateImagePayload(
                expectedContentLength: Int64(ImageLoader.maximumImagePayloadBytes),
                actualByteCount: ImageLoader.maximumImagePayloadBytes
            )
        )
        XCTAssertThrowsError(
            try ImageLoader.validateImagePayload(
                expectedContentLength: Int64(ImageLoader.maximumImagePayloadBytes + 1),
                actualByteCount: 0
            )
        )
        XCTAssertThrowsError(
            try ImageLoader.validateImagePayload(
                expectedContentLength: -1,
                actualByteCount: ImageLoader.maximumImagePayloadBytes + 1
            )
        )
    }

    func testImageLoaderRejectsNonHTTPURLs() async {
        let loader = ImageLoader(configuration: .ephemeral)
        do {
            _ = try await loader.load(url: URL(fileURLWithPath: "/etc/passwd"))
            XCTFail("Expected invalid URL")
        } catch ImageLoadError.invalidURL {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPosterURLDoesNotSendSignedImageURLThroughThirdPartyProxy() throws {
        let signed = try XCTUnwrap(
            URL.posterURL(from: "https://img.picbf.com/poster.jpg?token=private")
        )
        let publicURL = try XCTUnwrap(
            URL.posterURL(from: "https://img.picbf.com/poster.jpg")
        )

        XCTAssertEqual(signed.host, "img.picbf.com")
        XCTAssertEqual(publicURL.host, "images.weserv.nl")
        XCTAssertNil(URL.posterURL(from: "file:///etc/passwd"))
    }
}
