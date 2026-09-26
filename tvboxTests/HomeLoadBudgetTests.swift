import XCTest
@testable import TVBox

@MainActor
final class HomeLoadBudgetTests: XCTestCase {
    private let source = SourceBean(key: "budget", api: "https://fixture.example/api", type: 1)

    func testDeadlineReturnsWithoutWaitingForUncooperativeLoader() async {
        var late: CheckedContinuation<(sorts: [MovieSort.SortData], homeVideos: [Movie.Video]), Error>?
        let started = expectation(description: "Loader started")
        let finished = expectation(description: "Deadline released homepage")
        let model = HomeViewModel(currentSource: { self.source }, fallbackSources: { [] },
            sortLoader: { _ in
                try await withCheckedThrowingContinuation { continuation in
                    late = continuation
                    started.fulfill()
                }
            }, homeBudgetSeconds: 0.03, homeRequestSeconds: 1, listLoader: { _, _, _, _ in [] })
        let task = Task { await model.refresh(); finished.fulfill() }
        await fulfillment(of: [started, finished], timeout: 1)
        XCTAssertFalse(model.isLoadingHome)
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.homeLoadMessage?.contains("等待过久") == true)
        late?.resume(returning: ([], [Movie.Video(id: "late")]))
        await task.value
        await Task.yield()
        XCTAssertTrue(model.displayedVideos.isEmpty)
    }

    func testStopImmediatelyReleasesWaitAndRejectsLateCategoryResult() async {
        var late: CheckedContinuation<[Movie.Video], Error>?
        let started = expectation(description: "Category started")
        let finished = expectation(description: "Stopped homepage")
        let model = HomeViewModel(currentSource: { self.source }, fallbackSources: { [] },
            sortLoader: { _ in ([.init(id: "movie", name: "电影")], []) }, listLoader: { _, _, _, _ in
                try await withCheckedThrowingContinuation { continuation in
                    late = continuation
                    started.fulfill()
                }
            })
        let task = Task { await model.refresh(); finished.fulfill() }
        await fulfillment(of: [started], timeout: 1)
        model.stopHomeLoading()
        await fulfillment(of: [finished], timeout: 1)
        late?.resume(returning: [Movie.Video(id: "late")])
        await task.value
        await Task.yield()
        XCTAssertFalse(model.isLoadingHome)
        XCTAssertTrue(model.displayedVideos.isEmpty)
        XCTAssertTrue(model.homeLoadMessage?.contains("已停止") == true)
    }

    func testWholeScanSharesOneBudgetAcrossCategories() async {
        var calls = 0
        let model = HomeViewModel(currentSource: { self.source }, fallbackSources: { [] },
            sortLoader: { _ in ((0..<100).map { .init(id: "c\($0)", name: "分类\($0)") }, []) },
            homeBudgetSeconds: 0.08, homeRequestSeconds: 0.02, listLoader: { _, _, _, _ in
                calls += 1
                try await Task.sleep(for: .seconds(1))
                return []
            })
        let clock = ContinuousClock()
        let start = clock.now
        await model.refresh()
        XCTAssertLessThan(clock.now - start, .seconds(0.5))
        XCTAssertLessThan(calls, 20)
        XCTAssertTrue(model.homeLoadMessage?.contains("等待过久") == true)
    }

    func testCachedHomepageIsVisibleWhileRefreshingAndSurvivesTimeout() async {
        let store = HomeSnapshotStore()
        store.save(source: source, sorts: [.home()], videos: [Movie.Video(id: "cached")], sections: [])
        let started = expectation(description: "Refresh started")
        let model = HomeViewModel(currentSource: { self.source }, fallbackSources: { [] },
            sortLoader: { _ in
                started.fulfill()
                try await Task.sleep(for: .seconds(1))
                return ([], [])
            }, homeBudgetSeconds: 0.04, snapshotStore: store, listLoader: { _, _, _, _ in [] })
        let task = Task { await model.refresh() }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(model.displayedVideos.map(\.id), ["cached"])
        XCTAssertTrue(model.isLoadingHome)
        await task.value
        XCTAssertEqual(model.displayedVideos.map(\.id), ["cached"])
        XCTAssertFalse(model.isLoadingHome)
    }

    func testSnapshotPersistsButNeverMatchesChangedEndpoint() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("home.json")
        HomeSnapshotStore(fileURL: file).save(source: source, sorts: [.home()], videos: [Movie.Video(id: "cached")], sections: [])
        let restored = HomeSnapshotStore(fileURL: file)
        XCTAssertEqual(restored.snapshot(for: source)?.videos.first?.id, "cached")
        let other = SourceBean(key: source.key, api: "https://other.example/api", type: 1)
        XCTAssertNil(restored.snapshot(for: other))
    }
}
