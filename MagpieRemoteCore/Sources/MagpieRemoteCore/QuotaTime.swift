import Foundation

/// 额度 / 限额接口里的时间。
///
/// magpie 返回 Go `time.Time` 的 RFC 3339 写法（0–9 位小数，`Z` 或 `±hh:mm`）。早先的抓包笔记里记成了人读格式
/// `Sun 2026-11-01 2:40 AM CST (UTC+08:00)`，为稳妥两种都认；另外兼容 Unix 秒 / 毫秒数字。
/// 认不出的值返回 nil，不让整张卡片解码失败。
public enum QuotaTime {
    public static func parse(_ text: String) -> Date? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let date = parseRFC3339(text) { return date }
        if let date = parseHuman(text) { return date }
        if let number = Double(text) { return fromNumber(number) }
        return nil
    }

    public static func fromNumber(_ number: Double) -> Date? {
        guard number > 0 else { return nil }
        // 大于 1e12 视为毫秒。
        return Date(timeIntervalSince1970: number > 1e12 ? number / 1000 : number)
    }

    private static let rfc3339 = try! NSRegularExpression(
        pattern: #"^(\d{4})-(\d{2})-(\d{2})[Tt ](\d{2}):(\d{2})(?::(\d{2})(?:[.,](\d{1,9}))?)?\s*(Z|z|[+-]\d{2}(?::?\d{2})?)$"#)

    private static let human = try! NSRegularExpression(
        pattern: #"(\d{4})-(\d{2})-(\d{2})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([AaPp][Mm])?(?:\s+([A-Za-z][A-Za-z0-9+-]*))?(?:\s*\(UTC(?:([+-])(\d{1,2})(?::?(\d{2}))?)?\))?"#)

    static func parseRFC3339(_ text: String) -> Date? {
        let ns = text as NSString
        guard let m = rfc3339.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        guard let y = group(1).flatMap(Int.init), let mo = group(2).flatMap(Int.init), let d = group(3).flatMap(Int.init),
              let h = group(4).flatMap(Int.init), let mi = group(5).flatMap(Int.init), let zone = group(8) else { return nil }
        let s = group(6).flatMap(Int.init) ?? 0
        var offset = 0
        if zone != "Z" && zone != "z" {
            let sign = zone.hasPrefix("-") ? -1 : 1
            let digits = zone.dropFirst().replacingOccurrences(of: ":", with: "")
            let hh = Int(digits.prefix(2)) ?? 0
            let mm = digits.count >= 4 ? Int(digits.suffix(2)) ?? 0 : 0
            offset = sign * (hh * 3600 + mm * 60)
        }
        guard let base = makeDate(y, mo, d, h, mi, s, offset: offset) else { return nil }
        var fraction = 0.0
        if let f = group(7) { fraction = Double("0." + f) ?? 0 }
        return base.addingTimeInterval(fraction)
    }

    static func parseHuman(_ text: String) -> Date? {
        let ns = text as NSString
        guard let m = human.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        guard let y = group(1).flatMap(Int.init), let mo = group(2).flatMap(Int.init), let d = group(3).flatMap(Int.init),
              var h = group(4).flatMap(Int.init), let mi = group(5).flatMap(Int.init) else { return nil }
        let s = group(6).flatMap(Int.init) ?? 0
        if let ampm = group(7)?.uppercased() {
            guard (1...12).contains(h) else { return nil }
            if ampm == "AM" { h = h == 12 ? 0 : h } else { h = h == 12 ? 12 : h + 12 }
        }
        var offset: Int?
        if m.range(at: 9).location != NSNotFound {
            let sign = group(9) == "-" ? -1 : 1
            offset = sign * ((group(10).flatMap(Int.init) ?? 0) * 3600 + (group(11).flatMap(Int.init) ?? 0) * 60)
        } else if text.contains("(UTC)") {
            offset = 0
        } else if let abbreviation = group(8), let zone = TimeZone(abbreviation: abbreviation) {
            offset = zone.secondsFromGMT()
        }
        return makeDate(y, mo, d, h, mi, s, offset: offset ?? 0)
    }

    private static func makeDate(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int, offset: Int) -> Date? {
        guard (1...12).contains(mo), (1...31).contains(d), (0...23).contains(h), (0...59).contains(mi), (0...60).contains(s),
              let zone = TimeZone(secondsFromGMT: offset) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))
    }
}

/// 解码辅助：宽松读取（类型不对或为 null 时当作缺省，不让整个响应解码失败）。
extension KeyedDecodingContainer {
    func quotaTime(_ key: Key) -> Date? {
        if let text = try? decodeIfPresent(String.self, forKey: key) { return QuotaTime.parse(text) }
        if let number = try? decodeIfPresent(Double.self, forKey: key) { return QuotaTime.fromNumber(number) }
        return nil
    }

    func quotaDouble(_ key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
        if let text = try? decodeIfPresent(String.self, forKey: key) { return Double(text) }
        return nil
    }

    func quotaInt(_ key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = quotaDouble(key), value.isFinite, abs(value) < 9e18 { return Int(value) }
        return nil
    }

    func quotaString(_ key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value.isEmpty ? nil : value }
        return nil
    }

    func quotaBool(_ key: Key) -> Bool {
        (try? decodeIfPresent(Bool.self, forKey: key)) ?? false
    }

    /// 数组字段：缺省或 `null` 都当作空数组；单个元素解码失败时跳过该元素。
    func quotaArray<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
        guard let items = try? decodeIfPresent([QuotaLossy<T>].self, forKey: key) else { return [] }
        return items.compactMap(\.value)
    }
}

struct QuotaLossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: any Decoder) throws {
        value = try? T(from: decoder)
    }
}
