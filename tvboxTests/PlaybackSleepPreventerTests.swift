import XCTest
@testable import TVBox

#if os(macOS)
@MainActor
final class PlaybackSleepPreventerTests: XCTestCase {
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
#endif
