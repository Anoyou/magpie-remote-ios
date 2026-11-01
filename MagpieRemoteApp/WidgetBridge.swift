import Foundation
import Observation
import WidgetKit
import MagpieRemoteCore

/// App 这一侧的小组件桥：把额度、今日用量、并发写成快照放进 App Group，再让 WidgetKit 重载。
/// 快照里没有任何密钥；小组件只读快照、不联网。示例模式（UI 测试）不读不写。
@MainActor
@Observable
final class WidgetBridge {
    /// 找到的可用 App Group（自签改名后可能不是原名；为空表示小组件读不到数据）。
    private(set) var groups: [String] = []
    /// 上次写入的快照（额度页单独刷新时在它的基础上更新）。
    private(set) var last: WidgetSnapshot?
    private(set) var lastWrite: Date?
    private let store: WidgetSnapshotStore?

    /// 回到前台时，距上次写入不到这么久就不再请求主机。
    static let minimumInterval: TimeInterval = 120

    init(enabled: Bool) {
        if enabled {
            let resolved = WidgetSnapshotStore.live()
            groups = resolved.groups
            store = resolved.store
            last = resolved.store.read()
        } else {
            store = nil
        }
    }

    var isAvailable: Bool { store?.isAvailable ?? false }

    /// 「关于」里显示的状态。
    var statusText: String {
        if store == nil { return "示例模式不使用" }
        if groups.isEmpty { return "未连通" }
        return "已连通"
    }

    func shouldRefresh(now: Date) -> Bool {
        guard isAvailable else { return false }
        guard let lastWrite else { return true }
        return now.timeIntervalSince(lastWrite) >= Self.minimumInterval
    }

    func write(_ snapshot: WidgetSnapshot) {
        guard let store, store.isAvailable else { return }
        last = snapshot
        lastWrite = snapshot.generatedAt
        store.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

extension AppModel {
    /// 读一遍额度、今日用量、并发并写入小组件快照。连接成功、回到前台时调用（`force` 为 false 时 2 分钟内不重复）。
    /// 额度读不到（主机连不上）时不覆盖旧快照：小组件继续显示旧数据并标出更新时间，比显示一个错误更有用。
    func refreshWidgets(force: Bool = false) async {
        guard !isFixture, widgets.isAvailable else { return }
        let now = Date()
        guard force || widgets.shouldRefresh(now: now) else { return }
        guard let host = activeHost else {
            widgets.write(.make(hostName: nil, quota: nil, today: nil, concurrency: nil, now: now))
            return
        }
        guard case .connected = connection else { return }
        guard let quota = try? await loadQuotaSnapshot() else { return }
        let today = try? await loadUsageSummary(.today).value?.totals
        let concurrency = try? await loadConcurrency().value
        guard activeHost?.id == host.id else { return }
        widgets.write(.make(hostName: host.name, quota: quota, today: today, concurrency: concurrency, now: Date()))
    }

    /// 额度页读到 / 刷新出新数据时：只更新快照里的额度部分。
    func widgetQuotaChanged(_ quota: QuotaSnapshot) {
        guard !isFixture, widgets.isAvailable, let host = activeHost else { return }
        let now = Date()
        if let last = widgets.last, last.hostName == host.name {
            widgets.write(last.updatingQuota(quota, now: now))
        } else {
            widgets.write(.make(hostName: host.name, quota: quota, today: nil, concurrency: nil, now: now))
        }
    }

    /// 点小组件打开 App（`magpieremote://widget/…`）：切到对应页面。
    func open(_ url: URL) {
        guard let link = WidgetLink(url: url) else { return }
        sheet = nil
        if let segment = link.homeSegment { requestedHomeSegment = segment }
        switch link.route(dock: dock.layout) {
        case .tab(let page):
            selectedTab = .page(page)
        case .more(let page):
            selectedTab = .more
            morePush = page
        }
    }
}
