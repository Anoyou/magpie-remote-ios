import SwiftUI
import WidgetKit
import MagpieRemoteCore

/// 「额度」小组件：订阅账号的剩余额度与重置倒计时。点开打开 App 的「主页 › 额度」。
struct QuotaWidget: Widget {
    static let kind = "MagpieQuotaWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotProvider()) { entry in
            QuotaWidgetView(entry: entry)
        }
        .configurationDisplayName("额度")
        .description("订阅账号的剩余额度与重置时间。数据来自 App 上次读取。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct QuotaWidgetView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .widgetURL(WidgetLink.quota.url)
            .magpieWidgetBackground(family)
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .notice(let notice):
            QuotaNoticeView(notice: notice, family: family)
        case .accounts(let snapshot, let accounts):
            let stale = WidgetFreshness(generatedAt: snapshot.generatedAt, now: entry.date) == .stale
            switch family {
            case .accessoryCircular:
                QuotaCircular(account: WidgetDisplay.primaryAccount(accounts, now: entry.date), now: entry.date)
            case .accessoryRectangular:
                QuotaRectangular(account: WidgetDisplay.primaryAccount(accounts, now: entry.date), now: entry.date, stale: stale)
            case .accessoryInline:
                QuotaInline(account: WidgetDisplay.primaryAccount(accounts, now: entry.date), now: entry.date, stale: stale)
            case .systemMedium:
                QuotaList(snapshot: snapshot, accounts: WidgetDisplay.listedAccounts(accounts, limit: 2), windows: 2, now: entry.date)
            case .systemLarge, .systemExtraLarge:
                QuotaList(snapshot: snapshot, accounts: WidgetDisplay.listedAccounts(accounts, limit: 4), windows: 2, now: entry.date)
            default:
                QuotaSmall(snapshot: snapshot, account: WidgetDisplay.primaryAccount(accounts, now: entry.date), now: entry.date)
            }
        }
    }

    private enum Phase {
        case notice(WidgetNotice)
        case accounts(WidgetSnapshot, [WidgetQuotaAccount])
    }

    private var phase: Phase {
        switch entry.content {
        case .noAppGroup: return .notice(.noAppGroup)
        case .noSnapshot: return .notice(.noSnapshot)
        case .snapshot(let snapshot):
            switch snapshot.quota {
            case .noHost: return .notice(.noHost)
            case .keyHeld: return .notice(.keyHeld)
            case .failed(let message): return .notice(.failed(message))
            case .accounts(let accounts):
                return accounts.isEmpty ? .notice(.empty) : .accounts(snapshot, accounts)
            }
        }
    }
}

/// 没有额度可显示时：主屏显示提示，锁屏只显示图标 / 一句话。
private struct QuotaNoticeView: View {
    let notice: WidgetNotice
    let family: WidgetFamily

    var body: some View {
        switch family {
        case .accessoryCircular:
            Image(systemName: notice.symbol).font(.title3).widgetAccentable()
        case .accessoryInline:
            Label(notice.short, systemImage: notice.symbol)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label("额度", systemImage: "gauge.with.dots.needle.67percent").font(.headline).widgetAccentable()
                Text(notice.short).font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .systemSmall:
            WidgetMessage(symbol: notice.symbol, title: notice.title, detail: notice.detail, compact: true)
        default:
            WidgetMessage(symbol: notice.symbol, title: notice.title, detail: notice.detail)
        }
    }
}

// MARK: 主屏

/// 小号：最紧张的一个账号，大字剩余百分比 + 两个窗口。
private struct QuotaSmall: View {
    let snapshot: WidgetSnapshot
    let account: WidgetQuotaAccount?
    let now: Date

    var body: some View {
        let stale = WidgetFreshness(generatedAt: snapshot.generatedAt, now: now) == .stale
        VStack(alignment: .leading, spacing: 6) {
            if let account {
                AccountHeader(account: account)
                let windows = account.windows.map { WidgetDisplay.window($0, now: now) }
                if let tight = windows.filter({ $0.remaining != nil && !$0.resetPassed }).min(by: { ($0.remaining ?? 0) < ($1.remaining ?? 0) }) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(tight.valueText)
                            .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(tight.level.tint)
                            .widgetAccentable()
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                        Text("\(tight.name)剩余")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else if let balance = account.balance {
                    Text(balance)
                        .font(.title2.weight(.bold).monospacedDigit())
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                } else if let problem = account.problem {
                    Text(problem).font(.caption).foregroundStyle(.orange).lineLimit(3)
                }
                Spacer(minLength: 0)
                ForEach(Array(windows.prefix(2).enumerated()), id: \.offset) { _, window in
                    WindowRow(display: window, showsReset: false)
                }
                if let reset = windows.first(where: { $0.resetText != nil })?.resetText {
                    Text(reset).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                }
            }
        }
        .opacity(stale ? 0.55 : 1)
        .overlay(alignment: .bottomTrailing) {
            if stale {
                Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange).font(.caption)
            }
        }
    }
}

/// 中号 / 大号：几个账号，每个账号两个窗口。
private struct QuotaList: View {
    let snapshot: WidgetSnapshot
    let accounts: [WidgetQuotaAccount]
    let windows: Int
    let now: Date

    var body: some View {
        let stale = WidgetFreshness(generatedAt: snapshot.generatedAt, now: now) == .stale
        VStack(alignment: .leading, spacing: 8) {
            ForEach(accounts) { account in
                AccountBlock(account: account, windows: windows, now: now)
            }
            .opacity(stale ? 0.55 : 1)
            Spacer(minLength: 0)
            UpdatedFooter(snapshot: snapshot, now: now)
        }
    }
}

private struct AccountBlock: View {
    let account: WidgetQuotaAccount
    let windows: Int
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AccountHeader(account: account)
            if let problem = account.problem {
                Text(problem).font(.caption2).foregroundStyle(.orange).lineLimit(1)
            } else if account.windows.isEmpty, let balance = account.balance {
                Text("余额 \(balance)").font(.caption.monospacedDigit()).lineLimit(1)
            } else {
                ForEach(Array(account.windows.prefix(windows).enumerated()), id: \.offset) { _, window in
                    WindowRow(display: WidgetDisplay.window(window, now: now))
                }
            }
        }
        .padding(8)
        .background(.fill.quaternary, in: .rect(cornerRadius: 12, style: .continuous))
    }
}

// MARK: 锁屏

private struct QuotaCircular: View {
    let account: WidgetQuotaAccount?
    let now: Date

    var body: some View {
        let window = account?.windows
            .map { WidgetDisplay.window($0, now: now) }
            .filter { $0.remaining != nil && !$0.resetPassed }
            .min { ($0.remaining ?? 0) < ($1.remaining ?? 0) }
        if let window, let remaining = window.remaining {
            Gauge(value: remaining, in: 0...100) {
                Text(window.name)
            } currentValueLabel: {
                Text("\(Int(remaining.rounded()))")
                    .monospacedDigit()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
        } else {
            Image(systemName: "gauge.with.dots.needle.67percent").font(.title3).widgetAccentable()
        }
    }
}

private struct QuotaRectangular: View {
    let account: WidgetQuotaAccount?
    let now: Date
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            // 锁屏上别人也看得到：只写供应商名，不写账号（可能是邮箱）。
            Text(account?.title ?? "额度")
                .font(.headline)
                .lineLimit(1)
                .widgetAccentable()
            if let account {
                ForEach(Array(account.windows.prefix(2).enumerated()), id: \.offset) { _, raw in
                    let window = WidgetDisplay.window(raw, now: now)
                    HStack(spacing: 4) {
                        Text("\(window.name) \(window.valueText)").monospacedDigit()
                        if let reset = window.resetText { Text(reset).foregroundStyle(.secondary) }
                    }
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }
            }
            if stale {
                Text("打开 App 刷新").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct QuotaInline: View {
    let account: WidgetQuotaAccount?
    let now: Date
    let stale: Bool

    var body: some View {
        if stale {
            Text("额度 · 打开 App 刷新")
        } else if let account, let raw = account.tightestWindow {
            let window = WidgetDisplay.window(raw, now: now)
            if let reset = window.resetText {
                Text("\(account.title) \(window.valueText) · \(reset)")
            } else {
                Text("\(account.title) \(window.valueText)")
            }
        } else if let account, let balance = account.balance {
            Text("\(account.title) 余额 \(balance)")
        } else {
            Text("额度")
        }
    }
}
