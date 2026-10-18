import SwiftUI

/// 同一片单保持稳定尺寸；图片失败时仍保留可点击的标题和占位封面。
struct HomeCinemaShelf: View {
    let title: String
    let videos: [Movie.Video]
    var more: (() -> Void)? = nil
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var gridMetrics: PosterGridMetrics {
        PosterGridMetrics(isRegularWidth: horizontalSizeClass == .regular)
    }
    #else
    private let gridMetrics = PosterGridMetrics()
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.system(size: 21, weight: .bold))
                Spacer()
                if let more {
                    Button(action: more) {
                        Label("查看全部", systemImage: "chevron.right")
                            .font(.system(size: 12, weight: .medium))
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("查看全部\(title)")
                }
            }
            .padding(.horizontal, 28)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(videos, id: \.resourceID) { video in
                        NavigationLink(value: video) {
                            HomeCinemaPosterCard(video: video)
                                .frame(width: gridMetrics.shelfPosterWidth)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(video.name + (video.note.isEmpty ? "" : "，\(video.note)"))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 6)
            }
        }
    }
}

private struct HomeCinemaPosterCard: View {
    let video: Movie.Video
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.primary.opacity(0.05)
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay {
                    GeometryReader { geometry in
                        CachedAsyncImage(url: URL.posterURL(from: video.pic)) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Image(systemName: "film")
                                .font(.system(size: 28, weight: .ultraLight))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if !video.note.isEmpty {
                        Text(video.note)
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
                            .padding(8)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.primary.opacity(hovered ? 0.5 : 0.08), lineWidth: hovered ? 2 : 1))
                .scaleEffect(hovered && !reduceMotion ? 1.025 : 1)

            Text(video.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
    }
}

struct HomeCinemaCategoryLabel: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 14, weight: isSelected ? .bold : .medium))
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .overlay(alignment: .bottom) {
                if isSelected {
                    Capsule().fill(.orange).frame(height: 3).padding(.horizontal, 12)
                }
            }
            .contentShape(Rectangle())
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
