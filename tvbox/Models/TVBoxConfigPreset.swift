import Foundation

/// TVBox 配置入口。真实接口从不入库的 Config/Local/TVBoxPresets.json 加载。
struct TVBoxConfigPreset: Identifiable, Hashable, Codable {
    enum Compatibility: String, Codable {
        case native = "原生可用"
        case mixed = "部分兼容"
        case externalRuntime = "需额外运行时"
        case unavailable = "当前不可用"

        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            // 兼容早期本机预设使用的描述；语义等同于 macOS 原生可用。
            if value == "macOS 原生运行" {
                self = .native
                return
            }
            guard let compatibility = Self(rawValue: value) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "未知的配置兼容性：\(value)"
                )
            }
            self = compatibility
        }

        var isSelectable: Bool {
            self == .native || self == .mixed
        }
    }

    let id: String
    let name: String
    let url: String
    let compatibility: Compatibility
    let note: String

    static let all: [TVBoxConfigPreset] = {
        guard let url = Bundle.main.url(forResource: "TVBoxPresets", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return []
        }
        return decode(from: data)
    }()

    static func decode(from data: Data) -> [TVBoxConfigPreset] {
        guard let values = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        let decoder = JSONDecoder()
        return values.compactMap { value in
            guard JSONSerialization.isValidJSONObject(value),
                  let item = try? JSONSerialization.data(withJSONObject: value) else {
                return nil
            }
            return try? decoder.decode(TVBoxConfigPreset.self, from: item)
        }
    }
}
