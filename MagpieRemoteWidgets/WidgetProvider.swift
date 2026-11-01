import Foundation
import WidgetKit
import MagpieRemoteCore

/// 时间线上的一个点：那一刻的快照内容（同一份快照，倒计时按 `date` 重算）。
struct SnapshotEntry: TimelineEntry {
    let date: Date
    let content: WidgetContent
    /// 小组件库里的预览：用示例数据。
    var isSample = false
}

/// 两个小组件共用的时间线：读共享目录里的快照，按 Core 的 `WidgetTimelinePlan` 排时间点。
struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), content: .snapshot(WidgetSample.snapshot(now: Date())), isSample: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let now = Date()
        let content = Self.load()
        // 在小组件库里预览时还没有数据：给示例，让用户看得出样子。
        if context.isPreview, content.snapshot == nil {
            completion(SnapshotEntry(date: now, content: .snapshot(WidgetSample.snapshot(now: now)), isSample: true))
        } else {
            completion(SnapshotEntry(date: now, content: content))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let now = Date()
        let content = Self.load()
        let entries = WidgetTimelinePlan.entryDates(for: content, now: now).map { SnapshotEntry(date: $0, content: content) }
        completion(Timeline(entries: entries, policy: .after(WidgetTimelinePlan.reloadDate(for: content, now: now))))
    }

    /// 每次都重新找组、重新读文件：自签后组名可能变，文件也很小。
    static func load() -> WidgetContent {
        WidgetSnapshotStore.live().store.content()
    }
}

/// 小组件库预览用的示例数据（全部是假数据）。
enum WidgetSample {
    static func snapshot(now: Date) -> WidgetSnapshot {
        WidgetSnapshot(
            generatedAt: now,
            hostName: "示例 Mac",
            quota: .accounts([
                WidgetQuotaAccount(id: "sample|claude|", title: "Claude", account: "工作账号", icon: "claude",
                                   windows: [WidgetQuotaWindow(name: "5 小时", remaining: 63, resetsAt: now.addingTimeInterval(8280)),
                                             WidgetQuotaWindow(name: "每周", remaining: 38, resetsAt: now.addingTimeInterval(3 * 86400))],
                                   readAt: now),
                WidgetQuotaAccount(id: "sample|codex|", title: "Codex", account: "个人", icon: "codex-color",
                                   windows: [WidgetQuotaWindow(name: "5 小时", remaining: 18, resetsAt: now.addingTimeInterval(2820)),
                                             WidgetQuotaWindow(name: "每周", remaining: 72, resetsAt: now.addingTimeInterval(5 * 86400))],
                                   readAt: now),
                WidgetQuotaAccount(id: "sample|deepseek|", title: "DeepSeek", account: "DeepSeek", icon: "deepseek-color",
                                   balance: "¥ 23.71", readAt: now),
            ]),
            today: WidgetUsageToday(cost: 3.42, tokens: 1_284_000, calls: 236, errors: 4),
            concurrency: WidgetConcurrency(requests: 2, waiting: 0))
    }
}
