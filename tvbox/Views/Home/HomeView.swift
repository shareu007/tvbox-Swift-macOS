import SwiftUI

/// 首页 - 对应 Android 版 HomeActivity + UserFragment
struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel(snapshotStore: .shared)
    @EnvironmentObject var appState: AppState
    @State private var categoryScrollAnchorId: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    // 网格布局
    #if os(iOS)
    private let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 10)
    ]
    #else
    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 16)
    ]
    #endif
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 顶部栏
                headerBar

                if viewModel.isLoadingHome || viewModel.homeLoadMessage != nil {
                    HStack {
                        if viewModel.isLoadingHome { ProgressView().controlSize(.small) }
                        Text(viewModel.homeLoadMessage ?? "正在更新首页…")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if viewModel.isLoadingHome {
                            Button("停止加载") { viewModel.stopHomeLoading() }
                                .font(.caption)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                }
                
                if let message = viewModel.sourceRecoveryMessage {
                    HStack(spacing: 12) {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if !viewModel.isLoading {
                            Button("重试原来源") { Task { await viewModel.retryUnavailableSource() } }
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                }

                // 分类标签栏
                if !viewModel.sorts.isEmpty {
                    categoryTabBar
                }
                if let group = viewModel.selectedCategoryGroup, group.categories.count > 1 {
                    HomeSubcategoryPicker(group: group, selectedID: viewModel.selectedSort?.id) { category in
                        viewModel.selectSort(category)
                    }
                }
                if !viewModel.browseFilters.isEmpty {
                    HomeBrowseFilterBar(filters: viewModel.browseFilters, selections: viewModel.activeFilters) {
                        viewModel.selectFilter(key: $0, value: $1)
                    } clear: {
                        viewModel.clearFilters()
                    }
                }
                if !viewModel.filterScopeMessage.isEmpty {
                    Text(viewModel.filterScopeMessage)
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.bottom, 6)
                }
                
                // 内容区
                contentArea
            }
            .background(AppTheme.primaryGradient)
        }
        .task {
            await viewModel.refreshIfNeeded()
        }
    }
    
    // MARK: - 顶部栏（源选择器）
    
    private var headerBar: some View {
        HStack(spacing: 12) {
            // 源切换按钮
            Menu {
                ForEach(ApiConfig.shared.sourceBeanList.filter { $0.isHomeEligible }) { source in
                    Button {
                        ApiConfig.shared.setHomeSource(source)
                        Task { await viewModel.refresh() }
                    } label: {
                        HStack {
                            Text(source.name)
                            if source.key == ApiConfig.shared.homeSourceBean?.key {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.tv.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.orange)
                    Text(ApiConfig.shared.homeSourceBean?.name ?? "TVBox")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
    
    // MARK: - 分类标签栏
    
    private var categoryTabBar: some View {
        HStack(spacing: 4) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.categoryGroups) { group in
                            Button {
                                viewModel.selectCategoryGroup(group)
                            } label: {
                                BrowseChip(title: group.title, isSelected: viewModel.selectedCategoryGroup?.id == group.id)
                            }
                            .buttonStyle(.plain)
                            .id(group.id)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .onAppear {
                    syncCategoryScrollAnchorIfNeeded()
                    scrollCategoryBar(to: categoryScrollAnchorId, proxy: proxy, animated: false)
                }
                .onChange(of: viewModel.categoryGroups.map(\.id)) { oldValue, newValue in
                    syncCategoryScrollAnchorIfNeeded()
                    scrollCategoryBar(to: categoryScrollAnchorId, proxy: proxy, animated: false)
                }
                .onChange(of: viewModel.selectedCategoryGroup?.id) { oldId, newId in
                    guard let newId else { return }
                    categoryScrollAnchorId = newId
                    scrollCategoryBar(to: newId, proxy: proxy)
                }
            }
            Menu {
                ForEach(viewModel.categoryGroups) { group in
                    Button { viewModel.selectCategoryGroup(group) } label: {
                        if viewModel.selectedCategoryGroup?.id == group.id {
                            Label(group.title, systemImage: "checkmark")
                        } else { Text(group.title) }
                    }
                }
            } label: {
                Image(systemName: "square.grid.2x2")
                    .foregroundStyle(.orange)
                    .frame(width: 44, height: 44)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("全部分类")
            .padding(.trailing, 12)
        }
        .padding(.bottom, 4)
    }

    private func syncCategoryScrollAnchorIfNeeded() {
        let groups = viewModel.categoryGroups
        guard !groups.isEmpty else {
            categoryScrollAnchorId = nil
            return
        }
        if let selectedID = viewModel.selectedCategoryGroup?.id {
            categoryScrollAnchorId = selectedID
        } else if !groups.contains(where: { $0.id == categoryScrollAnchorId }) {
            categoryScrollAnchorId = groups.first?.id
        }
    }

    private func scrollCategoryBar(to id: String?, proxy: ScrollViewProxy, animated: Bool = true) {
        guard let id else { return }
        
        if animated && !reduceMotion {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(id, anchor: .center)
            }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }
    
    // MARK: - 内容区
    
    private var contentArea: some View {
        Group {
            if viewModel.isLoading && viewModel.displayedVideos.isEmpty {
                ScrollView {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在加载\(viewModel.selectedSort?.name ?? "分类")…").font(.callout)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(0..<8) { _ in
                            VodCardView(video: Movie.Video(name: "正在加载"))
                                .redacted(reason: .placeholder)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(20)
                }
            } else if viewModel.selectedSort?.isRecommendation == true, viewModel.errorMessage == nil {
                recommendationContent
            } else if let error = viewModel.errorMessage,
                      viewModel.selectedSort?.isRecommendation == false
                        ? viewModel.categoryVideos.isEmpty
                        : viewModel.homeVideos.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    
                    // 如果是不支持的源类型，显示类型信息
                    if let source = ApiConfig.shared.homeSourceBean, !source.isSupportedInSwift {
                        Text("当前源类型: \(source.typeDescription)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Button("重试") {
                        Task { await viewModel.refresh() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    Spacer()
                }
            } else if viewModel.selectedSort?.isRecommendation == false,
                      !viewModel.isLoading,
                      viewModel.errorMessage == nil,
                      viewModel.categoryVideos.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "film.stack")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text(viewModel.activeFilters.isEmpty ? "该分类暂无内容" : "暂无符合筛选条件的影片")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Button("重新加载") {
                        Task { await viewModel.refresh() }
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
            } else {
                let videos = viewModel.displayedVideos
                
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(videos) { video in
                            NavigationLink(value: video) {
                                VodCardView(video: video)
                            }
                            #if os(iOS)
                            .buttonStyle(VodCardPressStyle())
                            #else
                            .buttonStyle(.plain)
                            #endif
                            .onAppear {
                                Task { await viewModel.loadMoreIfNeeded(currentItem: video) }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    
                    if videos.isEmpty, !viewModel.isLoading, !viewModel.activeFilters.isEmpty {
                        VStack(spacing: 10) {
                            Text("已加载内容中暂无符合条件的影片").foregroundStyle(.secondary)
                            Button("重置筛选") { viewModel.clearFilters() }
                        }.padding()
                    }

                    // 加载更多
                    if viewModel.selectedSort?.isRecommendation != true {
                        if viewModel.isLoading {
                            ProgressView("加载更多…").padding()
                        } else if let error = viewModel.errorMessage {
                            VStack(spacing: 8) {
                                Text(error).font(.caption).foregroundStyle(.secondary)
                                Button("重试加载更多") { Task { await viewModel.retryCategoryPage() } }
                            }.padding()
                        } else if !viewModel.hasMore {
                            Text("已显示全部内容").font(.caption).foregroundStyle(.secondary).padding()
                        } else {
                            Button("加载更多") { Task { await viewModel.loadMore() } }.padding()
                        }
                    }
                }
                .id(viewModel.selectedSort?.id)
                .refreshable {
                    await viewModel.refresh()
                }
            }
        }
        .navigationDestination(for: Movie.Video.self) { video in
            DetailView(video: video)
        }
    }

    private var recommendationContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("发现好故事", systemImage: "sparkles")
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                        Spacer()
                        Button { Task { await viewModel.refresh() } } label: {
                            Label("刷新推荐", systemImage: "arrow.clockwise")
                                .font(.caption)
                                .frame(minHeight: 44)
                        }
                        .disabled(viewModel.isLoading || viewModel.isLoadingRecommendations)
                    }
                    Text("\(viewModel.displayedVideos.count) 部影片 · 按分类发现更多内容")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("热门内容按当前来源的热度排序；推荐不代表已验证可播放。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)

                if !viewModel.filteredHomeVideos.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("来源精选", systemImage: "star.fill")
                            .font(.headline).foregroundStyle(.white)
                            .padding(.horizontal, 20)
                        HomeRecommendationCards(videos: viewModel.filteredHomeVideos)
                    }
                }

                ForEach(viewModel.visibleRecommendationSections) { section in
                    HomeRecommendationSectionView(section: section) {
                        viewModel.openRecommendation(section)
                    } retry: {
                        Task { await viewModel.loadRecommendations() }
                    }
                }

                if viewModel.isLoadingRecommendations {
                    ProgressView("正在补充推荐内容…")
                        .frame(maxWidth: .infinity).padding()
                } else if viewModel.displayedVideos.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "film.stack").font(.largeTitle)
                        Text(viewModel.activeFilters.isEmpty ? "当前来源暂无推荐内容" : "暂无符合筛选条件的推荐")
                        if !viewModel.activeFilters.isEmpty {
                            Button("重置筛选") { viewModel.clearFilters() }
                        }
                        Text("可调整筛选、进入分类查看更多，或切换其他来源。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(24)
                }
            }
            .padding(.vertical, 16)
        }
        .refreshable { await viewModel.refresh() }
    }

}

struct HomeRecommendationSectionView: View {
    let section: HomeRecommendationSection
    let more: () -> Void
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Label(section.title, systemImage: section.isPopular ? "flame.fill" : "film.stack")
                        .font(.headline).foregroundStyle(section.isPopular ? .orange : .white)
                    Text(section.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button(action: more) {
                    Label("更多", systemImage: "chevron.right").font(.subheadline)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain).foregroundStyle(.orange)
                .accessibilityLabel("更多\(section.title)")
            }
            .padding(.horizontal, 20)
            if !section.videos.isEmpty {
                HomeRecommendationCards(videos: section.videos)
            } else if section.isLoading {
                ProgressView("正在加载\(section.sort.name)…")
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else if section.errorMessage == nil {
                Text("暂无匹配的推荐，可调整筛选或点击更多浏览")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20)
            }
            if let error = section.errorMessage {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("重试", action: retry).frame(minHeight: 44)
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

private struct HomeRecommendationCards: View {
    let videos: [Movie.Video]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(videos, id: \.resourceID) { video in
                    NavigationLink(value: video) {
                        VodCardView(video: video)
                            .frame(width: 140)
                    }
                    #if os(iOS)
                    .buttonStyle(VodCardPressStyle())
                    #else
                    .buttonStyle(.plain)
                    #endif
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
        }
    }
}

struct HomeBrowseFilterBar: View {
    let filters: [MovieSort.SortFilter]
    let selections: [String: String]
    let select: (String, String) -> Void
    let clear: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(filters, id: \.key) { filter in
                    let selected = selections[filter.key] ?? ""
                    let label = filter.values.first { $0.v == selected }?.n ?? (filter.values.isEmpty ? "暂无选项" : "全部")
                    Menu {
                        Picker(filter.name, selection: Binding(
                            get: { selections[filter.key] ?? "" },
                            set: { select(filter.key, $0) }
                        )) {
                            if !filter.values.contains(where: { $0.v.isEmpty }) {
                                Text("全部").tag("")
                            }
                            ForEach(filter.values, id: \.v) { Text($0.n).tag($0.v) }
                        }
                    } label: {
                        BrowseChip(title: "\(filter.name) · \(label)", icon: "line.3.horizontal.decrease", isSelected: !selected.isEmpty)
                    }
                    .menuStyle(.borderlessButton)
                    .disabled(filter.values.isEmpty)
                    .accessibilityLabel("\(filter.name)：\(label)")
                }
                if !selections.isEmpty {
                    Button("重置", action: clear)
                        .buttonStyle(.plain).foregroundStyle(.orange)
                        .frame(minHeight: 44)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 4)
    }
}


struct HomeSubcategoryPicker: View {
    let group: HomeCategoryGroup
    let selectedID: String?
    let select: (MovieSort.SortData) -> Void

    var body: some View {
        HStack {
            Menu {
                Picker("\(group.title)分类", selection: Binding(
                    get: { selectedID ?? "" },
                    set: { id in
                        if let category = group.categories.first(where: { $0.id == id }) { select(category) }
                    }
                )) {
                    ForEach(group.categories) { category in
                        Text(category.name).tag(category.id)
                    }
                }
            } label: {
                let name = group.categories.first { $0.id == selectedID }?.name ?? "选择分类"
                BrowseChip(title: "\(group.title)分类 · \(name)", icon: "square.grid.2x2", isSelected: true)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("\(group.title)分类")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }
}
