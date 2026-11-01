import SwiftUI
import MagpieRemoteCore

/// 底栏：前 4 个是「自定义底栏」里选的页面（默认主页、会话、路由、用量），第 5 个固定是「更多」。
struct MainTabs: View {
    @Environment(AppModel.self) private var model
    /// 需要 Web 密钥的页面（主页里的 Agent / 供应商、路由…）共用一份数据，不管它们在底栏还是在「更多」里。
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
                Tab(value: AppTab.page(page)) {
                    TabRoot { AppPageView(page: page) }
                } label: {
                    Label(page.title, page: page)
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

/// 每个标签页的根：导航栈。切换 / 添加主机只在「更多 › 当前主机」里（右上角不再放「主机」按钮）。
private struct TabRoot<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        NavigationStack { content }
    }
}
