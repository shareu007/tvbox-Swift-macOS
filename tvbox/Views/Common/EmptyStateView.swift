import SwiftUI

/// 通用空状态组件。
/// 在收藏、历史等页面复用，统一空页面视觉风格。
struct EmptyStateView: View {
    /// SF Symbol 图标名。
    let icon: String
    /// 主标题。
    let title: String
    /// 可选说明文字，为空时不渲染副文案区域。
    var message: String? = nil
    
    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 120, height: 120)
                    .overlay(
                        Circle().stroke(Color.orange.opacity(0.3), lineWidth: 1)
                    )
                
                Image(systemName: icon)
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(
                        LinearGradient(colors: [.orange, .red.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
            }
            .padding(.bottom, 8)
            
            // 标题强调当前页面状态，例如“暂无收藏”“暂无播放记录”。
            Text(title)
                .font(.title3.bold())
                .foregroundColor(.white.opacity(0.9))
                .tracking(1)
            
            // 副文案用于提供下一步引导，不参与核心逻辑判断。
            if let message = message {
                Text(message)
                    .font(.callout)
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .padding(40)
        .glassCard(cornerRadius: 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
