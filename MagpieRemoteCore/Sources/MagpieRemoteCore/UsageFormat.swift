import Foundation

/// 「用量」页的数字写法（中文习惯：万 / 亿，美元花费，毫秒 / 秒）。
public enum UsageFormat {
    /// 花费：`$3.42`；不足 1 美分时多保留两位（`$0.0013`），为 0 时 `$0.00`。
    public static func cost(_ value: Double) -> String {
        let v = value.isFinite ? value : 0
        if v == 0 { return "$0.00" }
        if Swift.abs(v) < 0.01 { return String(format: "$%.4f", v) }
        if Swift.abs(v) >= 1000 { return "$" + grouped(Int(v.rounded())) }
        return String(format: "$%.2f", v)
    }

    /// 词元数：`8211`、`18.4 万`、`1.6 亿`。
    public static func tokens(_ value: Int) -> String {
        let v = Double(value)
        if Swift.abs(v) >= 100_000_000 { return trimmed(v / 100_000_000) + " 亿" }
        if Swift.abs(v) >= 10_000 { return trimmed(v / 10_000) + " 万" }
        return String(value)
    }

    /// 次数：`1,234`。
    public static func count(_ value: Int) -> String { grouped(value) }

    /// 耗时：`912 毫秒`、`2.9 秒`、`1 分 30 秒`。
    public static func duration(ms: Int) -> String {
        if ms < 1000 { return "\(ms) 毫秒" }
        if ms < 60_000 { return trimmed(Double(ms) / 1000) + " 秒" }
        let seconds = ms / 1000
        return seconds % 60 == 0 ? "\(seconds / 60) 分" : "\(seconds / 60) 分 \(seconds % 60) 秒"
    }

    /// 占比：`42%`，不足 1% 时 `<1%`。
    public static func percent(_ fraction: Double) -> String {
        if fraction > 0 && fraction < 0.01 { return "<1%" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    /// 一位小数，末尾的 `.0` 去掉。
    static func trimmed(_ v: Double) -> String {
        let text = String(format: "%.1f", v)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    static func grouped(_ value: Int) -> String {
        let digits = String(Swift.abs(value))
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return (value < 0 ? "-" : "") + out
    }

    /// 请求时间的短写法：今天 `14:05`，今年 `11-01 14:05`，更早 `2025-11-01 14:05`；解析不了时原样返回。
    public static func time(_ timestamp: UsageTimestamp, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        guard let date = timestamp.date else { return timestamp.raw }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            formatter.dateFormat = "MM-dd HH:mm"
        } else {
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
        }
        return formatter.string(from: date)
    }

    /// 完整时间（详情页）：`2026-11-01 02:40:00`。
    public static func fullTime(_ timestamp: UsageTimestamp, timeZone: TimeZone = .current) -> String {
        guard let date = timestamp.date else { return timestamp.raw }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// 状态码的中文说明。
    public static func status(_ row: UsageRequestRow) -> String {
        if row.rejected { return "被拒绝（\(row.status)）" }
        if !row.failed { return "成功（\(row.status)）" }
        switch row.status {
        case 401: return "密钥无效（401）"
        case 403: return "不允许（403）"
        case 429: return "超出限制（429）"
        case 499: return "已取消（499）"
        case 500...599: return "上游出错（\(row.status)）"
        case 0: return "失败"
        default: return "失败（\(row.status)）"
        }
    }
}
