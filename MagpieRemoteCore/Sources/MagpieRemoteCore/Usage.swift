import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// 「用量」页的数据：网关 `GET /v1/magpie/usage`（汇总）、`GET /v1/magpie/usage/requests`（请求记录，分页）、
// `GET /v1/magpie/concurrency`（当前并发）。字段以 spec/gateway.md §6、§7、§11 与 spec/live 实测为准：
// - 时间是可读字符串（`Sun 2026-11-01 2:40 AM CST (UTC+08:00)`），也兼容 RFC3339（含纳秒）；
// - 花费是美元浮点数；Totals 字段直接铺在对象里（不是嵌套对象）；
// - 受限密钥（held key）读汇总 / 并发得到 403 `gateway_key_held`，但可以读自己的请求记录。

public enum UsageEndpoint {
    public static let summary = "/v1/magpie/usage"
    public static let requests = "/v1/magpie/usage/requests"
    public static let concurrency = "/v1/magpie/concurrency"
    /// 受限密钥被拒绝时的错误码。
    public static let keyHeldCode = "gateway_key_held"
}

// MARK: - 时间

/// magpie 返回的时间：保留原文，另解析出 `Date`（解析失败时为 nil，界面退回显示原文）。
public struct UsageTimestamp: Hashable, Sendable, Codable {
    public var raw: String
    public var date: Date?

    public init(raw: String) {
        self.raw = raw
        self.date = Self.parse(raw)
    }

    public init(date: Date, timeZone: TimeZone = .current) {
        self.raw = Self.format(date, timeZone: timeZone)
        self.date = date
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self.init(raw: text)
        } else if let seconds = try? container.decode(Double.self) {
            self.init(raw: String(seconds))
            date = Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
        } else {
            self.init(raw: "")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    nonisolated(unsafe) private static let human = try! NSRegularExpression(
        pattern: #"^[A-Za-z]{3},? (\d{4})-(\d{2})-(\d{2}) (\d{1,2}):(\d{2})(?::(\d{2}))? ?([AaPp][Mm]).*\(UTC([+-])(\d{1,2}):?(\d{2})\)\s*$"#)
    nonisolated(unsafe) private static let rfc3339 = try! NSRegularExpression(
        pattern: #"^(\d{4})-(\d{2})-(\d{2})[Tt ](\d{2}):(\d{2}):(\d{2})(\.\d+)?([Zz]|[+-]\d{2}:?\d{2})$"#)

    /// 解析 magpie 的两种时间写法；都不匹配时返回 nil。
    public static func parse(_ text: String) -> Date? {
        let text = text.trimmingCharacters(in: .whitespaces)
        let range = NSRange(text.startIndex..., in: text)
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String? {
            guard let r = Range(match.range(at: index), in: text) else { return nil }
            return String(text[r])
        }
        if let m = human.firstMatch(in: text, range: range) {
            guard let year = group(m, 1).flatMap(Int.init), let month = group(m, 2).flatMap(Int.init),
                  let day = group(m, 3).flatMap(Int.init), var hour = group(m, 4).flatMap(Int.init),
                  let minute = group(m, 5).flatMap(Int.init), let ampm = group(m, 7)?.uppercased(),
                  let sign = group(m, 8), let oh = group(m, 9).flatMap(Int.init), let om = group(m, 10).flatMap(Int.init),
                  (1...12).contains(hour) else { return nil }
            let second = group(m, 6).flatMap(Int.init) ?? 0
            if ampm == "AM" { if hour == 12 { hour = 0 } } else if hour != 12 { hour += 12 }
            let offset = (oh * 3600 + om * 60) * (sign == "-" ? -1 : 1)
            return make(year, month, day, hour, minute, second, 0, offset)
        }
        if let m = rfc3339.firstMatch(in: text, range: range) {
            guard let year = group(m, 1).flatMap(Int.init), let month = group(m, 2).flatMap(Int.init),
                  let day = group(m, 3).flatMap(Int.init), let hour = group(m, 4).flatMap(Int.init),
                  let minute = group(m, 5).flatMap(Int.init), let second = group(m, 6).flatMap(Int.init),
                  let zone = group(m, 8) else { return nil }
            var fraction = 0.0
            if let f = group(m, 7) { fraction = Double("0" + f) ?? 0 }
            var offset = 0
            if zone.uppercased() != "Z" {
                let digits = zone.dropFirst().replacingOccurrences(of: ":", with: "")
                let h = Int(digits.prefix(2)) ?? 0, mm = Int(digits.suffix(2)) ?? 0
                offset = (h * 3600 + mm * 60) * (zone.hasPrefix("-") ? -1 : 1)
            }
            return make(year, month, day, hour, minute, second, fraction, offset)
        }
        return nil
    }

    private static func make(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int, _ fraction: Double, _ offset: Int) -> Date? {
        guard let zone = TimeZone(secondsFromGMT: offset) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s)
        guard let date = calendar.date(from: components) else { return nil }
        return date.addingTimeInterval(fraction)
    }

    /// 生成与 magpie 相同的可读写法（fixture 用）。
    public static func format(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE yyyy-MM-dd h:mm a"
        let offset = timeZone.secondsFromGMT(for: date)
        let sign = offset < 0 ? "-" : "+"
        let abs = Swift.abs(offset)
        let abbreviation = timeZone.abbreviation(for: date) ?? "UTC"
        return formatter.string(from: date) + " \(abbreviation) (UTC\(sign)\(String(format: "%02d:%02d", abs / 3600, abs % 3600 / 60)))"
    }
}

// MARK: - 解码辅助

struct UsageKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension KeyedDecodingContainer where Key == UsageKey {
    func int(_ key: String) -> Int {
        if let v = try? decodeIfPresent(Int.self, forKey: UsageKey(key)) { return v }
        if let v = try? decodeIfPresent(Double.self, forKey: UsageKey(key)) { return Int(v) }
        return 0
    }
    func int64(_ key: String) -> Int64? {
        if let v = try? decodeIfPresent(Int64.self, forKey: UsageKey(key)) { return v }
        if let v = try? decodeIfPresent(Double.self, forKey: UsageKey(key)) { return Int64(v) }
        return nil
    }
    func double(_ key: String) -> Double {
        ((try? decodeIfPresent(Double.self, forKey: UsageKey(key))) ?? nil) ?? 0
    }
    func bool(_ key: String) -> Bool {
        ((try? decodeIfPresent(Bool.self, forKey: UsageKey(key))) ?? nil) ?? false
    }
    /// 字符串；缺失或空串时为 nil。
    func string(_ key: String) -> String? {
        guard let v = (try? decodeIfPresent(String.self, forKey: UsageKey(key))) ?? nil, !v.isEmpty else { return nil }
        return v
    }
    func list<T: Decodable>(_ type: T.Type, _ key: String) -> [T] {
        ((try? decodeIfPresent([T].self, forKey: UsageKey(key))) ?? nil) ?? []
    }
    func timestamp(_ key: String) -> UsageTimestamp? {
        (try? decodeIfPresent(UsageTimestamp.self, forKey: UsageKey(key))) ?? nil
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - 汇总

public enum UsagePeriod: String, CaseIterable, Identifiable, Hashable, Sendable, Codable {
    case today
    case week = "7d"
    case month = "30d"
    case all

    public var id: String { rawValue }
    /// 分段控件上的短标题。
    public var title: String {
        switch self {
        case .today: "今天"
        case .week: "7 天"
        case .month: "30 天"
        case .all: "全部"
        }
    }
    /// 卡片标题。
    public var heading: String {
        switch self {
        case .today: "今天"
        case .week: "近 7 天"
        case .month: "近 30 天"
        case .all: "全部时间"
        }
    }
}

/// magpie 的 `usage.Totals`（直接铺在汇总、分组、序列点上）。
public struct UsageTotals: Hashable, Sendable, Decodable {
    public var calls = 0
    public var errors = 0
    public var retried = 0
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0
    public var reasoning = 0
    /// 估算花费，美元。
    public var cost = 0.0
    /// 没有已知价格的请求数（花费里没算它们）。
    public var unpriced = 0
    public var timed = 0
    /// 所有计时请求的首字耗时之和（毫秒）。
    public var ttftMs = 0
    public var decodeMs = 0
    public var decodeOut = 0
    /// 计了速度的回复数（`decode_n`）。
    public var decodeN = 0
    /// 只能从会话文件估出「至少多快」的回复：词元、毫秒与条数（`floor_out` / `floor_ms` / `floor_n`）。
    public var floorOut = 0
    public var floorMs = 0
    public var floorN = 0
    /// magpie 因为回复陷入死循环而截断的请求数。
    public var loops = 0
    /// 缓存写入里保留一小时的部分。
    public var cacheWrite1h = 0
    /// 供应商不报告缓存的词元与请求数（命中率不算它们）。
    public var cacheUnknown = 0
    public var cacheUnknownCalls = 0

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: UsageKey.self)
        calls = c.int("calls"); errors = c.int("errors"); retried = c.int("retried")
        input = c.int("input"); output = c.int("output")
        cacheRead = c.int("cache_read"); cacheWrite = c.int("cache_write"); reasoning = c.int("reasoning")
        cost = c.double("cost"); unpriced = c.int("unpriced")
        timed = c.int("timed"); ttftMs = c.int("ttft_ms"); decodeMs = c.int("decode_ms"); decodeOut = c.int("decode_out")
        decodeN = c.int("decode_n"); floorOut = c.int("floor_out"); floorMs = c.int("floor_ms"); floorN = c.int("floor_n")
        loops = c.int("loops"); cacheWrite1h = c.int("cache_write_1h")
        cacheUnknown = c.int("cache_unknown"); cacheUnknownCalls = c.int("cache_unknown_calls")
    }

    /// 输入 + 输出（不含缓存），magpie「概览」默认的词元口径。
    public var inOut: Int { input + output }
    /// 缓存命中率：提示里从缓存读的比例；不报告缓存的供应商不计入。没有可算的提示时为 nil（magpie `cacheHitOf`）。
    public var cacheHitRate: Double? {
        let prompt = input + cacheRead + cacheWrite - cacheUnknown
        return prompt > 0 ? Double(cacheRead) / Double(prompt) : nil
    }
    /// 估出的「至少多快」（词元 / 秒）。
    public var floorSpeed: Double? { floorMs > 0 ? Double(floorOut) / (Double(floorMs) / 1000) : nil }

    /// 输入 + 输出 + 缓存读写（与 magpie 页面的「词元」口径一致）。
    public var tokens: Int { input + output + cacheRead + cacheWrite }
    /// 平均首字耗时（毫秒）。
    public var meanTTFTms: Int? { timed > 0 ? ttftMs / timed : nil }
    /// 输出速度（词元 / 秒）。
    public var tokensPerSecond: Double? { decodeMs > 0 ? Double(decodeOut) / (Double(decodeMs) / 1000) : nil }

    public static func + (a: UsageTotals, b: UsageTotals) -> UsageTotals {
        var t = a
        t.calls += b.calls; t.errors += b.errors; t.retried += b.retried
        t.input += b.input; t.output += b.output; t.cacheRead += b.cacheRead; t.cacheWrite += b.cacheWrite
        t.reasoning += b.reasoning; t.cost += b.cost; t.unpriced += b.unpriced
        t.timed += b.timed; t.ttftMs += b.ttftMs; t.decodeMs += b.decodeMs; t.decodeOut += b.decodeOut
        t.decodeN += b.decodeN; t.floorOut += b.floorOut; t.floorMs += b.floorMs; t.floorN += b.floorN
        t.loops += b.loops; t.cacheWrite1h += b.cacheWrite1h; t.cacheUnknown += b.cacheUnknown; t.cacheUnknownCalls += b.cacheUnknownCalls
        return t
    }
}

/// 汇总里的一个分组（模型 / Agent / 账号 / 网关密钥 / 供应商密钥）。
public struct UsageGroup: Hashable, Sendable, Identifiable, Decodable {
    public var id: String
    public var name: String?
    public var sub: String?
    public var icon: String?
    public var provider: String?
    public var model: String?
    public var account: String?
    public var agent: String?
    public var providerKeyId: String?
    public var providerKeyName: String?
    public var callerKeyId: String?
    public var callerKeyName: String?
    public var totals: UsageTotals

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: UsageKey.self)
        id = c.string("id") ?? ""
        name = c.string("name"); sub = c.string("sub"); icon = c.string("icon")
        provider = c.string("provider"); model = c.string("model"); account = c.string("account"); agent = c.string("agent")
        providerKeyId = c.string("providerKeyId"); providerKeyName = c.string("providerKeyName")
        callerKeyId = c.string("callerKeyId"); callerKeyName = c.string("callerKeyName")
        totals = try UsageTotals(from: decoder)
    }

    init(id: String, name: String?, sub: String? = nil, provider: String? = nil, model: String? = nil, account: String? = nil,
         providerKeyId: String? = nil, providerKeyName: String? = nil, callerKeyId: String? = nil, callerKeyName: String? = nil,
         totals: UsageTotals) {
        self.id = id; self.name = name; self.sub = sub; self.icon = nil; self.provider = provider; self.model = model
        self.account = account; self.agent = nil; self.providerKeyId = providerKeyId; self.providerKeyName = providerKeyName
        self.callerKeyId = callerKeyId; self.callerKeyName = callerKeyName; self.totals = totals
    }

    /// 给人看的名字：`callerKeys` 里 id 为 `none` 的是没带网关密钥的调用（本机程序）。
    public var displayName: String {
        if id == "none" && callerKeyName == nil && (name == nil || name == "none") { return "未用网关密钥（本机）" }
        return name ?? callerKeyName ?? providerKeyName ?? model ?? account ?? (id.isEmpty ? "未知" : id)
    }
}

public struct UsagePoint: Hashable, Sendable, Decodable {
    public var label: String
    public var time: UsageTimestamp?
    public var totals: UsageTotals

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: UsageKey.self)
        label = c.string("label") ?? ""
        time = c.timestamp("time")
        totals = try UsageTotals(from: decoder)
    }

    init(label: String, time: UsageTimestamp?, totals: UsageTotals) {
        self.label = label; self.time = time; self.totals = totals
    }
}

/// 分组维度（「用量」页的分组切换）。
public enum UsageDimension: String, CaseIterable, Identifiable, Hashable, Sendable {
    case model, agent, provider, account, callerKey

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .model: "模型"
        case .agent: "Agent"
        case .provider: "供应商"
        case .account: "账号"
        case .callerKey: "密钥"
        }
    }
}

/// 分组列表里的一行。
public struct UsageBreakdownItem: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var totals: UsageTotals
    /// 占比 0...1：有花费时按花费，否则按请求数。
    public var share: Double
    /// 词元占比 0...1（magpie「概览」列表的条形按词元算）。
    public var tokenShare: Double = 0
}

/// `GET /v1/magpie/usage` 的回复。
public struct UsageSummary: Hashable, Sendable, Decodable {
    public var period: String
    public var since: UsageTimestamp?
    public var totals: UsageTotals
    public var bucket: String?
    public var series: [UsagePoint]
    public var agents: [UsageGroup]
    public var models: [UsageGroup]
    public var accounts: [UsageGroup]
    public var callerKeys: [UsageGroup]
    public var providerKeys: [UsageGroup]
    public var sessionCount: Int

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: UsageKey.self)
        period = c.string("period") ?? ""
        since = c.timestamp("since")
        totals = try UsageTotals(from: decoder)
        bucket = c.string("bucket")
        series = c.list(UsagePoint.self, "series")
        agents = c.list(UsageGroup.self, "agents")
        models = c.list(UsageGroup.self, "models")
        accounts = c.list(UsageGroup.self, "accounts")
        callerKeys = c.list(UsageGroup.self, "callerKeys")
        providerKeys = c.list(UsageGroup.self, "providerKeys")
        sessionCount = c.int("sessionCount")
    }

    init(period: String, since: UsageTimestamp?, totals: UsageTotals, bucket: String?, series: [UsagePoint], agents: [UsageGroup],
         models: [UsageGroup], accounts: [UsageGroup], callerKeys: [UsageGroup], providerKeys: [UsageGroup], sessionCount: Int) {
        self.period = period; self.since = since; self.totals = totals; self.bucket = bucket; self.series = series
        self.agents = agents; self.models = models; self.accounts = accounts; self.callerKeys = callerKeys
        self.providerKeys = providerKeys; self.sessionCount = sessionCount
    }

    /// 某个维度的分组，按花费（其次请求数）从高到低。
    /// 汇总没有「供应商」分组，按模型分组的 `provider` 合并得到（模型分组覆盖所有调用）。
    public func breakdown(_ dimension: UsageDimension) -> [UsageBreakdownItem] {
        var items: [UsageBreakdownItem]
        switch dimension {
        case .model:
            items = models.map { .init(id: $0.id, title: $0.displayName, subtitle: $0.sub, totals: $0.totals, share: 0) }
        case .agent:
            items = agents.map { .init(id: $0.id, title: $0.displayName, subtitle: $0.id == $0.displayName ? nil : $0.id, totals: $0.totals, share: 0) }
        case .account:
            items = accounts.map { group in
                let parts = [group.sub, group.account == group.displayName ? nil : group.account].compactMap { $0 }
                return .init(id: group.id, title: group.displayName, subtitle: parts.joined(separator: " · ").nilIfEmpty, totals: group.totals, share: 0)
            }
        case .callerKey:
            items = callerKeys.map { .init(id: $0.id, title: $0.displayName, subtitle: nil, totals: $0.totals, share: 0) }
        case .provider:
            var order: [String] = []
            var names: [String: String] = [:]
            var sums: [String: UsageTotals] = [:]
            for group in models {
                let id = group.provider ?? group.id.split(separator: "/").first.map(String.init) ?? group.id
                if sums[id] == nil {
                    order.append(id)
                    names[id] = group.sub.map { String($0.components(separatedBy: " · ")[0]) } ?? id
                    sums[id] = UsageTotals()
                }
                sums[id] = sums[id]! + group.totals
            }
            items = order.map { id in
                .init(id: id, title: names[id]!, subtitle: names[id] == id ? nil : id, totals: sums[id]!, share: 0)
            }
        }
        let totalCost = items.reduce(0) { $0 + $1.totals.cost }
        let totalCalls = items.reduce(0) { $0 + $1.totals.calls }
        for i in items.indices {
            if totalCost > 0 { items[i].share = items[i].totals.cost / totalCost }
            else if totalCalls > 0 { items[i].share = Double(items[i].totals.calls) / Double(totalCalls) }
        }
        let totalTokens = items.reduce(0) { $0 + $1.totals.inOut }
        if totalTokens > 0 {
            for i in items.indices { items[i].tokenShare = Double(items[i].totals.inOut) / Double(totalTokens) }
        }
        return items.sorted {
            if $0.totals.cost != $1.totals.cost { return $0.totals.cost > $1.totals.cost }
            if $0.totals.calls != $1.totals.calls { return $0.totals.calls > $1.totals.calls }
            return $0.title < $1.title
        }
    }
}

// MARK: - 请求记录

/// 请求记录里的一行（`usageapi.Row`，只取 App 显示要用的字段；提示词与回复从不包含在内）。
public struct UsageRequestRow: Hashable, Sendable, Identifiable, Decodable {
    /// App 内的标识：优先 `route_id`，其次 `response_id`，否则由时间和内容拼出（同页重复时加后缀）。
    public var id: String
    public var time: UsageTimestamp
    public var routeId: Int64?
    public var agent: String
    public var agentName: String?
    public var provider: String
    public var providerName: String?
    public var host: String?
    public var providerAccount: String?
    public var providerKeyName: String?
    public var callerKeyId: String?
    public var callerKeyName: String?
    public var callerKeyLabel: String?
    /// 实际服务的模型。
    public var model: String
    /// 请求时写的模型（路由组时是组 id）。
    public var requested: String?
    public var served: String?
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0
    public var reasoning = 0
    public var effort: String?
    /// 总耗时（毫秒）。
    public var ms = 0
    public var ttftMs: Int?
    public var status = 0
    public var error: String?
    public var errorType: String?
    public var tries = 0
    public var endpoint: String?
    public var stop: String?
    public var session: String?
    public var cost = 0.0
    public var priced = false
    public var access: String?
    public var rejected = false
    public var responseId: String?
    /// 供应商给这次请求的 id。
    public var requestID: String?
    /// 不是对话本身的调用（子 Agent、起标题、权限检查…）的用途。
    public var kind: String?
    /// 发给供应商前在 magpie 里花的时间，以及其中脱敏、先失败的尝试、排队等名额的部分（毫秒）。
    public var sentMs: Int?
    public var ownMs: Int?
    public var maskingMs: Int?
    public var retriedMs: Int?
    public var queuedMs: Int?
    public var firstTextMs: Int?
    public var firstReasoningMs: Int?
    public var flowMs: Int?
    public var reasoningHidden = false
    /// 聚合商（OpenRouter 等）说在它后面实际回答的供应商。
    public var upstream: String?
    public var sessionProvider: String?
    public var sessionAccount: String?
    public var sessionOfficialLogin = false
    public var pricingModel: String?
    /// 通过同步拿到的另一台电脑上的调用。
    public var computer: String?
    public var computerName: String?
    /// 被算作某个 Agent 的客户端自己的名字。
    public var client: String?
    /// `log`：从 Agent 自己的会话文件读到的调用（网关没经手）。
    public var source: String?
    /// 回复里的模型跟发出去的不一样。
    public var swapped = false
    /// 远端 magpie 的路由组由组里某个成员回答。
    public var routed = false
    public var cacheWrite1h = 0
    public var cacheUnknown = false
    public var nativeSession: String?
    public var handedOn = false

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: UsageKey.self)
        time = c.timestamp("t") ?? UsageTimestamp(raw: "")
        routeId = c.int64("route_id")
        agent = c.string("agent") ?? ""
        agentName = c.string("agentName")
        provider = c.string("provider") ?? ""
        providerName = c.string("providerName")
        host = c.string("host")
        providerAccount = c.string("providerAccount")
        providerKeyName = c.string("providerKeyName")
        callerKeyId = c.string("callerKeyId")
        callerKeyName = c.string("callerKeyName")
        callerKeyLabel = c.string("callerKeyLabel")
        model = c.string("model") ?? ""
        requested = c.string("req")
        served = c.string("served")
        input = c.int("in"); output = c.int("out"); cacheRead = c.int("cache_read"); cacheWrite = c.int("cache_write")
        reasoning = c.int("reasoning")
        effort = c.string("effort")
        ms = c.int("ms")
        let ttft = c.int("ttft_ms")
        ttftMs = ttft > 0 ? ttft : nil
        status = c.int("status")
        error = c.string("err"); errorType = c.string("err_type")
        tries = c.int("tries")
        endpoint = c.string("ep"); stop = c.string("stop"); session = c.string("session")
        cost = c.double("cost"); priced = c.bool("priced")
        access = c.string("access"); rejected = c.bool("rejected"); responseId = c.string("response_id")
        func positive(_ key: String) -> Int? { let v = c.int(key); return v > 0 ? v : nil }
        requestID = c.string("rid"); kind = c.string("kind")
        sentMs = positive("sent_ms"); maskingMs = positive("masking_ms"); retriedMs = positive("retried_ms"); queuedMs = positive("queued_ms")
        ownMs = c.int64("own_ms").map { Int($0) }
        firstTextMs = positive("first_text_ms"); firstReasoningMs = positive("first_reasoning_ms"); flowMs = positive("flow_ms")
        reasoningHidden = c.bool("reasoning_hidden")
        upstream = c.string("upstream")
        sessionProvider = c.string("session_provider"); sessionAccount = c.string("session_account")
        sessionOfficialLogin = c.bool("session_official_login")
        pricingModel = c.string("pricing_model")
        computer = c.string("computer"); computerName = c.string("computerName")
        client = c.string("client"); source = c.string("source")
        swapped = c.bool("swapped"); routed = c.bool("routed")
        cacheWrite1h = c.int("cache_write_1h"); cacheUnknown = c.bool("cache_unknown")
        nativeSession = c.string("native_session"); handedOn = c.bool("handed_on")
        id = ""
        id = fallbackID
    }

    init(time: UsageTimestamp, routeId: Int64?, agent: String, agentName: String?, provider: String, providerName: String?, host: String?,
         providerAccount: String?, callerKeyId: String?, callerKeyName: String?, model: String, requested: String?,
         input: Int, output: Int, cacheRead: Int, cacheWrite: Int, reasoning: Int, ms: Int, ttftMs: Int?, status: Int,
         error: String?, errorType: String?, tries: Int, endpoint: String?, session: String?, cost: Double, priced: Bool, access: String?) {
        self.time = time; self.routeId = routeId; self.agent = agent; self.agentName = agentName; self.provider = provider
        self.providerName = providerName; self.host = host; self.providerAccount = providerAccount; self.providerKeyName = nil
        self.callerKeyId = callerKeyId; self.callerKeyName = callerKeyName; self.callerKeyLabel = callerKeyName; self.model = model
        self.requested = requested; self.served = status < 400 ? model : nil; self.input = input; self.output = output
        self.cacheRead = cacheRead; self.cacheWrite = cacheWrite; self.reasoning = reasoning; self.effort = nil; self.ms = ms
        self.ttftMs = ttftMs; self.status = status; self.error = error; self.errorType = errorType; self.tries = tries
        self.endpoint = endpoint; self.stop = status < 400 ? "stop" : nil; self.session = session; self.cost = cost; self.priced = priced
        self.access = access; self.rejected = false; self.responseId = nil
        self.id = ""
        self.id = fallbackID
    }

    var fallbackID: String {
        if let routeId { return "r\(routeId)" }
        if let responseId { return "p\(responseId)" }
        return "t\(time.raw)|\(model)|\(status)|\(ms)|\(input)|\(output)"
    }

    /// 是否失败：客户端收到的状态码 ≥ 400，或记录了错误。
    public var failed: Bool { status >= 400 || error != nil }
    /// 是否重试过（试了不止一次）。
    public var retried: Bool { tries > 1 }
    public var tokens: Int { input + output + cacheRead + cacheWrite }
    public var agentTitle: String { agentName ?? (agent.isEmpty ? "未知" : agent) }
    public var providerTitle: String? { providerName ?? provider.nilIfEmpty }
    public var callerKeyTitle: String? { callerKeyLabel ?? callerKeyName ?? callerKeyId }
    /// 请求的模型与实际服务的不同（路由组）时，给出请求时写的那个。
    public var requestedIfDifferent: String? {
        guard let requested, requested != model, !requested.hasSuffix("/" + model) else { return nil }
        return requested
    }
}

/// 筛选项（模型 / Agent / 密钥 / 供应商 / 账号）的一个可选值。
public struct UsageOption: Hashable, Sendable, Identifiable, Decodable {
    public var id: String
    public var name: String

    public init(id: String, name: String) { self.id = id; self.name = name }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: UsageKey.self)
        id = c.string("id") ?? ""
        name = c.string("name") ?? c.string("callerKeyName") ?? id
    }
}

/// `GET /v1/magpie/usage/requests` 的一页。
public struct UsageRequestPage: Hashable, Sendable, Decodable {
    public var period: String
    public var rows: [UsageRequestRow]
    public var offset: Int
    /// 符合筛选条件的总条数。
    public var total: Int
    /// 符合筛选条件的请求合计。
    public var totals: UsageTotals
    public var callerKeys: [UsageOption]
    public var agents: [UsageOption]
    public var providers: [UsageOption]
    /// 按模型的排名（`by.model`），其 id 正是 `model` 筛选要用的值。
    public var models: [UsageOption]
    public var accounts: [UsageOption]
    /// 趋势图：按小时 / 天 / 周（`bucket`），每个点再按维度拆开（`series[].by`）。
    public var bucket: String = ""
    public var series: [UsageLedgerPoint] = []
    /// 各维度的排名（`by`：model / modelAt / provider / agent / callerKey），词元多的在前。
    public var by: [String: [UsageShare]] = [:]
    /// 经网关的、读自会话文件的、客户端上报的三部分合计。
    public var through = UsageTotals()
    public var direct = UsageTotals()
    public var reported = UsageTotals()
    /// 这段时间里出现过的调用用途（筛选用）。
    public var purposes: [String] = []
    /// 这台电脑与同步来的其它电脑（只有一台时为空）。
    public var computers: [UsageShare] = []
    public var day: String?

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: UsageKey.self)
        period = c.string("period") ?? ""
        bucket = c.string("bucket") ?? ""
        series = c.list(UsageLedgerPoint.self, "series")
        by = ((try? c.decodeIfPresent([String: [UsageShare]].self, forKey: UsageKey("by"))) ?? nil) ?? [:]
        through = ((try? c.decodeIfPresent(UsageTotals.self, forKey: UsageKey("through"))) ?? nil) ?? UsageTotals()
        direct = ((try? c.decodeIfPresent(UsageTotals.self, forKey: UsageKey("direct"))) ?? nil) ?? UsageTotals()
        reported = ((try? c.decodeIfPresent(UsageTotals.self, forKey: UsageKey("reported"))) ?? nil) ?? UsageTotals()
        purposes = c.list(String.self, "purposes")
        computers = c.list(UsageShare.self, "computers")
        day = c.string("day")
        rows = Self.uniquified(c.list(UsageRequestRow.self, "rows"))
        offset = c.int("offset")
        total = c.int("total")
        totals = try UsageTotals(from: decoder)
        callerKeys = c.list(UsageOption.self, "callerKeys").map {
            $0.id == "none" && $0.name == "none" ? UsageOption(id: "none", name: "未用网关密钥（本机）") : $0
        }
        agents = c.list(UsageOption.self, "agents")
        providers = c.list(UsageOption.self, "providers")
        accounts = c.list(UsageOption.self, "accounts")
        if let by = try? c.nestedContainer(keyedBy: UsageKey.self, forKey: UsageKey("by")) {
            models = by.list(UsageOption.self, "model")
        } else {
            models = []
        }
    }

    init(period: String, rows: [UsageRequestRow], offset: Int, total: Int, totals: UsageTotals, callerKeys: [UsageOption],
         agents: [UsageOption], providers: [UsageOption], models: [UsageOption], accounts: [UsageOption]) {
        self.period = period; self.rows = Self.uniquified(rows); self.offset = offset; self.total = total; self.totals = totals
        self.callerKeys = callerKeys; self.agents = agents; self.providers = providers; self.models = models; self.accounts = accounts
    }

    static func uniquified(_ rows: [UsageRequestRow]) -> [UsageRequestRow] {
        var seen: [String: Int] = [:]
        return rows.map { row in
            var row = row
            let count = seen[row.id, default: 0]
            seen[row.id] = count + 1
            if count > 0 { row.id += "#\(count)" }
            return row
        }
    }
}

/// 请求记录的查询条件 → URL 参数（只发有值的；`failed` / `retried` 只认字面量 `1`）。
public struct UsageRequestQuery: Hashable, Sendable {
    public static let pageSize = 100
    public static let maxLimit = 500

    public var period: UsagePeriod
    public var offset: Int
    public var limit: Int
    public var failedOnly: Bool
    public var retriedOnly: Bool
    public var model: String?
    public var agent: String?
    public var callerKey: String?
    public var provider: String?
    public var account: String?
    /// 调用的用途（`purpose`，取自记录页的 `purposes`）。
    public var purpose: String?
    /// 哪台电脑（`computer`：`this` 或同步来的另一台的 id）。
    public var computer: String?
    /// 来源：`gateway` 经网关、`log` 读自会话文件、`reported` 客户端上报（`via`）。
    public var via: String?
    /// 只看某一天（`day`，YYYY-MM-DD，读者时区）。
    public var day: String?
    public var search: String

    public init(period: UsagePeriod = .today, offset: Int = 0, limit: Int = UsageRequestQuery.pageSize, failedOnly: Bool = false,
                retriedOnly: Bool = false, model: String? = nil, agent: String? = nil, callerKey: String? = nil,
                provider: String? = nil, account: String? = nil, purpose: String? = nil, computer: String? = nil,
                via: String? = nil, day: String? = nil, search: String = "") {
        self.period = period; self.offset = offset; self.limit = limit; self.failedOnly = failedOnly; self.retriedOnly = retriedOnly
        self.model = model; self.agent = agent; self.callerKey = callerKey; self.provider = provider; self.account = account
        self.purpose = purpose; self.computer = computer; self.via = via; self.day = day
        self.search = search
    }

    /// 是否设置了任何筛选（不算时间段与分页）。
    public var isFiltered: Bool {
        failedOnly || retriedOnly || model != nil || agent != nil || callerKey != nil || provider != nil || account != nil
            || purpose != nil || computer != nil || via != nil || day != nil || !trimmedSearch.isEmpty
    }

    public var trimmedSearch: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var queryItems: [URLQueryItem] {
        var items = [URLQueryItem(name: "period", value: period.rawValue)]
        items.append(URLQueryItem(name: "offset", value: String(max(0, offset))))
        items.append(URLQueryItem(name: "limit", value: String(min(max(1, limit), Self.maxLimit))))
        if failedOnly { items.append(URLQueryItem(name: "failed", value: "1")) }
        if retriedOnly { items.append(URLQueryItem(name: "retried", value: "1")) }
        for (name, value) in [("model", model), ("agent", agent), ("callerKey", callerKey), ("provider", provider), ("account", account),
                              ("purpose", purpose), ("computer", computer), ("via", via), ("day", day)] {
            if let value, !value.isEmpty { items.append(URLQueryItem(name: name, value: value)) }
        }
        if !trimmedSearch.isEmpty { items.append(URLQueryItem(name: "q", value: trimmedSearch)) }
        return items
    }

    /// 同样的条件，从头开始。
    public var firstPage: UsageRequestQuery {
        var q = self
        q.offset = 0
        return q
    }
}

/// 无限滚动的状态：按 offset 往后翻，直到 `offset >= total`。
public struct UsageRequestPager: Hashable, Sendable {
    public private(set) var query: UsageRequestQuery
    public private(set) var rows: [UsageRequestRow] = []
    public private(set) var total = 0
    public private(set) var totals = UsageTotals()
    /// 已从主机读到的行数（含去重时丢掉的），即下一页的 offset。
    public private(set) var fetched = 0
    public private(set) var loadedOnce = false

    public init(query: UsageRequestQuery) {
        self.query = query.firstPage
    }

    public var hasMore: Bool { !loadedOnce || fetched < total }

    /// 下一页的查询；已经读完时为 nil。
    public var nextQuery: UsageRequestQuery? {
        guard hasMore else { return nil }
        var q = query
        q.offset = fetched
        return q
    }

    /// 合入一页。页的 offset 与期望不符（过期的回复）时忽略并返回 false。
    @discardableResult
    public mutating func apply(_ page: UsageRequestPage, requestedOffset: Int) -> Bool {
        guard requestedOffset == fetched else { return false }
        if requestedOffset == 0 {
            rows = []
            totals = page.totals
        }
        var ids = Set(rows.map(\.id))
        for row in page.rows where ids.insert(row.id).inserted { rows.append(row) }
        fetched = requestedOffset + page.rows.count
        total = page.total
        loadedOnce = true
        // 主机返回空页却说还有更多（例如期间记录被清理）时停止，避免死循环。
        if page.rows.isEmpty { total = fetched }
        return true
    }
}

// MARK: - 并发

public struct ConcurrencyLane: Hashable, Sendable, Identifiable {
    /// `<provider id>#<key id>`，或只有供应商 id。
    public var id: String
    public var busy: Int
    public var waiting: Int
    public var limit: Int

    public var provider: String { String(id.split(separator: "#", maxSplits: 1).first ?? Substring(id)) }
    public var keyId: String? { id.contains("#") ? String(id.split(separator: "#", maxSplits: 1)[1]) : nil }
}

public struct ActiveRequest: Hashable, Sendable, Identifiable, Decodable {
    public var id: Int64
    public var agent: String
    public var model: String?
    public var provider: String?
    public var session: String?
    public var started: UsageTimestamp?
    public var ms: Int
    public var phase: String?

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: UsageKey.self)
        id = c.int64("id") ?? 0
        agent = c.string("agent") ?? ""
        model = c.string("model"); provider = c.string("provider"); session = c.string("session")
        started = c.timestamp("started")
        ms = c.int("ms")
        phase = c.string("phase")
    }

    init(id: Int64, agent: String, model: String?, provider: String?, ms: Int, phase: String?) {
        self.id = id; self.agent = agent; self.model = model; self.provider = provider; self.session = nil
        self.started = nil; self.ms = ms; self.phase = phase
    }

    public var phaseTitle: String {
        switch phase {
        case "slot": "排队等并发名额"
        case "rpm": "等速率限制"
        case "upstream": "上游处理中"
        default: "处理中"
        }
    }
}

/// `GET /v1/magpie/concurrency`。
public struct ConcurrencySnapshot: Hashable, Sendable, Decodable {
    /// 正在进行的 Agent 请求数。
    public var requests: Int
    /// 其中在排队等名额的。
    public var waiting: Int
    /// 等待工具结果的 Claude Code 回合。
    public var tools: Int
    public var lanes: [ConcurrencyLane]
    public var active: [ActiveRequest]

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: UsageKey.self)
        requests = c.int("requests"); waiting = c.int("waiting"); tools = c.int("tools")
        active = c.list(ActiveRequest.self, "active")
        var lanes: [ConcurrencyLane] = []
        if let data = try? c.nestedContainer(keyedBy: UsageKey.self, forKey: UsageKey("data")) {
            for key in data.allKeys {
                guard let lane = try? data.nestedContainer(keyedBy: UsageKey.self, forKey: key) else { continue }
                lanes.append(ConcurrencyLane(id: key.stringValue, busy: lane.int("busy"), waiting: lane.int("waiting"), limit: lane.int("limit")))
            }
        }
        self.lanes = lanes.sorted { $0.id < $1.id }
    }

    init(requests: Int, waiting: Int, tools: Int, lanes: [ConcurrencyLane], active: [ActiveRequest]) {
        self.requests = requests; self.waiting = waiting; self.tools = tools; self.lanes = lanes; self.active = active
    }

    public var isIdle: Bool { requests == 0 && active.isEmpty }
}

// MARK: - 受限密钥

/// 汇总 / 并发的读取结果：受限密钥（held key）读不到时给出主机的原话。
public enum UsageAccess<Value: Sendable & Hashable>: Hashable, Sendable {
    case available(Value)
    case held(message: String)

    public var value: Value? {
        if case .available(let value) = self { return value }
        return nil
    }
    public var isHeld: Bool {
        if case .held = self { return true }
        return false
    }
}

extension UsageEndpoint {
    /// 是否是受限密钥被拒（403 + `error.code == "gateway_key_held"`）。
    public static func isKeyHeld(status: Int, body: Data) -> Bool {
        guard status == 403,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return false }
        return (error["code"] as? String) == keyHeldCode
    }
}

// MARK: - 客户端

extension GatewayClient {
    public func usageSummary(period: UsagePeriod) async throws -> UsageAccess<UsageSummary> {
        try await fetchAllowingHeld(UsageEndpoint.summary, query: [URLQueryItem(name: "period", value: period.rawValue)])
    }

    public func usageRequests(_ query: UsageRequestQuery) async throws -> UsageRequestPage {
        guard let key, !key.isEmpty else { throw MagpieError.missingKey(.gatewayKey) }
        return try await get(UsageRequestPage.self, path: UsageEndpoint.requests, query: query.queryItems)
    }

    public func concurrency() async throws -> UsageAccess<ConcurrencySnapshot> {
        try await fetchAllowingHeld(UsageEndpoint.concurrency, query: [])
    }

    func fetchAllowingHeld<T: Decodable & Sendable & Hashable>(_ path: String, query: [URLQueryItem]) async throws -> UsageAccess<T> {
        guard let key, !key.isEmpty else { throw MagpieError.missingKey(.gatewayKey) }
        let request = try makeRequest(path, query: query)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MagpieError.from(error)
        }
        guard let http = response as? HTTPURLResponse else { throw MagpieError.unreachable(.other) }
        if UsageEndpoint.isKeyHeld(status: http.statusCode, body: data) {
            return .held(message: MagpieError.errorMessage(from: data) ?? "")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MagpieError.from(status: http.statusCode, body: data)
        }
        do {
            return .available(try JSONDecoder().decode(T.self, from: data))
        } catch {
            throw MagpieError.decoding(String(describing: error))
        }
    }
}
