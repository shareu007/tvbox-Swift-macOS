import Foundation
import CryptoKit

enum OfflineDownloadStatus: String, Codable {
    case queued, preparing, downloading, paused, failed, completed

    var title: String {
        switch self {
        case .queued: return "等待下载"
        case .preparing: return "正在解析"
        case .downloading: return "下载中"
        case .paused: return "已暂停"
        case .failed: return "下载失败"
        case .completed: return "已完成"
        }
    }
}

/// Only the source episode identity is persisted. Resolved signed URLs and HTTP
/// headers are obtained again on resume and never written into the task index.
struct OfflineDownload: Codable, Identifiable {
    let id: UUID
    let sourceKey: String
    let sourceIdentity: String
    let videoID: String
    let title: String
    let flag: String
    let episodeName: String
    let episodeID: String
    let createdAt: Date
    var status: OfflineDownloadStatus = .queued
    var receivedBytes: Int64 = 0
    var totalBytes: Int64?
    var completedSegments = 0
    var totalSegments = 0
    var localFileName: String?
    var errorMessage: String?

    init(info: VodInfo, episode: VodInfo.Episode, flag: String, sourceIdentity: String) {
        id = UUID()
        sourceKey = info.sourceKey
        self.sourceIdentity = sourceIdentity
        videoID = info.id
        title = info.name
        self.flag = flag
        episodeName = episode.name
        episodeID = episode.url
        createdAt = Date()
    }

    var fractionCompleted: Double? {
        if status == .completed { return 1 }
        if totalSegments > 0 { return min(1, Double(completedSegments) / Double(totalSegments)) }
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(receivedBytes) / Double(totalBytes))
    }

    func matches(_ other: OfflineDownload) -> Bool {
        sourceIdentity == other.sourceIdentity && videoID == other.videoID
            && flag == other.flag && episodeID == other.episodeID
    }

    static func identity(configURL: String, source: SourceBean) -> String {
        digest([configURL, source.key, source.api, String(source.type), source.ext ?? "", source.jar ?? ""]
            .map { "\($0.utf8.count):\($0)" }.joined())
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func requestIdentity(url: URL, headers: [String: String]) -> String {
        let fields = SourceSubtitleParser.safeHeaders(headers).map { ($0.key.lowercased(), $0.value) }
            .sorted { $0.0 < $1.0 }.map { "\($0.0):\($0.1)" }.joined(separator: "\n")
        return digest("\(url.absoluteString.utf8.count):\(url.absoluteString)\n\(fields)")
    }
}

struct OfflineDownloadProgress {
    var receivedBytes: Int64
    var totalBytes: Int64?
    var completedSegments = 0
    var totalSegments = 0
}

struct OfflineDownloadOutput {
    let fileName: String
    let receivedBytes: Int64
    var totalSegments = 0
}

enum OfflinePlaybackPolicy {
    static func engine(for url: URL?, preferred: PlayerEngine) -> PlayerEngine {
        // AVPlayer expects its own HLS asset-download format and cannot read
        // several of the other supported containers. Keep explicit mpv / VLC
        // preferences and native MP4 playback unchanged.
        guard let url, url.isFileURL, ["m3u8", "mkv", "webm", "flv", "ts"].contains(url.pathExtension.lowercased()),
              preferred == .system else { return preferred }
        if PlayerEngine.isMPVAvailable { return .mpv }
        if PlayerEngine.isVLCAvailable { return .vlc }
        return preferred
    }
}

enum OfflineDownloadError: LocalizedError {
    case invalidURL, invalidResponse, invalidRange, notMedia, incomplete, tooLarge, taskLimit, storage, sourceUnavailable
    case http(Int)
    case unsupportedHLS(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "该资源没有可直接下载的 HTTP 媒体地址"
        case .invalidResponse, .invalidRange: return "下载服务返回了无效响应，请换线路或重试"
        case .notMedia: return "该地址返回的内容不是可下载的视频"
        case .incomplete: return "下载内容不完整，请重试"
        case .tooLarge: return "下载内容超过支持的大小限制"
        case .taskLimit: return "最多保存 500 个下载任务，请清理旧任务后再添加"
        case .storage: return "无法保存下载，请检查磁盘空间和目录权限"
        case .sourceUnavailable: return "请先切回此任务使用的接口配置，再继续下载"
        case .http(let code):
            if code == 401 || code == 403 { return "媒体授权已失效，请检查登录状态后重试" }
            return "下载服务返回 HTTP \(code)，请重试或更换线路"
        case .unsupportedHLS(let reason): return reason
        }
    }

    static func message(for error: Error) -> String {
        if let error = error as? OfflineDownloadError { return error.localizedDescription }
        if let error = error as? SpiderGatewayError, case .parseNotSupported = error {
            return "该线路需要网页解析，暂无法下载，请选择直连线路"
        }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost: return "网络已断开，恢复连接后可继续下载"
            case .timedOut: return "下载连接超时，请重试"
            default: return "暂时无法连接下载服务，请重试"
            }
        }
        // Foundation / provider errors may contain signed URLs or account data.
        return "下载未完成，请检查网络、磁盘空间或更换线路后重试"
    }
}
