#if os(iOS)
import Foundation
import TVBoxNodeRuntime

/// Owns the in-process iOS engine; no external server or saved gateway is needed.
@MainActor
final class MobileSpiderGateway {
    static let shared = MobileSpiderGateway()

    private let resourcesDirectory: URL
    private let entryPoint: URL
    private let cacheDirectory: URL
    private let authenticationToken = UUID().uuidString + UUID().uuidString
    private var activeAllowedURLs: Set<String> = []

    init(resourcesDirectory: URL? = nil, entryPoint: URL? = nil, cacheDirectory: URL? = nil) {
        let resources = resourcesDirectory
            ?? Bundle.main.bundleURL.appendingPathComponent("SpiderGateway", isDirectory: true)
        self.resourcesDirectory = resources
        self.entryPoint = entryPoint ?? resources.appendingPathComponent("mobile-entry.mjs")
        self.cacheDirectory = cacheDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("TVBox/MobileSpider", isDirectory: true)
    }

    func ensureStarted(allowedBundleURL: String? = nil, replacingAllowlist: Bool = false) async throws -> String {
        guard FileManager.default.fileExists(atPath: entryPoint.path) else {
            throw MobileSpiderError.missingResources
        }
        let requestedURLs = Set(Self.allowedBundleURLs(for: allowedBundleURL))
        activeAllowedURLs = replacingAllowlist ? requestedURLs : activeAllowedURLs.union(requestedURLs)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let config = try JSONSerialization.data(withJSONObject: [
            "token": authenticationToken,
            "cloudConfig": CloudDriveCredentialStore.gatewayValues,
            "cacheRoot": cacheDirectory.path,
            "nodeBundleAllowedURLs": activeAllowedURLs.sorted(),
            "nodeBundleAllowChecksumRedirects": true
        ], options: [.sortedKeys])
        guard config.count <= 64 * 1024, let json = String(data: config, encoding: .utf8) else {
            throw MobileSpiderError.invalidConfiguration
        }
        TVBoxNodeRuntime.start(script: entryPoint.path, assetsDirectory: resourcesDirectory.path,
                              runtimeDirectory: cacheDirectory.path, configuration: json)
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let error = TVBoxNodeRuntime.startupError() {
                throw MobileSpiderError.startupFailed(error)
            }
            if let url = TVBoxNodeRuntime.listeningURL() {
                SpiderGatewaySettings.useEmbeddedGateway(at: url, token: authenticationToken)
                return url
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw MobileSpiderError.startupTimedOut
    }

    nonisolated static func allowedBundleURLs(for reference: String?) -> [String] {
        var values = [SourceBean.cloudPanBundleURL, SourceBean.cloudPanBundleURL + ".md5"]
        guard let reference, var url = URLComponents(
            string: reference.trimmingCharacters(in: .whitespacesAndNewlines)
        ), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return values }
        // Download credentials stay in the reference, outside the allowlist.
        url.user = nil
        url.password = nil
        url.fragment = nil
        if let value = url.url?.absoluteString { values.append(value) }
        if url.percentEncodedPath.lowercased().hasSuffix(".js.md5") {
            url.percentEncodedPath = String(url.percentEncodedPath.dropLast(4))
            if let value = url.url?.absoluteString { values.append(value) }
        }
        return Array(Set(values)).sorted()
    }
}

enum MobileSpiderError: LocalizedError {
    case missingResources
    case invalidConfiguration
    case startupFailed(String)
    case startupTimedOut

    var errorDescription: String? {
        switch self {
        case .missingResources: return "手机内置脚本组件不完整，请安装新版 IPA"
        case .invalidConfiguration: return "手机内置脚本配置过大或无效"
        case .startupFailed(let message): return message
        case .startupTimedOut: return "手机内置脚本引擎启动超时，请重新启动 App"
        }
    }
}
#endif
