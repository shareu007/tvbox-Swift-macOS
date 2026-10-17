import Foundation

/// Rewrites a finite HLS playlist into a self-contained local package. Unknown
/// URI-bearing tags are rejected, so offline playback cannot fetch remote media.
enum OfflineHLSPlaylist {
    struct Asset {
        enum Kind { case segment, initialization, key }
        let url: URL
        let name: String
        let kind: Kind
    }
    struct Plan {
        let manifest: String
        let assets: [Asset]
        var fingerprint: String {
            OfflineDownload.digest(manifest + assets.map { "\n\($0.url.absoluteString)" }.joined())
        }
    }
    enum Parsed { case variant(URL), media(Plan) }

    static let maximumPlaylistBytes: Int64 = 2 * 1024 * 1024

    static func parse(_ data: Data, baseURL: URL) throws -> Parsed {
        guard data.count <= maximumPlaylistBytes, let text = String(data: data, encoding: .utf8) else {
            throw OfflineDownloadError.invalidResponse
        }
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.first == "#EXTM3U" else { throw OfflineDownloadError.notMedia }
        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }) {
            var variants: [(Int64, URL)] = []
            var bandwidth: Int64?
            for line in lines {
                if line.hasPrefix("#EXT-X-MEDIA:") {
                    let fields = attributes(line)
                    if fields["URI"] != nil && ["AUDIO", "VIDEO"].contains(fields["TYPE"] ?? "") {
                        throw OfflineDownloadError.unsupportedHLS("该 HLS 使用独立音视频轨，暂不支持离线下载，请选择直链或其他画质")
                    }
                }
                if line.hasPrefix("#EXT-X-STREAM-INF:") {
                    bandwidth = Int64(attributes(line)["BANDWIDTH"] ?? "") ?? 0
                } else if !line.isEmpty, !line.hasPrefix("#"), let current = bandwidth {
                    variants.append((current, try remoteURL(line, base: baseURL)))
                    bandwidth = nil
                }
            }
            guard let best = variants.max(by: { $0.0 < $1.0 }) else { throw OfflineDownloadError.invalidResponse }
            return .variant(best.1)
        }
        guard lines.contains("#EXT-X-ENDLIST") else {
            throw OfflineDownloadError.unsupportedHLS("该资源是直播或尚未结束的流，暂不支持离线下载")
        }
        var output: [String] = []
        var assets: [Asset] = []
        var hasDuration = false
        var segmentCount = 0
        let retained = ["#EXTM3U", "#EXT-X-VERSION:", "#EXT-X-TARGETDURATION:", "#EXT-X-MEDIA-SEQUENCE:",
                        "#EXT-X-DISCONTINUITY-SEQUENCE:", "#EXT-X-DISCONTINUITY", "#EXT-X-INDEPENDENT-SEGMENTS",
                        "#EXT-X-ENDLIST", "#EXT-X-PLAYLIST-TYPE:"]
        for line in lines where !line.isEmpty {
            if line.hasPrefix("#EXT-X-KEY:") {
                let fields = attributes(line)
                if fields["METHOD"] == "NONE" {
                    output.append("#EXT-X-KEY:METHOD=NONE")
                } else {
                    guard fields["METHOD"] == "AES-128", fields["KEYFORMAT"] == nil || fields["KEYFORMAT"] == "identity",
                          let uri = fields["URI"] else {
                        throw OfflineDownloadError.unsupportedHLS("该资源使用 DRM 或暂不支持的加密格式，无法离线下载")
                    }
                    // FFmpeg applies its local extension allowlist to key URIs
                    // too. A generated .key.ts name opens just this 16-byte key,
                    // while keeping all protocol and extension guards enabled.
                    let name = "asset-\(assets.count).key.ts"
                    assets.append(Asset(url: try remoteURL(uri, base: baseURL), name: name, kind: .key))
                    var key = "#EXT-X-KEY:METHOD=AES-128,URI=\"\(name)\""
                    if let iv = fields["IV"] {
                        guard iv.hasPrefix("0x"), iv.count == 34,
                              iv.dropFirst(2).allSatisfy({ $0.isHexDigit }) else { throw OfflineDownloadError.invalidResponse }
                        key += ",IV=\(iv)"
                    }
                    output.append(key)
                }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let fields = attributes(line)
                guard fields["BYTERANGE"] == nil, let uri = fields["URI"] else {
                    throw OfflineDownloadError.unsupportedHLS("该 HLS 使用字节范围片段，暂不支持离线下载，请更换线路")
                }
                let name = "asset-\(assets.count).mp4"
                assets.append(Asset(url: try remoteURL(uri, base: baseURL), name: name, kind: .initialization))
                output.append("#EXT-X-MAP:URI=\"\(name)\"")
            } else if line.hasPrefix("#EXTINF:") {
                let duration = line.dropFirst(8).split(separator: ",", omittingEmptySubsequences: false).first ?? ""
                guard let seconds = Double(duration), seconds.isFinite, seconds > 0, !hasDuration else {
                    throw OfflineDownloadError.invalidResponse
                }
                output.append("#EXTINF:\(duration),")
                hasDuration = true
            } else if !line.hasPrefix("#") {
                guard hasDuration else { throw OfflineDownloadError.invalidResponse }
                let remote = try remoteURL(line, base: baseURL)
                let suffix = remote.pathExtension.lowercased() == "m4s" ? "m4s" : "ts"
                let name = "asset-\(assets.count).\(suffix)"
                assets.append(Asset(url: remote, name: name, kind: .segment))
                output.append(name)
                hasDuration = false
                segmentCount += 1
            } else if retained.contains(where: { $0.hasSuffix(":") ? line.hasPrefix($0) : line == $0 }) {
                output.append(line)
            } else if ["#EXT-X-BYTERANGE:", "#EXT-X-GAP", "#EXT-X-DEFINE:", "#EXT-X-PART:", "#EXT-X-SESSION-KEY:"].contains(where: line.hasPrefix)
                        || line.contains("URI=") {
                throw OfflineDownloadError.unsupportedHLS("该 HLS 包含暂不支持的扩展，请选择其他线路下载")
            }
            guard assets.count <= 20000 else { throw OfflineDownloadError.tooLarge }
        }
        guard !hasDuration, segmentCount > 0 else { throw OfflineDownloadError.invalidResponse }
        return .media(Plan(manifest: output.joined(separator: "\n") + "\n", assets: assets))
    }

    static func remoteURL(_ reference: String, base: URL) throws -> URL {
        guard !reference.contains("{$"), let url = URL(string: reference, relativeTo: base)?.absoluteURL,
              SourceSubtitleParser.isRemoteURL(url),
              !(base.scheme?.lowercased() == "https" && url.scheme?.lowercased() == "http") else {
            throw OfflineDownloadError.invalidURL
        }
        return url
    }

    private static func attributes(_ line: String) -> [String: String] {
        guard let colon = line.firstIndex(of: ":") else { return [:] }
        let fields = String(line[line.index(after: colon)...])
        let regex = try! NSRegularExpression(pattern: #"([A-Z0-9-]+)=(?:"([^"]*)"|([^,]*))(?:,|$)"#)
        var result: [String: String] = [:]
        for match in regex.matches(in: fields, range: NSRange(fields.startIndex..., in: fields)) {
            guard let keyRange = Range(match.range(at: 1), in: fields),
                  let valueRange = Range(match.range(at: match.range(at: 2).location == NSNotFound ? 3 : 2), in: fields) else { continue }
            result[String(fields[keyRange])] = String(fields[valueRange])
        }
        return result
    }
}
