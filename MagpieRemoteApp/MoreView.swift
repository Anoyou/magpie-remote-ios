import SwiftUI
import MagpieRemoteCore

/// 底栏第 5 个「更多」：列出不在底栏里的所有页面（点开都是 App 内原生页面），以及配置引导和「自定义底栏」。
/// 取代原来的「管理」标签页，原来管理页里的入口都还在这里（或在底栏里）。
struct MoreView: View {
    @Environment(AppModel.self) private var model
    @Environment(ManageStore.self) private var store

    private var more: [AppPage] { model.dock.layout.morePages }
    private var magpiePages: [AppPage] { [.home, .sessions, .routes, .keys].filter(more.contains) }
    private var gatewayPages: [AppPage] { [.usage, .chat].filter(more.contains) }

    var body: some View {
        List {
            if more.contains(.hosts) {
                Section("主机") {
                    MorePageLink(page: .hosts) {
                        Text(model.activeHost?.name ?? "未添加")
                    }
                }
            }

            ManageStatusSection(store: store)

            if !gatewayPages.isEmpty {
                Section("网关") {
                    ForEach(gatewayPages) { MorePageLink(page: $0) }
                }
            }

            if !magpiePages.isEmpty {
                Section {
                    ForEach(magpiePages) { page in
                        MorePageLink(page: page) {
                            if let detail = detail(page) { Text(detail) }
                        }
                    }
                } header: {
                    Text("magpie")
                } footer: {
                    Text("「主页」里是 Agent、供应商与额度；模型的开关在各个供应商里。")
                }
            }

            if more.contains(.hostTools) {
                if HostTools.service(for: store.service) != nil {
                    HostToolsSection(store: store)
                } else {
                    Section("主机工具") { MorePageLink(page: .hostTools) }
                }
            }

            if more.contains(.plugins) {
                Section {
                    MorePageLink(page: .plugins)
                } footer: {
                    Text("已安装与内置插件：开关、检查更新、添加、移除和选项。")
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
                    Label("配置引导", systemImage: "list.number")
                }
                .accessibilityIdentifier("manage.guide")
                NavigationLink {
                    DockCustomizeView()
                } label: {
                    LabeledContent {
                        if !model.dock.layout.isDefault { Text("已自定义") }
                    } label: {
                        Label("自定义底栏", systemImage: "dock.rectangle")
                    }
                }
                .accessibilityIdentifier("more.customize")
            } header: {
                Text("App")
            }
        }
        .navigationTitle("更多")
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
                Label(page.moreTitle, page: page)
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
            UsageView().navigationTitle(page.title)
        case .chat:
            ChatView().navigationTitle(page.title)
        case .about:
            AboutView()
        case .hosts:
            HostListContent()
        case .routes:
            ManageGate(title: page.title) { store in
                ManageGroupsView(store: store).id(store.configurationKey)
            }
        case .keys:
            ManageGate(title: page.title) { ManageKeysView(store: $0) }
        case .plugins:
            ManageGate(title: page.title) { ManagePluginsView(manage: $0) }
        case .sessions:
            ManageGate(title: page.title) { store in
                if let service = AgentSessionsServices.make(from: store.service) {
                    AgentSessionsView(service: service).id(store.configurationKey)
                } else {
                    ContentUnavailableView("会话记录", systemImage: page.symbol, description: Text("这台主机暂时不能读取 Agent 会话。"))
                }
            }
        case .hostTools:
            ManageGate(title: page.title) { store in
                List { HostToolsSection(store: store) }
                    .navigationTitle(page.title)
            }
        case .web:
            ManageGate(title: page.title) { store in
                List { MagpieWebSection(store: store) }
                    .navigationTitle(page.title)
            }
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
        }
    }
}
