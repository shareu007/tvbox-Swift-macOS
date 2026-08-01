#if os(macOS)
import Foundation

/// 网盘凭据保存在用户 Application Support 私有目录，不进入项目配置或系统钥匙串。
enum CloudDriveCredentialStore {
    static let maximumCredentialBytes = 32 * 1024

    enum Credential: String, CaseIterable {
        case quarkCookie = "quark-cookie"
        case aliToken = "ali-refresh-token"
    }

    private static let fileStore = CloudDriveCredentialFileStore(fileURL: defaultFileURL)

    static func value(for credential: Credential) -> String {
        fileStore.values()[credential.rawValue] ?? ""
    }

    static func save(_ value: String, for credential: Credential) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.lengthOfBytes(using: .utf8) <= maximumCredentialBytes else {
            throw CloudDriveCredentialError.tooLarge(maximumCredentialBytes)
        }
        do {
            try fileStore.save(normalized, forKey: credential.rawValue)
        } catch {
            throw CloudDriveCredentialError.file(error.localizedDescription)
        }
    }

    static var configuredCount: Int {
        let values = fileStore.values()
        return Credential.allCases.reduce(0) {
            $0 + ((values[$1.rawValue] ?? "").isEmpty ? 0 : 1)
        }
    }

    /// 仅传给 App 内置子进程，不进入用户的影视接口配置。
    static var gatewayValues: [String: String] {
        let storedValues = fileStore.values()
        return [
            "aliToken": storedValues[Credential.aliToken.rawValue] ?? "",
            "quarkCookie": storedValues[Credential.quarkCookie.rawValue] ?? ""
        ]
        .filter { !$0.value.isEmpty }
    }

    private static var defaultFileURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("TVBox", isDirectory: true)
            .appendingPathComponent("PrivateConfig", isDirectory: true)
            .appendingPathComponent("cloud-drive-credentials.json")
    }
}

struct CloudDriveCredentialFileStore {
    let fileURL: URL

    func values() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return values
    }

    func save(_ value: String, forKey key: String) throws {
        var storedValues = values()
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            storedValues.removeValue(forKey: key)
        } else {
            storedValues[key] = normalized
        }

        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )

        let data = try JSONEncoder().encode(storedValues)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}

enum CloudDriveCredentialError: LocalizedError {
    case file(String)
    case tooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .file(let message):
            return "无法保存本机网盘凭据：\(message)"
        case .tooLarge(let maximumBytes):
            return "网盘凭据过大（上限 \(maximumBytes / 1024) KB）"
        }
    }
}
#endif
