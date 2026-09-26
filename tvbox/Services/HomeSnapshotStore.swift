import Foundation

/// Private, bounded cache of unfiltered homepages. Full source identity prevents cross-config reuse.
@MainActor
final class HomeSnapshotStore {
    struct Snapshot: Codable {
        let source: SourceBean
        let sorts: [MovieSort.SortData]
        let videos: [Movie.Video]
        let sections: [HomeRecommendationSection]
        let savedAt: Date
    }

    static let shared = HomeSnapshotStore(fileURL: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("TVBox/HomeSnapshots.json"))
    private let fileURL: URL?
    private var snapshots: [Snapshot]

    /// nil uses an isolated in-memory store, including in tests.
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL), data.count <= 4 * 1024 * 1024,
           let saved = try? JSONDecoder().decode([Snapshot].self, from: data) {
            snapshots = Array(saved.prefix(5))
        } else { snapshots = [] }
    }

    func snapshot(for source: SourceBean) -> Snapshot? {
        snapshots.first { $0.source == source && Date().timeIntervalSince($0.savedAt) < 24 * 3600 }
    }

    func save(source: SourceBean, sorts: [MovieSort.SortData], videos: [Movie.Video], sections: [HomeRecommendationSection]) {
        guard !videos.isEmpty || sections.contains(where: { !$0.videos.isEmpty }) else { return }
        let sections = sections.map { section in
            var section = section
            section.isLoading = false
            section.errorMessage = nil
            return section
        }
        snapshots.removeAll { $0.source == source }
        snapshots.insert(.init(source: source, sorts: sorts, videos: Array(videos.prefix(100)), sections: sections, savedAt: Date()), at: 0)
        snapshots = Array(snapshots.prefix(5))
        guard let fileURL, let data = try? JSONEncoder().encode(snapshots), data.count <= 4 * 1024 * 1024 else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
