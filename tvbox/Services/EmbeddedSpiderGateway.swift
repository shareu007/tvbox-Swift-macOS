#if os(macOS)
import AppKit
import Darwin
import Foundation
import Security

private final class GatewayProcessTerminationTicket: @unchecked Sendable {
    let process: Process

    init(process: Process) {
        self.process = process
    }

    func forceKillIfNeeded() {
        guard process.isRunning else { return }
        let identifier = process.processIdentifier
        guard identifier > 0 else { return }
        _ = Darwin.kill(identifier, SIGKILL)
    }
}

private enum GatewayProcessTerminator {
    private static let queue = DispatchQueue(
        label: "com.tvbox.gateway-process-termination",
        qos: .utility
    )

    static func terminate(_ process: Process, forceAfter delay: TimeInterval) {
        guard process.isRunning else { return }
        let ticket = GatewayProcessTerminationTicket(process: process)
        process.terminate()
        queue.asyncAfter(deadline: .now() + max(delay, 0)) {
            ticket.forceKillIfNeeded()
        }
    }
}

@MainActor
final class EmbeddedSpiderGateway {
    static let shared = EmbeddedSpiderGateway()
    nonisolated static let maximumBootstrapBytes = 64 * 1024
    nonisolated static let maximumStartupOutputBytes = 256 * 1024

    private var process: Process?
    private var outputPipe: Pipe?
    private var startupTask: Task<String, Error>?
    private var activeAllowedBundleURLs: Set<String> = []
    private var activeGatewayURL: String?
    private var activeAuthenticationToken: String?
    private var terminationObserver: NSObjectProtocol?

    private init() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in EmbeddedSpiderGateway.shared.stop() }
        }
    }

    func ensureStarted(
        allowedBundleURL: String? = nil,
        replacingAllowlist: Bool = false
    ) async throws -> String {
        var allowedBundleURLs = Self.allowedCatVodBundleURLs(for: allowedBundleURL)
        let requestedAllowlist = Set(allowedBundleURLs)
        if let url = runningGatewayURL(
            requestedAllowlist: requestedAllowlist,
            replacing: replacingAllowlist
        ) {
            return url
        }
        if let startupTask {
            _ = try await startupTask.value
            if let url = runningGatewayURL(
                requestedAllowlist: requestedAllowlist,
                replacing: replacingAllowlist
            ) {
                return url
            }
        }
        if !replacingAllowlist {
            allowedBundleURLs = Array(activeAllowedBundleURLs.union(requestedAllowlist)).sorted()
        }
        if process?.isRunning == true {
            stop()
        }

        let task = Task { @MainActor in
            try await launch(allowedBundleURLs: allowedBundleURLs)
        }
        startupTask = task
        do {
            let url = try await task.value
            startupTask = nil
            return url
        } catch {
            startupTask = nil
            stop()
            throw error
        }
    }

    private func allowlistMatches(
        _ requestedAllowlist: Set<String>,
        replacing: Bool
    ) -> Bool {
        replacing
            ? activeAllowedBundleURLs == requestedAllowlist
            : requestedAllowlist.isSubset(of: activeAllowedBundleURLs)
    }

    private func runningGatewayURL(
        requestedAllowlist: Set<String>,
        replacing: Bool
    ) -> String? {
        guard let process,
              process.isRunning,
              let activeGatewayURL,
              let activeAuthenticationToken,
              allowlistMatches(requestedAllowlist, replacing: replacing) else {
            return nil
        }
        // Reassert the runtime connection if another settings operation cleared
        // it while the owned process remained alive.
        SpiderGatewaySettings.useEmbeddedGateway(
            at: activeGatewayURL,
            token: activeAuthenticationToken
        )
        return activeGatewayURL
    }

    func stop() {
        startupTask?.cancel()
        startupTask = nil
        SpiderGatewaySettings.useEmbeddedGateway(at: nil)
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        if let process {
            Self.terminateProcess(process)
        }
        process = nil
        activeAllowedBundleURLs = []
        activeGatewayURL = nil
        activeAuthenticationToken = nil
    }

    nonisolated static func listeningURL(in output: String) -> String? {
        let marker = "Spider Gateway listening on "
        guard let markerRange = output.range(of: marker) else { return nil }
        let remainder = output[markerRange.upperBound...]
        let value = remainder.prefix { !$0.isWhitespace }
        guard let url = URL(string: String(value)),
              url.host == "127.0.0.1",
              url.port != nil else { return nil }
        return url.absoluteString
    }

    nonisolated static func allowedCatVodBundleURLs(for reference: String?) -> [String] {
        var values = [
            SourceBean.cloudPanBundleURL,
            SourceBean.cloudPanBundleURL + ".md5"
        ]
        guard let reference,
              var components = URLComponents(
                string: reference.trimmingCharacters(in: .whitespacesAndNewlines)
              ),
              ["http", "https"].contains(components.scheme?.lowercased() ?? "") else {
            return values
        }
        components.user = nil
        components.password = nil
        components.fragment = nil
        guard let sanitized = components.url?.absoluteString else { return values }
        values.append(sanitized)
        if components.percentEncodedPath.lowercased().hasSuffix(".js.md5") {
            components.percentEncodedPath = String(
                components.percentEncodedPath.dropLast(4)
            )
            if let bundleURL = components.url?.absoluteString {
                values.append(bundleURL)
            }
        }
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    nonisolated static func makeAuthenticationToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw EmbeddedSpiderGatewayError.cannotGenerateAuthenticationToken
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func bootstrapData(
        authenticationToken: String,
        cloudConfig: [String: String],
        allowedBundleURLs: [String] = []
    ) throws -> Data {
        let value: [String: Any] = [
            "token": authenticationToken,
            "cloudConfig": cloudConfig,
            "nodeBundleAllowedURLs": allowedBundleURLs
        ]
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        } catch {
            throw EmbeddedSpiderGatewayError.cannotEncodeBootstrap
        }
        guard data.count <= maximumBootstrapBytes else {
            throw EmbeddedSpiderGatewayError.bootstrapTooLarge(maximumBootstrapBytes)
        }
        return data
    }

    nonisolated static func sanitizedProcessEnvironment(
        _ inherited: [String: String]
    ) -> [String: String] {
        let allowedNames = ["PATH", "LANG", "LC_ALL", "TMPDIR", "TZ"]
        return allowedNames.reduce(into: [:]) { result, name in
            if let value = inherited[name], !value.isEmpty {
                result[name] = value
            }
        }
    }

    nonisolated static func terminateProcess(
        _ process: Process,
        forceAfter delay: TimeInterval = 2
    ) {
        GatewayProcessTerminator.terminate(process, forceAfter: delay)
    }

    private func launch(allowedBundleURLs: [String]) async throws -> String {
        guard let resources = Bundle.main.resourceURL else {
            throw EmbeddedSpiderGatewayError.missingResources
        }
        let nodeURL = resources.appendingPathComponent("EmbeddedNode/node")
        let gatewayURL = resources.appendingPathComponent("SpiderGateway/index.mjs")
        guard FileManager.default.isExecutableFile(atPath: nodeURL.path),
              FileManager.default.fileExists(atPath: gatewayURL.path) else {
            throw EmbeddedSpiderGatewayError.missingResources
        }

        let cacheRoot = try gatewayCacheDirectory()
        let authenticationToken = try Self.makeAuthenticationToken()
        let bootstrapData = try Self.bootstrapData(
            authenticationToken: authenticationToken,
            cloudConfig: CloudDriveCredentialStore.gatewayValues,
            allowedBundleURLs: allowedBundleURLs
        )
        let process = Process()
        let outputPipe = Pipe()
        let bootstrapPipe = Pipe()
        process.executableURL = nodeURL
        process.arguments = [gatewayURL.path]
        process.standardInput = bootstrapPipe
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.currentDirectoryURL = resources.appendingPathComponent("SpiderGateway")

        var environment = Self.sanitizedProcessEnvironment(
            ProcessInfo.processInfo.environment
        )
        environment["SPIDER_GATEWAY_HOST"] = "127.0.0.1"
        environment["SPIDER_GATEWAY_PORT"] = "0"
        environment["TVBOX_GATEWAY_BOOTSTRAP_STDIN"] = "1"
        environment.removeValue(forKey: "SPIDER_GATEWAY_TOKEN")
        environment.removeValue(forKey: "TVBOX_CLOUD_CONFIG")
        environment["SPIDER_GATEWAY_CACHE_DIR"] = cacheRoot.appendingPathComponent("jars").path
        environment["CATVOD_BUNDLE_CACHE_DIR"] = cacheRoot.appendingPathComponent("bundles").path
        environment["CATVOD_RUNTIME_DIR"] = cacheRoot.appendingPathComponent("runtime").path
        environment["CATVOD_BUNDLE_ALLOW_HTTP"] = allowedBundleURLs.contains {
            $0.lowercased().hasPrefix("http://")
        } ? "true" : "false"
        environment["CATVOD_IDLE_MS"] = "15000"
        environment["CATVOD_MAX_SESSIONS"] = "1"
        process.environment = environment

        let waiter = GatewayStartupWaiter(
            maximumOutputBytes: Self.maximumStartupOutputBytes
        )
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                waiter.fail(EmbeddedSpiderGatewayError.exitedBeforeStartup)
            } else {
                waiter.consume(data)
            }
        }
        process.terminationHandler = { process in
            waiter.fail(EmbeddedSpiderGatewayError.exitedBeforeStartup)
            Task { @MainActor in
                guard EmbeddedSpiderGateway.shared.process === process else { return }
                SpiderGatewaySettings.useEmbeddedGateway(at: nil)
                EmbeddedSpiderGateway.shared.outputPipe?.fileHandleForReading.readabilityHandler = nil
                EmbeddedSpiderGateway.shared.outputPipe = nil
                EmbeddedSpiderGateway.shared.process = nil
                EmbeddedSpiderGateway.shared.activeAllowedBundleURLs = []
                EmbeddedSpiderGateway.shared.activeGatewayURL = nil
                EmbeddedSpiderGateway.shared.activeAuthenticationToken = nil
            }
        }

        do {
            try process.run()
            try? bootstrapPipe.fileHandleForReading.close()
            defer { try? bootstrapPipe.fileHandleForWriting.close() }
            try bootstrapPipe.fileHandleForWriting.write(contentsOf: bootstrapData)
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            try? bootstrapPipe.fileHandleForReading.close()
            try? bootstrapPipe.fileHandleForWriting.close()
            Self.terminateProcess(process)
            throw EmbeddedSpiderGatewayError.cannotLaunch(error.localizedDescription)
        }
        self.process = process
        activeAllowedBundleURLs = Set(allowedBundleURLs)
        self.outputPipe = outputPipe

        let url = try await waiter.wait(timeoutNanoseconds: 10_000_000_000)
        activeGatewayURL = url
        activeAuthenticationToken = authenticationToken
        SpiderGatewaySettings.useEmbeddedGateway(at: url, token: authenticationToken)
        return url
    }

    private func gatewayCacheDirectory() throws -> URL {
        let root = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("TVBox/SpiderGateway", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

final class GatewayStartupWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumOutputBytes: Int
    private var buffer = Data()
    private var result: Result<String, Error>?
    private var continuation: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?

    init(maximumOutputBytes: Int = EmbeddedSpiderGateway.maximumStartupOutputBytes) {
        self.maximumOutputBytes = max(1, maximumOutputBytes)
    }

    func consume(_ data: Data) {
        finishIfNeeded {
            buffer.append(data)
            guard buffer.count <= maximumOutputBytes else {
                return .failure(
                    EmbeddedSpiderGatewayError.startupOutputTooLarge(maximumOutputBytes)
                )
            }
            guard let output = String(data: buffer, encoding: .utf8),
                  let url = EmbeddedSpiderGateway.listeningURL(in: output) else { return nil }
            return .success(url)
        }
    }

    func fail(_ error: Error) {
        finishIfNeeded { .failure(error) }
    }

    func wait(timeoutNanoseconds: UInt64) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanoseconds)
                        self?.fail(EmbeddedSpiderGatewayError.startupTimedOut)
                    } catch {
                        // The waiter completed before its timeout.
                    }
                }
                lock.lock()
                if let result {
                    lock.unlock()
                    timeoutTask.cancel()
                    continuation.resume(with: result)
                } else {
                    self.continuation = continuation
                    self.timeoutTask = timeoutTask
                    lock.unlock()
                }
            }
        } onCancel: {
            fail(CancellationError())
        }
    }

    private func finishIfNeeded(_ body: () -> Result<String, Error>?) {
        lock.lock()
        guard result == nil, let newResult = body() else {
            lock.unlock()
            return
        }
        result = newResult
        let continuation = continuation
        self.continuation = nil
        let timeoutTask = timeoutTask
        self.timeoutTask = nil
        lock.unlock()
        timeoutTask?.cancel()
        continuation?.resume(with: newResult)
    }
}

enum EmbeddedSpiderGatewayError: LocalizedError {
    case missingResources
    case cannotLaunch(String)
    case exitedBeforeStartup
    case startupTimedOut
    case cannotGenerateAuthenticationToken
    case cannotEncodeBootstrap
    case bootstrapTooLarge(Int)
    case startupOutputTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .missingResources:
            return "App 内置的 Spider 运行组件不完整，请重新安装 App"
        case .cannotLaunch(let message):
            return "无法启动内置 Spider 服务：\(message)"
        case .exitedBeforeStartup:
            return "内置 Spider 服务启动失败"
        case .startupTimedOut:
            return "内置 Spider 服务启动超时"
        case .cannotGenerateAuthenticationToken:
            return "无法为内置 Spider 服务生成安全令牌"
        case .cannotEncodeBootstrap:
            return "无法准备内置 Spider 服务的安全启动配置"
        case .bootstrapTooLarge(let maximumBytes):
            return "内置 Spider 服务的安全启动配置过大（上限 \(maximumBytes / 1024) KB）"
        case .startupOutputTooLarge(let maximumBytes):
            return "内置 Spider 服务启动日志异常过大（上限 \(maximumBytes / 1024) KB）"
        }
    }
}
#endif
