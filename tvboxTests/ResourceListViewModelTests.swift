import XCTest
@testable import TVBox

@MainActor
final class ResourceListViewModelTests: XCTestCase {
    func testExpiredVerificationLabelAgreesWithAvailableCount() async throws {
        var date = Date()
        let video = Movie.Video(id: "clock-regression")
        let model = ResourceListViewModel(now: { date }, verifyPlayback: { _ in
            .verified(flag: "direct", episode: "1")
        }, loadDetail: { self.info(for: $0) })
        await model.check([video], verifyPlayback: true)
        date += 61
        XCTAssertEqual(model.playableCount(in: [video], kind: .all, cloudSourceKeys: []), 0)
        let state = try XCTUnwrap(model.states[video.resourceID])
        XCTAssertEqual(state.label(at: date), "抽检结果已过时，请重新检查")
        XCTAssertFalse(ResourceStatusFilter.playable.includes(state, at: date))
        XCTAssertTrue(ResourceStatusFilter.pending.includes(state, at: date))
        XCTAssertEqual(state.label(at: date.addingTimeInterval(-2)), "抽检可用 · direct · 1")
    }

    func testPlayableResourcesSortBeforePendingAndFailuresWithStableTies() async {
        var date = Date(timeIntervalSince1970: 1000)
        let videos = ["failed", "pending", "good", "empty", "good2", "unseen"].map { Movie.Video(id: $0) }
        let model = ResourceListViewModel(now: { date }, verifyPlayback: { info in
            if info.id == "failed" { return .failed("媒体已下线") }
            if info.id == "pending" { return .needsPlayback("需登录") }
            return .verified(flag: "直连", episode: "第1集")
        }, loadDetail: { video in video.id == "empty" ? nil : self.info(for: video) })
        await model.check(Array(videos.dropLast()), verifyPlayback: true)
        XCTAssertEqual(model.sortedResources(videos).map(\.id), ["good", "good2", "pending", "unseen", "failed", "empty"])
        date += 60
        XCTAssertEqual(model.sortedResources(videos).map(\.id), ["pending", "good", "good2", "unseen", "failed", "empty"])
    }

    func testGroupOrderingOnlyUsesResourcesMatchingSelectedKind() async {
        let cloud = Movie.Video(id: "cloud", sourceKey: "cloud")
        let online = Movie.Video(id: "online", sourceKey: "online")
        let unknown = Movie.Video(id: "unknown", sourceKey: "cloud")
        let model = ResourceListViewModel(verifyPlayback: { info in
            info.sourceKey == "online" ? .verified(flag: "直连", episode: "第1集") : .failed("已下线")
        }, loadDetail: { self.info(for: $0) })
        await model.check([cloud, online], verifyPlayback: true)
        let groups = [SearchResultGroup(id: "unknown", title: "待确认", year: "", resources: [unknown]),
                      SearchResultGroup(id: "mixed", title: "混合", year: "", resources: [cloud, online])]
        XCTAssertEqual(model.sortedGroups(groups, kind: .all, cloudSourceKeys: ["cloud"]).map(\.id), ["mixed", "unknown"])
        XCTAssertEqual(model.sortedGroups(groups.reversed(), kind: .cloud, cloudSourceKeys: ["cloud"]).map(\.id), ["unknown", "mixed"])
    }

    func testKindAndAvailabilityMustMatchTheSameResource() async {
        let online = Movie.Video(id: "1", sourceKey: "online")
        let cloud = Movie.Video(id: "2", sourceKey: "cloud")
        let model = ResourceListViewModel(verifyPlayback: { info in
            info.sourceKey == "online" ? .verified(flag: "直连", episode: "第1集") : .needsPlayback("需登录")
        }, loadDetail: { self.info(for: $0) })
        await model.check([online, cloud], verifyPlayback: true)
        XCTAssertEqual(model.playableCount(in: [online, cloud], kind: .cloud, cloudSourceKeys: ["cloud"]), 0)
        XCTAssertEqual(model.playableCount(in: [online, cloud], kind: .online, cloudSourceKeys: ["cloud"]), 1)
    }

    func testSuccessfulAlternateRouteBecomesDefaultAndOldSearchStatesArePruned() async {
        let video = Movie.Video(id: "1")
        let model = ResourceListViewModel(verifyPlayback: { _ in
            .verified(flag: "备用", episode: "第1集")
        }, loadDetail: { video in
            VodInfo.from(video: video, playFrom: "默认$$$备用", playUrl: "第1集$https://example.com/one.mp4$$$第1集$https://example.com/two.mp4")
        })
        await model.check([video], verifyPlayback: true)
        XCTAssertEqual(model.states[video.resourceID]?.detail?.playFlag, "备用")
        model.retainResults([])
        XCTAssertTrue(model.states.isEmpty)
    }

    func testStoppedCheckCannotPublishLatePlaybackSuccess() async {
        let started = expectation(description: "Playback probe started")
        var finish: CheckedContinuation<Void, Never>?
        let model = ResourceListViewModel(verifyPlayback: { _ in
            await withCheckedContinuation { continuation in
                finish = continuation
                started.fulfill()
            }
            return .verified(flag: "直连", episode: "第1集")
        }, loadDetail: { self.info(for: $0) })
        let video = Movie.Video(id: "1")
        let task = Task { await model.check([video], verifyPlayback: true) }
        await fulfillment(of: [started], timeout: 2)
        model.cancelChecking()
        finish?.resume()
        await task.value
        XCTAssertTrue(model.states.isEmpty)
        XCTAssertFalse(model.isChecking)
    }

    func testPlayableFilterRequiresFreshMediaVerification() {
        let video = Movie.Video(id: "1")
        let date = Date()
        XCTAssertFalse(ResourceStatusFilter.playable.includes(.ready(info(for: video), checkedAt: date)))
        let checked = ResourceCheckState.ready(info(for: video), checkedAt: date, playback: .verified(flag: "直连", episode: "第1集"))
        XCTAssertTrue(ResourceStatusFilter.playable.includes(checked))
        XCTAssertFalse(checked.isPlayable(at: date.addingTimeInterval(61)))
        XCTAssertFalse(ResourceStatusFilter.pending.includes(.empty))
        XCTAssertFalse(ResourceStatusFilter.pending.includes(.failed("超时")))
    }

    func testDirectoryCacheCanBeUpgradedButCannotRenewOldPlaybackProof() async {
        var date = Date()
        var loads = 0
        var probes = 0
        let video = Movie.Video(id: "1")
        let model = ResourceListViewModel(now: { date }, verifyPlayback: { _ in
            probes += 1
            return .verified(flag: "直连", episode: "第1集")
        }, loadDetail: { video in
            loads += 1
            return self.info(for: video)
        })
        await model.check([video])
        await model.check([video], verifyPlayback: true)
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(probes, 1)
        XCTAssertTrue(model.states[video.resourceID]?.playback.isVerified == true)
        date += 61
        await model.check([video])
        XCTAssertEqual(loads, 2)
        XCTAssertEqual(model.states[video.resourceID]?.playback, .notChecked)
    }

    func testDuplicateSearchHitsAreCheckedOnceAndFailureDoesNotHideDirectory() async {
        let video = Movie.Video(id: "1")
        var calls = 0
        let model = ResourceListViewModel(verifyPlayback: { _ in
            calls += 1
            return .failed("媒体下线")
        }, loadDetail: { self.info(for: $0) })
        await model.check([video, video], verifyPlayback: true)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(model.totalCount, 1)
        XCTAssertEqual(model.completedCount, 1)
        XCTAssertNotNil(model.states[video.resourceID]?.detail)
        XCTAssertTrue(ResourceStatusFilter.issues.includes(model.states[video.resourceID]))
        XCTAssertFalse(ResourceStatusFilter.playable.includes(model.states[video.resourceID]))
    }

    func testStatusAndProviderFiltersDoNotClassifyPendingAsFailed() {
        XCTAssertFalse(ResourceStatusFilter.issues.includes(nil))
        XCTAssertFalse(ResourceStatusFilter.issues.includes(.checking))
        XCTAssertTrue(ResourceStatusFilter.issues.includes(.failed("超时")))
        XCTAssertTrue(ResourceStatusFilter.issues.includes(.empty))
        let video = Movie.Video(id: "1", sourceKey: "cloud")
        XCTAssertTrue(ResourceKindFilter.cloud.includes(video, cloudSourceKeys: ["cloud"]))
        XCTAssertFalse(ResourceKindFilter.online.includes(video, cloudSourceKeys: ["cloud"]))
        XCTAssertTrue(ResourceKindFilter.all.includes(video, cloudSourceKeys: []))
    }

    private func info(for video: Movie.Video) -> VodInfo {
        VodInfo.from(video: video, playFrom: "直连", playUrl: "第1集$https://example.com/test.mp4")
    }

    func testChecksEveryResourceWithoutTreatingErrorsAsExpiry() async {
        let videos = (0..<4).map { Movie.Video(id: "\($0)", name: "测试剧", sourceKey: "source") }
        let model = ResourceListViewModel { video in
            switch video.id {
            case "0": return self.info(for: video)
            case "1": return nil
            case "2": throw URLError(.timedOut)
            default: return VodInfo(id: video.id)
            }
        }
        await model.check(videos)
        XCTAssertEqual(model.states.count, 4)
        XCTAssertNotNil(model.states[videos[0].resourceID]?.detail)
        if case .empty = model.states[videos[1].resourceID] {} else { XCTFail("Missing details must be explicit") }
        if case .failed(let message) = model.states[videos[2].resourceID] {
            XCTAssertFalse(message.contains("过期"))
        } else { XCTFail("Timeout must remain retryable") }
        if case .empty = model.states[videos[3].resourceID] {} else { XCTFail("Empty episodes are not ready") }
        XCTAssertFalse(model.isChecking)
    }

    func testRefreshRechecksPreviouslyReadyResourcesAndBoundsConcurrency() async {
        var active = 0
        var peak = 0
        var calls = 0
        var shouldFail = false
        let model = ResourceListViewModel { video in
            active += 1
            calls += 1
            peak = max(peak, active)
            defer { active -= 1 }
            try await Task.sleep(nanoseconds: 1_000_000)
            return shouldFail ? nil : self.info(for: video)
        }
        let videos = (0..<8).map { Movie.Video(id: "\($0)", sourceKey: "source") }
        await model.check(videos)
        XCTAssertLessThanOrEqual(peak, 3)
        XCTAssertEqual(calls, 8)
        await model.check(videos)
        XCTAssertEqual(calls, 8)
        shouldFail = true
        await model.check(videos, refresh: true)
        XCTAssertEqual(calls, 16)
        XCTAssertTrue(model.states.values.allSatisfy { $0.detail == nil })
    }

    func testCancelledCheckDoesNotPublishReadyState() async {
        let video = Movie.Video(id: "1", sourceKey: "source")
        let model = ResourceListViewModel { video in
            try? await Task.sleep(nanoseconds: 100_000_000)
            return self.info(for: video)
        }
        let task = Task { await model.check([video]) }
        await Task.yield()
        task.cancel()
        await task.value
        XCTAssertNil(model.states[video.resourceID])
        XCTAssertFalse(model.isChecking)
    }

    func testOldDirectoryChecksAreRefreshedWhenReturningToResources() async {
        var date = Date(timeIntervalSince1970: 100)
        var calls = 0
        let video = Movie.Video(id: "1", sourceKey: "source")
        let model = ResourceListViewModel(now: { date }) { video in
            calls += 1
            return calls == 1 ? self.info(for: video) : nil
        }
        await model.check([video])
        date += 61
        await model.check([video])
        XCTAssertEqual(calls, 2)
        XCTAssertNil(model.states[video.resourceID]?.detail)
    }

    func testDetailUsesCheckedEpisodesWithoutRequestingAnotherSource() async {
        let video = Movie.Video(id: "1", sourceKey: "test-only-source")
        let detail = DetailViewModel()
        await detail.loadDetail(video: video, initialInfo: info(for: video))
        XCTAssertEqual(detail.currentEpisodes.count, 1)
        XCTAssertEqual(detail.vodInfo?.sourceKey, video.sourceKey)
        XCTAssertNil(detail.errorMessage)
    }

    func testDetailReportsMissingSourceAndEmptyEpisodes() async {
        let video = Movie.Video(id: "1", sourceKey: "test-only-missing-source")
        let detail = DetailViewModel()
        await detail.loadDetail(video: video)
        XCTAssertEqual(detail.errorMessage, "该来源已移除，请重新搜索并选择其他资源")
        await detail.loadDetail(video: video, initialInfo: VodInfo(id: video.id))
        XCTAssertEqual(detail.errorMessage, "该资源未返回剧集，请返回资源列表重试或选择其他来源")
        XCTAssertFalse(detail.isLoading)
    }
}
