import Foundation

// 小组件时间线：快照是 App 某一刻写的，小组件在之后几个小时里要按「现在」重新算倒计时、
// 判断窗口是否已过重置时间、数据是否已经太旧。这些都放在 Core 里便于单元测试。

/// 快照新旧程度。
public enum WidgetFreshness: Hashable, Sendable {
    /// 30 分钟内。
    case fresh
    /// 30 分钟到 6 小时：照常显示，角落写「x 小时前」。
    case aging
    /// 6 小时以上：数值变灰，并提示打开 App 刷新。
    case stale

    public static let agingAfter: TimeInterval = 30 * 60
    public static let staleAfter: TimeInterval = 6 * 3600

    public init(generatedAt: Date, now: Date) {
        let age = now.timeIntervalSince(generatedAt)
        if age >= Self.staleAfter { self = .stale } else if age >= Self.agingAfter { self = .aging } else { self = .fresh }
    }
}

/// 小组件要显示的整体状态。
public enum WidgetContent: Hashable, Sendable {
    /// 共享目录不可用（自签时 App Group 没开通 / 被改名）。
    case noAppGroup
    /// 共享目录可用，但 App 还没写过快照（或快照是更新版本写的）。
    case noSnapshot
    case snapshot(WidgetSnapshot)

    public var snapshot: WidgetSnapshot? {
        if case .snapshot(let snapshot) = self { return snapshot }
        return nil
    }
}

/// 一个时间点上一个窗口的显示。
public struct WidgetWindowDisplay: Hashable, Sendable {
    public var name: String
    public var remaining: Double?
    /// 「63%」；没有百分比时是供应商文字或「—」。
    public var valueText: String
    /// 「2 小时 18 分后重置」；已过重置时间：「已重置，待刷新」；没有重置时间为 nil。
    public var resetText: String?
    /// 已过重置时间：主机还没重新读，显示的剩余量已经不准（实际多半已经回满）。
    public var resetPassed: Bool
    /// 剩余量的紧张程度（决定颜色）。
    public var level: WidgetQuotaLevel
}

/// 剩余量的紧张程度：与额度页进度条颜色一致（≤10% 红、≤25% 橙，其余正常）。
public enum WidgetQuotaLevel: Hashable, Sendable {
    case normal, low, critical, unknown

    public init(remaining: Double?) {
        guard let remaining else { self = .unknown; return }
        if remaining <= 10 { self = .critical } else if remaining <= 25 { self = .low } else { self = .normal }
    }
}

public enum WidgetDisplay {
    /// 某个窗口在 `now` 时的显示。
    public static func window(_ window: WidgetQuotaWindow, now: Date) -> WidgetWindowDisplay {
        var passed = false
        var resetText: String?
        if let reset = window.resetsAt {
            if reset <= now {
                passed = true
                resetText = "已重置，待刷新"
            } else {
                resetText = WidgetFormat.countdown(to: reset, now: now) + "后重置"
            }
        }
        let value = window.remaining.map(QuotaFormat.percent) ?? window.detail ?? "—"
        return WidgetWindowDisplay(name: window.name, remaining: window.remaining, valueText: value, resetText: resetText,
                                   resetPassed: passed, level: passed ? .unknown : WidgetQuotaLevel(remaining: window.remaining))
    }

    /// 小号 / 锁屏只放一个账号时选哪个：最紧张（剩余最少、且还没过重置时间）的账号；都没有百分比时取第一个。
    public static func primaryAccount(_ accounts: [WidgetQuotaAccount], now: Date) -> WidgetQuotaAccount? {
        func effective(_ account: WidgetQuotaAccount) -> Double? {
            account.windows.filter { !($0.resetsAt.map { $0 <= now } ?? false) }.compactMap(\.remaining).min()
        }
        let metered = accounts.filter { effective($0) != nil && $0.problem == nil }
        if let tightest = metered.min(by: { effective($0)! < effective($1)! }) { return tightest }
        return accounts.first
    }

    /// 中号 / 大号显示的账号：有问题的账号排后面，其余保持主机顺序。
    public static func listedAccounts(_ accounts: [WidgetQuotaAccount], limit: Int) -> [WidgetQuotaAccount] {
        let ok = accounts.filter { $0.problem == nil }
        let bad = accounts.filter { $0.problem != nil }
        return Array((ok + bad).prefix(max(limit, 0)))
    }

    /// 底部的读取时间说明：「刚刚更新」「25 分钟前更新」「3 小时前更新」「11月2日 周一 09:00 更新」。
    public static func updatedText(_ generatedAt: Date, now: Date, timeZone: TimeZone = .current) -> String {
        let seconds = now.timeIntervalSince(generatedAt)
        if seconds < 60 { return "刚刚更新" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) 分钟前更新" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) 小时前更新" }
        return QuotaFormat.absolute(generatedAt, now: now, timeZone: timeZone) + " 更新"
    }
}

public enum WidgetFormat {
    /// 紧凑倒计时：「1 分」「18 分」「2 小时 18 分」「3 天 4 小时」。已过去返回「0 分」。
    public static func countdown(to date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "0 分" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "\(max(minutes, 1)) 分" }
        let hours = minutes / 60, rest = minutes % 60
        if hours < 24 { return rest == 0 ? "\(hours) 小时" : "\(hours) 小时 \(rest) 分" }
        let days = hours / 24, restHours = hours % 24
        return restHours == 0 ? "\(days) 天" : "\(days) 天 \(restHours) 小时"
    }

    /// 花费：「$0.52」「$12.3」「$1,234」——小组件空间小，金额大时少保留小数。
    public static func cost(_ value: Double) -> String {
        if value <= 0 { return "$0" }
        if value < 0.01 { return "<$0.01" }
        if value < 10 { return String(format: "$%.2f", value) }
        if value < 100 { return String(format: "$%.1f", value) }
        return "$" + QuotaFormat.tokens(Int(value.rounded()))
    }

    /// 失败率：「0%」「2.4%」「<0.1%」；没有调用时为「—」。
    public static func failureRate(_ rate: Double?) -> String {
        guard let rate else { return "—" }
        let percent = rate * 100
        if percent <= 0 { return "0%" }
        if percent < 0.1 { return "<0.1%" }
        if percent >= 10 { return "\(Int(percent.rounded()))%" }
        return String(format: "%.1f%%", percent)
    }
}

/// 时间线：从快照算出 WidgetKit 需要的若干时间点。
public enum WidgetTimelinePlan {
    /// 倒计时每隔多久重算一次。
    public static let step: TimeInterval = 15 * 60
    /// 时间线最远排到多久之后（之后由 WidgetKit 再来要新的时间线；App 写入新快照时会立即重载）。
    public static let horizon: TimeInterval = 6 * 3600
    /// 最多多少个时间点（WidgetKit 对单条时间线没有硬上限，这里留余量控制内存）。
    public static let maxEntries = 40

    /// 时间点：现在；之后每 15 分钟一个（对齐到整刻钟）；每个窗口的重置时刻（让「已重置，待刷新」准时出现）；
    /// 快照变「旧」与「很旧」的时刻。都在 `horizon` 之内，升序去重。
    public static func entryDates(for content: WidgetContent, now: Date) -> [Date] {
        guard case .snapshot(let snapshot) = content else { return [now] }
        let end = now.addingTimeInterval(horizon)
        var dates: Set<Date> = [now]
        // 对齐到下一个整刻钟（相对 1970 的整 15 分钟，与时区无关的刻钟在中国 / 整点时区上也是整刻钟）。
        let first = (now.timeIntervalSince1970 / step).rounded(.up) * step
        var t = Date(timeIntervalSince1970: first)
        while t <= end {
            if t > now { dates.insert(t) }
            t = t.addingTimeInterval(step)
        }
        for account in snapshot.quota.accounts {
            for window in account.windows {
                if let reset = window.resetsAt, reset > now, reset <= end { dates.insert(reset) }
            }
        }
        for threshold in [WidgetFreshness.agingAfter, WidgetFreshness.staleAfter] {
            let at = snapshot.generatedAt.addingTimeInterval(threshold)
            if at > now, at <= end { dates.insert(at) }
        }
        return Array(dates.sorted().prefix(maxEntries))
    }

    /// 时间线用完后多久再来要：排到的最后一个时间点；只有「现在」一个点时（没有快照）30 分钟后再看。
    public static func reloadDate(for content: WidgetContent, now: Date) -> Date {
        let dates = entryDates(for: content, now: now)
        if dates.count <= 1 { return now.addingTimeInterval(30 * 60) }
        return dates.last!
    }
}
