import SwiftUI

/// 优先展示抽检可用资源，同一状态内保留搜索顺序。
struct ResourceListView: View {
    let group: SearchResultGroup
    @ObservedObject var viewModel: ResourceListViewModel
    @State private var refreshID = UUID()
    @State private var lastRefreshID: UUID?
    @State private var kind: ResourceKindFilter = .all
    @State private var status: ResourceStatusFilter = .all

    init(group: SearchResultGroup, viewModel: ResourceListViewModel, initialStatus: ResourceStatusFilter = .all,
         initialKind: ResourceKindFilter = .all) {
        self.group = group
        self.viewModel = viewModel
        _status = State(initialValue: initialStatus)
        _kind = State(initialValue: initialKind)
    }

    private var checkedCount: Int {
        group.resources.filter { viewModel.states[$0.resourceID]?.isComplete == true }.count
    }

    private func visibleResources(at date: Date) -> [Movie.Video] {
        let cloudKeys = Set(ApiConfig.shared.sourceBeanList.filter(\.isSearchOnly).map(\.key))
        return viewModel.sortedResources(group.resources.filter {
            kind.includes($0, cloudSourceKeys: cloudKeys) && status.includes(viewModel.states[$0.resourceID], at: date)
        }, at: date)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            content(at: context.date)
        }
    }

    private func content(at date: Date) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                summary(at: date)
                filters(at: date)
                if visibleResources(at: date).isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "line.3.horizontal.decrease.circle").font(.largeTitle)
                        Text(viewModel.isChecking ? "正在检查，暂时没有符合条件的资源" : "没有符合条件的资源")
                            .multilineTextAlignment(.center)
                        Button("显示全部资源") {
                            kind = .all
                            status = .all
                        }
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                }
                ForEach(visibleResources(at: date), id: \.resourceID) { video in
                    resourceRow(video, at: date)
                }
            }
            .padding(20)
        }
        .background(AppTheme.primaryGradient)
        .navigationTitle(group.title)
        .toolbar {
            if viewModel.isChecking {
                Button("停止检查") { viewModel.cancelChecking() }
            }
            Button { refreshID = UUID() } label: {
                Label("重新检查", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isChecking)
        }
        .task(id: group.resources.map(\.resourceID) + [refreshID.uuidString]) {
            let refresh = lastRefreshID != nil && lastRefreshID != refreshID
            lastRefreshID = refreshID
            viewModel.startChecking(group.resources, refresh: refresh)
        }
        .onDisappear { viewModel.cancelChecking() }
    }

    private func summary(at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("\(group.resources.count) 个资源", systemImage: "square.stack.3d.up")
                    .font(.headline)
                Spacer()
                if !group.year.isEmpty { Text(group.year).foregroundStyle(.secondary) }
            }
            HStack {
                Text("\(group.resources.filter { viewModel.states[$0.resourceID]?.isPlayable(at: date) == true }.count) 个抽检可用")
                    .foregroundStyle(.green)
                Spacer()
                Text("已检查 \(checkedCount)/\(group.resources.count)").foregroundStyle(.secondary)
            }
            .font(.caption)
            ProgressView(value: Double(checkedCount), total: Double(max(1, group.resources.count)))
                .tint(.orange)
                .accessibilityLabel("资源检查进度")
            Text("每个在线资源最多抽检三条线路的首集，不保证整部剧均可播放。网盘及需解析的来源保留目录，待播放器确认。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
    }

    private func filters(at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("只看抽检可用", isOn: Binding(
                get: { status == .playable },
                set: { status = $0 ? .playable : .all }
            ))
            .tint(.orange)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ResourceKindFilter.allCases) { option in
                        Button { kind = option } label: {
                            BrowseChip(title: option.rawValue, icon: option.icon, isSelected: kind == option)
                        }.buttonStyle(.plain)
                    }
                }
            }
            HStack {
                Text("显示 \(visibleResources(at: date).count) 个").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("检查状态", selection: $status) {
                    ForEach(ResourceStatusFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
    }

    @ViewBuilder
    private func resourceRow(_ video: Movie.Video, at date: Date) -> some View {
        let state = viewModel.states[video.resourceID]
        if let info = state?.detail {
            NavigationLink {
                DetailView(video: video, initialInfo: info, initialInfoCheckedAt: state?.checkedAt,
                           preferredPlaybackFlag: state?.isPlayable(at: date) == true ? info.playFlag : nil)
            } label: {
                ResourceRowView(video: video, sourceName: sourceName(video), state: state, date: date)
            }.buttonStyle(.plain)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ResourceRowView(video: video, sourceName: sourceName(video), state: state, date: date)
                if state?.isComplete == true {
                    NavigationLink("打开详情并重试") { DetailView(video: video) }
                        .font(.callout)
                        .frame(minHeight: 44)
                        .padding(.horizontal, 14)
                }
            }
        }
    }

    private func sourceName(_ video: Movie.Video) -> String {
        ApiConfig.shared.getSource(key: video.sourceKey)?.name ?? "来源已移除"
    }
}

struct ResourceRowView: View {
    let video: Movie.Video
    let sourceName: String
    let state: ResourceCheckState?
    var date: Date = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var statusColor: Color {
        if state?.isPlayable(at: date) == true { return .green }
        if state?.detail != nil, state?.playback.isFailure != true { return .secondary }
        return state?.isComplete == true ? .orange : .secondary
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: state?.isPlayable(at: date) == true ? "checkmark.circle.fill" : "play.rectangle")
                .font(.title3)
                .foregroundStyle(statusColor)
                .frame(width: 32, height: 32)
                .background(statusColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 7) {
                Text(sourceName).font(.headline).foregroundStyle(.white)
                Text(video.name).font(.subheadline).foregroundStyle(.white.opacity(0.8)).lineLimit(2)
                if ["夸克网盘", "阿里云盘", "123网盘"].contains(video.note) {
                    Text(video.note).font(.caption).foregroundStyle(.orange)
                }
                Text(state?.label(at: date) ?? "等待检查…")
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: state?.label(at: date))
            }
            Spacer(minLength: 0)
            if state?.detail != nil {
                Image(systemName: "chevron.right").foregroundStyle(.secondary).padding(.top, 8)
            } else if let state, case .checking = state {
                ProgressView().controlSize(.small).padding(.top, 8)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(statusColor.opacity(0.15), lineWidth: 1))
    }
}
