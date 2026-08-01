import Foundation
import Network
import Combine

/// 网络连接状态监控器，基于 NWPathMonitor 实时跟踪设备网络可达性。
/// 供 UI 层展示离线提示、以及在网络恢复时触发自动重试。
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()
    
    /// 当前是否有可用网络连接。
    @Published private(set) var isConnected: Bool = true
    /// 当前连接类型描述（Wi-Fi / 蜂窝 / 有线 / 未知）。
    @Published private(set) var connectionType: ConnectionType = .unknown
    
    /// 网络从断开恢复到连接时发送信号，用于触发自动重试。
    let networkRestoredPublisher = PassthroughSubject<Void, Never>()
    
    enum ConnectionType: String {
        case wifi = "Wi-Fi"
        case cellular = "蜂窝"
        case wiredEthernet = "有线"
        case unknown = "未知"
    }
    
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.tvbox.networkmonitor", qos: .utility)
    private var wasDisconnected = false
    
    private init() {
        startMonitoring()
    }
    
    private func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let connected = path.status == .satisfied
                let previouslyConnected = self.isConnected
                
                self.isConnected = connected
                self.connectionType = Self.resolveConnectionType(path)
                
                if connected && !previouslyConnected {
                    self.networkRestoredPublisher.send()
                }
                
                if !connected {
                    self.wasDisconnected = true
                }
            }
        }
        monitor.start(queue: monitorQueue)
    }
    
    private static func resolveConnectionType(_ path: NWPath) -> ConnectionType {
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        if path.usesInterfaceType(.wiredEthernet) { return .wiredEthernet }
        return .unknown
    }
    
    deinit {
        monitor.cancel()
    }
}
