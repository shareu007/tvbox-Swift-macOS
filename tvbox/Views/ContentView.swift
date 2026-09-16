import SwiftUI

/// 根视图 - 对应 Android 版 HomeActivity 的 TabView 导航
struct ContentView: View {
    /// 首次配置页点击“最近使用”时，当前要写入的输入框目标。
    private enum ApiInputTarget {
        case vod
        case live
    }
    
    /// 全局状态（配置加载、分栏状态等）。
    @EnvironmentObject var appState: AppState
    /// 网络连接状态。
    @EnvironmentObject var networkMonitor: NetworkMonitor
    /// 设置页 ViewModel。根视图复用它处理首次配置与多仓库选择。
    @StateObject private var settingsVM = SettingsViewModel()
    /// 当前主标签索引。
    @State private var selectedTab = 0
    /// 已配置用户主动修改接口时显示输入页。
    @State private var showSetup = false
    /// 首次配置页历史回填目标输入框。
    @State private var setupInputTarget: ApiInputTarget = .vod
    
    var body: some View {
        Group {
            if appState.shouldShowMainInterface && !showSetup {
                mainTabView
            } else {
                setupView
            }
        }
        .overlay(multiRepoSelectionOverlay)
        .overlay(alignment: .top) {
            networkStatusBanner
        }
        .preferredColorScheme(.dark)
        .task {
            await appState.restoreSavedConfigurationIfNeeded()
        }
    }
    
    @ViewBuilder
    private var multiRepoSelectionOverlay: some View {
        // 若配置地址解析出“多仓库入口”，在根层统一弹窗，避免被子页面导航遮挡。
        if let pending = settingsVM.pendingMultiRepoSelection {
            SelectionModal(
                title: "选择\(pending.target.title)仓库",
                icon: "list.bullet.rectangle.portrait.fill",
                items: pending.options,
                selectedItem: nil,
                itemTitle: { $0.name },
                onSelect: { option in
                    Task {
                        await settingsVM.selectPendingMultiRepoOption(option)
                        if settingsVM.configSuccess {
                            appState.applyLoadedConfigState()
                            showSetup = false
                        }
                    }
                },
                onCancel: {
                    settingsVM.cancelPendingMultiRepoSelection()
                }
            )
        }
    }
    
    // MARK: - 主界面
    
    /// 主体导航容器：iOS 使用 TabView，macOS 使用 NavigationSplitView。
    private var mainTabView: some View {
        #if os(iOS)
        TabView(selection: $selectedTab) {
            configurationContent { HomeView() }
                .tabItem {
                    Label("首页", systemImage: "house.fill")
                }
                .tag(0)
            
            configurationContent {
                LiveView(onExit: { selectedTab = 0 })
            }
                .tabItem {
                    Label("直播", systemImage: "tv.fill")
                }
                .tag(1)
            
            configurationContent { SearchView() }
                .tabItem {
                    Label("搜索", systemImage: "magnifyingglass")
                }
                .tag(2)
            
            ProfileView()
                .tabItem {
                    Label("个人中心", systemImage: "person.fill")
                }
                .tag(3)
        }
        .tint(.orange)
        .onChange(of: selectedTab) { _, _ in
            HapticManager.shared.selection()
        }
        #else
        NavigationSplitView(columnVisibility: $appState.splitViewVisibility) {
            List(selection: $selectedTab) {
                Label("首页", systemImage: "house.fill")
                    .tag(0)
                Label("直播", systemImage: "tv.fill")
                    .tag(1)
                Label("搜索", systemImage: "magnifyingglass")
                    .tag(2)
                Label("收藏", systemImage: "heart.fill")
                    .tag(3)
                Label("历史", systemImage: "clock.fill")
                    .tag(5)
                Label("设置", systemImage: "gearshape.fill")
                    .tag(4)
            }
            .navigationTitle("TVBox")
            .listStyle(.sidebar)
        } detail: {
            switch selectedTab {
            case 0: configurationContent { HomeView() }
            case 1: configurationContent { LiveView() }
            case 2: configurationContent { SearchView() }
            case 3:
                NavigationStack {
                    FavoritesView()
                }
            case 4: SettingsView()
            case 5:
                NavigationStack {
                    HistoryView()
                }
            default: configurationContent { HomeView() }
            }
        }
        #endif
    }
    
    /// 已保存接口的用户先进入主界面，等配置恢复成功再创建依赖来源的页面。
    @ViewBuilder
    private func configurationContent<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if appState.isConfigLoaded {
            content()
        } else {
            ConfigRestoreView(error: appState.configLoadError, isLoading: appState.isLoadingConfig) {
                Task { await appState.retryConfig() }
            } edit: {
                showSetup = true
            }
        }
    }

    // MARK: - 首次配置页面
    
    /// 首次启动或未加载配置时的引导页面。
    private var setupView: some View {
        ZStack {
            // 背景装饰
            AppTheme.primaryGradient
                .ignoresSafeArea()
            
            // 装饰性光晕
            VStack {
                HStack {
                    Circle()
                        .fill(Color.orange.opacity(0.15))
                        .frame(width: 300, height: 300)
                        .blur(radius: 80)
                        .offset(x: -100, y: -100)
                    Spacer()
                }
                Spacer()
                HStack {
                    Spacer()
                    Circle()
                        .fill(Color.red.opacity(0.15))
                        .frame(width: 300, height: 300)
                        .blur(radius: 80)
                        .offset(x: 100, y: 100)
                }
            }
            .ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 32) {
                    if appState.shouldShowMainInterface {
                        Button("返回首页") { showSetup = false }
                            .buttonStyle(.plain).foregroundStyle(.orange)
                            .padding(.top, 20)
                    }
                    // Logo 区域
                    VStack(spacing: 20) {
                        ZStack {
                            Circle()
                                .fill(AppTheme.accentGradient)
                                .frame(width: 100, height: 100)
                                .blur(radius: 20)
                                .opacity(0.5)
                            
                            Image(systemName: "play.tv.fill")
                                .font(.system(size: 80))
                                .foregroundStyle(
                                    AppTheme.accentGradient
                                )
                                .shadow(color: .red.opacity(0.3), radius: 15, x: 0, y: 10)
                        }
                        
                        VStack(spacing: 8) {
                            Text("TVBox")
                                .font(.system(size: 48, weight: .heavy, design: .rounded))
                                .foregroundColor(.white)
                                .tracking(2)
                            
                            Text("极致视听 · 简洁至上")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.6))
                                .tracking(4)
                        }
                    }
                    .padding(.top, 60)
                    
                    // 输入表单
                    VStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("接口配置")
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding(.leading, 4)
                            
                            HStack {
                                Image(systemName: "link")
                                    .foregroundColor(.orange)
                                TextField("请输入点播接口地址 (URL)", text: $settingsVM.vodApiUrl)
                                    .textFieldStyle(.plain)
                                    .foregroundColor(.white)
                                    .onTapGesture {
                                        setupInputTarget = .vod
                                    }
                                    #if os(iOS)
                                    .autocapitalization(.none)
                                    .keyboardType(.URL)
                                    #endif
                                
                                Button {
                                    if let text = readPasteboardText() {
                                        settingsVM.vodApiUrl = text
                                    }
                                } label: {
                                    Image(systemName: "doc.on.clipboard")
                                        .foregroundColor(.orange)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding()
                            .glassCard(cornerRadius: 15)
                            
                            HStack {
                                Image(systemName: "tv")
                                    .foregroundColor(.orange)
                                TextField("请输入直播接口地址 (URL，可留空跟随点播)", text: $settingsVM.liveApiUrl)
                                    .textFieldStyle(.plain)
                                    .foregroundColor(.white)
                                    .onTapGesture {
                                        setupInputTarget = .live
                                    }
                                    #if os(iOS)
                                    .autocapitalization(.none)
                                    .keyboardType(.URL)
                                    #endif
                                
                                Button {
                                    if let text = readPasteboardText() {
                                        settingsVM.liveApiUrl = text
                                    }
                                } label: {
                                    Image(systemName: "doc.on.clipboard")
                                        .foregroundColor(.orange)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding()
                            .glassCard(cornerRadius: 15)
                        }
                        
                        // 确认按钮
                        Button {
                            Task {
                                await settingsVM.loadConfig()
                                if settingsVM.configSuccess {
                                    appState.applyLoadedConfigState()
                                    showSetup = false
                                }
                            }
                        } label: {
                            HStack {
                                if settingsVM.isLoadingConfig {
                                    ProgressView()
                                        .tint(.white)
                                        .padding(.trailing, 8)
                                }
                                Text(settingsVM.isLoadingConfig ? "正在解析配置..." : "开启影音之旅")
                                    .fontWeight(.bold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(AppTheme.accentGradient)
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                            .shadow(color: .red.opacity(0.4), radius: 12, x: 0, y: 6)
                        }
                        .buttonStyle(.plain)
                        .disabled(
                            settingsVM.isLoadingConfig
                            || settingsVM.vodApiUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                        
                        // 历史记录
                        if !settingsVM.apiHistory.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("最近使用")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.5))
                                    .padding(.horizontal, 4)
                                
                                ForEach(settingsVM.apiHistory.prefix(3), id: \.self) { url in
                                    Button {
                                        switch setupInputTarget {
                                        case .vod:
                                            settingsVM.vodApiUrl = url
                                        case .live:
                                            settingsVM.liveApiUrl = url
                                        }
                                    } label: {
                                        HStack {
                                            Image(systemName: "clock.arrow.2.circlepath")
                                                .font(.caption)
                                            Text(SensitiveURLRedactor.redact(url))
                                                .font(.caption)
                                                .lineLimit(1)
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 8))
                                        }
                                        .padding(.vertical, 10)
                                        .padding(.horizontal, 16)
                                        .foregroundColor(.white.opacity(0.7))
                                        .glassCard(cornerRadius: 10)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 30)
                    
                    // 错误提示
                    if let error = settingsVM.configError {
                        HStack {
                            Image(systemName: "exclamationmark.circle.fill")
                            Text(error)
                        }
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding()
                        .glassCard(cornerRadius: 10)
                        .padding(.horizontal, 30)
                    }
                    
                    Spacer(minLength: 50)
                }
            }
        }
    }
    
    /// 网络断开时在顶部显示提示条。
    @ViewBuilder
    private var networkStatusBanner: some View {
        if !networkMonitor.isConnected {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 13, weight: .semibold))
                Text("网络连接已断开")
                    .font(.system(size: 13, weight: .medium))
                if appState.isRetryingConfig {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(.white)
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(Color.red.opacity(0.85))
            )
            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.3), value: networkMonitor.isConnected)
        }
    }
    
    private func readPasteboardText() -> String? {
        #if os(iOS)
        UIPasteboard.general.string
        #else
        // macOS 下通过 NSPasteboard 读取纯文本。
        NSPasteboard.general.string(forType: .string)
        #endif
    }
}


/// 配置恢复状态显示在首页内部，不再短暂展示首次使用表单。
struct ConfigRestoreView: View {
    let error: String?
    let isLoading: Bool
    let retry: () -> Void
    let edit: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: error == nil ? "play.tv.fill" : "wifi.exclamationmark")
                .font(.system(size: 42)).foregroundStyle(.orange)
            if let error, !isLoading {
                Text("暂时无法加载已保存的接口").font(.headline)
                Text(error).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).textSelection(.enabled)
                HStack(spacing: 16) {
                    Button("重试", action: retry).buttonStyle(.borderedProminent).tint(.orange)
                    Button("修改接口", action: edit).buttonStyle(.bordered)
                }
            } else {
                ProgressView("正在加载首页…")
                Text("正在恢复已保存的接口").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.primaryGradient)
    }
}
