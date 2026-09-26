import Foundation

/// 用户在 App 内成功加载过的点播配置。地址只写入本机私有设置文件。
struct SavedVodConfig: Identifiable, Codable, Hashable {
    enum Compatibility: String, Codable, Equatable {
        case compatible
        case partial
        case incompatible
        case unknown

        var title: String {
            switch self {
            case .compatible: return "协议全部支持"
            case .partial: return "协议部分支持"
            case .incompatible: return "协议暂不支持"
            case .unknown: return "协议未检测"
            }
        }
    }

    let id: UUID
    var name: String
    var url: String
    var configurationProtocol: String
    var sourceProtocols: [String]
    var compatibility: Compatibility
    var supportedSourceCount: Int
    var totalSourceCount: Int
    var protocolCheckedAt: Date?
    var lastUsedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        url: String,
        configurationProtocol: String,
        sourceProtocols: [String] = [],
        compatibility: Compatibility,
        supportedSourceCount: Int = 0,
        totalSourceCount: Int = 0,
        protocolCheckedAt: Date? = nil,
        lastUsedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.configurationProtocol = configurationProtocol
        self.sourceProtocols = sourceProtocols
        self.compatibility = compatibility
        self.supportedSourceCount = supportedSourceCount
        self.totalSourceCount = totalSourceCount
        self.protocolCheckedAt = protocolCheckedAt
        self.lastUsedAt = lastUsedAt
    }

    static func displayName(for urlString: String) -> String {
        guard let host = URLComponents(string: urlString)?.host, !host.isEmpty else {
            return "点播配置"
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func decode(from string: String) -> [SavedVodConfig] {
        guard let data = string.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([SavedVodConfig].self, from: data)) ?? []
    }

    static func encode(_ configs: [SavedVodConfig]) throws -> String {
        let data = try JSONEncoder().encode(configs)
        guard let value = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                configs,
                EncodingError.Context(
                    codingPath: [],
                    debugDescription: "无法编码点播配置列表"
                )
            )
        }
        return value
    }
}

/// 点播配置加载完成后的协议与兼容性报告。
struct VodConfigInspectionResult: Identifiable, Equatable {
    let id = UUID()
    let configurationProtocol: String
    let sourceProtocols: [String]
    let compatibility: SavedVodConfig.Compatibility
    let supportedSourceCount: Int
    let totalSourceCount: Int
    let checkedAt = Date()

    var message: String {
        let sourceProtocolText = sourceProtocols.isEmpty
            ? "未发现点播源协议"
            : sourceProtocols.joined(separator: "、")
        return "配置协议：\(configurationProtocol)\n站点协议：\(sourceProtocolText)\n协议支持：\(supportedSourceCount) / \(totalSourceCount) 个站点（\(compatibility.title)）\n协议检测时间：\(checkedAt.formatted(date: .numeric, time: .shortened))\n\n本次仅检查协议。首页实测：未执行；播放实测：未执行。\n协议支持不代表站点可访问或影片可播放。可在“我的点播配置”中检测首页，播放结果将在实际播放后记录。\n\n该接口已加入“我的点播配置”。"
    }
}
