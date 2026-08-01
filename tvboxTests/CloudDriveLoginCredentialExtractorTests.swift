#if os(macOS)
import XCTest
@testable import TVBox

final class CloudDriveLoginCredentialExtractorTests: XCTestCase {
    func testQuarkCookieRequiresLoginMarkerAndIncludesAllQuarkCookies() throws {
        let cookies = [
            try XCTUnwrap(HTTPCookie(properties: [
                .domain: ".quark.cn", .path: "/", .name: "__puus", .value: "login-value"
            ])),
            try XCTUnwrap(HTTPCookie(properties: [
                .domain: "pan.quark.cn", .path: "/", .name: "other", .value: "other-value"
            ])),
            try XCTUnwrap(HTTPCookie(properties: [
                .domain: ".example.com", .path: "/", .name: "ignored", .value: "secret"
            ]))
        ]

        let cookie = try XCTUnwrap(CloudDriveLoginCredentialExtractor.quarkCookie(from: cookies))

        XCTAssertEqual(cookie, "__puus=login-value; other=other-value")
        XCTAssertFalse(cookie.contains("ignored"))
    }

    func testQuarkCookieRejectsAnonymousCookies() throws {
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: ".quark.cn", .path: "/", .name: "anonymous", .value: "value"
        ]))

        XCTAssertNil(CloudDriveLoginCredentialExtractor.quarkCookie(from: [cookie]))
    }

    func testAliRefreshTokenFindsNestedToken() {
        let values = [
            "plain text",
            #"{"auth":{"token":{"refresh_token":"ali-refresh-token"}}}"#
        ]

        XCTAssertEqual(
            CloudDriveLoginCredentialExtractor.aliRefreshToken(from: values),
            "ali-refresh-token"
        )
    }

    func testAliRefreshTokenRejectsEmptyAndMalformedValues() {
        let values = ["not-json", #"{"refresh_token":""}"#]

        XCTAssertNil(CloudDriveLoginCredentialExtractor.aliRefreshToken(from: values))
    }
}
#endif
