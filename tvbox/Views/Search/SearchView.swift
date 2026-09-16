import SwiftUI

/// 搜索页 - 对应 Android 版 SearchActivity
struct SearchView: View {
    /// 搜索状态与结果管理。
    @StateObject private var viewModel = SearchViewModel()
    @StateObject private var resourceChecks = ResourceListViewModel()
    @State private var onlyPlayable = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    #if os(iOS)
    /// iOS 卡片网格参数。
    private let columns = [
        GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 12)
    ]
    #else
    /// macOS 卡片网格参数。
    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 16)
    ]
    #endif
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 搜索栏
                searchBar
                
                // 内容
                if !viewModel.results.isEmpty {
                    searchResults
                } else if viewModel.isSearching {
                    Spacer()
                    ProgressView("正在搜索影视与网盘资源…")
                        .tint(.orange)
                    Text("网盘资源通常需要 10–20 秒")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 8)
                    Spacer()
                } else if viewModel.keyword.isEmpty {
                    // 输入为空时显示历史；输入非空但无结果时显示提示文案。
                    searchHistorySection
                } else if let error = viewModel.errorMessage {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.largeTitle)
                            .foregroundColor(.gray)
                        Text(error)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
            .background(Color(red: 0.08, green: 0.08, blue: 0.1))
            .navigationTitle("搜索")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .onDisappear {
            viewModel.cancelSearch()
            resourceChecks.cancelChecking()
        }
        .onChange(of: viewModel.isSearching) { _, searching in
            if searching { resourceChecks.cancelChecking() }
            else if onlyPlayable { resourceChecks.startChecking(viewModel.results) }
        }
        .onChange(of: viewModel.results.map(\.resourceID)) { _, _ in
            resourceChecks.retainResults(viewModel.results)
        }
    }
    
    // MARK: - 搜索栏
    
    /// 顶部搜索输入区。
    private var searchBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
                
                TextField("搜索影片...", text: $viewModel.keyword)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .foregroundColor(.white)
                    .submitLabel(.search)
                    .onSubmit {
                        viewModel.submitSearch()
                    }
                    #if os(iOS)
                    .autocapitalization(.none)
                    #endif
                
                if !viewModel.keyword.isEmpty {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                            viewModel.clearSearch()
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.05))
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(LinearGradient(colors: [.orange.opacity(0.5), .clear], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            )
            
            Button {
                viewModel.submitSearch()
            } label: {
                Text("搜索")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(LinearGradient(colors: [.orange, .red], startPoint: .leading, endPoint: .trailing))
                    .cornerRadius(14)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 10)
    }
    
    // MARK: - 搜索结果
    
    /// 搜索结果网格。
    private var searchResults: some View {
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            searchResultsContent
        }
    }

    private var searchResultsContent: some View {
        VStack(spacing: 0) {
            if viewModel.isSearching {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在补充更多来源及网盘资源…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    let groups = resourceChecks.sortedGroups(viewModel.filteredGroups, kind: viewModel.resourceKind,
                        cloudSourceKeys: Set(ApiConfig.shared.sourceBeanList.filter(\.isSearchOnly).map(\.key))).filter { group in
                        !onlyPlayable || playableCount(in: group) > 0
                    }
                    Text("\(groups.count) 部影视 · \(groups.reduce(0) { $0 + $1.resources.count }) 个资源")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("同一剧目的来源已汇总，抽检可用优先，检查未通过的排在最后。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    availabilityControls
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(ResourceKindFilter.allCases) { kind in
                                Button { viewModel.resourceKind = kind } label: {
                                    BrowseChip(title: kind.rawValue, icon: kind.icon, isSelected: viewModel.resourceKind == kind)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if groups.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "line.3.horizontal.decrease.circle").font(.largeTitle)
                            Text(resourceChecks.isChecking ? "正在逐个抽检，可用结果会陆续出现…" : (onlyPlayable ? "尚无抽检通过的资源，可检查资源或查看待确认来源" : "当前没有这类资源"))
                            Button("查看全部") {
                                viewModel.resourceKind = .all
                                onlyPlayable = false
                            }
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(groups) { group in
                            NavigationLink(value: group) {
                                VStack(alignment: .leading, spacing: 6) {
                                    VodCardView(video: group.poster)
                                    let count = playableCount(in: group)
                                    Text(count > 0 ? "\(count) 个抽检可用" : "待确认播放")
                                        .font(.caption)
                                        .foregroundStyle(count > 0 ? Color.green : Color.secondary)
                                }
                            }
                            #if os(iOS)
                            .buttonStyle(VodCardPressStyle())
                            #else
                            .buttonStyle(.plain)
                            #endif
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .navigationDestination(for: SearchResultGroup.self) { selected in
            // 慢源补充年份后分组 ID 可能变化，通过原始资源继续定位当前剧目。
            let current = viewModel.groupedResults.first {
                $0.resources.contains { $0.resourceID == selected.resources.first?.resourceID }
            } ?? selected
            ResourceListView(group: current, viewModel: resourceChecks, initialStatus: onlyPlayable ? .playable : .all, initialKind: viewModel.resourceKind)
        }
    }

    private func playableCount(in group: SearchResultGroup) -> Int {
        resourceChecks.playableCount(in: group.resources, kind: viewModel.resourceKind,
                                     cloudSourceKeys: Set(ApiConfig.shared.sourceBeanList.filter(\.isSearchOnly).map(\.key)))
    }

    private var availabilityControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("只看抽检可用", isOn: $onlyPlayable)
                .tint(.orange)
                .onChange(of: onlyPlayable) { _, enabled in
                    if enabled && !viewModel.isSearching { resourceChecks.startChecking(viewModel.results) }
                }
            HStack {
                if resourceChecks.isChecking {
                    ProgressView().controlSize(.small)
                    Text("已检查 \(resourceChecks.completedCount)/\(resourceChecks.totalCount)").font(.caption)
                    Spacer()
                    Button("停止") { resourceChecks.cancelChecking() }
                } else {
                    Text("抽检首集媒体；网盘及特殊解析来源需播放确认")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("检查资源") { resourceChecks.startChecking(viewModel.results, refresh: true) }
                        .disabled(viewModel.isSearching)
                }
            }
            .frame(minHeight: 32)
        }
    }
    
    // MARK: - 搜索历史
    
    /// 搜索历史区域，支持复用历史关键词与一键清空。
    private var searchHistorySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !viewModel.searchHistory.isEmpty {
                HStack {
                    Text("搜索历史")
                        .font(.headline)
                        .foregroundColor(.white)
                    Spacer()
                    Button {
                        viewModel.clearHistory()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                            Text("清空")
                        }
                        .font(.caption)
                        .foregroundColor(.gray)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                
                FlowLayout(spacing: 8) {
                    ForEach(viewModel.searchHistory, id: \.self) { keyword in
                        Button {
                            viewModel.keyword = keyword
                            viewModel.submitSearch()
                        } label: {
                            Text(keyword)
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.8))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Color.white.opacity(0.1))
                                .cornerRadius(16)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
            
            Spacer()
        }
    }
}

/// 流式布局
struct FlowLayout: Layout {
    /// 子项间距。
    var spacing: CGFloat = 8
    
    /// 计算整体尺寸。
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangement(proposal: proposal, subviews: subviews)
        return result.size
    }
    
    /// 按计算结果放置子视图。
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangement(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }
    
    /// 核心排版算法：按最大宽度逐个放置，超宽后自动换行。
    private func arrangement(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0
        
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            maxX = max(maxX, currentX)
        }
        
        return (CGSize(width: maxX, height: currentY + lineHeight), positions)
    }
}
