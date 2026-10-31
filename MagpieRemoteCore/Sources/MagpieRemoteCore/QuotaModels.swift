import Foundation

// 「额度」页的数据模型。形状见 magpie 源码 internal/provider/{quotas,subscription_usage,quota_history}.go 与 internal/budget：
// - `GET /v1/magpie/quotas/cards`、`POST /v1/magpie/quotas/refresh` → `{"object":"list","data":[SubscriptionQuota]}`
// - `GET /v1/magpie/quotas` → `{"object":"list","data":[Quota]}`（与卡片字段大体相同，窗口多一个 `remaining`）
// - `GET /v1/magpie/quotas/history?days=` → `{"object":"list","data":[{provider,user,lines:[{name,points:[…]}]}]}`
// - `GET /v1/magpie/limit` → 调用方这把密钥自己的限额
// 所有字段都按「可能缺失 / 可能为 null」宽松解码。

/// 卡片种类：订阅（Claude / Codex 等）、套餐、预付余额。
public enum QuotaKind: String, Codable, Hashable, Sendable {
    case subscription, plan, balance, unknown

    public init(raw: String?) {
        self = raw.flatMap(QuotaKind.init(rawValue:)) ?? .unknown
    }
}

/// 一个额度窗口（例如「5 小时」「每周」）。`used` / `remaining` 是 0–100 的百分比。
public struct QuotaWindow: Decodable, Hashable, Sendable {
    public var name: String
    public var used: Double?
    public var remaining: Double?
    public var unlimited: Bool
    public var resetsAt: Date?
    /// 距重置的秒数（卡片接口有时只给这个）。
    public var resetSecs: Double?
    /// 供应商自己的计数，例如 `"248 / 2000"`。
    public var display: String?
    /// 只有文字、不该画进度条的窗口。
    public var text: String?
    public var amount: Double?
    public var limit: Double?
    public var unit: String?
    public var runsOutAt: Date?
    /// 预付余额（单位见 `unit`）；有它时 `used` 没有意义。
    public var balance: Double?

    enum CodingKeys: String, CodingKey {
        case name, used, remaining, unlimited, resetsAt, resetSecs, display, text, amount, limit, unit, runsOutAt, balance
    }

    public init(name: String, used: Double? = nil, remaining: Double? = nil, unlimited: Bool = false, resetsAt: Date? = nil,
                resetSecs: Double? = nil, display: String? = nil, text: String? = nil, amount: Double? = nil, limit: Double? = nil,
                unit: String? = nil, runsOutAt: Date? = nil, balance: Double? = nil) {
        self.name = name
        self.used = used
        self.remaining = remaining
        self.unlimited = unlimited
        self.resetsAt = resetsAt
        self.resetSecs = resetSecs
        self.display = display
        self.text = text
        self.amount = amount
        self.limit = limit
        self.unit = unit
        self.runsOutAt = runsOutAt
        self.balance = balance
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.quotaString(.name) ?? ""
        used = c.quotaDouble(.used)
        remaining = c.quotaDouble(.remaining)
        unlimited = c.quotaBool(.unlimited)
        resetsAt = c.quotaTime(.resetsAt)
        resetSecs = c.quotaDouble(.resetSecs)
        display = c.quotaString(.display)
        text = c.quotaString(.text)
        amount = c.quotaDouble(.amount)
        limit = c.quotaDouble(.limit)
        unit = c.quotaString(.unit)
        runsOutAt = c.quotaTime(.runsOutAt)
        balance = c.quotaDouble(.balance)
    }

    /// 剩余百分比 0–100；无限、只有文字、或是余额窗口时为 nil（不画进度条）。
    public var remainingPercent: Double? {
        if unlimited || text != nil || balance != nil { return nil }
        let value = remaining ?? used.map { 100 - $0 }
        return value.map { min(max($0, 0), 100) }
    }

    public var usedPercent: Double? { remainingPercent.map { 100 - $0 } }

    /// 重置时间：优先用 `resetsAt`，否则用读取时间加 `resetSecs` 推算。
    public func resetDate(readAt: Date?) -> Date? {
        if let resetsAt { return resetsAt }
        if let resetSecs, let readAt, resetSecs > 0 { return readAt.addingTimeInterval(resetSecs) }
        return nil
    }
}

/// 余额拆分中的一项（例如「赠送 ¥ 3.00」）。
public struct QuotaBalancePart: Decodable, Hashable, Sendable {
    public var label: String?
    public var text: String
    public var percent: Double?
    public var error: String?

    enum CodingKeys: String, CodingKey { case label, text, percent, error }

    public init(label: String? = nil, text: String, percent: Double? = nil, error: String? = nil) {
        self.label = label
        self.text = text
        self.percent = percent
        self.error = error
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = c.quotaString(.label)
        text = c.quotaString(.text) ?? ""
        percent = c.quotaDouble(.percent)
        error = c.quotaString(.error)
    }
}

/// 一个账号的额度卡片（订阅、套餐或余额）。
public struct QuotaCard: Decodable, Hashable, Identifiable, Sendable {
    public var provider: String
    public var name: String
    public var icon: String?
    public var kind: QuotaKind
    public var plan: String?
    public var user: String?
    public var alias: String?
    public var seat: String?
    public var windows: [QuotaWindow]
    /// 供应商给的显示文字（例如 `"¥ 23.71"`），不要当金额解析。
    public var balance: String?
    public var balanceSplit: [QuotaBalancePart]
    public var error: String?
    public var pluginError: String?
    public var needsAccessKey: Bool
    /// 有值表示这是那个时间读到的缓存值。
    public var asOf: Date?
    public var readAt: Date?
    public var readDeferred: Bool
    public var until: Date?
    public var renew: String?
    /// 来自另一台 magpie 的卡片（不能在这台主机上重新读取）。
    public var from: String?

    enum CodingKeys: String, CodingKey {
        case provider, name, icon, kind, plan, user, alias, seat, windows, balance, balanceSplit, error, pluginError,
             needsAccessKey, asOf, readAt, readDeferred, until, renew, from
    }

    public init(provider: String, name: String, icon: String? = nil, kind: QuotaKind = .subscription, plan: String? = nil,
                user: String? = nil, alias: String? = nil, seat: String? = nil, windows: [QuotaWindow] = [], balance: String? = nil,
                balanceSplit: [QuotaBalancePart] = [], error: String? = nil, pluginError: String? = nil, needsAccessKey: Bool = false,
                asOf: Date? = nil, readAt: Date? = nil, readDeferred: Bool = false, until: Date? = nil, renew: String? = nil, from: String? = nil) {
        self.provider = provider
        self.name = name
        self.icon = icon
        self.kind = kind
        self.plan = plan
        self.user = user
        self.alias = alias
        self.seat = seat
        self.windows = windows
        self.balance = balance
        self.balanceSplit = balanceSplit
        self.error = error
        self.pluginError = pluginError
        self.needsAccessKey = needsAccessKey
        self.asOf = asOf
        self.readAt = readAt
        self.readDeferred = readDeferred
        self.until = until
        self.renew = renew
        self.from = from
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = c.quotaString(.provider) ?? ""
        name = c.quotaString(.name) ?? provider
        icon = c.quotaString(.icon)
        kind = QuotaKind(raw: c.quotaString(.kind))
        plan = c.quotaString(.plan)
        user = c.quotaString(.user)
        alias = c.quotaString(.alias)
        seat = c.quotaString(.seat)
        windows = c.quotaArray(QuotaWindow.self, .windows)
        balance = c.quotaString(.balance)
        balanceSplit = c.quotaArray(QuotaBalancePart.self, .balanceSplit)
        error = c.quotaString(.error)
        // pluginError 的形状没有抓到过：字符串直接用，对象就取其中的 message。
        if let text = c.quotaString(.pluginError) {
            pluginError = text
        } else if let object = try? c.decodeIfPresent([String: QuotaLossy<String>].self, forKey: .pluginError) {
            pluginError = object["message"]?.value ?? object["error"]?.value
        } else {
            pluginError = nil
        }
        needsAccessKey = c.quotaBool(.needsAccessKey)
        asOf = c.quotaTime(.asOf)
        readAt = c.quotaTime(.readAt)
        readDeferred = c.quotaBool(.readDeferred)
        until = c.quotaTime(.until)
        renew = c.quotaString(.renew)
        from = c.quotaString(.from)
    }

    /// 同一账号的稳定标识：主机按 `provider|小写 user` 区分账号（与刷新节流的键一致）。
    public var id: String { [from ?? "", provider, user?.lowercased() ?? ""].joined(separator: "|") }

    /// 历史曲线的匹配键（历史接口里 user 已小写）。
    public var historyKey: String { QuotaHistorySeries.key(provider: provider, user: user) }

    /// 卡片上显示的账号名：别名 > 账号 > 套餐名。
    public var accountLabel: String {
        alias ?? user ?? plan ?? name
    }

    /// 别名之外再显示的副标题（账号与套餐）。
    public var accountDetail: String? {
        var parts: [String] = []
        if alias != nil, let user { parts.append(user) }
        if let plan, plan != accountLabel { parts.append(plan) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 余额显示文字：`balance` 原样显示；没有时把拆分项拼起来。
    public var balanceText: String? {
        if let balance { return balance }
        let parts = balanceSplit.filter { !$0.text.isEmpty }.map { part in part.label.map { "\($0) \(part.text)" } ?? part.text }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 能画进度条的窗口。
    public var meteredWindows: [QuotaWindow] { windows.filter { $0.remainingPercent != nil } }

    /// 最紧张的窗口剩余百分比（卡片右上角的大数字）。
    public var lowestRemaining: Double? { meteredWindows.compactMap(\.remainingPercent).min() }

    /// 要提示给用户的问题（读不到、需要访问密钥等）。
    public var problem: String? {
        if needsAccessKey { return "这个账号需要在 Mac 上的 magpie 里补填访问密钥。" }
        return error ?? pluginError
    }

    /// 是否能让这台主机重新读取（别的 magpie 转来的卡片不行）。
    public var canRefresh: Bool { from == nil && !provider.contains("/") }
}

/// 按供应商分组（同一供应商可能有多个账号）。
public struct QuotaGroup: Hashable, Identifiable, Sendable {
    public var provider: String
    public var title: String
    public var cards: [QuotaCard]
    public var id: String { provider }

    /// 保持主机返回的顺序：组按首次出现排序，组内按原顺序。
    public static func group(_ cards: [QuotaCard]) -> [QuotaGroup] {
        var order: [String] = []
        var map: [String: QuotaGroup] = [:]
        for card in cards {
            let key = card.from.map { "\($0)/\(card.provider)" } ?? card.provider
            if map[key] == nil {
                order.append(key)
                map[key] = QuotaGroup(provider: key, title: card.name, cards: [])
            }
            map[key]?.cards.append(card)
        }
        return order.compactMap { map[$0] }
    }
}

/// 列表响应 `{"object":"list","data":[…]}`；`data` 为 null 时当作空。
struct QuotaList<T: Decodable>: Decodable {
    let data: [T]
    enum CodingKeys: String, CodingKey { case data }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.data) else {
            throw DecodingError.keyNotFound(CodingKeys.data, .init(codingPath: [], debugDescription: "缺少 data"))
        }
        data = c.quotaArray(T.self, .data)
    }
}

// MARK: 历史

public struct QuotaHistoryPoint: Decodable, Hashable, Sendable {
    public var at: Date
    /// 剩余百分比 0–100。
    public var left: Double
    public var start: Date?
    public var resetsAt: Date?

    enum CodingKeys: String, CodingKey { case at, left, start, resetsAt }

    public init(at: Date, left: Double, start: Date? = nil, resetsAt: Date? = nil) {
        self.at = at
        self.left = left
        self.start = start
        self.resetsAt = resetsAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let at = c.quotaTime(.at), let left = c.quotaDouble(.left) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "历史点缺少 at / left"))
        }
        self.at = at
        self.left = min(max(left, 0), 100)
        start = c.quotaTime(.start)
        resetsAt = c.quotaTime(.resetsAt)
    }
}

public struct QuotaHistoryLine: Decodable, Hashable, Identifiable, Sendable {
    public var name: String
    public var points: [QuotaHistoryPoint]
    public var id: String { name }

    enum CodingKeys: String, CodingKey { case name, points }

    public init(name: String, points: [QuotaHistoryPoint]) {
        self.name = name
        self.points = points
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.quotaString(.name) ?? ""
        points = c.quotaArray(QuotaHistoryPoint.self, .points).sorted { $0.at < $1.at }
    }
}

/// 一个账号的历史曲线（每个窗口一条线）。
public struct QuotaHistorySeries: Decodable, Hashable, Identifiable, Sendable {
    public var provider: String
    public var user: String?
    public var lines: [QuotaHistoryLine]
    public var id: String { Self.key(provider: provider, user: user) }

    enum CodingKeys: String, CodingKey { case provider, user, lines }

    public init(provider: String, user: String?, lines: [QuotaHistoryLine]) {
        self.provider = provider
        self.user = user
        self.lines = lines
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = c.quotaString(.provider) ?? ""
        user = c.quotaString(.user)
        lines = c.quotaArray(QuotaHistoryLine.self, .lines)
    }

    public static func key(provider: String, user: String?) -> String {
        provider + "|" + (user?.lowercased() ?? "")
    }

    public var pointCount: Int { lines.reduce(0) { $0 + $1.points.count } }
}

/// 历史曲线可选的时间范围（主机最多保留 45 天）。
public enum QuotaHistoryRange: Int, CaseIterable, Hashable, Identifiable, Sendable {
    case week = 7, month = 30, all = 45
    public var id: Int { rawValue }
    public var days: Int { rawValue }
    public var title: String { "\(rawValue) 天" }
}

// MARK: 密钥自己的限额

/// `budget.Status`：一项限额在当前周期的用量。
public struct KeyBudget: Decodable, Hashable, Sendable {
    public var period: String
    public var days: Int?
    public var hours: Int?
    public var start: Date?
    public var reset: Date?
    public var calls: Int
    public var tokens: Int
    /// 美元。
    public var cost: Double
    public var tokenLimit: Int?
    public var costLimit: Double?
    public var tokensLeft: Int?
    public var costLeft: Double?
    public var spent: Bool

    enum CodingKeys: String, CodingKey {
        case period, days, hours, start, reset, calls, tokens, cost, tokenLimit, costLimit, tokensLeft, costLeft, spent
    }

    public init(period: String, days: Int? = nil, hours: Int? = nil, start: Date? = nil, reset: Date? = nil, calls: Int = 0,
                tokens: Int = 0, cost: Double = 0, tokenLimit: Int? = nil, costLimit: Double? = nil, tokensLeft: Int? = nil,
                costLeft: Double? = nil, spent: Bool = false) {
        self.period = period
        self.days = days
        self.hours = hours
        self.start = start
        self.reset = reset
        self.calls = calls
        self.tokens = tokens
        self.cost = cost
        self.tokenLimit = tokenLimit
        self.costLimit = costLimit
        self.tokensLeft = tokensLeft
        self.costLeft = costLeft
        self.spent = spent
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        period = c.quotaString(.period) ?? ""
        days = c.quotaInt(.days)
        hours = c.quotaInt(.hours)
        start = c.quotaTime(.start)
        reset = c.quotaTime(.reset)
        calls = c.quotaInt(.calls) ?? 0
        tokens = c.quotaInt(.tokens) ?? 0
        cost = c.quotaDouble(.cost) ?? 0
        tokenLimit = c.quotaInt(.tokenLimit).flatMap { $0 > 0 ? $0 : nil }
        costLimit = c.quotaDouble(.costLimit).flatMap { $0 > 0 ? $0 : nil }
        tokensLeft = c.quotaInt(.tokensLeft)
        costLeft = c.quotaDouble(.costLeft)
        spent = c.quotaBool(.spent)
    }

    /// 「每 5 小时」「每天」等。
    public var periodText: String {
        switch period {
        case "day": return "每天"
        case "week": return "每周"
        case "month": return "每月"
        case "days": return days.map { "每 \($0) 天" } ?? "按天"
        case "hours": return hours.map { "每 \($0) 小时" } ?? "按小时"
        default: return period.isEmpty ? "限额" : period
        }
    }

    /// 已用比例 0...1：词元与金额两项里更紧的一项；都不限时为 nil。
    public var usedFraction: Double? {
        var fractions: [Double] = []
        if let tokenLimit { fractions.append(Double(tokens) / Double(tokenLimit)) }
        if let costLimit { fractions.append(cost / costLimit) }
        if spent { return 1 }
        return fractions.max().map { min(max($0, 0), 1) }
    }

    public var remainingPercent: Double? { usedFraction.map { (1 - $0) * 100 } }

    /// 用量说明，例如「已用 4.45 万 / 5 万 词元 · $0.52 / $5.00 · 17 次调用」。
    public var usageText: String {
        var parts: [String] = []
        if let tokenLimit {
            parts.append("已用 \(QuotaFormat.tokens(tokens)) / \(QuotaFormat.tokens(tokenLimit)) 词元")
        } else {
            parts.append("已用 \(QuotaFormat.tokens(tokens)) 词元")
        }
        if let costLimit {
            parts.append("\(QuotaFormat.usd(cost)) / \(QuotaFormat.usd(costLimit))")
        } else if cost > 0 {
            parts.append(QuotaFormat.usd(cost))
        }
        parts.append("\(calls) 次调用")
        return parts.joined(separator: " · ")
    }
}

/// `GET /v1/magpie/limit`：调用方这把密钥自己的限额。
public struct KeyLimit: Decodable, Hashable, Sendable {
    public var limited: Bool
    public var key: String?
    public var expires: Date?
    /// 起约束作用的那一项。
    public var limit: KeyBudget?
    public var limits: [KeyBudget]
    /// 签发者的限额（签发出来的密钥同时受它约束）。
    public var issuerLimits: [KeyBudget]

    enum CodingKeys: String, CodingKey { case limited, key, expires, limit, limits, issuerLimits }

    public init(limited: Bool, key: String? = nil, expires: Date? = nil, limit: KeyBudget? = nil, limits: [KeyBudget] = [], issuerLimits: [KeyBudget] = []) {
        self.limited = limited
        self.key = key
        self.expires = expires
        self.limit = limit
        self.limits = limits
        self.issuerLimits = issuerLimits
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        limited = c.quotaBool(.limited)
        key = c.quotaString(.key)
        expires = c.quotaTime(.expires)
        limit = try? c.decodeIfPresent(KeyBudget.self, forKey: .limit)
        limits = c.quotaArray(KeyBudget.self, .limits)
        issuerLimits = c.quotaArray(KeyBudget.self, .issuerLimits)
    }

    /// 要逐项显示的限额：自己的各项 + 签发者的各项（去重）。
    public var allBudgets: [KeyBudget] {
        var result = limits
        if result.isEmpty, let limit { result = [limit] }
        for item in issuerLimits where !result.contains(item) { result.append(item) }
        return result
    }
}

// MARK: 页面快照与刷新

/// 额度页要显示的内容。
public enum QuotaSnapshot: Hashable, Sendable {
    /// 订阅 / 套餐 / 余额卡片（可能为空：主机上没有登录任何订阅账号）。
    case cards([QuotaCard])
    /// 这把网关密钥受限（`gateway_key_held`），主机不告诉它账号额度，只能看它自己的限额。
    case keyHeld(KeyLimit)
}

/// 下拉刷新的结果。
public enum QuotaRefreshOutcome: Hashable, Sendable {
    /// 至少一张卡片的读取时间变了：主机确实重新读了。
    case refreshed
    /// 读取时间都没变：主机 30 秒内刚刷新过，这次返回的是缓存。
    case cached
    /// 没有可比较的读取时间。
    case unknown

    /// 比较刷新前后的 `readAt` 判断是否命中主机的 30 秒节流。
    public static func compare(before: [QuotaCard], after: [QuotaCard]) -> QuotaRefreshOutcome {
        let old = Dictionary(before.map { ($0.id, $0.readAt) }, uniquingKeysWith: { first, _ in first })
        var compared = false
        for card in after {
            guard let newRead = card.readAt else { continue }
            guard let entry = old[card.id] else { return .refreshed }
            guard let oldRead = entry else { return .refreshed }
            compared = true
            if newRead > oldRead { return .refreshed }
        }
        return compared ? .cached : .unknown
    }
}

/// 客户端的刷新节流：主机对每个 `provider|小写 user` 30 秒内只真正重读一次，App 也不在这期间重复请求。
public struct QuotaRefreshThrottle: Sendable {
    public static let gap: TimeInterval = 30
    public static let allKey = "*"
    private var last: [String: Date] = [:]

    public init() {}

    /// 还要等多久（秒）；可以刷新时为 nil。
    public func wait(for key: String = Self.allKey, now: Date = Date()) -> TimeInterval? {
        let times = key == Self.allKey ? [last[Self.allKey]] : [last[key], last[Self.allKey]]
        guard let recent = times.compactMap({ $0 }).max() else { return nil }
        let left = Self.gap - now.timeIntervalSince(recent)
        return left > 0 ? left : nil
    }

    public mutating func record(_ key: String = Self.allKey, now: Date = Date()) {
        last[key] = now
    }
}
