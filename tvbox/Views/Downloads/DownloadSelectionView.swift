import SwiftUI

struct DownloadSelectionView: View {
    let info: VodInfo
    let flag: String
    let selectedIndex: Int
    @ObservedObject var manager: OfflineDownloadManager
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<Int> = []
    @State private var notice: String?
    @State private var added = false

    private var episodes: [VodInfo.Episode] { info.playUrlMap[flag] ?? [] }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(info.name).font(.title2.bold())
                Text("线路：\(flag)").foregroundStyle(.secondary)
                Text("支持直链文件和普通点播 M3U8。网盘资源使用当前登录状态解析；来源不支持下载时会显示原因。")
                    .font(.callout).foregroundStyle(.secondary)
                List(Array(episodes.enumerated()), id: \.offset) { index, episode in
                    Toggle(episode.name, isOn: Binding(
                        get: { selected.contains(index) },
                        set: { if $0 { selected.insert(index) } else { selected.remove(index) } }
                    ))
                }
                HStack {
                    Button(selected.count == episodes.count ? "取消全选" : "全选") {
                        selected = selected.count == episodes.count ? [] : Set(episodes.indices)
                    }
                    Spacer()
                    Button("下载 \(selected.count) 集") { enqueue() }
                        .buttonStyle(.borderedProminent).tint(.orange)
                        .disabled(selected.isEmpty)
                }
            }
            .padding(20)
            .navigationTitle("选择下载剧集")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .onAppear { if episodes.indices.contains(selectedIndex) { selected = [selectedIndex] } }
            .alert(added ? "已加入下载管理" : "无法添加下载", isPresented: Binding(
                get: { notice != nil }, set: { if !$0 { notice = nil; if added { dismiss() } } }
            )) {
                Button("好") { notice = nil; if added { dismiss() } }
            } message: { Text(notice ?? "") }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 420, idealHeight: 520)
        #endif
    }

    private func enqueue() {
        guard let source = ApiConfig.shared.getSource(key: info.sourceKey) else {
            notice = OfflineDownloadError.sourceUnavailable.localizedDescription
            return
        }
        do {
            let requested = selected.sorted().filter { episodes.indices.contains($0) }.map { episodes[$0] }
            try manager.enqueue(info: info, episodes: requested, flag: flag, source: source, configURL: ApiConfig.shared.configUrl)
            added = true
            notice = "可在下载管理中查看进度、暂停或继续，已完成的内容可直接离线播放。"
        } catch { notice = OfflineDownloadError.message(for: error) }
    }
}
