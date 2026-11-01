import SwiftUI
import WidgetKit
import MagpieRemoteCore

/// 「今日用量」小组件：今天的花费、词元、请求数、失败率与当前并发。点开打开 App 的「用量」。
struct UsageWidget: Widget {
    static let kind = "MagpieUsageWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotProvider()) { entry in
            UsageWidgetView(entry: entry)
        }
        .configurationDisplayName("今日用量")
        .description("今天经过网关的花费、词元、请求数与失败率。数据来自 App 上次读取。")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct UsageWidgetView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .widgetURL(WidgetLink.usage.url)
            .magpieWidgetBackground(family)
    }

    @ViewBuilder private var content: some View {
        if let notice = notice {
            UsageNoticeView(notice: notice, family: family)
        } else if let snapshot = entry.content.snapshot, let today = snapshot.today {
            let stale = WidgetFreshness(generatedAt: snapshot.generatedAt, now: entry.date) == .stale
            switch family {
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    Text("今日 \(WidgetFormat.cost(today.cost))")
                        .font(.headline.monospacedDigit())
                        .widgetAccentable()
                    Text("\(QuotaFormat.tokens(today.tokens)) 词元 · \(today.calls) 次")
                        .font(.caption.monospacedDigit())
                    Text(stale ? "打开 App 刷新" : "失败率 \(WidgetFormat.failureRate(today.failureRate))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
            case .accessoryInline:
                Text(stale ? "用量 · 打开 App 刷新" : "今日 \(WidgetFormat.cost(today.cost)) · \(QuotaFormat.tokens(today.tokens)) 词元")
            case .systemMedium:
                UsageMedium(snapshot: snapshot, today: today, now: entry.date, stale: stale)
            default:
                UsageSmall(snapshot: snapshot, today: today, now: entry.date, stale: stale)
            }
        } else {
            UsageNoticeView(notice: .failed("用量暂时读不到"), family: family)
        }
    }

    private var notice: WidgetNotice? {
        switch entry.content {
        case .noAppGroup: return .noAppGroup
        case .noSnapshot: return .noSnapshot
        case .snapshot(let snapshot):
            if case .noHost = snapshot.quota { return .noHost }
            return nil
        }
    }
}

private struct UsageNoticeView: View {
    let notice: WidgetNotice
    let family: WidgetFamily

    var body: some View {
        switch family {
        case .accessoryInline:
            Label(notice.short, systemImage: notice.symbol)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label("今日用量", systemImage: "chart.bar.xaxis").font(.headline).widgetAccentable()
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

/// 小号：大字花费 + 词元 / 请求 / 失败率。
private struct UsageSmall: View {
    let snapshot: WidgetSnapshot
    let today: WidgetUsageToday
    let now: Date
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("今日花费", systemImage: "chart.bar.xaxis")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(WidgetFormat.cost(today.cost))
                .font(.system(size: 32, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.tint)
                .widgetAccentable()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Spacer(minLength: 0)
            StatLine(title: "词元", value: QuotaFormat.tokens(today.tokens))
            StatLine(title: "请求", value: "\(today.calls)")
            StatLine(title: "失败率", value: WidgetFormat.failureRate(today.failureRate), warn: (today.failureRate ?? 0) >= 0.05)
        }
        .opacity(stale ? 0.55 : 1)
        .overlay(alignment: .bottomTrailing) {
            if stale {
                Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange).font(.caption)
            }
        }
    }
}

/// 中号：四个数字块 + 并发 + 更新时间。
private struct UsageMedium: View {
    let snapshot: WidgetSnapshot
    let today: WidgetUsageToday
    let now: Date
    let stale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatTile(title: "今日花费", value: WidgetFormat.cost(today.cost), accent: true)
                StatTile(title: "词元", value: QuotaFormat.tokens(today.tokens))
            }
            HStack(spacing: 8) {
                StatTile(title: "请求", value: "\(today.calls)")
                StatTile(title: "失败率", value: WidgetFormat.failureRate(today.failureRate), warn: (today.failureRate ?? 0) >= 0.05)
            }
            .opacity(stale ? 0.55 : 1)
            HStack(spacing: 6) {
                if let concurrency = snapshot.concurrency {
                    Label(concurrency.waiting > 0 ? "并发 \(concurrency.requests) · 排队 \(concurrency.waiting)" : "并发 \(concurrency.requests)",
                          systemImage: "arrow.left.arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                UpdatedFooter(snapshot: snapshot, now: now)
            }
        }
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    var accent = false
    var warn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(warn ? AnyShapeStyle(.orange) : accent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.fill.quaternary, in: .rect(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct StatLine: View {
    let title: String
    let value: String
    var warn = false

    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(warn ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
        }
        .font(.caption)
        .lineLimit(1)
    }
}
