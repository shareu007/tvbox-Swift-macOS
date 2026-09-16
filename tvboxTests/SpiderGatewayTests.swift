import XCTest
@testable import TVBox

#if os(macOS)
import Darwin
#endif

@MainActor
final class SpiderGatewayTests: XCTestCase {
    func testSiteJarOverridesTopLevelSpiderJar() {
        XCTAssertEqual(
            ApiConfig.resolvedSpiderJar(
                siteJar: " https://example.com/site.jar ",
                defaultJar: "https://example.com/default.jar"
            ),
            "https://example.com/site.jar"
        )
    }

    func testTopLevelSpiderJarIsUsedWhenSiteJarIsEmpty() {
        XCTAssertEqual(
            ApiConfig.resolvedSpiderJar(
                siteJar: "  ",
                defaultJar: " https://example.com/default.jar "
            ),
            "https://example.com/default.jar"
        )
    }

    func testTypeThreeAvailabilityRequiresConfiguredGateway() throws {
        let previous = SpiderGatewaySettings.baseURL
        let previousToken = SpiderGatewaySettings.token
        defer {
            try? SpiderGatewaySettings.save(previous)
            try? SpiderGatewaySettings.saveToken(previousToken)
        }

        let source = SourceBean(api: "csp_Demo", type: 3, jar: "https://example.com/spider.jar")
        try SpiderGatewaySettings.save("")
        XCTAssertFalse(source.isSupportedInSwift)

        try SpiderGatewaySettings.save("https://gateway.example.com/")
        XCTAssertTrue(source.isSupportedInSwift)
        XCTAssertEqual(SpiderGatewaySettings.baseURL, "https://gateway.example.com")

        let missingJar = SourceBean(api: "csp_Demo", type: 3)
        XCTAssertFalse(missingJar.isSupportedInSwift)
    }

    func testGatewayTokenIsTrimmedAndCanBeCleared() throws {
        let previous = SpiderGatewaySettings.savedToken
        defer { try? SpiderGatewaySettings.saveToken(previous) }

        try SpiderGatewaySettings.saveToken("  secret-token  ")
        XCTAssertEqual(SpiderGatewaySettings.token, "secret-token")
        XCTAssertEqual(SpiderGatewaySettings.savedToken, "secret-token")

        try SpiderGatewaySettings.saveToken("  ")
        XCTAssertTrue(SpiderGatewaySettings.token.isEmpty)
    }

    func testCatVodBundleURLRecognition() {
        XCTAssertTrue(SpiderGatewayService.isCatVodBundleURL("https://example.com/cat/index.js"))
        XCTAssertTrue(SpiderGatewayService.isCatVodBundleURL("https://example.com/cat/index.js.md5"))
        XCTAssertTrue(
            SpiderGatewayService.isCatVodBundleURL(
                "http://demo:secret@example.com/cat/index.js.md5"
            )
        )
        XCTAssertFalse(SpiderGatewayService.isCatVodBundleURL("https://example.com/config.json"))
        XCTAssertFalse(SpiderGatewayService.isCatVodBundleURL("file:///tmp/index.js"))
    }

    func testSpiderPlaybackQualityOptionsAreParsedAndDeduplicated() {
        let options = SpiderGatewayService.playbackQualityOptions(from: [
            "qualityOptions": [
                ["name": "4K", "url": "https://video.example/4k.mp4"],
                ["name": "高清", "url": "https://video.example/high.mp4"],
                ["name": "重复", "url": "https://video.example/4k.mp4"],
                ["name": "", "url": "https://video.example/invalid.mp4"]
            ]
        ])

        XCTAssertEqual(options, [
            SpiderPlaybackQualityOption(name: "4K", url: "https://video.example/4k.mp4"),
            SpiderPlaybackQualityOption(name: "高清", url: "https://video.example/high.mp4")
        ])
    }

#if os(macOS)
    func testEmbeddedGatewayCanStartAndStop() async throws {
        let previousURL = SpiderGatewaySettings.savedBaseURL
        let previousToken = SpiderGatewaySettings.savedToken
        defer {
            EmbeddedSpiderGateway.shared.stop()
            try? SpiderGatewaySettings.save(previousURL)
            try? SpiderGatewaySettings.saveToken(previousToken)
        }
        try SpiderGatewaySettings.save("https://external-gateway.example")
        try SpiderGatewaySettings.saveToken("external-token")

        let url = try await EmbeddedSpiderGateway.shared.ensureStarted()
        XCTAssertTrue(url.hasPrefix("http://127.0.0.1:"))
        XCTAssertEqual(SpiderGatewaySettings.baseURL, url)
        XCTAssertEqual(SpiderGatewaySettings.token.count, 64)
        XCTAssertNotEqual(SpiderGatewaySettings.token, "external-token")
        XCTAssertEqual(SpiderGatewaySettings.savedToken, "external-token")

        SpiderGatewaySettings.useEmbeddedGateway(at: nil)
        XCTAssertEqual(SpiderGatewaySettings.baseURL, "https://external-gateway.example")
        let reusedURL = try await EmbeddedSpiderGateway.shared.ensureStarted()
        XCTAssertEqual(reusedURL, url)
        XCTAssertEqual(SpiderGatewaySettings.baseURL, url)
        XCTAssertEqual(SpiderGatewaySettings.token.count, 64)

        EmbeddedSpiderGateway.shared.stop()
        XCTAssertEqual(SpiderGatewaySettings.baseURL, "https://external-gateway.example")
        XCTAssertEqual(SpiderGatewaySettings.token, "external-token")
    }

    func testEmbeddedGatewayAuthenticationTokensAreUnique() throws {
        let first = try EmbeddedSpiderGateway.makeAuthenticationToken()
        let second = try EmbeddedSpiderGateway.makeAuthenticationToken()

        XCTAssertEqual(first.count, 64)
        XCTAssertEqual(second.count, 64)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.allSatisfy { $0.isHexDigit })
    }

    func testEmbeddedGatewayBootstrapEncodesSecretsWithoutEnvironmentSyntax() throws {
        let data = try EmbeddedSpiderGateway.bootstrapData(
            authenticationToken: "ephemeral-token",
            cloudConfig: ["quarkCookie": "private-cookie"],
            allowedBundleURLs: ["https://example.com/cat.js?token=private"]
        )
        let value = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let cloudConfig = try XCTUnwrap(value["cloudConfig"] as? [String: String])

        XCTAssertEqual(value["token"] as? String, "ephemeral-token")
        XCTAssertEqual(cloudConfig["quarkCookie"], "private-cookie")
        XCTAssertEqual(
            value["nodeBundleAllowedURLs"] as? [String],
            ["https://example.com/cat.js?token=private"]
        )
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("SPIDER_GATEWAY_TOKEN="))
    }

    func testEmbeddedGatewayRejectsOversizedBootstrap() {
        XCTAssertThrowsError(
            try EmbeddedSpiderGateway.bootstrapData(
                authenticationToken: "token",
                cloudConfig: [
                    "quarkCookie": String(
                        repeating: "x",
                        count: EmbeddedSpiderGateway.maximumBootstrapBytes
                    )
                ]
            )
        ) { error in
            guard case EmbeddedSpiderGatewayError.bootstrapTooLarge(let maximumBytes) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(maximumBytes, EmbeddedSpiderGateway.maximumBootstrapBytes)
        }
    }

    func testEmbeddedGatewayOnlyInheritsNonSensitiveProcessEnvironment() {
        let environment = EmbeddedSpiderGateway.sanitizedProcessEnvironment([
            "PATH": "/usr/bin:/bin",
            "TMPDIR": "/private/tmp/example",
            "LANG": "zh_CN.UTF-8",
            "GITHUB_TOKEN": "private-token",
            "TVBOX_CLOUD_CONFIG": "private-cookie",
            "SPIDER_GATEWAY_TOKEN": "private-gateway-token"
        ])

        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(environment["TMPDIR"], "/private/tmp/example")
        XCTAssertEqual(environment["LANG"], "zh_CN.UTF-8")
        XCTAssertNil(environment["GITHUB_TOKEN"])
        XCTAssertNil(environment["TVBOX_CLOUD_CONFIG"])
        XCTAssertNil(environment["SPIDER_GATEWAY_TOKEN"])
    }

    func testEmbeddedGatewayForceKillsProcessThatIgnoresTermination() async throws {
        let process = Process()
        let readyPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "trap '' TERM; echo ready; exec /usr/bin/yes >/dev/null"
        ]
        process.standardOutput = readyPipe
        process.standardError = FileHandle.nullDevice
        let terminated = expectation(description: "unresponsive process terminated")
        process.terminationHandler = { _ in terminated.fulfill() }
        try process.run()
        defer {
            if process.isRunning {
                process.interrupt()
            }
        }
        let readyData = try XCTUnwrap(
            try readyPipe.fileHandleForReading.read(upToCount: 6)
        )
        XCTAssertEqual(String(decoding: readyData, as: UTF8.self), "ready\n")

        EmbeddedSpiderGateway.terminateProcess(process, forceAfter: 0.05)
        await fulfillment(of: [terminated], timeout: 2)

        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGKILL)
    }

    func testGatewayStartupWaiterRejectsUnboundedOutput() async {
        let waiter = GatewayStartupWaiter(maximumOutputBytes: 4)
        waiter.consume(Data("12345".utf8))

        do {
            _ = try await waiter.wait(timeoutNanoseconds: 1_000_000_000)
            XCTFail("Expected startup output limit failure")
        } catch EmbeddedSpiderGatewayError.startupOutputTooLarge(let maximumBytes) {
            XCTAssertEqual(maximumBytes, 4)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEmbeddedGatewayListeningURLParsing() {
        XCTAssertEqual(
            EmbeddedSpiderGateway.listeningURL(
                in: "log line\nSpider Gateway listening on http://127.0.0.1:54321\n"
            ),
            "http://127.0.0.1:54321"
        )
        XCTAssertNil(
            EmbeddedSpiderGateway.listeningURL(
                in: "Spider Gateway listening on http://0.0.0.0:54321"
            )
        )
    }

    func testEmbeddedGatewayAllowlistStripsCredentialsAndScopesManifestPair() {
        let urls = EmbeddedSpiderGateway.allowedCatVodBundleURLs(
            for: "http://demo:secret@example.com/cat/index.js.md5#fragment"
        )

        XCTAssertTrue(urls.contains(SourceBean.cloudPanBundleURL))
        XCTAssertTrue(urls.contains(SourceBean.cloudPanBundleURL + ".md5"))
        XCTAssertTrue(urls.contains("http://example.com/cat/index.js.md5"))
        XCTAssertTrue(urls.contains("http://example.com/cat/index.js"))
        XCTAssertFalse(urls.contains { $0.contains("demo") || $0.contains("secret") })
    }
#endif

    func testNodeCatVodSourceIsGatewayCompatible() {
        let source = SourceBean(
            api: "/spider/douban/3",
            type: 3,
            jar: "https://example.com/cat/index.js.md5"
        )
        XCTAssertTrue(source.isSpiderGatewayCompatible)
        XCTAssertEqual(source.typeDescription, "Node")
    }

    func testBuiltInCloudPanSourceIsSearchOnlyAndSupportedOnMacOS() {
        let source = SourceBean.cloudPan
        XCTAssertEqual(source.key, "builtin_cloudpan")
        XCTAssertEqual(source.api, "/spider/cloudpan/3")
        XCTAssertTrue(source.isSearchable)
        XCTAssertTrue(source.isQuickSearchEnabled)
        XCTAssertTrue(source.isSearchOnly)
        XCTAssertFalse(source.isFilterable)
#if os(macOS)
        XCTAssertTrue(source.isSupportedInSwift)
        XCTAssertFalse(source.isHomeEligible)
#endif
    }

    func testFanTaiYingSixVGuardUsesNodeCompatibilitySource() {
        let source = SourceBean(
            key: "新6V",
            name: "新6V",
            api: "csp_SixVGuard",
            type: 3,
            ext: "https://www.xb6v.com/",
            jar: "https://example.com/fan.txt"
        ).applyingNodeCompatibility()

        XCTAssertEqual(source.api, "/spider/xb6v/3")
        XCTAssertEqual(source.jar, "https://raw.githubusercontent.com/qist/tvbox/master/cat/dist/index.js")
        XCTAssertEqual(source.ext, "https://www.xb6v.com/")
        XCTAssertTrue(source.isSupportedInSwift)
    }

    func testFanTaiYingKuafuSearchUsesNodeCompatibilitySource() {
        let source = SourceBean(
            key: "YpanSo",
            name: "盘她｜夸父",
            api: "csp_YpanSoGuard",
            type: 3,
            jar: "https://example.com/fan.txt"
        ).applyingNodeCompatibility()

        XCTAssertEqual(source.api, SourceBean.panSearchAPI)
        XCTAssertEqual(source.jar, SourceBean.cloudPanBundleURL)
        XCTAssertTrue(source.ext?.contains("\"engine\":\"kuafu\"") == true)
        XCTAssertTrue(source.isSearchOnly)
        XCTAssertFalse(source.isHomeEligible)
    }

    func testFanTaiYingPanSouPreservesObjectExtension() {
        let source = SourceBean(
            key: "JPan",
            name: "易搜｜四盘",
            api: "csp_S_zpsGuard",
            type: 3,
            ext: #"{"siteUrl":"https://so.252035.xyz/"}"#,
            jar: "https://example.com/fan.txt"
        ).applyingNodeCompatibility()

        XCTAssertEqual(source.api, SourceBean.panSearchAPI)
        XCTAssertTrue(source.ext?.contains("\"engine\":\"pansou\"") == true)
        XCTAssertTrue(source.ext?.contains("https:\\/\\/so.252035.xyz\\/") == true)
    }

    func testQistQuarkGuardAliasesUseNativePanSearchImplementations() {
        let miPan = SourceBean(
            key: "米搜",
            api: "csp_MIPanSoGuard",
            type: 3,
            jar: "https://example.com/fan.txt"
        ).applyingNodeCompatibility()
        let quarkSearch = SourceBean(
            key: "夸搜",
            api: "csp_PanSearchGuard",
            type: 3,
            ext: #"{"pan":"quark"}"#,
            jar: "https://example.com/fan.txt"
        ).applyingNodeCompatibility()
        let quarkPanSo = SourceBean(
            key: "QuarkPanso",
            api: "csp_QuarkPanso",
            type: 3,
            jar: "https://example.com/fan.txt"
        ).applyingNodeCompatibility()

        XCTAssertTrue(miPan.ext?.contains("\"engine\":\"kuafu\"") == true)
        XCTAssertTrue(quarkSearch.ext?.contains("\"engine\":\"pansou\"") == true)
        XCTAssertTrue(quarkPanSo.ext?.contains("\"engine\":\"pansou\"") == true)
        XCTAssertTrue([miPan, quarkSearch, quarkPanSo].allSatisfy(\.isSearchOnly))
    }

    func testQistFunletuJarAndDRPYScriptsUseNativePanSearchImplementations() {
        let jarSource = SourceBean(
            key: "Funletu",
            api: "csp_Funletu",
            type: 3,
            ext: "./lib/token.json",
            jar: "https://example.com/fan.txt"
        ).applyingNodeCompatibility()
        let drpySource = SourceBean(
            key: "drpy_js_趣盤搜",
            api: "./lib/drpy2.min.js",
            type: 3,
            ext: "./js/funletu.js",
            jar: "https://example.com/fan.txt"
        ).applyingNodeCompatibility()
        let yyetsSource = SourceBean(
            key: "drpy_js_yyets",
            api: "./lib/drpy2.min.js",
            type: 3,
            ext: "./js/yyets.js",
            jar: "https://example.com/fan.txt"
        ).applyingNodeCompatibility()

        XCTAssertTrue(jarSource.ext?.contains("\"engine\":\"funletu\"") == true)
        XCTAssertTrue(drpySource.ext?.contains("\"engine\":\"funletu\"") == true)
        XCTAssertTrue(yyetsSource.ext?.contains("\"engine\":\"yyets\"") == true)
        XCTAssertTrue([jarSource, drpySource, yyetsSource].allSatisfy(\.isSearchOnly))
    }

    func testQistKKPansScriptAndBuiltInSourceUseNativeQuarkSearch() {
        let source = SourceBean(
            key: "drpy_js_KK網盤",
            name: "KK網盤｜磁力",
            api: "./lib/drpy2.min.js",
            type: 3,
            ext: "./js/kkpans.js",
            jar: "https://example.com/fan.txt"
        ).applyingNodeCompatibility()

        XCTAssertEqual(source.api, SourceBean.panSearchAPI)
        XCTAssertTrue(source.ext?.contains("\"engine\":\"kkpans\"") == true)
        XCTAssertTrue(source.isSearchOnly)
        XCTAssertFalse(source.isHomeEligible)

        let builtIn = SourceBean.kkPanSearch
        XCTAssertEqual(builtIn.key, SourceBean.kkPanSearchKey)
        XCTAssertEqual(builtIn.api, SourceBean.panSearchAPI)
        XCTAssertTrue(builtIn.ext?.contains("\"engine\":\"kkpans\"") == true)
        XCTAssertTrue(builtIn.isSupportedInSwift)
    }

    func testQistQuarkShareResolvesCatalogRelativeToLoadedConfig() {
        let source = SourceBean(
            key: "QuarkShare",
            api: "csp_QuarkShare",
            type: 3,
            ext: "./lib/token.json$$$./json/quarkshare.txt",
            jar: "https://example.com/fan.txt"
        ).applyingNodeCompatibility(
            baseConfigURL: "https://raw.githubusercontent.com/qist/tvbox/master/js.json"
        )

        XCTAssertEqual(source.api, SourceBean.panSearchAPI)
        XCTAssertTrue(source.ext?.contains("\"engine\":\"quarkshare\"") == true)
        XCTAssertTrue(
            source.ext?.contains(
                "https:\\/\\/raw.githubusercontent.com\\/qist\\/tvbox\\/master\\/json\\/quarkshare.txt"
            ) == true
        )
        XCTAssertTrue(source.isSearchOnly)
    }

    func testSearchSourcesPrioritizeHomeThenQuickSourcesAndApplyLimit() {
        let regular = SourceBean(key: "regular", api: "https://example.com/regular", type: 1)
        let quick = SourceBean(key: "quick", api: "https://example.com/quick", quickSearch: 1, type: 1)
        let home = SourceBean(key: "home", api: "https://example.com/home", type: 1)
        let invalid = SourceBean(key: "invalid", api: "relative/path", quickSearch: 1, type: 1)

        let sources = SourceService.prioritizedSearchSources(
            [regular, quick, invalid, home],
            homeSource: home,
            limit: 2
        )

        XCTAssertEqual(sources.map(\.key), ["home", "quick"])
    }

    func testBuiltInCloudSearchIsNotDroppedBySearchFanoutLimit() {
        let home = SourceBean(key: "home", api: "https://example.com/home", type: 1)
        let quickSources = (0..<20).map {
            SourceBean(key: "quick-\($0)", api: "https://example.com/\($0)", quickSearch: 1, type: 1)
        }

        let sources = SourceService.prioritizedSearchSources(
            quickSources + [.cloudPan, home],
            homeSource: home,
            limit: 2
        )

        XCTAssertEqual(sources.map(\.key), ["home", SourceBean.cloudPanKey])
    }

    func testPanSearchSourcesCannotCrowdOnlineVideoSourcesOutOfNormalFanout() {
        let home = SourceBean(key: "home", api: "https://example.com/home", type: 1)
        let onlineSources = (0..<10).map {
            SourceBean(
                key: "online-\($0)",
                api: "https://example.com/\($0)",
                quickSearch: 1,
                type: 1
            )
        }
        let configuredPanSources = (0..<10).map {
            SourceBean(
                key: "pan-\($0)",
                api: SourceBean.panSearchAPI,
                quickSearch: 1,
                type: 3,
                ext: #"{"engine":"kuafu"}"#,
                jar: SourceBean.cloudPanBundleURL
            )
        }

        let sources = SourceService.prioritizedSearchSources(
            configuredPanSources + onlineSources + [.kkPanSearch, .cloudPan, home],
            homeSource: home,
            limit: 12
        )

        XCTAssertEqual(sources.first?.key, "home")
        XCTAssertEqual(
            Array(sources.dropFirst().prefix(2).map(\.key)),
            [SourceBean.cloudPanKey, SourceBean.kkPanSearchKey]
        )
        XCTAssertEqual(sources.filter { !$0.isSearchOnly }.count, 9)
        XCTAssertEqual(sources.filter(\.isSearchOnly).count, 3)
    }

    func testBuiltInCloudSearchAllowsAsyncAggregationToFinish() {
        XCTAssertEqual(
            SourceService.searchTimeoutNanoseconds(for: .cloudPan),
            20_000_000_000
        )
        XCTAssertEqual(
            SourceService.searchTimeoutNanoseconds(
                for: SourceBean(key: "regular", api: "https://example.com/api", type: 1)
            ),
            8_000_000_000
        )
    }

    func testRecommendationSortDoesNotCollideWithProviderHomeCategory() {
        let recommendation = MovieSort.SortData.home()
        let providerCategory = MovieSort.SortData(id: "home", name: "首页")

        XCTAssertTrue(recommendation.isRecommendation)
        XCTAssertFalse(providerCategory.isRecommendation)
        XCTAssertNotEqual(recommendation.id, providerCategory.id)
    }

    func testLocalConfigPresetDecoding() throws {
        let json = #"[{"id":"example","name":"示例","url":"https://example.com/config.json","compatibility":"原生可用","note":"仅用于测试"}]"#
        let preset = try XCTUnwrap(TVBoxConfigPreset.decode(from: Data(json.utf8)).first)

        XCTAssertEqual(preset.id, "example")
        XCTAssertEqual(preset.url, "https://example.com/config.json")
        XCTAssertTrue(preset.compatibility.isSelectable)
    }

    func testLocalConfigPresetAcceptsMacOSNativeCompatibilityAlias() throws {
        let json = #"[{"id":"node","name":"Node","url":"https://example.com/index.js","compatibility":"macOS 原生运行","note":"仅用于测试"}]"#
        let preset = try XCTUnwrap(TVBoxConfigPreset.decode(from: Data(json.utf8)).first)

        XCTAssertEqual(preset.compatibility, .native)
        XCTAssertTrue(preset.compatibility.isSelectable)
    }

    func testMalformedPresetDoesNotHideOtherPresets() throws {
        let json = """
        [
          {"id":"broken","name":"坏数据","url":"https://example.com/broken","compatibility":"未知状态","note":"忽略"},
          {"id":"valid","name":"可用","url":"https://example.com/valid","compatibility":"部分兼容","note":"保留"}
        ]
        """
        let presets = TVBoxConfigPreset.decode(from: Data(json.utf8))

        XCTAssertEqual(presets.map(\.id), ["valid"])
    }

    @MainActor
    func testMatchingPresetUsesNormalizedURL() throws {
        let json = #"[{"id":"demo","name":"示例","url":"https://example.com/config.json","compatibility":"原生可用","note":"仅用于测试"}]"#
        let preset = try XCTUnwrap(TVBoxConfigPreset.decode(from: Data(json.utf8)).first)

        let match = SettingsViewModel.matchingPreset(
            for: "https://example.com/config.json ",
            in: [preset]
        )

        XCTAssertEqual(match?.id, "demo")
    }

    @MainActor
    func testManualURLDoesNotMatchBuiltInPreset() throws {
        let json = #"[{"id":"demo","name":"示例","url":"https://example.com/config.json","compatibility":"原生可用","note":"仅用于测试"}]"#
        let preset = try XCTUnwrap(TVBoxConfigPreset.decode(from: Data(json.utf8)).first)

        let match = SettingsViewModel.matchingPreset(
            for: "https://example.com/manual.json",
            in: [preset]
        )

        XCTAssertNil(match)
    }

    @MainActor
    func testLoadedConfigInspectionReportsPartialCompatibility() {
        let sources = [
            SourceBean(key: "json", name: "JSON", api: "https://example.com/api", type: 1),
            SourceBean(key: "unknown", name: "未知", api: "custom", type: 99)
        ]

        let result = SettingsViewModel.inspectLoadedConfig(
            entryURL: "https://example.com/config.json",
            sources: sources
        )

        XCTAssertEqual(result.configurationProtocol, "TVBox JSON")
        XCTAssertEqual(result.compatibility, .partial)
        XCTAssertEqual(result.supportedSourceCount, 1)
        XCTAssertEqual(result.totalSourceCount, 2)
        XCTAssertEqual(result.sourceProtocols, ["JSON", "未知"])
    }

    @MainActor
    func testConfigurationProtocolCanBeInferredBeforeLoading() {
        XCTAssertEqual(
            SettingsViewModel.inferredConfigurationProtocol(
                for: "https://example.com/config.json"
            ),
            "TVBox JSON"
        )
        XCTAssertEqual(
            SettingsViewModel.inferredConfigurationProtocol(
                for: "https://example.com/index.js.md5"
            ),
            "CatVod JavaScript"
        )
    }

    func testSavedVodConfigRoundTripKeepsPrivateListMetadata() throws {
        let config = SavedVodConfig(
            name: "示例配置",
            url: "https://example.com/config.json",
            configurationProtocol: "TVBox JSON",
            sourceProtocols: ["JSON", "Node"],
            compatibility: .compatible,
            supportedSourceCount: 8,
            totalSourceCount: 8
        )

        let encoded = try SavedVodConfig.encode([config])
        let decoded = try XCTUnwrap(SavedVodConfig.decode(from: encoded).first)

        XCTAssertEqual(decoded.id, config.id)
        XCTAssertEqual(decoded.url, config.url)
        XCTAssertEqual(decoded.sourceProtocols, ["JSON", "Node"])
        XCTAssertEqual(decoded.compatibility, .compatible)
    }

    func testCMSRequestQueryOverridesPresetDefaults() {
        let merged = SourceService.mergingQueryItems(
            existing: [
                URLQueryItem(name: "ac", value: "list"),
                URLQueryItem(name: "token", value: "demo")
            ],
            incoming: [
                URLQueryItem(name: "ac", value: "class"),
                URLQueryItem(name: "pg", value: "1")
            ]
        )

        XCTAssertEqual(merged.filter { $0.name == "ac" }.map(\.value), ["class"])
        XCTAssertEqual(merged.first(where: { $0.name == "token" })?.value, "demo")
        XCTAssertEqual(merged.first(where: { $0.name == "pg" })?.value, "1")
    }

    func testObjectExtIsPreservedAsJSONString() throws {
        let json = #"{"sites":[{"key":"demo","type":3,"api":"csp_Demo","ext":{"token":"abc","enabled":true}}]}"#
        let config = try JSONDecoder().decode(AppConfigData.self, from: Data(json.utf8))
        let ext = try XCTUnwrap(config.sites?.first?.ext?.stringValue)
        let data = try XCTUnwrap(ext.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["token"] as? String, "abc")
        XCTAssertEqual(object["enabled"] as? Bool, true)
    }
}
