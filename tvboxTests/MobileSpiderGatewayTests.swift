#if os(iOS)
import XCTest
@testable import TVBox

@MainActor
final class MobileSpiderGatewayTests: XCTestCase {
    func testCatVodImportAndCloudPlaybackUseSavedCredentialsWithoutExternalGateway() async throws {
        let previousCookie = CloudDriveCredentialStore.value(for: .quarkCookie)
        let previousAliToken = CloudDriveCredentialStore.value(for: .aliToken)
        let previousURL = SpiderGatewaySettings.savedBaseURL
        let previousToken = SpiderGatewaySettings.savedToken
        let config = ApiConfig.shared
        let previousSources = config.sourceBeanList
        let previousHome = config.homeSourceBean
        let previousLoaded = config.isLoaded
        let previousConfigURL = config.configUrl
        let previousLiveURL = config.liveConfigUrl
        let settingsKeys: [PrivateSettingsStore.Key] = [.vodURL, .liveURL, .savedVodConfigs]
        let previousSettings = settingsKeys.map { PrivateSettingsStore.value(for: $0) }
        let defaults = UserDefaults.standard
        let previousHistory = defaults.object(forKey: "api_history")
        let previousHomeKey = defaults.object(forKey: HawkConfig.HOME_API)
        defer {
            try? CloudDriveCredentialStore.save([.quarkCookie: previousCookie, .aliToken: previousAliToken])
            SpiderGatewaySettings.useEmbeddedGateway(at: nil)
            try? SpiderGatewaySettings.save(previousURL)
            try? SpiderGatewaySettings.saveToken(previousToken)
            config.sourceBeanList = previousSources
            config.homeSourceBean = previousHome
            config.isLoaded = previousLoaded
            config.configUrl = previousConfigURL
            config.liveConfigUrl = previousLiveURL
            for (key, value) in zip(settingsKeys, previousSettings) {
                try? PrivateSettingsStore.save(value, for: key)
            }
            defaults.set(previousHistory, forKey: "api_history")
            defaults.set(previousHomeKey, forKey: HawkConfig.HOME_API)
        }
        try SpiderGatewaySettings.save("")
        try SpiderGatewaySettings.saveToken("")
        try CloudDriveCredentialStore.save([.quarkCookie: "", .aliToken: ""])
        SpiderGatewaySettings.useEmbeddedGateway(at: nil)
        XCTAssertFalse(SpiderGatewaySettings.isConfigured)

        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TVBox/MobileSpiderTests", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fake-catvod-mobile", withExtension: "js"))
        let bundle = root.appendingPathComponent("fixture.js")
        try Data(contentsOf: fixture).write(to: bundle)
        let resources = Bundle.main.bundleURL.appendingPathComponent("SpiderGateway", isDirectory: true)
        let entry = root.appendingPathComponent("test-entry.mjs")
        let modulePath = try jsonString(resources.appendingPathComponent("mobile-entry.mjs").absoluteString)
        let bundlePath = try jsonString(bundle.path)
        // Only the download boundary is replaced. The native engine, thread
        // runner, catalog endpoint, app parser and all source actions are real.
        try """
        import { startMobileGateway } from \(modulePath);
        const bridge = process._linkedBinding('tvbox_mobile');
        let gateway;
        let folderName = '';
        let savedFiles = [];
        gateway = await startMobileGateway(bridge, {nodeBundleCache: {async resolve() {
            const response = await fetch(`http://127.0.0.1:${gateway.server.address().port}/health`);
            if (!(await response.json()).catVodConfigured) throw new Error('Native fetch failed');
            return {path: \(bundlePath), digest: 'mobile-fixture'};
        }}, fetchValue: async (rawURL, request) => {
            const url = new URL(rawURL);
            if (url.hostname !== 'drive-pc.quark.cn') throw new Error('Unexpected fixture host');
            const expected = JSON.parse(bridge.configuration()).cloudConfig.quarkCookie;
            if (!expected || request.headers.cookie !== expected) return new Response(null, {status: 401});
            if (url.pathname.endsWith('/share/sharepage/detail')) return Response.json({data: {list: [
                {fid: 'fixture-file', share_fid_token: 'fixture-fresh-token', file_name: 'movie.mp4', size: 10485760}
            ]}});
            if (url.pathname.endsWith('/file/sort')) return Response.json({data: {list:
                url.searchParams.get('pdir_fid') === '0'
                    ? (folderName ? [{dir: 1, fid: 'fixture-cache', file_name: folderName}] : []) : savedFiles
            }});
            if (url.pathname.endsWith('/file')) {
                folderName = JSON.parse(request.body).file_name;
                return Response.json({data: {fid: 'fixture-cache'}});
            }
            if (url.pathname.endsWith('/share/sharepage/save')) return Response.json({data: {task_id: 'fixture-task'}});
            if (url.pathname.endsWith('/task')) {
                savedFiles = [{fid: 'fixture-saved-file', file_name: 'movie.mp4', size: 10485760}];
                return Response.json({data: {save_as: {save_as_top_fids: ['fixture-saved-file']}}});
            }
            if (url.pathname.endsWith('/file/download')) return Response.json({data: [
                {fid: 'fixture-saved-file', download_url: 'https://media.quark.cn/fixture.mp4'}
            ]});
            throw new Error('Unexpected fixture operation');
        }}).catch(() => bridge.failed());
        """.write(to: entry, atomically: true, encoding: .utf8)
        let runtime = MobileSpiderGateway(resourcesDirectory: resources, entryPoint: entry, cacheDirectory: root)
        _ = try await runtime.ensureStarted()

        let reference = "https://fixture.example.test/index.js.md5"
        let multiRepo = try await config.fetchMultiRepoOptions(from: reference)
        XCTAssertNil(multiRepo)
        let model = SettingsViewModel()
        model.vodApiUrl = reference
        model.liveApiUrl = ""
        await model.loadConfig(presentInspection: true)
        XCTAssertNil(model.configError)
        XCTAssertTrue(model.configSuccess)
        XCTAssertTrue(config.isLoaded)
        let source = try XCTUnwrap(config.sourceBeanList.first { $0.key == "mobile-fixture" })
        XCTAssertTrue(source.isSupportedInSwift)
        XCTAssertEqual(source.jar, reference)
        XCTAssertTrue(SpiderGatewaySettings.savedBaseURL.isEmpty)

        let service = SpiderGatewayService.shared
        let home = try await service.home(source: source)
        XCTAssertEqual(home.sorts.first?.id, "movie")
        XCTAssertEqual(home.homeVideos.first?.id, "one")
        let category = try await service.category(source: source, tid: "movie", page: 2, filters: nil)
        XCTAssertEqual(category.first?.id, "movie2")
        let detail = try await service.detail(source: source, id: "one")
        XCTAssertEqual(detail?.playFlags, ["direct"])
        let search = try await service.search(source: source, keyword: "fixture-query")
        XCTAssertEqual(search.first?.id, "fixture-query")
        let playback = try await service.player(source: source, flag: "direct", id: "https://media.example.test/fixture.mp4")
        XCTAssertEqual(playback.url, "https://media.example.test/fixture.mp4")
        XCTAssertEqual(playback.headers["Referer"], "https://media.example.test/")
        let permissions = try await service.search(source: source, keyword: "permissions")
        let permissionData = Data(try XCTUnwrap(permissions.first?.name).utf8)
        let checks = try JSONDecoder().decode([String: Bool].self, from: permissionData)
        XCTAssertEqual(checks.count, 7)
        XCTAssertTrue(checks.values.allSatisfy { $0 })

        // The engine remains in the app; clearing UI settings must not require
        // entering a gateway or restarting a second Node engine.
        SpiderGatewaySettings.useEmbeddedGateway(at: nil)
        let restored = try await service.search(source: source, keyword: "after-settings-change")
        XCTAssertEqual(restored.first?.id, "after-settings-change")

        let cloudSource = SourceBean(key: "cloud-fixture", name: "Fixture cloud",
                                    api: "/spider/wogg/3", type: 3, jar: reference)
        let cloudEpisode = try JSONSerialization.data(withJSONObject: [
            "providerId": "quark", "shareId": "fixture-share", "fileId": "fixture-file", "mode": "original",
            "playToken": try jsonStringDictionary([
                "shareId": "fixture-share", "fid": "fixture-file", "stoken": "fixture-token",
                "shareFidToken": "fixture-file-token", "fileName": "movie.mp4"
            ])
        ]).base64EncodedString()
        await assertCloudLoginRequired(service: service, source: cloudSource, episode: cloudEpisode)
        for cookie in ["__puus=fixture-first", "__puus=fixture-replacement"] {
            try CloudDriveCredentialStore.save([.quarkCookie: cookie, .aliToken: "fixture-ali-token"])
            let cloudPlayback = try await service.player(source: cloudSource, flag: "夸克原画", id: cloudEpisode)
            XCTAssertEqual(cloudPlayback.url, "https://media.quark.cn/fixture.mp4")
            XCTAssertEqual(cloudPlayback.headers.first { $0.key.lowercased() == "cookie" }?.value, cookie)
            XCTAssertTrue(SpiderGatewaySettings.savedBaseURL.isEmpty)
        }
        try CloudDriveCredentialStore.save([.quarkCookie: "", .aliToken: ""])
        await assertCloudLoginRequired(service: service, source: cloudSource, episode: cloudEpisode)
    }

    private func assertCloudLoginRequired(service: SpiderGatewayService, source: SourceBean, episode: String) async {
        do {
            _ = try await service.player(source: source, flag: "夸克原画", id: episode)
            XCTFail("Missing or cleared Cookie must require login")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("保存夸克 Cookie"))
        }
    }

    private func jsonStringDictionary(_ value: [String: String]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    func testManifestAllowlistRemovesCredentialsAndIncludesPairedScript() {
        let values = MobileSpiderGateway.allowedBundleURLs(for: "https://user:secret@example.com/index.js.md5?q=one#fragment")
        XCTAssertTrue(values.contains("https://example.com/index.js.md5?q=one"))
        XCTAssertTrue(values.contains("https://example.com/index.js?q=one"))
        XCTAssertFalse(values.contains { $0.contains("secret") || $0.contains("fragment") })
    }

    private func jsonString(_ value: String) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}
#endif
