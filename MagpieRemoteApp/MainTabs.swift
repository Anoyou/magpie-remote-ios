import SwiftUI
import MagpieRemoteCore

struct MainTabs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            Tab(AppTab.quota.title, systemImage: AppTab.quota.symbol, value: AppTab.quota) {
                TabRoot(tab: .quota) { QuotaView() }
            }
            .accessibilityIdentifier("tab.quota")

            Tab(AppTab.usage.title, systemImage: AppTab.usage.symbol, value: AppTab.usage) {
                TabRoot(tab: .usage) { UsageView() }
            }
            .accessibilityIdentifier("tab.usage")

            Tab(AppTab.chat.title, systemImage: AppTab.chat.symbol, value: AppTab.chat) {
                TabRoot(tab: .chat) { ChatView() }
            }
            .accessibilityIdentifier("tab.chat")

            Tab(AppTab.manage.title, systemImage: AppTab.manage.symbol, value: AppTab.manage) {
                TabRoot(tab: .manage) { ManageView() }
            }
            .accessibilityIdentifier("tab.manage")
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .hosts: HostSettingsView()
            case .guide: NavigationStack { SetupGuideView(showsDone: true) }
            }
        }
    }
}

/// 每个标签页的根：导航栏标题 + 右上角「主机」按钮。
private struct TabRoot<Content: View>: View {
    @Environment(AppModel.self) private var model
    let tab: AppTab
    @ViewBuilder var content: Content

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(tab.title)
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
