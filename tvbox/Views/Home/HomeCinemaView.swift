import SwiftUI

/// 首页专用的视觉组件；沿用影片导航，不参与接口请求或播放器事件处理。
struct HomeCinemaHero: View {
    let videos: [Movie.Video]
    @State private var selectedID: String?

    private var featured: [Movie.Video] { Array(videos.prefix(5)) }
    private var selectedIndex: Int {
        featured.firstIndex { $0.resourceID == selectedID } ?? 0
    }

    var body: some View {
        if !featured.isEmpty {
            GeometryReader { geometry in
                let compact = geometry.size.width < 600
                let video = featured[selectedIndex]
                ZStack(alignment: .bottomLeading) {
                    artwork(video, size: geometry.size, compact: compact)
                        .allowsHitTesting(false)

                    VStack(alignment: .leading, spacing: compact ? 14 : 20) {
                        Label("精选放映", systemImage: "sparkle")
                            .font(.system(size: 12, weight: .bold))
                            .tracking(3)
                            .foregroundStyle(Color.orange)

                        Text(video.name)
                            .font(.system(size: compact ? 34 : 50, weight: .heavy))
                            .lineLimit(2)
                            .minimumScaleFactor(0.75)
                            .fixedSize(horizontal: false, vertical: true)

                        if !metadata(video).isEmpty {
                            Text(metadata(video))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white.opacity(0.8))
                                .lineLimit(2)
                        }

                        if !video.des.stripHTML.isEmpty {
                            Text(video.des.stripHTML)
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.75))
                                .lineSpacing(5)
                                .lineLimit(2)
                        }

                        NavigationLink(value: video) {
                            Label("查看影片", systemImage: "play.fill")
                                .font(.system(size: 14, weight: .bold))
                                .padding(.horizontal, 24)
                                .frame(minHeight: 46)
                                .foregroundStyle(Color.black)
                                .background(.white, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("查看\(video.name)")
                        .padding(.top, 4)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: compact ? .infinity : geometry.size.width * 0.49, alignment: .leading)
                    .padding(compact ? 24 : 40)
                    .padding(.bottom, 54)

                    if featured.count > 1 {
                        HStack(spacing: 8) {
                            ForEach(featured.indices, id: \.self) { index in
                                Button {
                                    selectedID = featured[index].resourceID
                                } label: {
                                    Capsule()
                                        .fill(.white.opacity(index == selectedIndex ? 1 : 0.35))
                                        .frame(width: index == selectedIndex ? 24 : 8, height: 3)
                                        .frame(minWidth: 24, minHeight: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("精选 \(index + 1)：\(featured[index].name)")
                                .accessibilityAddTraits(index == selectedIndex ? [.isSelected] : [])
                            }
                            Spacer(minLength: 8)
                            heroArrow("chevron.left", label: "上一部精选") { move(by: -1) }
                            heroArrow("chevron.right", label: "下一部精选") { move(by: 1) }
                        }
                        .padding(.horizontal, compact ? 20 : 36)
                        .padding(.bottom, 16)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            #if os(iOS)
            .frame(height: 490)
            #else
            .frame(height: 480)
            #endif
            .padding(.horizontal, 24)
            .accessibilityElement(children: .contain)
        }
    }

    private func artwork(_ video: Movie.Video, size: CGSize, compact: Bool) -> some View {
        ZStack(alignment: .trailing) {
            Color(hex: "121418")
            CachedAsyncImage(url: URL.posterURL(from: video.pic)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                LinearGradient(colors: [Color(hex: "252D3A"), .black], startPoint: .topTrailing, endPoint: .bottomLeading)
            }
            .frame(width: size.width, height: size.height)
            .blur(radius: 32)
            .opacity(0.55)
            .clipped()

            CachedAsyncImage(url: URL.posterURL(from: video.pic)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "film.stack")
                    .font(.system(size: 70, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: compact ? size.width : size.width * 0.65, height: size.height,
                   alignment: .top)
            .clipped()
            .mask {
                LinearGradient(stops: [
                    .init(color: compact ? .black : .clear, location: 0),
                    .init(color: .black, location: 0.3)
                ], startPoint: .leading, endPoint: .trailing)
            }

            LinearGradient(stops: [
                .init(color: .black.opacity(compact ? 0.15 : 0.98), location: 0),
                .init(color: .black.opacity(compact ? 0.1 : 0.8), location: 0.32),
                .init(color: .clear, location: 0.85)
            ], startPoint: .leading, endPoint: .trailing)

            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(compact ? 0.55 : 0.1), location: 0.35),
                .init(color: .black.opacity(0.95), location: 1)
            ], startPoint: .top, endPoint: .bottom)
        }
        .id(video.resourceID)
        .frame(width: size.width, height: size.height)
        .clipped()
        .accessibilityHidden(true)
    }

    private func metadata(_ video: Movie.Video) -> String {
        [video.year, video.area, video.type, video.note]
            .filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }

    private func heroArrow(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.25), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.3)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func move(by offset: Int) {
        selectedID = featured[(selectedIndex + offset + featured.count) % featured.count].resourceID
    }
}

/// 同一片单保持稳定尺寸；图片失败时仍保留可点击的标题和占位封面。
struct HomeCinemaShelf: View {
    let title: String
    let videos: [Movie.Video]
    var more: (() -> Void)? = nil

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
                                #if os(iOS)
                                .frame(width: 136)
                                #else
                                .frame(width: 164)
                                #endif
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
