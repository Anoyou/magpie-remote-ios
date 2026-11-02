import SwiftUI
import MagpieRemoteCore

/// 底栏第 5 个「更多」：列出不在底栏里的所有页面（点开都是 App 内原生页面），以及配置引导和「自定义底栏」。
/// 取代原来的「管理」标签页，原来管理页里的入口都还在这里（或在底栏里）。
///
/// 0.6.2 起照 iOS「设置」的样式排：分组圆角列表，每组有标题（主机 · 页面 · 主机工具 · 在网页中打开 · App），
/// 每一行是彩色圆角方块图标 + 名字 + 可选的值 + 右箭头（`SettingsIcon`）。
struct MoreView: View {
    @Environment(AppModel.self) private var model
    @Environment(ManageStore.self) private var store

    private var more: [AppPage] { model.dock.layout.morePages }
    /// 「页面」一组：不在底栏里的页面，按这个顺序。
    private var pages: [AppPage] { [.home, .sessions, .routes, .usage, .chat, .keys, .library, .plugins].filter(more.contains) }
    /// 读到了、而且兼容时的 magpie 版本（其余状态由 ManageStatusSection 单独显示）。
    private var magpieVersion: String? {
        guard store.phase == .ready, store.incompatible == nil else { return nil }
        return store.settings?.version
    }

    var body: some View {
        List {
            if more.contains(.hosts) || magpieVersion != nil {
                Section {
                    if more.contains(.hosts) {
                        MorePageLink(page: .hosts) {
                            Text(model.activeHost?.name ?? "未添加")
                        }
                    }
                    if let magpieVersion {
                        LabeledContent {
                            Text(magpieVersion)
                        } label: {
                            SettingsLabel("magpie 版本", icon: Image(systemName: "bird.fill"), color: .indigo)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("more.magpieVersion")
                    }
                } header: {
                    Text("主机")
                } footer: {
                    if model.isFixture, magpieVersion != nil {
                        Text("示例数据：修改只保存在这次运行里。")
                    }
                }
            }

            ManageStatusSection(store: store, showsVersion: false)

            if !pages.isEmpty {
                Section {
                    ForEach(pages) { page in
                        MorePageLink(page: page) {
                            if let detail = detail(page) { Text(detail) }
                        }
                    }
                } header: {
                    Text("页面")
                } footer: {
                    if pages.contains(.home) {
                        Text("「主页」里是 Agent、供应商与额度；模型的开关在各个供应商里。")
                    }
                }
            }

            if more.contains(.hostTools) {
                if HostTools.service(for: store.service) != nil {
                    HostToolsSection(store: store)
                } else {
                    Section("主机工具") { MorePageLink(page: .hostTools) }
                }
            }

            if more.contains(.web) {
                if store.service != nil {
                    MagpieWebSection(store: store)
                } else {
                    Section("在网页中打开") { MorePageLink(page: .web) }
                }
            }

            Section {
                if more.contains(.about) { MorePageLink(page: .about) }
                NavigationLink {
                    SetupGuideView(showsDone: false)
                } label: {
                    SettingsLabel("配置引导", icon: Image(systemName: "list.number"), color: .green)
                }
                .accessibilityIdentifier("manage.guide")
                NavigationLink {
                    DockCustomizeView()
                } label: {
                    LabeledContent {
                        if !model.dock.layout.isDefault { Text("已自定义") }
                    } label: {
                        SettingsLabel("自定义底栏", icon: Image(systemName: "dock.rectangle"), color: .blue)
                    }
                }
                .accessibilityIdentifier("more.customize")
            } header: {
                Text("App")
            }
        }
        .listStyle(.insetGrouped)
        .pageHeader("更多")
        // 点小组件打开、而对应页面在「更多」里时：直接推入那个页面。
        .navigationDestination(item: Binding(get: { model.morePush }, set: { model.morePush = $0 })) { page in
            AppPageView(page: page)
        }
        .refreshable { await store.refresh() }
        .onAppear { Task { await store.configure(model: model) } }
        .manageAlerts(store: store, id: "more")
    }

    private func detail(_ page: AppPage) -> String? {
        switch page {
        case .routes: store.groups.map { "\($0.visible.count) 个路由组" }
        case .keys: store.phase == .ready ? "\(store.keys.count) 把" : nil
        default: nil
        }
    }
}

/// 「更多」里的一行：推入这个页面。
private struct MorePageLink<Detail: View>: View {
    let page: AppPage
    @ViewBuilder var detail: Detail

    var body: some View {
        NavigationLink {
            AppPageView(page: page)
        } label: {
            LabeledContent {
                detail
            } label: {
                SettingsLabel(page.moreTitle, icon: page.image, color: page.tint)
            }
        }
        .accessibilityIdentifier(page.moreIdentifier)
    }
}

extension MorePageLink where Detail == EmptyView {
    init(page: AppPage) {
        self.init(page: page) { EmptyView() }
    }
}

/// 一个页面本身。底栏和「更多」都用它，所以同一个页面在哪儿打开都一样。
struct AppPageView: View {
    let page: AppPage

    var body: some View {
        switch page {
        case .home:
            HomeView()
        case .usage:
            UsageView()
        case .chat:
            ChatView()
        case .about:
            AboutView()
        case .hosts:
            HostListContent()
        case .routes:
            ManageGate(title: page.title, subtitle: page.headerSubtitle) { store in
                ManageGroupsView(store: store).id(store.configurationKey)
            }
        case .keys:
            ManageGate(title: page.title, subtitle: page.headerSubtitle) { ManageKeysView(store: $0) }
        case .plugins:
            ManageGate(title: page.title, subtitle: page.headerSubtitle) { ManagePluginsView(manage: $0) }
        case .sessions:
            ManageGate(title: page.title, subtitle: page.headerSubtitle) { store in
                if let service = AgentSessionsServices.make(from: store.service) {
                    AgentSessionsView(service: service).id(store.configurationKey)
                } else {
                    ContentUnavailableView("会话记录", systemImage: page.symbol, description: Text("这台主机暂时不能读取 Agent 会话。"))
                        .pageHeader(page.title, subtitle: page.headerSubtitle)
                }
            }
        case .hostTools:
            ManageGate(title: page.title, subtitle: page.headerSubtitle) { store in
                List { PageTopStripSection(); HostToolsSection(store: store) }
                    .pageHeader(page.title)
            }
        case .web:
            ManageGate(title: page.title, subtitle: page.headerSubtitle) { store in
                List { PageTopStripSection(); MagpieWebSection(store: store) }
                    .pageHeader(page.title)
            }
        case .library:
            ManageGate(title: page.title, subtitle: page.headerSubtitle) { LibraryPage(manage: $0) }
        }
    }
}

extension AppPage {
    /// 「更多」里的行名（比底栏上的稍完整一点）。
    var moreTitle: String {
        switch self {
        case .sessions: "Agent 会话记录"
        case .hosts: "当前主机"
        default: title
        }
    }

    /// 「更多」里这一行的 identifier。沿用原来「管理」页的名字，UI 测试依赖它们。
    var moreIdentifier: String {
        switch self {
        case .home: "more.home"
        case .sessions: "manage.sessions"
        case .routes: "manage.groups"
        case .keys: "manage.keys"
        case .plugins: "manage.plugins"
        case .hostTools: "manage.hostTools"
        case .web: "manage.web"
        case .hosts: "manage.hosts"
        case .about: "manage.about"
        case .usage: "more.usage"
        case .chat: "more.chat"
        case .library: "more.library"
        }
    }
}

// MARK: - 「设置」样式的行

/// iOS「设置」样式的行图标：彩色圆角方块里一个白色图标。
struct SettingsIcon: View {
    let image: Image
    let color: Color

    var body: some View {
        image
            .resizable()
            .scaledToFit()
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .frame(width: 30, height: 30)
            .background(color.gradient, in: .rect(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// 「设置」样式的一行：彩色图标 + 名字（可选第二行说明）。
struct SettingsLabel: View {
    let title: String
    var detail: String? = nil
    let icon: Image
    let color: Color

    init(_ title: String, detail: String? = nil, icon: Image, color: Color) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.color = color
    }

    var body: some View {
        Label {
            if let detail {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(title)
            }
        } icon: {
            SettingsIcon(image: icon, color: color)
        }
    }
}

extension AppPage {
    /// 「更多」里这一页图标方块的颜色（和 iOS「设置」一样每类一种颜色）。
    var tint: Color {
        switch self {
        case .home: .blue
        case .sessions: .green
        case .routes: .orange
        case .usage: .purple
        case .chat: .teal
        case .keys: .yellow
        case .library: .brown
        case .plugins: .pink
        case .hostTools: .gray
        case .web: .cyan
        case .hosts: .indigo
        case .about: .gray
        }
    }
}
