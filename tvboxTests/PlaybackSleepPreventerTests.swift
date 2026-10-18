import XCTest
#if os(iOS)
import UIKit
#endif
@testable import TVBox

@MainActor
final class PlaybackSleepPreventerTests: XCTestCase {
    func testPausingOnePlayerKeepsScreenAwakeUntilAllPlaybackStops() {
        let first = UUID()
        let second = UUID()
        let preventer = PlaybackSleepPreventer.shared
        defer { preventer.end(owner: first); preventer.end(owner: second) }

        preventer.setPlaybackActive(true, owner: first)
        preventer.setPlaybackActive(true, owner: second)
        preventer.setPlaybackActive(false, owner: first)
        XCTAssertTrue(preventer.isPreventingSleep)
        #if os(iOS)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        #endif

        preventer.setPlaybackActive(false, owner: second)
        XCTAssertFalse(preventer.isPreventingSleep)
        #if os(iOS)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
        #endif
    }

    func testActivityUsesReferenceCountedOwners() {
        let first = UUID()
        let second = UUID()
        let preventer = PlaybackSleepPreventer.shared

        preventer.setPlaybackActive(true, owner: first)
        preventer.setPlaybackActive(true, owner: first)
        XCTAssertEqual(preventer.activeOwnerCount, 1)
        XCTAssertTrue(preventer.isPreventingSleep)

        preventer.setPlaybackActive(true, owner: second)
        preventer.end(owner: first)
        XCTAssertEqual(preventer.activeOwnerCount, 1)
        XCTAssertTrue(preventer.isPreventingSleep)

        preventer.end(owner: second)
        XCTAssertEqual(preventer.activeOwnerCount, 0)
        XCTAssertFalse(preventer.isPreventingSleep)
    }
}
