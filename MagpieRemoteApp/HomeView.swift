import SwiftUI
import UIKit
import MagpieRemoteCore

/// 「主页」：原来的 Agent、供应商、额度三页合成一页，顶部分页器切换。
/// 记住上次选的那页（本机 UserDefaults；示例模式不保存，UI 测试每次都从 Agent 开始）。
/// 导航栏标题跟着分页走（Agent / 供应商 / 额度），推入的详情页返回按钮也是这个名字。
struct HomeView: View {
    @Environment(AppModel.self) private var model
    /// nil：还没读保存的值（读要等拿到 `model`）。
    @State private var chosen: HomeSegment?

    private var defaults: UserDefaults? { model.isFixture ? nil : .standard }
    private var segment: HomeSegment { chosen ?? HomeSegment(stored: defaults?.string(forKey: HomeSegment.defaultsKey)) }

    var body: some View {
        page
            .safeAreaBar(edge: .top, spacing: 0) { picker }
            // 点「额度」小组件打开时切到额度分页。
            .onChange(of: model.requestedHomeSegment, initial: true) { _, request in
                guard let request else { return }
                choose(request)
                model.requestedHomeSegment = nil
            }
    }

    @ViewBuilder private var page: some View {
        switch segment {
        case .agents:
            ManageGate(title: HomeSegment.agents.title) { ManageAgentsView(store: $0) }
        case .providers:
            ManageGate(title: HomeSegment.providers.title) { ManageProvidersView(store: $0) }
        case .quota:
            QuotaView().pageHeader(HomeSegment.quota.title)
        }
    }

    private var picker: some View {
        Picker("主页", selection: Binding(get: { segment }, set: { choose($0) })) {
            ForEach(HomeSegment.allCases) { segment in
                Text(segment.title).tag(segment)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .accessibilityIdentifier("home.segment")
    }

    private func choose(_ next: HomeSegment) {
        let changed = next != segment
        chosen = next
        defaults?.set(next.rawValue, forKey: HomeSegment.defaultsKey)
        guard changed else { return }
        // 换分页时导航栏标题是原地改的（Agent → 供应商），iOS 26 的大标题画出了新名字，
        // 无障碍树里却还是旧名字（VoiceOver 会读「Agent」）。整页内容都换了，告诉系统「换屏」让它重新读一遍。
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
    }
}
