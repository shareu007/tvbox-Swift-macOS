import SwiftUI

// MARK: - VodCard Press Style (iOS only)

#if os(iOS)
/// 按压缩放动画样式 - 为 VodCard 提供触觉反馈式的按压效果
struct VodCardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}
#endif

/// 视频卡片组件
struct VodCardView: View {
    /// 卡片对应的视频数据。
    let video: Movie.Video
    /// 悬停状态（主要用于 macOS 悬停放大动效）。
    @State private var isHovered = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 封面图
            ZStack(alignment: .bottomLeading) {
                CachedAsyncImage(url: URL.posterURL(from: video.pic)) { image in
                    image
                        .resizable()
                        .aspectRatio(2/3, contentMode: .fill)
                } placeholder: {
                    placeholderImage
                        .overlay(ProgressView().tint(.white))
                }
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius))
                .shadow(color: .black.opacity(0.4), radius: 8, x: 0, y: 4)
                
                // 底部渐变叠加（用于保护备注文字）
                if !video.note.isEmpty {
                    LinearGradient(
                        colors: [.black.opacity(0.8), .clear],
                        startPoint: .bottom,
                        endPoint: .center
                    )
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardRadius))
                }
                
                // 备注标签
                if !video.note.isEmpty {
                    Text(video.note)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(Color.orange.opacity(0.9))
                        )
                        .padding(8)
                }
            }
            // 悬停缩放只增强视觉反馈，不影响点击命中区域。
            .scaleEffect(isHovered ? 1.05 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
            
            // 标题
            VStack(alignment: .leading, spacing: 2) {
                Text(video.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                
                if !video.type.isEmpty {
                    Text(video.type)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 4)
        }
        #if os(iOS)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        #endif
    }
    
    /// 海报占位图，避免图片加载失败导致卡片高度塌陷。
    private var placeholderImage: some View {
        RoundedRectangle(cornerRadius: AppTheme.cardRadius)
            .fill(Color.white.opacity(0.05))
            .aspectRatio(2/3, contentMode: .fill)
            .overlay(
                Image(systemName: "film.fill")
                    .font(.system(size: 30))
                    .foregroundColor(.white.opacity(0.2))
            )
    }
}
