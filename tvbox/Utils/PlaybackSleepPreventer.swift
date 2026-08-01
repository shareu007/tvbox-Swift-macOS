import Foundation

#if os(macOS)
/// 播放期间阻止 macOS 因空闲而关闭显示器或进入系统睡眠。
/// 使用 owner 引用计数，兼容内联/全屏播放器短暂并存的切换过程。
@MainActor
final class PlaybackSleepPreventer {
    static let shared = PlaybackSleepPreventer()

    private var activeOwners: Set<UUID> = []
    private var activity: (any NSObjectProtocol)?

    var activeOwnerCount: Int { activeOwners.count }
    var isPreventingSleep: Bool { activity != nil }

    private init() {}

    func setPlaybackActive(_ active: Bool, owner: UUID) {
        if active {
            activeOwners.insert(owner)
        } else {
            activeOwners.remove(owner)
        }
        updateActivity()
    }

    func end(owner: UUID) {
        activeOwners.remove(owner)
        updateActivity()
    }

    private func updateActivity() {
        if activeOwners.isEmpty {
            if let activity {
                ProcessInfo.processInfo.endActivity(activity)
                self.activity = nil
            }
            return
        }

        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleDisplaySleepDisabled],
            reason: "TVBox 正在播放视频"
        )
    }
}
#endif
