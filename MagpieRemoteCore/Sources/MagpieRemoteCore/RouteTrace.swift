import Foundation

// 实时路由：magpie 网页「路由」页上半部分的舞台。数据来自 web 接口 `GET /api/gateway/trace?after=<seq>[&wait=1]`
// （internal/gui/trace.go → gateway.TraceState / gateway.Route）。网关自己的 `/v1/magpie/trace` 只回答本机，手机读不到。
// 行的状态与文案移植自 magpie 的 internal/gui/assets/plugins/routing/client.js（render、header、FAIL、HUES …），
// magpie 以 MIT 许可发布（Copyright (c) 2026 yetone），见仓库的 THIRD_PARTY_NOTICES.md。

// MARK: 接口数据

/// 一次请求在等待失败后休息的账号或 Key（gateway.Rest）。
public struct TraceRest: Hashable, Sendable {
    /// rate / credit / quota / other / auth …
    public var why: String
    public var status: Int
    public var until: Date?
    public var error: String

    init(_ json: WebJSON) {
        why = json["why"]?.string ?? ""
        status = json["status"]?.int ?? 0
        until = json["until"]?.string.flatMap(UsageTimestamp.parse)
        error = json["error"]?.string ?? ""
    }
}

/// 路由为一个请求排的一个座位（gateway.Weighed）：一个账号或 Key 上的一个模型。
public struct TraceSeat: Hashable, Sendable {
    public var id: String
    public var provider: String
    /// 供应商名。
    public var name: String
    /// 账号名，或 Key 的名字 / 脱敏值。
    public var who: String
    /// "account" / "key" / "provider"。
    public var kind: String
    public var plan: String
    public var model: String
    public var fixed: String
    public var fast: Bool
    /// 它所在供应商的路由方式。
    public var routing: String
    public var fallback: Bool
    public var known: Bool
    /// 计入这个模型的额度已用百分比。
    public var used: Double
    public var balance: Double?
    public var unit: String
    public var free: Bool
    public var rest: TraceRest?
    /// 套餐不含这个模型：被跳过。
    public var unlisted: Bool
    /// 请求超出它的上下文：被跳过。
    public var window: Int
    public var credits: Bool
    public var renews: Date?
    public var tokens: Double

    init(_ json: WebJSON) {
        id = json["id"]?.string ?? ""
        provider = json["provider"]?.string ?? ""
        name = json["name"]?.string ?? ""
        who = json["who"]?.string ?? ""
        kind = json["kind"]?.string ?? "key"
        plan = json["plan"]?.string ?? ""
        model = json["model"]?.string ?? ""
        fixed = json["fixed"]?.string ?? ""
        fast = json["fast"]?.bool ?? false
        routing = json["routing"]?.string ?? ""
        fallback = json["fallback"]?.bool ?? false
        known = json["known"]?.bool ?? false
        used = json["used"]?.double ?? 0
        balance = json["balance"]?.double
        unit = json["unit"]?.string ?? ""
        free = json["free"]?.bool ?? false
        rest = json["rest"].flatMap { $0.object == nil ? nil : TraceRest($0) }
        unlisted = json["unlisted"]?.bool ?? false
        window = json["window"]?.int ?? 0
        credits = json["credits"]?.bool ?? false
        let renewal = json["usedRenews"]?.string ?? json["renews"]?.array?.first?.string
        renews = renewal.flatMap(UsageTimestamp.parse)
        tokens = json["tokens"]?.double ?? 0
    }

    /// 网页的 `seat`：同一个账号上的两个模型是两个座位。
    public var key: String { id + "\u{0}" + model + (fixed.isEmpty ? "" : ":" + fixed) }

    /// 行上加粗的名字：供应商本身（kind = provider）时是供应商名，否则是账号 / Key。
    public var title: String { kind == "provider" || who.isEmpty ? name : who }
    /// 行上灰色的补充：备用时是供应商名，账号时是套餐。
    public var detail: String {
        if fallback { return name }
        if kind == "provider" { return "" }
        if !plan.isEmpty { return plan }
        return title == name ? "" : name
    }
    public var modelLabel: String { fixed.isEmpty ? model : "\(model):\(fixed)" }
}

/// 一次尝试（gateway.Try）。
public struct TraceTry: Hashable, Sendable {
    public var id: String
    public var model: String
    public var fixed: String
    public var start: Date?
    public var done: Bool
    public var status: Int
    public var ms: Int
    public var ttft: Int
    public var fail: String
    public var error: String
    public var rest: TraceRest?
    public var again: Int
    public var credits: Bool

    init(_ json: WebJSON) {
        id = json["id"]?.string ?? ""
        model = json["model"]?.string ?? ""
        fixed = json["fixed"]?.string ?? ""
        start = json["start"]?.string.flatMap(UsageTimestamp.parse)
        done = json["done"]?.bool ?? false
        status = json["status"]?.int ?? 0
        ms = json["ms"]?.int ?? 0
        ttft = json["ttft"]?.int ?? 0
        fail = json["fail"]?.string ?? ""
        error = json["error"]?.string ?? ""
        rest = json["rest"].flatMap { $0.object == nil ? nil : TraceRest($0) }
        again = json["again"]?.int ?? 0
        credits = json["credits"]?.bool ?? false
    }

    /// 网页的 `tryOk`：状态码 < 400 且没有中途断开。
    public var ok: Bool { done && status < 400 && fail.isEmpty }
}

/// 网关记下的一次请求（gateway.Route + 网页的 routeJSON）。
public struct TraceRoute: Hashable, Sendable, Identifiable {
    public var id: Int64
    public var seq: Int64
    public var time: Date?
    public var agent: String
    public var model: String
    public var provider: String
    public var groupID: String?
    public var groupName: String?
    public var groupRouting: String
    public var kind: String
    public var order: [TraceSeat]
    public var tries: [TraceTry]
    public var done: Bool
    public var status: Int
    public var error: String
    public var ms: Int
    public var ttft: Int
    public var tokens: Int
    public var output: Int
    public var sessionTitle: String
    public var cost: Double?
    public var affinityMode: String?
    public var affinityKept: Bool

    public init(json: WebJSON) {
        id = Int64(json["id"]?.int ?? 0)
        seq = Int64(json["seq"]?.int ?? 0)
        time = json["time"]?.string.flatMap(UsageTimestamp.parse)
        agent = json["agent"]?.string ?? ""
        model = json["model"]?.string ?? ""
        provider = json["provider"]?.string ?? ""
        if let group = json["group"], group.object != nil {
            groupID = group["id"]?.string
            groupName = group["name"]?.string ?? group["id"]?.string
            groupRouting = group["routing"]?.string ?? ""
        } else {
            groupID = nil
            groupName = nil
            groupRouting = ""
        }
        kind = json["kind"]?.string ?? ""
        order = (json["order"]?.array ?? []).map(TraceSeat.init)
        tries = (json["tries"]?.array ?? []).map(TraceTry.init)
        done = json["done"]?.bool ?? false
        status = json["status"]?.int ?? 0
        error = json["error"]?.string ?? ""
        ms = json["ms"]?.int ?? 0
        ttft = json["ttft"]?.int ?? 0
        tokens = json["tokens"]?.int ?? 0
        output = json["out"]?.int ?? 0
        sessionTitle = json["sessionTitle"]?.string ?? ""
        cost = (json["priced"]?.bool ?? false) ? json["cost"]?.double : nil
        affinityMode = json["affinity"]?["mode"]?.string
        affinityKept = json["affinity"]?["kept"]?.bool ?? false
    }

    /// 网页的 `tried`：一次尝试落在哪个座位上。
    public func seat(of attempt: TraceTry) -> TraceSeat? {
        let key = attempt.id + "\u{0}" + attempt.model + (attempt.fixed.isEmpty ? "" : ":" + attempt.fixed)
        return order.first { $0.key == key }
            ?? order.first { $0.id == attempt.id && $0.model == attempt.model }
            ?? order.first { $0.id == attempt.id }
    }

    /// 尝试落座的行键。
    public func seatKey(of attempt: TraceTry) -> String {
        seat(of: attempt)?.key ?? (attempt.id + "\u{0}" + attempt.model + (attempt.fixed.isEmpty ? "" : ":" + attempt.fixed))
    }

    /// 正在尝试的座位（请求还在路上时）。
    public var trying: TraceTry? { tries.last { !$0.done } }
    /// 回答了的那次尝试。
    public var answered: TraceTry? { tries.last { $0.ok } }
    /// 请求结束且 Agent 拿到了错误。
    public var failed: Bool { done && (status >= 400 || (!error.isEmpty && answered == nil)) }
    /// 改道次数：失败后交给下一个的尝试。
    public var rerouted: Int { tries.filter { $0.done && !$0.ok }.count - (failed ? 1 : 0) }

    /// 路由方式：组的，或第一个非备用座位所在供应商的。
    public var routing: String {
        if groupID != nil { return groupRouting }
        return (order.first { !$0.fallback } ?? order.first)?.routing ?? ""
    }
}

public struct TraceTotals: Hashable, Sendable {
    public var requests: Int
    public var rerouted: Int
    public var errors: Int

    public init(requests: Int = 0, rerouted: Int = 0, errors: Int = 0) {
        self.requests = requests
        self.rerouted = rerouted
        self.errors = errors
    }
}

/// `GET /api/gateway/trace` 的一次回答。
public struct TraceSnapshot: Hashable, Sendable {
    public var seq: Int64
    public var routes: [TraceRoute]
    public var totals: TraceTotals
    /// 网关现在还保留的全部请求 id；nil = 没给。
    public var ids: [Int64]?
    /// 这台 magpie 在提供网关（或读得到提供网关的那台）。false 时没有可看的路由。
    public var mine: Bool
    public var now: Date?

    public init(json: WebJSON) {
        seq = Int64(json["seq"]?.int ?? 0)
        routes = (json["routes"]?.array ?? []).map(TraceRoute.init)
        let totals = json["totals"] ?? .null
        self.totals = TraceTotals(requests: totals["requests"]?.int ?? 0, rerouted: totals["rerouted"]?.int ?? 0, errors: totals["errors"]?.int ?? 0)
        ids = json["ids"]?.array.map { $0.compactMap { $0.int.map(Int64.init) } }
        mine = json["mine"]?.bool ?? false
        now = json["now"]?.string.flatMap(UsageTimestamp.parse)
    }
}

// MARK: 合并

/// 网页 `poll()` 的合并规则：按 seq 增量读，网关重启（seq 变小）时清空，
/// 网关已丢弃的未完成请求删掉，只留最近 60 个。
public struct TraceBook: Hashable, Sendable {
    public private(set) var seq: Int64 = 0
    public private(set) var routes: [Int64: TraceRoute] = [:]
    public private(set) var totals = TraceTotals()
    public private(set) var mine = true
    public private(set) var loaded = false
    /// 这次合并新出现的请求（第一次读取时为空：那时的请求不再飞一遍）。
    public private(set) var fresh: [Int64] = []
    /// 主机时间减本机时间（秒）。
    public private(set) var skew: TimeInterval = 0
    public static let keep = 60

    public init() {}

    public mutating func apply(_ snapshot: TraceSnapshot, receivedAt: Date = Date()) {
        mine = snapshot.mine
        totals = snapshot.totals
        if let now = snapshot.now { skew = now.timeIntervalSince(receivedAt) }
        guard snapshot.mine else {
            loaded = false
            fresh = []
            return
        }
        if snapshot.seq < seq { routes.removeAll() }
        seq = snapshot.seq
        let first = !loaded
        fresh = []
        for route in snapshot.routes {
            if routes[route.id] == nil, !first { fresh.append(route.id) }
            routes[route.id] = route
        }
        if let ids = snapshot.ids {
            let kept = Set(ids)
            for (id, route) in routes where !route.done && !kept.contains(id) { routes[id] = nil }
        }
        let sorted = routes.keys.sorted()
        for id in sorted.dropLast(Self.keep) { routes[id] = nil }
        loaded = true
    }

    /// 新的在前。
    public var list: [TraceRoute] { routes.values.sorted { $0.id > $1.id } }
    public var newest: TraceRoute? { routes.values.max { $0.id < $1.id } }
    /// 还在路上的请求。
    public var underWay: [TraceRoute] { list.filter { !$0.done } }
}

// MARK: 舞台

/// 舞台上一行（一个座位）的状态，对应网页行上的 class：on / now / rest / left / low。
public enum StageRowState: Hashable, Sendable {
    /// 正在回答（点会跳，线在流动）。
    case answering
    /// 回答了显示中的请求（亮着，不动）。
    case answered
    /// 失败后在休息，或把错误交给了 Agent（虚线框，红字）。
    case resting
    /// 套餐不含 / 超出上下文：被跳过（点线框，淡）。
    case passedOver
    case idle

    public var lit: Bool { self == .answering || self == .answered }
}

public struct StageRow: Hashable, Sendable, Identifiable {
    public var id: String
    public var seat: TraceSeat
    public var state: StageRowState
    /// 行上的一句话（已用 72% · 3 小时后重置、回答中…）。
    public var status: String
    /// 额度条（0–100）；不显示时为 nil。
    public var bar: Double?
    /// 用了 90% 以上（灰一点）。
    public var low: Bool
    /// 线的颜色来自哪个 Agent（亮着时）。
    public var agent: String?
    /// 失败时右上角红色的小标签（状态码）。
    public var tag: String?
}

public struct StageAgent: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// 有请求在路上：它到 magpie 的线在流动。
    public var busy: Bool
    public var hue: String
}

/// 一次舞台画面：左边的 Agent、中间的 magpie、下面的账号行、上方的标题和说明、底部的计数。
public struct RouteStage: Hashable, Sendable {
    public var routeID: Int64
    public var agents: [StageAgent]
    public var rows: [StageRow]
    /// 标题加粗部分（组名或供应商名）。
    public var name: String
    /// 标题其余部分（· 路由组 · 启用 2 个）。
    public var tail: String
    /// 标题下的一句话：路由方式在做什么。
    public var mode: String
    /// magpie 方框里的路由方式小标签。
    public var chip: String
    public var chipHidden: Bool
    public var caption: String
}

public enum RouteStageBuilder {
    /// 网页 HUES / SPARE：每个 Agent 一个颜色（都不是红色：红色只表示失败）。
    public static let hues: [String: String] = [
        "claude": "#d97757", "codex": "#6366f1", "gemini": "#0ea5e9", "copilot": "#a855f7", "cursor": "#14b8a6", "opencode": "#eab308",
        "crush": "#ec4899", "goose": "#84cc16", "pi": "#10b981", "omp": "#d946ef", "omo": "#7c3aed", "dsh": "#06b6d4", "commandcode": "#f97316",
        "mimocode": "#3b82f6", "deveco": "#3c99cc",
    ]
    public static let spare = ["#8b5cf6", "#22c55e", "#0d9488", "#0891b2", "#ca8a04", "#db2777", "#2563eb", "#65a30d"]

    public static func hue(_ agent: String) -> String {
        if let hue = hues[agent] { return hue }
        var h: UInt32 = 0
        for scalar in agent.unicodeScalars { h = h &* 31 &+ scalar.value }
        return spare[Int(h % UInt32(spare.count))]
    }

    /// 网页 FAIL 的中文。
    public static func failWord(_ why: String) -> String {
        switch why {
        case "rate": "限流"
        case "credit": "余额不足"
        case "quota": "额度用尽"
        case "auth": "需要重新登录"
        case "canceled": "已取消"
        case "foreign": "别的账号的推理"
        case "floor": "回答太短"
        case "verify": "需要验证"
        case "refused": "被拒绝（安全过滤）"
        case "shape": "请求无法识别"
        case "sight": "不接受图片"
        case "proxy": "连不上代理"
        case "offline": "网络断开"
        case "effort": "套餐不含这个推理强度"
        case "overflow": "超出模型上下文"
        case "room": "回答超出剩余上下文"
        case "slow": "迟迟不出字"
        case "prompt": "Agent 的提示词被拒"
        case "restricted": "账号被厂商限制"
        default: "失败"
        }
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s) 秒" }
        if s < 3600 { return "\(s / 60) 分钟" }
        if s < 86400 { let h = s / 3600, m = (s % 3600) / 60; return m > 0 && h < 10 ? "\(h) 小时 \(m) 分" : "\(h) 小时" }
        return "\(s / 86400) 天"
    }

    static func restSay(_ rest: TraceRest, now: Date) -> String {
        let prefix = rest.why.isEmpty || rest.why == "other" ? (rest.status > 0 ? "\(rest.status) · " : "") : ""
        let left = (rest.until ?? now).timeIntervalSince(now)
        return prefix + failWord(rest.why) + " · " + duration(left) + "后恢复"
    }

    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    /// 把要显示的请求（第一个是选中的）画成舞台。`agentName` 把 Agent id 换成名字。
    public static func build(current: TraceRoute, staged: [TraceRoute], now: Date = Date(),
                             agentName: (String) -> String = { $0 }) -> RouteStage {
        let routes = [current] + staged.filter { $0.id != current.id }
        // 左边的 Agent：按出现顺序
        var agentIDs: [String] = []
        for route in routes where !agentIDs.contains(route.agent) { agentIDs.append(route.agent) }
        let busy = Set(routes.filter { $0.tries.contains { !$0.done } }.map(\.agent))
        let agents = agentIDs.map { StageAgent(id: $0, name: agentName($0), busy: busy.contains($0), hue: hue($0)) }

        // 每个座位：最近一个排到它的请求说了算（选中的请求优先）
        var seats: [(TraceSeat, TraceRoute)] = []
        var seen = Set<String>()
        for route in routes {
            for seat in route.order where !seen.contains(seat.key) {
                seen.insert(seat.key)
                seats.append((seat, route))
            }
        }
        var trying: [String: TraceRoute] = [:]
        for route in routes { for attempt in route.tries where !attempt.done { trying[route.seatKey(of: attempt)] = route } }

        let rows = seats.map { seat, route -> StageRow in
            let key = seat.key
            var answered = Set<String>(), gave: [String: TraceTry] = [:], went: [String: TraceTry] = [:], rests: [String: TraceRest] = [:]
            for item in route.order { if let rest = item.rest { rests[item.key] = rest } }
            for (index, attempt) in route.tries.enumerated() {
                let at = route.seatKey(of: attempt)
                let last = index == route.tries.count - 1
                if attempt.ok { answered.insert(at) }
                else if attempt.done, attempt.rest == nil, attempt.again == 0, route.done, last { gave[at] = attempt }
                else if attempt.done, attempt.rest == nil, attempt.again == 0, !attempt.credits, !last { went[at] = attempt }
                if let rest = attempt.rest { rests[at] = rest }
            }
            for attempt in route.tries where attempt.ok { rests[route.seatKey(of: attempt)] = nil }
            let rest = rests[key]
            let resting = rest.map { ($0.until ?? .distantPast) > now } ?? false
            let otherAgents = agents.count > 1

            var status: String
            if seat.unlisted { status = "套餐不含这个模型 · 已跳过" }
            else if resting, let rest { status = restSay(rest, now: now) }
            else if seat.window > 0 { status = "请求超出其 \(UsageFormat.tokens(seat.window)) 上下文 · 已跳过" }
            else if let other = trying[key] { status = other.id != current.id && !otherAgents ? "在回答另一个请求…" : "回答中…" }
            else if answered.contains(key) { status = otherAgents ? "回答了 \(agentName(route.agent))" : "回答了这个请求" }
            else if let attempt = gave[key] { status = "\(attempt.status) · \(failWord(attempt.fail)) · 已交给 \(agentName(route.agent))" }
            else if let attempt = went[key] { status = "\(attempt.status) · \(failWord(attempt.fail)) · 已转给下一个" }
            else if seat.free { status = "免费 · 不花额度" }
            else if seat.known {
                let used = seat.balance.map { String(format: "剩余 %.0f %@", $0, seat.unit).trimmingCharacters(in: .whitespaces) } ?? "已用 \(percent(seat.used))"
                if seat.routing.isEmpty, seat.used >= 98, seat.balance == nil { status = used + (seat.credits ? " · 用积分" : " · 几乎用尽") }
                else if seat.routing.isEmpty, seat.used >= 90, seat.balance == nil { status = used + " · 留到最后" }
                else if let renews = seat.renews, renews > now { status = used + " · " + duration(renews.timeIntervalSince(now)) + "后重置" }
                else { status = used }
            } else if seat.kind == "account" { status = "剩余额度未知" }
            else if seat.routing == "usage" { status = "最近 \(UsageFormat.tokens(Int(seat.tokens))) token" }
            else { status = seat.kind == "key" ? "API 密钥" : "一个 Key" }

            let flying = !resting && trying[key] != nil
            let on = flying || (!resting && answered.contains(key))
            let state: StageRowState = flying ? .answering : on ? .answered
                : (resting || gave[key] != nil) ? .resting : (seat.unlisted || seat.window > 0) ? .passedOver : .idle
            let bar = seat.known && !seat.free && seat.balance == nil ? min(100, max(0, seat.used)) : nil
            let tag = (gave[key] ?? went[key]).map { "\($0.status)" }
            let lightBy = flying ? trying[key]?.agent : on ? route.agent : nil
            return StageRow(id: key, seat: seat, state: state, status: status, bar: bar,
                            low: seat.routing.isEmpty && seat.known && seat.used >= 90, agent: lightBy, tag: tag)
        }

        // 标题与说明（网页 header）
        let first = current.order.first { !$0.fallback } ?? current.order.first
        let routing = GroupRouting(raw: current.routing)
        let enabled = current.order.filter { !$0.fallback }.count
        let none = current.order.isEmpty
        let lone = current.groupID == nil && enabled == 1
        let name = current.groupName ?? first?.name ?? current.provider
        var tail = current.groupID != nil ? " · 路由组" : ""
        if none { tail += current.done ? "" : " · 等待中" } else { tail += enabled == 1 ? " · 启用 1 个" : " · 启用 \(enabled) 个" }
        if agents.count > 1 { tail += " · \(agents.count) 个 Agent 同时在发" }
        let mode: String
        if none { mode = current.done ? "这个请求没有交给任何账号。" : "magpie 还没开始路由这个请求，所以还没选出由谁处理。" }
        else if lone { mode = "这里只开了一个账号或 Key，路由没有可选的。在供应商的编辑页再开一个，路由方式就在下面的「多账号 / 多 Key」里设置。" }
        else if routing == .smart, current.groupID == nil, first?.kind == "key", !current.order.contains(where: \.known) {
            mode = "智能：适合这个请求的 Key 先用（专为该模型 API 准备的），其余按顺序；失败后休息中的排最后。"
        } else { mode = routing.hint }

        return RouteStage(routeID: current.id, agents: agents, rows: rows, name: name, tail: tail, mode: mode,
                          chip: routing.title, chipHidden: lone || (none && current.groupID == nil),
                          caption: caption(current, agentName: agentName))
    }

    /// 舞台下方的一句话：这次请求怎么样了。
    public static func caption(_ route: TraceRoute, agentName: (String) -> String = { $0 }) -> String {
        let agent = agentName(route.agent)
        let model = route.model.isEmpty ? "请求" : route.model
        if let attempt = route.trying, let seat = route.seat(of: attempt) {
            return "\(agent) 的 \(model) 正交给 \(seat.name)\(seat.who.isEmpty || seat.kind == "provider" ? "" : " · \(seat.who)")"
        }
        if route.failed {
            let last = route.tries.last
            return "\(agent) 收到了错误：\(route.status > 0 ? "\(route.status) · " : "")\(last.map { failWord($0.fail) } ?? (route.error.isEmpty ? "失败" : route.error))"
        }
        if let attempt = route.answered, let seat = route.seat(of: attempt) {
            let where_ = seat.kind == "provider" || seat.who.isEmpty ? seat.name : "\(seat.name) · \(seat.who)"
            let hops = route.rerouted > 0 ? "，中途改道 \(route.rerouted) 次" : ""
            let time = route.ms > 0 ? String(format: "，用时 %.1f 秒", Double(route.ms) / 1000) : ""
            return "\(where_) 回答了 \(agent) 的 \(model)\(hops)\(time)"
        }
        if route.order.isEmpty { return route.done ? "没有谁处理这个请求" : "magpie 还没开始路由这个请求" }
        return "\(agent) 的 \(model) 等待中"
    }
}
