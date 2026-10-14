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

    func testQuarkCookieWaitsForAuthenticatedSessionInsteadOfPreloginIdentifiers() throws {
        let cookies = try ["__pus", "kps", "__kps"].map { name in
            try XCTUnwrap(HTTPCookie(properties: [
                .domain: ".quark.cn", .path: "/", .name: name, .value: "prelogin-value"
            ]))
        }
        XCTAssertNil(CloudDriveLoginCredentialExtractor.quarkCookie(from: cookies))
    }

    func testQuarkCookieRejectsEmptyOrExpiredSessionMarkers() throws {
        let empty = try XCTUnwrap(HTTPCookie(properties: [
            .domain: ".quark.cn", .path: "/", .name: "__puus", .value: ""
        ]))
        let expired = try XCTUnwrap(HTTPCookie(properties: [
            .domain: ".quark.cn", .path: "/", .name: "__puus", .value: "expired-value",
            .expires: Date(timeIntervalSince1970: 1)
        ]))
        XCTAssertNil(CloudDriveLoginCredentialExtractor.quarkCookie(from: [empty]))
        XCTAssertNil(CloudDriveLoginCredentialExtractor.quarkCookie(from: [expired]))
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
