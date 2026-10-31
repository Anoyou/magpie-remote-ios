import Foundation

/// 额度页的中文显示文字（放在 Core 里便于单元测试）。
public enum QuotaFormat {
    /// 「63%」「38.5%」。
    public static func percent(_ value: Double) -> String {
        let clamped = min(max(value, 0), 100)
        if clamped > 0 && clamped < 1 { return "<1%" }
        let rounded = (clamped * 10).rounded() / 10
        if rounded == rounded.rounded() { return "\(Int(rounded))%" }
        return String(format: "%.1f%%", rounded)
    }

    /// 距离某个时间点的相对说明：「2 小时 18 分钟后」「3 天 4 小时后」。已过去时返回 nil。
    public static func relative(to date: Date, now: Date = Date()) -> String? {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return nil }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "\(max(minutes, 1)) 分钟后" }
        let hours = minutes / 60, restMinutes = minutes % 60
        if hours < 24 { return restMinutes == 0 ? "\(hours) 小时后" : "\(hours) 小时 \(restMinutes) 分钟后" }
        let days = hours / 24, restHours = hours % 24
        return restHours == 0 ? "\(days) 天后" : "\(days) 天 \(restHours) 小时后"
    }

    /// 绝对时间：「今天 05:00」「明天 09:00」「11月4日 周三 09:00」「2027年1月3日 09:00」。
    public static func absolute(_ date: Date, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: date)
        let time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        let dayStart = calendar.startOfDay(for: date)
        let todayStart = calendar.startOfDay(for: now)
        let dayDiff = calendar.dateComponents([.day], from: todayStart, to: dayStart).day ?? 0
        switch dayDiff {
        case 0: return "今天 \(time)"
        case 1: return "明天 \(time)"
        case 2: return "后天 \(time)"
        case -1: return "昨天 \(time)"
        default: break
        }
        let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let weekday = parts.weekday.map { weekdays[($0 - 1 + 7) % 7] } ?? ""
        let sameYear = calendar.component(.year, from: now) == parts.year
        let day = "\(parts.month ?? 0)月\(parts.day ?? 0)日"
        if sameYear { return "\(day) \(weekday) \(time)" }
        return "\(parts.year ?? 0)年\(day) \(time)"
    }

    /// 重置说明：「2 小时 18 分钟后重置（今天 05:00）」；已过时间：「已到重置时间（今天 03:00），等待主机更新」。
    public static func reset(_ date: Date, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let absolute = absolute(date, now: now, timeZone: timeZone)
        if let relative = relative(to: date, now: now) { return "\(relative)重置（\(absolute)）" }
        return "已到重置时间（\(absolute)），等待主机更新"
    }

    /// 读取时间：「刚刚读取」「5 分钟前读取」「昨天 23:10 读取」。
    public static func readAgo(_ date: Date, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "刚刚读取" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) 分钟前读取" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) 小时前读取" }
        return "\(absolute(date, now: now, timeZone: timeZone)) 读取"
    }

    /// 词元数：「9,981」「4.45 万」「1.2 亿」。
    public static func tokens(_ value: Int) -> String {
        let v = Double(value)
        if abs(v) >= 100_000_000 { return trimmed(v / 100_000_000, digits: 2) + " 亿" }
        if abs(v) >= 10_000 { return trimmed(v / 10_000, digits: 2) + " 万" }
        var digits = String(abs(value))
        var groups: [String] = []
        while digits.count > 3 {
            groups.insert(String(digits.suffix(3)), at: 0)
            digits.removeLast(3)
        }
        groups.insert(digits, at: 0)
        return (value < 0 ? "-" : "") + groups.joined(separator: ",")
    }

    /// 美元：「$0.52」「$5.00」。
    public static func usd(_ value: Double) -> String {
        if value > 0 && value < 0.01 { return "<$0.01" }
        return String(format: "$%.2f", value)
    }

    /// 常见窗口名翻成中文，不认识的原样显示。
    public static func windowName(_ name: String) -> String {
        let map: [String: String] = [
            "5 hours": "5 小时", "5h": "5 小时", "five hours": "5 小时",
            "week": "每周", "weekly": "每周", "7 days": "7 天",
            "day": "每天", "daily": "每天", "today": "今天",
            "month": "每月", "monthly": "每月", "30 days": "30 天",
            "credits": "点数", "balance": "余额",
        ]
        return map[name.lowercased()] ?? name
    }

    private static func trimmed(_ value: Double, digits: Int) -> String {
        var text = String(format: "%.\(digits)f", value)
        while text.contains(".") && (text.hasSuffix("0") || text.hasSuffix(".")) { text.removeLast() }
        return text
    }
}
