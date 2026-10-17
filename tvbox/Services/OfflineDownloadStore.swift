import Foundation

/// Durable, private media library. CachesDirectory is intentionally avoided:
/// the OS must not evict a movie the user explicitly downloaded for a trip.
struct OfflineDownloadStore {
    static let maximumTasks = 500
    static let maximumIndexBytes = 4 * 1024 * 1024
    let root: URL

    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TVBox/OfflineDownloads", isDirectory: true)
    }

    func load() throws -> [OfflineDownload] {
        let index = root.appendingPathComponent("index.json")
        guard FileManager.default.fileExists(atPath: index.path) else { return [] }
        guard Self.size(index) <= Self.maximumIndexBytes else { throw OfflineDownloadError.storage }
        let tasks = try JSONDecoder().decode([OfflineDownload].self, from: Data(contentsOf: index))
        guard tasks.count <= Self.maximumTasks, Set(tasks.map(\.id)).count == tasks.count,
              tasks.allSatisfy({ $0.localFileName == nil || Self.isLocalMediaName($0.localFileName!) }) else {
            throw OfflineDownloadError.storage
        }
        return tasks
    }

    func save(_ tasks: [OfflineDownload]) throws {
        guard tasks.count <= Self.maximumTasks else { throw OfflineDownloadError.taskLimit }
        let data = try JSONEncoder().encode(tasks)
        guard data.count <= Self.maximumIndexBytes else { throw OfflineDownloadError.tooLarge }
        try Self.makeDirectory(root)
        try Self.writePrivate(data, to: root.appendingPathComponent("index.json"))
    }

    func directory(for id: UUID) throws -> URL {
        try Self.makeDirectory(root)
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try Self.makeDirectory(directory)
        return directory
    }

    func localURL(for task: OfflineDownload) -> URL? {
        guard task.status == .completed, let name = task.localFileName, Self.isLocalMediaName(name) else { return nil }
        let directory = root.appendingPathComponent(task.id.uuidString, isDirectory: true)
        let url = directory.appendingPathComponent(name)
        guard url.resolvingSymlinksInPath().deletingLastPathComponent() == directory.standardizedFileURL,
              Self.size(url) > 0 else { return nil }
        return url
    }

    func remove(_ id: UUID) throws {
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    static func isLocalMediaName(_ name: String) -> Bool {
        ["media.mp4", "media.mkv", "media.flv", "media.ts", "media.mov", "media.webm", "offline.m3u8"].contains(name)
    }

    static func size(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func makeDirectory(_ url: URL) throws {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw OfflineDownloadError.storage }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        var privateURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try privateURL.setResourceValues(values)
    }

    static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
