import SwiftUI

/// 剧集详情的展示层。背景不接收点击，操作按钮由详情页提供。
struct DetailCinemaHeader<Actions: View>: View {
    let info: VodInfo
    let compact: Bool
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: 14) {
                titleAndMetadata(large: false)
                actions()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(28)
        } else {
            GeometryReader { geometry in
                let narrow = geometry.size.width < 600
                ZStack(alignment: .bottomLeading) {
                    DetailCinemaArtwork(pic: info.pic, size: geometry.size, narrow: narrow)
                        .allowsHitTesting(false)
                    VStack(alignment: .leading, spacing: 18) {
                        titleAndMetadata(large: true)
                        if !info.des.stripHTML.isEmpty {
                            Text(info.des.stripHTML)
                                .font(.callout)
                                .lineSpacing(4)
                                .lineLimit(3)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        actions().padding(.top, 6)
                    }
                    .frame(maxWidth: narrow ? .infinity : min(580, geometry.size.width * 0.62), alignment: .leading)
                    .padding(narrow ? 24 : 40)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .background(.black)
                .clipped()
                .environment(\.colorScheme, .dark)
            }
            #if os(iOS)
            .frame(height: 500)
            #else
            .frame(height: 480)
            #endif
        }
    }

    private func titleAndMetadata(large: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(info.name)
                .font(.system(size: large ? 38 : 24, weight: .heavy))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .fixedSize(horizontal: false, vertical: true)
            let metadata = [info.year, info.area, info.typeName, info.note].filter { !$0.isEmpty }
            if !metadata.isEmpty {
                Text(metadata.joined(separator: "  ·  "))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

private struct DetailCinemaArtwork: View {
    let pic: String
    let size: CGSize
    let narrow: Bool

    var body: some View {
        ZStack(alignment: .trailing) {
            Color(hex: "151820")
            artwork
                .frame(width: size.width, height: size.height)
                .blur(radius: 30)
                .opacity(0.45)
                .clipped()
            artwork
                .frame(width: narrow ? size.width : size.width * 0.64, height: size.height, alignment: .top)
                .clipped()
                .mask {
                    LinearGradient(stops: [
                        .init(color: narrow ? .black : .clear, location: 0),
                        .init(color: .black, location: 0.35)
                    ], startPoint: .leading, endPoint: .trailing)
                }
            LinearGradient(colors: [.black.opacity(narrow ? 0.15 : 0.95), .clear],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(0.5), location: 0.45),
                .init(color: .black.opacity(0.95), location: 1)
            ], startPoint: .top, endPoint: .bottom)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .accessibilityHidden(true)
    }

    private var artwork: some View {
        CachedAsyncImage(url: URL.posterURL(from: pic)) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Color.clear
        }
    }
}

struct DetailCinemaActionStyle: ButtonStyle {
    var prominent = false
    var onArtwork = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 18)
            .frame(minHeight: 44)
            .foregroundStyle(prominent && onArtwork ? Color.black : Color.primary)
            .background(background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(prominent ? 0 : 0.2)))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }

    private var background: Color {
        if prominent { return onArtwork ? .white : .orange.opacity(0.2) }
        return onArtwork ? .black.opacity(0.3) : .primary.opacity(0.06)
    }
}

struct DetailCinemaAbout: View {
    let info: VodInfo

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 16) {
                if !info.des.stripHTML.isEmpty {
                    Text(info.des.stripHTML).font(.callout).lineSpacing(5)
                }
                credit("导演", value: info.director)
                credit("演员", value: info.actor)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 16)
        } label: {
            Text("关于本片").font(.headline).foregroundStyle(.primary)
                .frame(minHeight: 44)
        }
        .tint(.secondary)
        .padding(.horizontal, 28)
    }

    @ViewBuilder
    private func credit(_ title: String, value: String) -> some View {
        if !value.isEmpty {
            HStack(alignment: .top, spacing: 14) {
                Text(title).foregroundStyle(.tertiary).frame(width: 36, alignment: .leading)
                Text(value).frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.callout)
        }
    }
}
