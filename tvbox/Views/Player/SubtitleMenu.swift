import SwiftUI

struct SubtitleMenu: View {
    @ObservedObject var state: SubtitleState
    var onSelect: (SubtitleSelection) -> Void

    var body: some View {
        Menu {
            choice("自动（优先中文）", selection: .automatic)
            choice("关闭字幕", selection: .off)
            Divider()
            if state.tracks.isEmpty {
                Text(state.isLoading ? "正在读取字幕轨…" : state.unavailableMessage)
            } else {
                ForEach(state.tracks) { track in
                    choice(track.title, selection: .track(track.id))
                }
                if let current = state.tracks.first(where: { $0.id == state.selectedTrackID }) {
                    Divider()
                    Text("当前：\(current.title)")
                }
            }
        } label: {
            Label("字幕", systemImage: "captions.bubble")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.12))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("字幕")
        .accessibilityIdentifier("player.subtitleMenu")
    }

    private func choice(_ title: String, selection: SubtitleSelection) -> some View {
        Button { onSelect(selection) } label: {
            if state.selection == selection {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}
