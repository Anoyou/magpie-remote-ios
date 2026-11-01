import SwiftUI
import WidgetKit
import MagpieRemoteCore

// 两个小组件共用的小部件：容器背景、提示、进度条、底部更新时间。
// 风格与 App 一致：系统 Liquid Glass 背景（iOS 26 主屏「清透 / 着色」外观下由系统换成玻璃），
// 内部用浅填充圆角块分组；颜色只用强调色、橙、红三档（同额度页：≤25% 橙、≤10% 红）。

extension WidgetQuotaLevel {
    var tint: Color {
        switch self {
        case .normal: .accentColor
        case .low: .orange
        case .critical: .red
        case .unknown: .secondary
        }
    }
}

extension View {
    /// 小组件容器背景：主屏用系统背景（玻璃外观下系统会自动换掉），锁屏配件用系统的配件背景。
    func magpieWidgetBackground(_ family: WidgetFamily) -> some View {
        containerBackground(for: .widget) {
            switch family {
            case .accessoryCircular, .accessoryRectangular, .accessoryInline:
                AccessoryWidgetBackground()
            default:
                Color(.systemBackground)
            }
        }
    }
}

/// 没有数据时的提示：图标 + 一句话 + 「打开 App 刷新」。点整个小组件打开 App。
struct WidgetMessage: View {
    let symbol: String
    let title: String
    var detail: String?
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 4 : 6) {
            Image(systemName: symbol)
                .font(compact ? .title3 : .title2)
                .foregroundStyle(.tint)
                .widgetAccentable()
            Text(title)
                .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 快照之外的几种状态对应的提示。
enum WidgetNotice {
    case noAppGroup, noSnapshot, noHost, keyHeld, failed(String), empty

    var symbol: String {
        switch self {
        case .noAppGroup: "exclamationmark.triangle"
        case .noSnapshot: "arrow.clockwise"
        case .noHost: "desktopcomputer"
        case .keyHeld: "key"
        case .failed: "wifi.exclamationmark"
        case .empty: "gauge.with.dots.needle.0percent"
        }
    }

    var title: String {
        switch self {
        case .noAppGroup, .noSnapshot: "打开 App 刷新"
        case .noHost: "打开 App 添加主机"
        case .keyHeld: "这把密钥看不到账号额度"
        case .failed: "读取失败"
        case .empty: "主机上没有订阅账号"
        }
    }

    var detail: String? {
        switch self {
        case .noAppGroup: "小组件读不到 App 的数据：重新签名时要保留扩展和 App Group"
        case .noSnapshot: "打开一次 App，小组件就会显示数据"
        case .noHost: nil
        case .keyHeld: "在 App 的额度页可以看这把密钥自己的限额"
        case .failed(let message): message + " · 打开 App 重试"
        case .empty: nil
        }
    }

    /// 锁屏一行文字里放的短句。
    var short: String {
        switch self {
        case .noAppGroup, .noSnapshot, .failed: "打开 App 刷新"
        case .noHost: "未添加主机"
        case .keyHeld: "密钥受限"
        case .empty: "没有订阅账号"
        }
    }
}

/// 细进度条（剩余百分比）。已过重置时间时画成虚的灰条。
struct RemainingBar: View {
    let display: WidgetWindowDisplay
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if let remaining = display.remaining, !display.resetPassed {
                    Capsule()
                        .fill(display.level.tint)
                        .frame(width: max(height, proxy.size.width * CGFloat(remaining) / 100))
                        .widgetAccentable()
                }
            }
        }
        .frame(height: height)
    }
}

/// 一个窗口的一行：名称、剩余百分比、进度条、重置倒计时。
struct WindowRow: View {
    let display: WidgetWindowDisplay
    var showsReset = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(display.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if showsReset, let reset = display.resetText {
                    Text(reset)
                        .font(.caption2)
                        .foregroundStyle(display.resetPassed ? Color.orange : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Text(display.valueText)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(display.resetPassed ? Color.secondary : display.level.tint)
                    .lineLimit(1)
            }
            if display.remaining != nil {
                RemainingBar(display: display)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 账号标题：官方标志 + 账号名（+ 供应商名）。
struct AccountHeader: View {
    let account: WidgetQuotaAccount
    var iconSize: CGFloat = 16

    var body: some View {
        HStack(spacing: 6) {
            BrandIcon(account.icon, size: iconSize)
            Text(account.account)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            if account.title != account.account {
                Text(account.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

/// 底部：主机名 · 更新时间；数据太旧时改成提示刷新。
struct UpdatedFooter: View {
    let snapshot: WidgetSnapshot
    let now: Date

    var body: some View {
        let freshness = WidgetFreshness(generatedAt: snapshot.generatedAt, now: now)
        HStack(spacing: 4) {
            if freshness == .stale {
                Image(systemName: "arrow.clockwise")
                Text("数据已过时 · 打开 App 刷新")
            } else {
                if let host = snapshot.hostName {
                    Text(host).lineLimit(1)
                    Text("·")
                }
                Text(WidgetDisplay.updatedText(snapshot.generatedAt, now: now))
            }
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(freshness == .stale ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}
