import SwiftUI
import MagpieRemoteCore

/// 底栏：前 4 个是「自定义底栏」里选的页面（默认 Agent、会话、供应商、路由），第 5 个固定是「更多」。
struct MainTabs: View {
    @Environment(AppModel.self) private var model
    /// 需要 Web 密钥的页面（供应商、路由、Agent…）共用一份数据，不管它们在底栏还是在「更多」里。
    @State private var manage = ManageStore()

    private var configurationID: String {
        guard let host = model.activeHost else { return "none" }
        return [host.id.uuidString, host.webURL.absoluteString, host.gatewayURL.absoluteString,
                "\(model.hasSecret(.webKey, host: host.id))", "\(model.hasSecret(.issuerKey, host: host.id))",
                "\(model.hosts.hosts.count)"].joined(separator: "|")
    }

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            ForEach(model.dock.layout.pages) { page in
                Tab(page.title, systemImage: page.symbol, value: AppTab.page(page)) {
                    TabRoot { AppPageView(page: page) }
                }
                .accessibilityIdentifier("tab.\(page.rawValue)")
            }

            Tab("更多", systemImage: "ellipsis.circle", value: AppTab.more) {
                TabRoot { MoreView() }
            }
            .accessibilityIdentifier("tab.more")
        }
        // 下滑时底栏缩成一个按钮；UI 测试里关掉，免得滑动列表后找不到底栏上的页面。
        .tabBarMinimizeBehavior(RT.uiTesting ? .never : .onScrollDown)
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .hosts: HostSettingsView()
            case .guide: NavigationStack { SetupGuideView(showsDone: true) }
            }
        }
        .task(id: configurationID) { await manage.configure(model: model) }
        .environment(manage)
    }
}

/// 每个标签页的根：导航栈 + 右上角「主机」按钮（随时切换主机、打开配置引导）。
private struct TabRoot<Content: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder var content: Content

    var body: some View {
        NavigationStack {
            content
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            model.sheet = .hosts
                        } label: {
                            Label(model.activeHost?.name ?? "主机", systemImage: "desktopcomputer")
                        }
                        .accessibilityIdentifier("hosts.open")
                    }
                }
        }
    }
}
