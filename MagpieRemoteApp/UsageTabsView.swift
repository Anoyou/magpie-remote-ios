import SwiftUI
import MagpieRemoteCore

/// 「用量」页的四个标签，与 magpie 网页 Usage 页一致：概览、请求、会话、上下文。
enum UsageTab: String, CaseIterable, Identifiable, Hashable {
    case overview, requests, sessions, context
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "概览"
        case .requests: "请求"
        case .sessions: "会话"
        case .context: "上下文"
        }
    }
}

/// 「用量」页：顶部分段切换四个标签。概览与请求走网关（网关密钥），会话与上下文走 magpie 网页接口（Web 密钥）。
struct UsageView: View {
    @State private var tab: UsageTab = .overview
    /// 概览与请求共用一个时间段（网页上也是同一个）。
    @State private var period: UsagePeriod = .today
    /// 受限网关密钥：概览读不到汇总时由概览告诉这里，请求标签据此隐藏「密钥」筛选。
    @State private var held = false

    var body: some View {
        Group {
            switch tab {
            case .overview:
                UsageOverviewPane(period: $period, held: $held)
            case .requests:
                UsageRequestsView(period: $period, held: held, embedded: true)
            case .sessions:
                ManageGate(title: AppPage.usage.title, subtitle: AppPage.usage.headerSubtitle) { store in
                    UsageSessionsPane(service: UsageWebServices.make(from: store.service), manage: store)
                        .id(store.configurationKey)
                }
            case .context:
                ManageGate(title: AppPage.usage.title, subtitle: AppPage.usage.headerSubtitle) { store in
                    UsageContextPane(service: UsageWebServices.make(from: store.service),
                                     tune: HostTools.service(for: store.service))
                        .id(store.configurationKey)
                }
            }
        }
        // 和「主页」的分页器一样放在导航栏下方的 safeAreaBar 里（大标题在导航栏里，不会被分页器挤掉）。
        .safeAreaBar(edge: .top, spacing: 0) {
            Picker("用量", selection: $tab) {
                ForEach(UsageTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .accessibilityIdentifier("usage.tab")
        }
        .pageHeader(AppPage.usage.title, subtitle: AppPage.usage.headerSubtitle)
    }
}
