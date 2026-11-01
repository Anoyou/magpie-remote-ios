import Foundation

// 网关密钥的限额、可用模型 / 账号、可看额度（官方 Gateway › Keys，internal/gui/assets/plugins/gateway/keys.js；
// 接口 POST /api/caller-keys/{limit-key,reset-limit-key,models-key,accounts-key,quotas-key}、GET /api/caller-keys/models）。
// 文案用官方中文（internal/gui/assets/i18n.js 的 zh）。

// MARK: 一条限额

/// 一条限额（magpie `access.Limit`）：周期 + Token 上限 / 估算费用上限。
public struct CallerKeyLimit: Hashable, Sendable {
    /// day / week / month（自然日、周、月），days（每 N 天），hours（每 N 小时）。
    public var period: String
    public var days: Int
    public var hours: Int
    public var tokens: Int
    public var cost: Double
    public var cacheReads: Bool

    public init(period: String = "day", days: Int = 0, hours: Int = 0, tokens: Int = 0, cost: Double = 0, cacheReads: Bool = false) {
        self.period = period
        self.days = days
        self.hours = hours
        self.tokens = tokens
        self.cost = cost
        self.cacheReads = cacheReads
    }

    public init(json: WebJSON) {
        period = json["period"]?.string ?? "day"
        days = json["days"]?.int ?? 0
        hours = json["hours"]?.int ?? 0
        tokens = json["tokens"]?.int ?? 0
        cost = json["cost"]?.double ?? 0
        cacheReads = json["cacheReads"]?.bool ?? false
    }

    /// 发给 `limit-key` 的 `limit`（官方 save：只发周期、上限、cacheReads，周期型再带 days / hours）。
    public var json: WebJSON {
        var out: [String: WebJSON] = ["period": .string(period), "tokens": .int(Int64(tokens)), "cost": .double(cost), "cacheReads": .bool(cacheReads)]
        if period == "days" { out["days"] = .int(Int64(days)) }
        if period == "hours" { out["hours"] = .int(Int64(hours)) }
        return .object(out)
    }

    /// 周期的说法（官方 perWords）：每日 / 每周 / 每月 / 每 10 天 / 每 5 小时。
    public static func perWords(_ period: String, days: Int, hours: Int) -> String {
        switch period {
        case "day": "每日"
        case "week": "每周"
        case "month": "每月"
        case "days": "每 \(days) 天"
        case "hours": "每 \(hours) 小时"
        default: period
        }
    }

    public var perWords: String { Self.perWords(period, days: days, hours: hours) }

    /// 编辑器里周期菜单的选项（官方 limitPeriods / limitPer）。
    public static let periods: [(value: String, title: String)] = [
        ("day", "每日"), ("week", "每周"), ("month", "每月"), ("days", "每 N 天"), ("hours", "每 N 小时"),
    ]

    /// 一把密钥最多几条限额（magpie `access.MaxLimits`）。
    public static let maxLimits = 5
}

// MARK: 用了多少

/// 一条限额现在用了多少（magpie `budget.Status`，`keys[].used` / `keys[].usedAll[]`）。
public struct KeyLimitUsage: Hashable, Sendable {
    public var period: String
    public var days: Int
    public var hours: Int
    public var start: Date?
    public var reset: Date?
    public var tokens: Int
    public var cost: Double
    public var unpriced: Int
    public var inFlight: Int
    public var tokenLimit: Int
    public var costLimit: Double
    public var tokensLeft: Int
    public var costLeft: Double
    /// 用完了：到 reset 之前都拒绝。
    public var spent: Bool

    public init(json: WebJSON) {
        period = json["period"]?.string ?? ""
        days = json["days"]?.int ?? 0
        hours = json["hours"]?.int ?? 0
        start = json["start"]?.string.flatMap(QuotaTime.parse)
        reset = json["reset"]?.string.flatMap(QuotaTime.parse)
        tokens = json["tokens"]?.int ?? 0
        cost = json["cost"]?.double ?? 0
        unpriced = json["unpriced"]?.int ?? 0
        inFlight = json["inFlight"]?.int ?? 0
        tokenLimit = json["tokenLimit"]?.int ?? 0
        costLimit = json["costLimit"]?.double ?? 0
        tokensLeft = json["tokensLeft"]?.int ?? 0
        costLeft = json["costLeft"]?.double ?? 0
        spent = json["spent"]?.bool ?? false
    }

    public var perWords: String { CallerKeyLimit.perWords(period, days: days, hours: hours) }
}

/// 官方 usd：100 美元以上取整，否则两位小数。
public func keyUSD(_ value: Double) -> String {
    value >= 100 ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
}

/// 重置时间的说法（官方 resetClock）：今天只写时刻，明天写「明天 HH:mm」，本周写星期几，再远写日期。
public func keyResetClock(_ at: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
    let time = DateFormatter()
    time.locale = Locale(identifier: "zh_CN")
    time.calendar = calendar
    time.timeZone = calendar.timeZone
    time.dateFormat = "HH:mm"
    let clock = time.string(from: at)
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: at)).day ?? 0
    if days <= 0 { return clock }
    if days == 1 { return "明天 \(clock)" }
    let weekday = (calendar.component(.weekday, from: now) + 5) % 7 // 周一 = 0
    let date = DateFormatter()
    date.locale = Locale(identifier: "zh_CN")
    date.calendar = calendar
    date.timeZone = calendar.timeZone
    date.dateFormat = days <= 6 - weekday ? "EEE" : "M月d日"
    return date.string(from: at) + " " + clock
}

// MARK: 密钥上的字段

extension WebCallerKey {
    /// 这把密钥的所有限额，第一条在前（官方 keyLimits）。
    public var limits: [CallerKeyLimit] {
        guard let first = raw["limit"], first.object != nil else { return [] }
        return [CallerKeyLimit(json: first)] + (raw["moreLimits"]?.array ?? []).map(CallerKeyLimit.init(json:))
    }

    /// 每条限额用了多少，和 `limits` 同序（官方 keyUsed：`usedAll`，旧版只有 `used`）。
    public var usages: [KeyLimitUsage] {
        if let all = raw["usedAll"]?.array, !all.isEmpty { return all.map(KeyLimitUsage.init(json:)) }
        if let used = raw["used"], used.object != nil, used["period"] != nil { return [KeyLimitUsage(json: used)] }
        return []
    }

    /// 最卡住它的那条（官方 bindingUsed）：用完的里面最晚重置的，否则第一条。
    public var bindingUsage: KeyLimitUsage? {
        let all = usages
        let spent = all.filter(\.spent)
        guard !spent.isEmpty else { return all.first }
        return spent.reduce(spent[0]) { a, b in (b.reset ?? .distantPast) > (a.reset ?? .distantPast) ? b : a }
    }

    /// 只能用的账号（`<provider>/<id>`）。
    public var accounts: [String] { raw["accounts"]?.strings ?? [] }
    /// 能看到可用部分的额度（官方「可看额度」）。
    public var quotas: Bool { raw["quotas"]?.bool ?? false }

    /// 限额按钮上的字（官方 gatewayLimitBadge）：没有时「限额」；否则「已用完 · 12.3 万 / 200 万 · $1.20 / $5.00 · 每日 · 另 1 条限额」。
    public var limitBadge: String {
        guard let u = bindingUsage else { return limits.isEmpty ? "限额" : (limitSummary ?? "限额") }
        var parts: [String] = []
        if u.tokenLimit > 0 { parts.append(UsageFormat.tokens(u.tokens) + " / " + UsageFormat.tokens(u.tokenLimit)) }
        if u.costLimit > 0 { parts.append(keyUSD(u.cost) + " / " + keyUSD(u.costLimit)) }
        let more = usages.count - 1
        var text = (u.spent ? "已用完 · " : "") + parts.joined(separator: " · ") + " · " + u.perWords
        if more > 0 { text += " · " + (more == 1 ? "另 1 条限额" : "另 \(more) 条限额") }
        return text
    }

    /// 一条限额下面那一行（官方 gatewayLimitLine）：「已用 … Token · 剩余 … · 估算费用 … · 明天 00:00 重置」。
    public func limitLine(_ u: KeyLimitUsage, now: Date = Date(), calendar: Calendar = .current) -> String {
        var parts: [String] = []
        if usages.count > 1 { parts.append(u.perWords) }
        if u.tokenLimit > 0 {
            parts.append("已用 \(UsageFormat.tokens(u.tokens)) / \(UsageFormat.tokens(u.tokenLimit)) Token · 剩余 \(UsageFormat.tokens(u.tokensLeft))")
        }
        if u.costLimit > 0 { parts.append("估算费用 \(keyUSD(u.cost)) / \(keyUSD(u.costLimit)) · 剩余 \(keyUSD(u.costLeft))") }
        if let reset = u.reset {
            let when = keyResetClock(reset, now: now, calendar: calendar)
            parts.append(u.spent ? "\(when) 前拒绝请求" : "\(when) 重置")
        }
        if u.inFlight > 0 { parts.append(u.inFlight == 1 ? "1 个请求进行中" : "\(u.inFlight) 个请求进行中") }
        return parts.joined(separator: " · ")
    }

    /// 可用模型按钮上的字（官方 gatewayModelsBadge）。`names`：账号 id → 显示名（`accountNames`）。
    public func modelsBadge(accountNames: [String: String] = [:]) -> String {
        let ms = models, accounts = accounts
        if ms.isEmpty && accounts.isEmpty { return "全部模型" }
        if !ms.isEmpty { return ms.count == 1 && accounts.isEmpty ? ms[0] : "\(ms.count) 个模型" }
        return accounts.count == 1 ? (accountNames[accounts[0]] ?? accounts[0]) : "\(accounts.count) 个账号"
    }

    /// 「重置额度？」的说明（官方 askResetLimit）。
    public func resetLimitMessage(index: Int, now: Date = Date(), calendar: Calendar = .current) -> String {
        let all = usages
        let u = index < all.count ? all[index] : nil
        switch u?.period {
        case "days": return "\(name) 已用的 Token 和费用一起清零，并从现在开始新的 \(u?.days ?? 0) 天周期。"
        case "hours": return "\(name) 已用的 Token 和费用一起清零，并从现在开始新的 \(u?.hours ?? 0) 小时周期。"
        default:
            let when = u?.reset.map { keyResetClock($0, now: now, calendar: calendar) } ?? ""
            return "\(name) 已用的 Token 和费用一起清零，本周期内此前的调用不再计入；周期仍在 \(when) 重置。"
        }
    }
}

extension WebCallerKeys {
    /// 账号 id → 显示名（`accountNames`）。
    public static func accountNames(_ json: WebJSON) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in json["accountNames"]?.object ?? [:] { if let name = value.string { out[key] = name } }
        return out
    }
}

// MARK: 编辑一条限额

/// 限额编辑器的草稿（官方 limitDraft / gatewayLimitEditor）：什么都不发，直到「保存」。
public struct KeyLimitDraft: Hashable, Sendable {
    /// 第几条（等于已有条数时是在新加一条）。
    public var index: Int
    public var period: String
    public var days: String
    public var hours: String
    public var tokens: String
    public var cost: String
    public var cacheReads: Bool
    /// 原来的那条（新加时为 nil）。
    public let kept: CallerKeyLimit?
    /// 这把密钥原有几条。
    public let count: Int

    /// 第 n 条的草稿；n 等于条数时是新的一条，周期选一个还没有的（官方：一周搭配 5 小时）。
    public init(key: WebCallerKey, index n: Int) {
        let limits = key.limits
        index = n
        count = limits.count
        kept = n < limits.count ? limits[n] : nil
        let taken = limits.map(\.period)
        let l = kept ?? CallerKeyLimit(period: "", tokens: 0)
        period = !l.period.isEmpty ? l.period : n > 0 ? (["week", "hours", "day", "month"].first { !taken.contains($0) } ?? "days") : "day"
        days = l.days > 0 ? String(l.days) : ""
        hours = l.hours > 0 ? String(l.hours) : (n > 0 && period == "hours" ? "5" : "")
        tokens = l.tokens > 0 ? String(l.tokens) : ""
        cost = l.cost > 0 ? Self.plain(l.cost) : ""
        cacheReads = l.cacheReads
    }

    public var isNew: Bool { index >= count }

    /// 一个数量，照官方 limitTokens：2000000、2,000,000、500k、2M、1.5m、100万、1亿；空为 0，认不出为 nil。
    public static func tokens(_ text: String) -> Int? {
        let s = text.lowercased().filter { !",_ \t\n".contains($0) }
        if s.isEmpty { return 0 }
        let units: [Character: Double] = ["k": 1e3, "m": 1e6, "b": 1e9, "万": 1e4, "亿": 1e8]
        var number = s
        var mult = 1.0
        if let last = s.last, let unit = units[last] { mult = unit; number = String(s.dropLast()) }
        guard number.range(of: #"^\d+(\.\d+)?$"#, options: .regularExpression) != nil, let value = Double(number) else { return nil }
        return Int((value * mult).rounded())
    }

    /// 美元，照官方 limitCost：可带 $；空为 0，认不出为 nil。
    public static func cost(_ text: String) -> Double? {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("$") || s.hasPrefix("＄") { s.removeFirst() }
        if s.isEmpty { return 0 }
        guard s.range(of: #"^\d+(\.\d+)?$"#, options: .regularExpression) != nil else { return nil }
        return Double(s)
    }

    /// 1…max 的整数，否则 nil（官方 limitDays / limitHours）。
    static func whole(_ text: String, max: Int) -> Int? {
        let s = text.trimmingCharacters(in: .whitespaces)
        guard s.range(of: #"^\d{1,4}$"#, options: .regularExpression) != nil, let n = Int(s), n >= 1, n <= max else { return nil }
        return n
    }

    static func plain(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    /// 输错时的提示（官方 update 的 bad）；没问题为 nil。
    public var problem: String? {
        if period == "days" && Self.whole(days, max: 3650) == nil { return "天数应为 1 到 3650 的整数" }
        if period == "hours" && Self.whole(hours, max: 8760) == nil { return "小时数应为 1 到 8760 的整数" }
        if Self.tokens(tokens) == nil { return "Token 应为数量，例如 2000000、2M 或 200万" }
        if Self.cost(cost) == nil { return "费用以美元计，例如 5 或 2.50" }
        return nil
    }

    /// 和原来那条比改过没有。
    public var changed: Bool {
        let k = kept ?? CallerKeyLimit()
        if period != (kept?.period ?? "day") || Self.tokens(tokens) != k.tokens || Self.cost(cost) != k.cost || cacheReads != k.cacheReads { return true }
        if period == "days" && Self.whole(days, max: 3650) != k.days { return true }
        if period == "hours" && Self.whole(hours, max: 8760) != k.hours { return true }
        return false
    }

    /// 能不能保存：没输错、改过，新加的一条要有上限。
    public var canSave: Bool {
        guard problem == nil, changed else { return false }
        return !isNew || (Self.tokens(tokens) ?? 0) > 0 || (Self.cost(cost) ?? 0) > 0
    }

    /// 保存后的这条；两个上限都空 = 取消这条（nil）。
    public var limit: CallerKeyLimit? {
        let tk = Self.tokens(tokens) ?? 0, c = Self.cost(cost) ?? 0
        guard tk > 0 || c > 0 else { return nil }
        return CallerKeyLimit(period: period, days: period == "days" ? Self.whole(days, max: 3650) ?? 0 : 0,
                        hours: period == "hours" ? Self.whole(hours, max: 8760) ?? 0 : 0, tokens: tk, cost: c, cacheReads: cacheReads)
    }

    /// 有几条（或正在新加）时要带 index（官方：which 存在时才发 index）。
    public var sendsIndex: Bool { count > 1 || (isNew && count > 0) }

    /// `POST /api/caller-keys/limit-key` 的请求体。
    public func body(key: String) -> WebJSON {
        var out: [String: WebJSON] = ["key": .string(key), "limit": limit?.json ?? .null]
        if sendsIndex { out["index"] = .int(Int64(index)) }
        return .object(out)
    }

    /// 保存后的提示（官方「已保存 X 的限额」「已取消 X 的限额」）。
    public func savedSaid(name: String) -> String { limit != nil ? "已保存 \(name) 的限额" : "已取消 \(name) 的限额" }
}

extension WebRequests {
    /// `reset-limit-key`：几条限额时只重置第 index 条，只有一条时不带 index（官方 askResetLimit）。
    public static func callerKeyResetLimit(_ key: WebCallerKey, index: Int) -> WebJSON {
        key.usages.count > 1 ? ["key": .string(key.id), "index": .int(Int64(index))] : ["key": .string(key.id)]
    }

    /// `models-key`：空 = 全部模型。
    public static func callerKeyModels(_ key: String, models: [String]) -> WebJSON {
        ["key": .string(key), "models": .strings(models)]
    }

    /// `accounts-key`：空 = 全部账号。
    public static func callerKeyAccounts(_ key: String, accounts: [String]) -> WebJSON {
        ["key": .string(key), "accounts": .strings(accounts)]
    }

    /// `quotas-key`。
    public static func callerKeyQuotas(_ key: String, on: Bool) -> WebJSON {
        ["key": .string(key), "quotas": .bool(on)]
    }
}

// MARK: 可用模型 / 账号的选项

/// `GET /api/caller-keys/models`：可以限定的模型（路由组在前，然后每个供应商的模型）与账号。
public struct CallerKeyModels: Hashable, Sendable {
    public struct Model: Hashable, Sendable {
        public var id: String
        public var name: String
        public var provider: String
        public var providerName: String
        public var group: Bool
    }

    public struct Account: Hashable, Sendable {
        public var id: String
        public var name: String
        public var provider: String
        public var providerName: String
        public var plan: String
        /// 是供应商的一把 Key（不是登录的账号）。
        public var key: Bool
    }

    public var models: [Model]
    public var accounts: [Account]

    public init(json: WebJSON) {
        models = (json["models"]?.array ?? []).compactMap { m in
            guard let id = m["id"]?.string else { return nil }
            return Model(id: id, name: m["name"]?.string ?? id, provider: m["provider"]?.string ?? "",
                         providerName: m["providerName"]?.string ?? m["provider"]?.string ?? "", group: m["group"]?.bool ?? false)
        }
        accounts = (json["accounts"]?.array ?? []).compactMap { a in
            guard let id = a["id"]?.string else { return nil }
            return Account(id: id, name: a["name"]?.string ?? id, provider: a["provider"]?.string ?? "",
                           providerName: a["providerName"]?.string ?? a["provider"]?.string ?? "",
                           plan: a["plan"]?.string ?? "", key: a["key"]?.bool ?? false)
        }
    }

    /// 选项列表里的一项（官方 gatewayModelsBadge 的 opts）。
    public struct Option: Hashable, Identifiable, Sendable {
        public enum Kind: Hashable, Sendable { case all, model, wildcard, account }
        public var value: String
        public var name: String
        public var note: String
        public var kind: Kind
        /// 所属的小节（「路由组」或供应商名；「全部模型」和不再提供的为空）。
        public var section: String
        public var id: String { value }
    }

    /// 照官方的顺序排好：「全部模型」，路由组（先「全部路由组」），每个供应商（先「X 的全部模型」，再模型，再它的账号），
    /// 没列出模型的供应商的账号，最后是密钥里留着、但现在没提供的模型 / 没登录的账号。
    public func options(for key: WebCallerKey) -> [Option] {
        let ms = key.models, picked = key.accounts
        var out = [Option(value: "", name: "全部模型", note: "任何模型和任何账号，包括以后添加的", kind: .all, section: "")]
        let named = Set(picked.map { String($0.split(separator: "/").first ?? "").lowercased() })
        func modelsReach(_ pid: String) -> Bool {
            ms.contains { m in
                let head = String(m.split(separator: "/").first ?? "").lowercased()
                return head == pid || head.contains("*")
            }
        }
        var ofProvider: [String: [Option]] = [:]
        var providerOrder: [String] = []
        let accountIDs = Set(accounts.map(\.id))
        for a in accounts {
            let pid = a.provider.lowercased()
            let note: String
            if !picked.isEmpty && !named.contains(pid) {
                note = !ms.isEmpty && modelsReach(pid) ? "会被使用：\(a.providerName) 没有勾选任何账号" : "不会被使用：\(a.providerName) 没有勾选任何模型或账号"
            } else {
                note = a.plan.isEmpty ? a.providerName : a.providerName + " · " + a.plan
            }
            if ofProvider[a.provider] == nil { providerOrder.append(a.provider) }
            ofProvider[a.provider, default: []].append(Option(value: a.id, name: a.name, note: note, kind: .account, section: a.providerName))
        }
        var seen = Set<String>()
        var listed = ""
        func endBlock() {
            out += ofProvider[listed] ?? []
            ofProvider[listed] = nil
            listed = ""
        }
        for m in models {
            if m.group {
                endBlock()
                if seen.insert("group").inserted {
                    out.append(Option(value: "group/*", name: "全部路由组", note: "group/*", kind: .wildcard, section: "路由组"))
                }
                out.append(Option(value: m.id, name: m.name, note: m.id, kind: .model, section: "路由组"))
                continue
            }
            if m.provider != listed {
                endBlock()
                listed = m.provider
            }
            if seen.insert("p:" + m.provider).inserted {
                out.append(Option(value: m.provider + "/*", name: "\(m.providerName) 的全部模型", note: m.provider + "/*", kind: .wildcard, section: m.providerName))
            }
            out.append(Option(value: m.id, name: m.name, note: m.id, kind: .model, section: m.providerName))
        }
        endBlock()
        for provider in providerOrder { out += ofProvider[provider] ?? [] }
        for v in ms where !out.contains(where: { $0.value == v }) {
            out.append(Option(value: v, name: v, note: "当前未提供", kind: .model, section: ""))
        }
        var known = accountIDs
        for v in picked where !known.contains(v) {
            known.insert(v)
            out.append(Option(value: v, name: v, note: "当前未登录", kind: .account, section: ""))
        }
        return out
    }

    /// 勾选完之后要发的（官方：模型总是发；账号只在变了时发）。`picked` 里不含「全部模型」。
    public static func split(picked: [String], options: [Option], key: WebCallerKey) -> (models: [String], accounts: [String]?) {
        let accountValues = Set(options.filter { $0.kind == .account }.map(\.value))
        let models = picked.filter { !accountValues.contains($0) }
        let accounts = picked.filter { accountValues.contains($0) }
        let changed = accounts.count != key.accounts.count || accounts.contains { !key.accounts.contains($0) }
        return (models, changed ? accounts : nil)
    }

    /// 保存后的提示（官方 status）。
    public static func savedSaid(name: String, models: [String], accounts: [String]) -> String {
        if !models.isEmpty { return "\(name) 仅可使用所选模型" }
        if !accounts.isEmpty { return "\(name) 仅可使用所选账号的模型" }
        return "\(name) 可使用全部模型"
    }
}

extension WebClient {
    /// `GET /api/caller-keys/models`：能限定给一把网关密钥的模型与账号。
    public func callerKeyModels() async throws -> CallerKeyModels {
        CallerKeyModels(json: try await get("/api/caller-keys/models"))
    }
}
