import Foundation

/// 可能包含账号、签名参数或 Bearer Token 的设置不写入 UserDefaults。
/// 文件只对当前用户开放，并在 iOS 上启用数据保护。
enum PrivateSettingsStore {
    enum Key: String {
        case vodURL = "vod-url"
        case liveURL = "live-url"
        case spiderGatewayURL = "spider-gateway-url"
        case spiderGatewayToken = "spider-gateway-token"
    }

    private static let lock = NSLock()
    private static let fileStore = PrivateSettingsFileStore(fileURL: defaultFileURL)

    static func value(for key: Key, migratingLegacyKey legacyKey: String? = nil) -> String {
        lock.lock()
        defer { lock.unlock() }

        if let stored = fileStore.values()[key.rawValue] {
            return stored
        }
        guard let legacyKey,
              let legacy = UserDefaults.standard.string(forKey: legacyKey),
              !legacy.isEmpty else { return "" }

        // 只有安全文件写入成功后才删除旧值，避免升级过程丢失配置。
        if (try? fileStore.save(legacy, forKey: key.rawValue)) != nil {
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
        return legacy
    }

    static func save(_ value: String, for key: Key, legacyKey: String? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        try fileStore.save(value, forKey: key.rawValue)
        if let legacyKey {
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
    }

    private static var defaultFileURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("TVBox", isDirectory: true)
            .appendingPathComponent("PrivateConfig", isDirectory: true)
            .appendingPathComponent("private-settings.json")
    }
}

struct PrivateSettingsFileStore {
    static let maximumFileBytes = 256 * 1024
    static let maximumValueBytes = 64 * 1024

    let fileURL: URL

    func values() -> [String: String] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.intValue <= Self.maximumFileBytes,
              let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return [:]
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.maximumFileBytes + 1),
              data.count <= Self.maximumFileBytes,
              let result = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return result
    }

    func save(_ value: String, forKey key: String) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.lengthOfBytes(using: .utf8) <= Self.maximumValueBytes else {
            throw PrivateSettingsError.valueTooLarge(Self.maximumValueBytes)
        }

        var storedValues = values()
        if normalized.isEmpty {
            storedValues.removeValue(forKey: key)
        } else {
            storedValues[key] = normalized
        }

        let data = try JSONEncoder().encode(storedValues)
        guard data.count <= Self.maximumFileBytes else {
            throw PrivateSettingsError.fileTooLarge(Self.maximumFileBytes)
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
        try data.write(to: fileURL, options: .atomic)

        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try FileManager.default.setAttributes(attributes, ofItemAtPath: fileURL.path)
    }
}

enum PrivateSettingsError: LocalizedError {
    case valueTooLarge(Int)
    case fileTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .valueTooLarge(let maximumBytes):
            return "私密设置过大（单项上限 \(maximumBytes / 1024) KB）"
        case .fileTooLarge(let maximumBytes):
            return "私密设置文件过大（上限 \(maximumBytes / 1024) KB）"
        }
    }
}
