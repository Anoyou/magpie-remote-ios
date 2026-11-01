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
    /// 是什么定的休息多久（gateway.Rest.By）：retry-after / credit / window / resets / quota / backoff / cooldown …
    public var by: String = ""
    /// 连续失败了几次（backoff）。
    public var failures: Int = 0
    /// 只是这一个模型在休息时是它的名字。
    public var model: String = ""

    init(_ json: WebJSON) {
        why = json["why"]?.string ?? ""
        status = json["status"]?.int ?? 0
        until = json["until"]?.string.flatMap(UsageTimestamp.parse)
        error = json["error"]?.string ?? ""
        by = json["by"]?.string ?? ""
        failures = json["failures"]?.int ?? 0
        model = json["model"]?.string ?? ""
    }
}

/// 路由为一个请求排的一个座位（gateway.Weighed）：一个账号或 Key 上的一个模型。
public struct TraceSeat: Hashable, Sendable {
    public var id: String
    public var provider: String
    /// 供应商名。
    public var name: String
    /// 主机给的标志名（gateway.Weighed 的 `icon`）与供应商预设（`preset`）。
    public var icon: String = ""
    public var preset: String = ""
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
    /// 它在组里的哪个子组下（gateway.Weighed.Via：由外到内的组 id）。
    public var via: [String] = []
    /// 只用某个 API、排在其他之后。
    public var aside = false

    init(_ json: WebJSON) {
        id = json["id"]?.string ?? ""
        provider = json["provider"]?.string ?? ""
        name = json["name"]?.string ?? ""
        icon = json["icon"]?.string ?? ""
        preset = json["preset"]?.string ?? ""
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
        via = json["via"]?.strings ?? []
        aside = json["aside"]?.bool ?? false
    }

    /// 网页的 `seat`：同一个账号上的两个模型是两个座位。
    public var key: String { id + "\u{0}" + model + (fixed.isEmpty ? "" : ":" + fixed) }

    /// 行上加粗的名字：供应商本身（kind = provider）时是供应商名，否则是账号 / Key。
    public var title: String { kind == "provider" || who.isEmpty ? name : who }
    /// 行上灰色的补充：备用时是供应商名，账号时是套餐。
    public var detail: String {
        // 网页 makeRow()：`w.fallback ? w.name : w.kind === "provider" ? "" : w.plan || ""`
        if fallback { return name }
        if kind == "provider" { return "" }
        return plan
    }
    public var modelLabel: String { fixed.isEmpty ? model : "\(model):\(fixed)" }
}

/// 组里的一个子组（gateway.SubGroup）。
public struct TraceSubGroup: Hashable, Sendable {
    public var id: String
    public var ref: String
    public var name: String
    public var routing: String
    public var rules: Int

    init(_ json: WebJSON) {
        id = json["id"]?.string ?? ""
        ref = json["ref"]?.string ?? ""
        name = json["name"]?.string ?? ""
        routing = json["routing"]?.string ?? ""
        rules = json["rules"]?.int ?? 0
    }
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
    /// 再试之前 Agent 已经走了。
    public var gone: Bool
    /// 最后一个额度用完、Agent 拿到的是更早一次的错误。
    public var earlier = false

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
        again = json["again"]?.int ?? (json["again"]?.bool == true ? 1 : 0)
        credits = json["credits"]?.bool ?? false
        gone = json["gone"]?.bool ?? false
        earlier = json["earlier"]?.bool ?? false
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
    /// Agent 选它用的名字（group/<id> 或 auto/<model>）。
    public var groupRef: String = ""
    /// 组里的子组（由外到内）。
    public var groupSubs: [TraceSubGroup] = []
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
    /// 网页的 `groupSession`：parentSession，没有时是 session（「按会话」分组用）。
    public var session: String
    public var folder: String

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
            groupRef = group["ref"]?.string ?? ""
            groupSubs = (group["subs"]?.array ?? []).map(TraceSubGroup.init)
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
        let parent = json["parentSession"]?.string ?? ""
        session = parent.isEmpty ? (json["session"]?.string ?? "") : parent
        folder = json["folder"]?.string ?? ""
    }

    /// 网页的 `sessionKey`：同一个 Agent 的同一个会话；没有会话标识时为空。
    public var sessionKey: String { session.isEmpty ? "" : (agent.isEmpty ? "other" : agent) + "\u{0}" + session }

    /// 结束的时刻（开始 + 用时）；没有时间时为 nil。
    public var endedAt: Date? { time.map { $0.addingTimeInterval(Double(ms) / 1000) } }

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
    /// 读这份路由的那台 magpie（另一台接管网关时会变：网页从头读一遍）。
    public var pid: Int
    /// 回答里出现的账号（网页 `noteAccounts`）：user / account / alias，以及 kind = account 的 who。给「账号打码」用。
    public var accounts: [String]

    public init(json: WebJSON) {
        seq = Int64(json["seq"]?.int ?? 0)
        routes = (json["routes"]?.array ?? []).map(TraceRoute.init)
        let totals = json["totals"] ?? .null
        self.totals = TraceTotals(requests: totals["requests"]?.int ?? 0, rerouted: totals["rerouted"]?.int ?? 0, errors: totals["errors"]?.int ?? 0)
        ids = json["ids"]?.array.map { $0.compactMap { $0.int.map(Int64.init) } }
        mine = json["mine"]?.bool ?? false
        now = json["now"]?.string.flatMap(UsageTimestamp.parse)
        pid = json["by"]?["pid"]?.int ?? 0
        var found: [String] = []
        Self.noteAccounts(json, into: &found)
        accounts = found
    }

    /// app.js `noteAccount`：去掉首尾空白后 2–80 个字符、没有换行的才算。
    static func noteAccount(_ value: String, into out: inout [String]) {
        let s = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = s.utf16.count
        if n >= 2 && n <= 80 && !s.contains("\n") && !s.contains("\r") && !out.contains(s) { out.append(s) }
    }

    /// app.js `noteAccounts`：最多走 8 层。
    static func noteAccounts(_ json: WebJSON, into out: inout [String], depth: Int = 0) {
        guard depth <= 8 else { return }
        switch json {
        case .array(let items):
            for item in items { noteAccounts(item, into: &out, depth: depth + 1) }
        case .object(let object):
            let isAccount = object["kind"]?.string == "account"
            for key in object.keys.sorted() {
                guard let value = object[key] else { continue }
                if case .string(let text) = value {
                    if key == "user" || key == "account" || key == "alias" || (key == "who" && isAccount) { noteAccount(text, into: &out) }
                } else if key == "who", isAccount, case .array(let names) = value {
                    for name in names { if let text = name.string { noteAccount(text, into: &out) } }
                } else if value.object != nil || value.array != nil {
                    noteAccounts(value, into: &out, depth: depth + 1)
                }
            }
        default:
            break
        }
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
    /// 这一页见过的账号（只增不减，与网页的 accountNames 一样）。
    public private(set) var accounts: [String] = []
    /// 路由来自哪台 magpie。
    public private(set) var pid = 0
    public static let keep = 60

    public init() {}

    public mutating func apply(_ snapshot: TraceSnapshot, receivedAt: Date = Date()) {
        mine = snapshot.mine
        totals = snapshot.totals
        if let now = snapshot.now { skew = now.timeIntervalSince(receivedAt) }
        for name in snapshot.accounts where !accounts.contains(name) { accounts.append(name) }
        // 另一台 magpie 接管了网关（#2606）：它的请求和 seq 是它自己的，从头读一遍（网页 poll 的 fromOther）
        let fromOther = loaded && snapshot.pid != pid
        pid = snapshot.pid
        if fromOther {
            routes.removeAll()
            seq = 0
            loaded = false
            fresh = []
            return
        }
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

    /// 网页 `underWay()`：还在路上的最近 4 个（旧的在前）——回到页面时只有它们接着飞。
    public var playable: [TraceRoute] { Array(underWay.reversed().suffix(Self.live)) }
    public static let live = 4

    /// 网页 `told()`：实时卡片讲的那个请求。它没结束前一直讲它；更新的请求还没被路由时也不抢走一个已经路由了的。
    public func told(_ shown: Int64?) -> TraceRoute? {
        let n = newest
        guard let shown, let c = routes[shown], let n, c.id != n.id else { return n }
        if !c.done { return c }
        return n.done || !n.tries.isEmpty || c.tries.isEmpty ? n : c
    }

    /// 一个 Agent 最后一个请求结束后在舞台上留多久（网页 LINGER）。
    public static let linger: TimeInterval = 12

    /// 网页 `staged()`：舞台上画的请求——选中的只画它自己；否则是正在飞的、每个 Agent 还在路上或刚结束 12 秒内的
    /// 最后一个，加上卡片讲的那个；最多 4 个 Agent。旧的在前。
    public func staged(current: TraceRoute?, pinned: Bool, playing: Set<Int64>, now: Date) -> [TraceRoute] {
        if pinned { return current.map { [$0] } ?? [] }
        let hostNow = now.addingTimeInterval(skew)
        let rs = routes.values.sorted { $0.id < $1.id }
        var last: [String: Int64] = [:]
        for r in rs { last[r.agent] = r.id }
        var out = rs.filter { r in
            if playing.contains(r.id) { return true }
            guard last[r.agent] == r.id else { return false }
            if !r.done { return true }
            guard let end = r.endedAt else { return false }
            return end > hostNow.addingTimeInterval(-Self.linger)
        }
        if let current, let c = routes[current.id], !out.contains(where: { $0.id == c.id }) { out.append(c) }
        var agents: [String] = []
        for r in out where !agents.contains(r.agent) { agents.append(r.agent) }
        let kept = Set(agents.suffix(4))
        return out.filter { kept.contains($0.agent) }.sorted { $0.id < $1.id }
    }
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
    /// 卡片上的小字（网页 a.sub）：它最近一个请求的模型；同时在几个文件夹里干活时是这些文件夹的最后一级。
    public var sub: String = ""
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
    /// 网页 hueOf()：见 AgentHues。
    public static func hue(_ agent: String) -> String { AgentHues.shared.hue(agent) }

    /// 网页 FAIL 的中文。
    public static func failWord(_ why: String) -> String { RouteWords.failWord(why) }

    public static func duration(_ seconds: TimeInterval) -> String { RouteWords.dur(seconds) }

    static func restSay(_ rest: TraceRest, now: Date) -> String { RouteStory.restSay(rest, now: now) }

    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    /// 网页 rebuild() 里 Agent 卡片的先后：已经在台上的保持原来的位置，新来的按请求先后排在后面
    /// （`[...keep, ...ags.filter((a) => !keep.includes(a))]`，ags 按请求 id 排）。
    public static func agentOrder(previous: [String], routes: [TraceRoute]) -> [String] {
        var present: [String] = []
        for route in routes.sorted(by: { $0.id < $1.id }) where !present.contains(route.agent) { present.append(route.agent) }
        let keep = previous.filter(present.contains)
        return keep + present.filter { !keep.contains($0) }
    }

    /// 把要显示的请求（第一个是选中的）画成舞台。`agentName` 把 Agent id 换成名字。
    /// `order`：Agent 卡片的先后（见 agentOrder）；nil 时选中的请求的 Agent 在最前。
    public static func build(current: TraceRoute, staged: [TraceRoute], now: Date = Date(), order: [String]? = nil,
                             agentName: (String) -> String = { $0 }) -> RouteStage {
        let routes = [current] + staged.filter { $0.id != current.id }
        // 左边的 Agent：按出现顺序
        var agentIDs: [String] = []
        for route in routes where !agentIDs.contains(route.agent) { agentIDs.append(route.agent) }
        if let order { agentIDs = agentOrder(previous: order, routes: routes) }
        let busy = Set(routes.filter { $0.tries.contains { !$0.done } }.map(\.agent))
        AgentHues.shared.spread(agentIDs)
        let byID = routes.sorted { $0.id < $1.id }
        let agents = agentIDs.map { id -> StageAgent in
            let mine = byID.filter { $0.agent == id }
            var folders: [String] = []
            for route in mine where !route.folder.isEmpty && !folders.contains(route.folder) { folders.append(route.folder) }
            let sub = folders.count > 1 ? folders.map { $0.split(separator: "/").last.map(String.init) ?? $0 }.joined(separator: ", ")
                : mine.last?.model ?? ""
            return StageAgent(id: id, name: agentName(id), busy: busy.contains(id), hue: hue(id), sub: sub)
        }

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
            if seat.unlisted {
                status = seat.kind == "key" ? rt("{name}'s list for this key has no {model}", ["name": seat.name, "model": seat.model])
                    : rt("its plan doesn't list {model}", ["model": seat.model])
            }
            else if resting, let rest { status = restSay(rest, now: now) }
            else if seat.window > 0 { status = "请求超出其 \(UsageFormat.tokens(seat.window)) 上下文 · 已跳过" }
            else if let other = trying[key] { status = other.id != current.id && !otherAgents ? "在回答另一个请求…" : "回答中…" }
            else if answered.contains(key) { status = otherAgents ? "回答了 \(agentName(route.agent))" : "回答了这个请求" }
            else if let attempt = gave[key] { status = "\(attempt.status) · \(failWord(attempt.fail)) · 已交给 \(agentName(route.agent))" }
            else if let attempt = went[key] { status = "\(attempt.status) · \(failWord(attempt.fail)) · 已转给下一个" }
            else if seat.free { status = "免费 · 不花额度" }
            else if seat.known {
                let used = seat.balance.map { String(format: "剩余 %.0f %@", $0, seat.unit).trimmingCharacters(in: .whitespaces) } ?? "已用 \(percent(seat.used))"
                if seat.routing.isEmpty, seat.used >= 98, seat.balance == nil { status = used + (seat.credits ? " · 使用 Credits" : " · 几乎用尽") }
                else if seat.routing.isEmpty, seat.used >= 90, seat.balance == nil { status = used + " · 留到最后" }
                else if let renews = seat.renews, renews > now { status = used + " · " + duration(renews.timeIntervalSince(now)) + "后重置" }
                else { status = used }
            } else if seat.kind == "account" { status = "剩余额度未知" }
            else if seat.routing == "usage" { status = "最近 \(UsageFormat.tokens(Int(seat.tokens))) token" }
            else { status = seat.kind == "key" ? "API 密钥" : "一个 Key" }
            // 网页 render()：已知额度何时重置一直写在行上（回答中、留到最后、被跳过时也写），休息中的写何时恢复
            if !resting, !seat.unlisted, seat.known, !seat.free, let renews = seat.renews, renews > now {
                let renew = rt("renews in {d}", ["d": duration(renews.timeIntervalSince(now))])
                if !status.contains(renew) { status += " · " + renew }
            }

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

// MARK: 账号打码（app.js 的 hideAccounts，网页「路由」页的「账号打码」）

/// 一段文字里要打码的部分换成同样形状的替身字母（网页 `.pii`：模糊、半透明），其余照旧。
public struct MaskSegment: Hashable, Sendable {
    public var text: String
    public var masked: Bool

    public init(_ text: String, masked: Bool) {
        self.text = text
        self.masked = masked
    }
}

/// 移植自 app.js：邮箱地址一律打码；账号名（网关回答里的 user / account / alias / 账号的 who）整词打码，
/// 但供应商、Agent 的名字和几个通用词不算账号。替身字母每次一样：模糊之后读着像个名字，却不是。
public struct AccountMask: Sendable {
    /// app.js NOT_ACCOUNTS。
    public static let notAccounts: Set<String> = ["default", "own", "desktop", "account", "main", "local", "unknown", "none", "free", "pro", "api key", "signed in"]
    /// app.js EMAIL：`[\w.+*•-]+@[\w*•-]+(?:\.[\w*•-]+)+`（JS 的 \w 只是 ASCII）。
    static let emailPattern = "[A-Za-z0-9_.+*•-]+@[A-Za-z0-9_*•-]+(?:\\.[A-Za-z0-9_*•-]+)+"
    private static let isEmail = try! NSRegularExpression(pattern: "^(?:" + emailPattern + ")$")

    public let names: [String]
    private let finder: NSRegularExpression?

    /// - Parameters:
    ///   - accounts: 见过的账号
    ///   - notNames: 供应商 id / 名字、Agent id / 名字（不当账号）
    public init(accounts: [String], notNames: [String]) {
        var not = Self.notAccounts
        for n in notNames where !n.isEmpty { not.insert(n.lowercased()) }
        var seen = Set<String>()
        var list: [String] = []
        for raw in accounts {
            let n = raw.trimmingCharacters(in: .whitespaces)
            guard n.utf16.count >= 2, !seen.contains(n) else { continue }
            seen.insert(n)
            let ns = n as NSString
            if Self.isEmail.firstMatch(in: n, range: NSRange(location: 0, length: ns.length)) != nil { continue }
            // 「名字 (2)」是第二个同名的
            let bare = n.lowercased().replacingOccurrences(of: " \\(\\d+\\)$", with: "", options: .regularExpression)
            if not.contains(bare) { continue }
            list.append(n)
        }
        // 长的在前：一个名字在另一个里面时整个藏起来
        let order = Dictionary(uniqueKeysWithValues: list.enumerated().map { ($1, $0) })
        names = list.sorted { a, b in
            let x = a.utf16.count, y = b.utf16.count
            return x != y ? x > y : order[a]! < order[b]!
        }
        let escaped = { (s: String) in NSRegularExpression.escapedPattern(for: s) }
        let at = names.filter { $0.contains("@") }.map(escaped)
        let plain = names.filter { !$0.contains("@") }.map(escaped)
        finder = try? NSRegularExpression(pattern: (at + [Self.emailPattern] + plain).joined(separator: "|"))
    }

    private static func isWord(_ u: UInt16?) -> Bool {
        guard let u else { return false }
        return (u >= 48 && u <= 57) || (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || u == 95
    }

    private static func isJoin(_ u: UInt16?) -> Bool { u == 45 || u == 46 }

    /// app.js `joined`：名字挨着字母数字，或挨着连字符 / 点再接字母数字（lingting-react-ui 里的 lingting 不是账号）。
    private static func joined(_ s: [UInt16], _ i: Int, _ step: Int) -> Bool {
        let at = { (k: Int) -> UInt16? in k >= 0 && k < s.count ? s[k] : nil }
        return isWord(at(i)) || (isJoin(at(i)) && isWord(at(i + step)))
    }

    /// app.js `dots`：每个不是 @ 和 . 的字符（按 UTF-16）换成 "aeiounrstlcmdh" 里的一个，h 从 7 起 h = h * 31 + 字符码。
    public static func dots(_ s: String) -> String {
        let letters = Array("aeiounrstlcmdh".utf16)
        var h: UInt32 = 7
        var out: [UInt16] = []
        for u in s.utf16 {
            if u == 64 || u == 46 { out.append(u); continue }
            h = h &* 31 &+ UInt32(u)
            out.append(letters[Int(h % 14)])
        }
        return String(decoding: out, as: UTF16.self)
    }

    /// 把一段文字切成打码与不打码的几段。
    public func segments(_ text: String) -> [MaskSegment] {
        guard let finder, text.utf16.count >= 2 else { return [MaskSegment(text, masked: false)] }
        let ns = text as NSString
        let units = Array(text.utf16)
        var out: [MaskSegment] = []
        var last = 0
        for match in finder.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let r = match.range
            guard r.length > 0 else { continue }
            let hit = ns.substring(with: r)
            if !hit.contains("@") {
                let first = units[r.location], end = r.location + r.length, lastUnit = units[end - 1]
                if (Self.isWord(first) && Self.joined(units, r.location - 1, -1)) || (Self.isWord(lastUnit) && Self.joined(units, end, 1)) { continue }
            }
            if r.location > last { out.append(MaskSegment(ns.substring(with: NSRange(location: last, length: r.location - last)), masked: false)) }
            out.append(MaskSegment(Self.dots(hit), masked: true))
            last = r.location + r.length
        }
        if out.isEmpty { return [MaskSegment(text, masked: false)] }
        if last < ns.length { out.append(MaskSegment(ns.substring(from: last), masked: false)) }
        return out
    }

    /// 打码后的纯文字（替身字母代替账号）。
    public func apply(_ text: String) -> String { segments(text).map(\.text).joined() }
}

// MARK: 飞行（client.js play() / fly() / home()）

/// 一段飞行走哪条路（线由界面按卡片的位置画出）。
public enum FlightLeg: Hashable, Sendable {
    /// Agent → magpie：路由还没选出谁，到 magpie 那里等。
    case toHub
    /// 飞向座位：从 Agent 出发整条飞（Agent 的线 + 穿过 magpie + 座位的线），或从 magpie 里接着飞。
    case out(seat: String, from: FlightOrigin)
    /// 回答：座位的线倒着飞 + 穿过 magpie + Agent 的线倒着飞。
    case home(seat: String)
    /// 失败但还有下一个：沿座位的线飞回 magpie，由它交给下一个。
    case bounce(seat: String)
}

/// 去程从哪里起飞。
public enum FlightOrigin: Hashable, Sendable {
    /// 从 Agent 起飞。
    case agent
    /// 在 magpie 那里等过（Agent 线的终点）。
    case hubFromAgent
    /// 从上一个座位弹回 magpie 后（那条座位线的起点，朝回飞的方向）。
    case hubFromSeat(String)
}

/// 点的样子（routing.css .pkt / .back / .err）。
public enum FlightDot: Hashable, Sendable {
    /// 请求：实心，Agent 的颜色，带光晕。
    case request
    /// 回答：卡片色填充，Agent 色的圈，小一点（r = 4）。
    case answer
    /// 失败：Agent 色填充，红圈。
    case error
}

public struct FlightSegment: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case fly(FlightLeg, duration: TimeInterval)
        /// 点停在座位前等它回答；pulsing = 一闪一闪（.held，rtheld 1.2 秒）。
        case holdSeat(String, pulsing: Bool)
        /// 点和喜鹊停在 magpie 前，等路由选出谁。
        case holdHub
    }

    public var kind: Kind
    /// 开始的时刻（timeIntervalSinceReferenceDate）。
    public var start: TimeInterval
    /// 结束的时刻；nil = 还在等。
    public var end: TimeInterval?
    public var dot: FlightDot
    /// 衔着点的喜鹊；nil = 点自己停着。
    public var bird: Int?
}

/// 一次失败落在座位上（网页 play() 里的 `rerun(row.li, "hit")` 与红色标签）：那一行抖一下（rthit 0.45 秒），
/// 右上角显示「状态码 · 原因」1.8 秒。
public struct FlightHit: Hashable, Sendable {
    public var seat: String
    public var at: TimeInterval
    public var status: Int
    public var fail: String
}

/// 卡片跳一下（网页 `tick()`，rttick 0.4 秒）：Agent 在请求出发、回答到达时，magpie 在喜鹊到达、从它这里再出发时。
public struct FlightTick: Hashable, Sendable {
    public enum Node: Hashable, Sendable { case agent, hub }
    public var node: Node
    public var at: TimeInterval
}

/// 舞台下那句话要说的一句（网页 play() 里的 say）：开演时讲路由为什么这样排（lead），一次失败落下时讲那次尝试，
/// 回答到了时（不重要地）讲回答。
public struct FlightSay: Hashable, Sendable {
    public var at: TimeInterval
    /// nil = 开演时的那句（firstWhy）；否则是第几次尝试。
    public var attempt: Int?
    public var lo: Bool
}

/// 一只喜鹊：出现（rtcome 0.3 秒），松开点后向上飞走（.away 0.45 秒）。
public struct FlightBird: Hashable, Sendable {
    public var id: Int
    public var come: TimeInterval
    /// 松开点的时刻；nil = 还衔着。
    public var away: TimeInterval?
}

/// 一个请求的整段演出，按网关的记录一步步排出来（与网页 play() 的顺序和时长相同）：
/// 一只喜鹊把请求从 Agent 衔过 magpie 送到路由排的第一个（1.4 秒；在 magpie 等过就 0.9 秒），
/// 放下点让它在那里等回答；另一只把回答衔回 Agent（1.4 秒）。失败时另一只把红圈衔回 magpie（0.62 秒），
/// 第一只再把请求送到下一个；那是最后的回答（没有休息、没有再试）就把错误衔回 Agent（1.35 秒）。
/// 路由还没选出谁时，先飞到 magpie 等着（0.62 秒）。
public struct RoutePlay: Hashable, Sendable {
    public static let toHubTime: TimeInterval = 0.62
    public static let outTime: TimeInterval = 1.4
    public static let onTime: TimeInterval = 0.9
    public static let homeTime: TimeInterval = 1.4
    public static let failHomeTime: TimeInterval = 1.35
    public static let bounceTime: TimeInterval = 0.62
    /// 喜鹊松开点后飞走用的时间。
    public static let awayTime: TimeInterval = 0.45
    /// 网页的一段飞行在它走完后的第一帧才算到（requestAnimationFrame 里 k ≥ 1 时 resolve），下一步才开始：
    /// 实测（fake clock、16 毫秒一帧）每段平均晚 9 毫秒左右；一段一段累起来，回程比网页早出发。
    public static let frameLag: TimeInterval = 0.01

    private enum Step: Hashable, Sendable {
        case begin
        case next
        /// 在座位上等第 i 次尝试结束。
        case held(Int)
        /// 回答了，等请求整个结束（它的 token 那时才算好）。
        case answered(Int)
        case ended
    }

    public let route: Int64
    public let agent: String
    public private(set) var segments: [FlightSegment] = []
    public private(set) var birds: [FlightBird] = []
    public private(set) var hits: [FlightHit] = []
    public private(set) var ticks: [FlightTick] = []
    public private(set) var says: [FlightSay] = []
    /// 减弱动态效果（网页 still()）：每段飞行瞬间完成，点直接出现在终点；没有喜鹊（界面不画）。
    public let still: Bool
    private var step = Step.begin
    private var index = 0
    private var origin = FlightOrigin.agent
    private var carrier: Int?
    private var cursor: TimeInterval

    public init(route: TraceRoute, now: TimeInterval, still: Bool = false) {
        self.route = route.id
        agent = route.agent
        cursor = now
        self.still = still
    }

    /// 演完了（最后一段已经排好结束时间）。
    public var ended: Bool { step == .ended }

    /// 最后一只喜鹊也飞走的时刻；还没演完时为 nil。
    public var over: TimeInterval? {
        guard ended else { return nil }
        let last = segments.last?.end ?? cursor
        return max(last, birds.compactMap(\.away).max() ?? last) + Self.awayTime
    }

    private mutating func bird(at t: TimeInterval) -> Int {
        let id = birds.count
        birds.append(FlightBird(id: id, come: t, away: nil))
        return id
    }

    private mutating func release(_ id: Int?, at t: TimeInterval) {
        guard let id, birds.indices.contains(id), birds[id].away == nil else { return }
        birds[id].away = t
    }

    private mutating func fly(_ leg: FlightLeg, _ duration: TimeInterval, dot: FlightDot, bird: Int?, now: TimeInterval) {
        let duration = still ? 0 : duration
        let start = max(cursor, now)
        // 点停在终点直到这段「到了」的那一帧（frameLag），下一段从那时开始
        let lag = still ? 0 : Self.frameLag
        segments.append(FlightSegment(kind: .fly(leg, duration: duration), start: start, end: start + duration + lag, dot: dot, bird: bird))
        cursor = start + duration + lag
    }

    private mutating func hold(_ kind: FlightSegment.Kind, dot: FlightDot, bird: Int?, now: TimeInterval) {
        let start = max(cursor, now)
        segments.append(FlightSegment(kind: kind, start: start, end: nil, dot: dot, bird: bird))
        cursor = start
    }

    /// 合上正在等的那一段。
    private mutating func close(now: TimeInterval) {
        guard let last = segments.indices.last, segments[last].end == nil else { return }
        let end = max(segments[last].start, now)
        segments[last].end = end
        cursor = end
    }

    /// 按网关现在的记录把演出往下排。`route` 为 nil：网关已经不再保留它，演出就此结束。
    /// `seated` 判断一个座位在舞台上有没有行（没有就跳过那次尝试，网页 `if (!row) { i++; continue; }`）。
    public mutating func advance(_ route: TraceRoute?, now: TimeInterval, seated: (String) -> Bool = { _ in true }) {
        guard let route else {
            close(now: now)
            release(carrier, at: max(cursor, now))
            carrier = nil
            step = .ended
            return
        }
        while true {
            switch step {
            case .begin:
                carrier = bird(at: max(cursor, now))
                ticks.append(FlightTick(node: .agent, at: max(cursor, now)))
                says.append(FlightSay(at: max(cursor, now), attempt: nil, lo: false))
                if route.tries.isEmpty {
                    fly(.toHub, Self.toHubTime, dot: .request, bird: carrier, now: now)
                    ticks.append(FlightTick(node: .hub, at: cursor))
                    hold(.holdHub, dot: .request, bird: carrier, now: now)
                    origin = .hubFromAgent
                }
                step = .next
            case .next:
                if index >= route.tries.count {
                    if route.done {
                        close(now: now)
                        release(carrier, at: cursor)
                        carrier = nil
                        step = .ended
                    }
                    return
                }
                let attempt = route.tries[index]
                let seat = route.seatKey(of: attempt)
                guard route.seat(of: attempt) != nil, seated(seat) else { index += 1; continue }
                close(now: now) // 在 magpie 等的那一段
                if carrier == nil { carrier = bird(at: max(cursor, now)) }
                if origin != .agent { ticks.append(FlightTick(node: .hub, at: max(cursor, now))) }
                fly(.out(seat: seat, from: origin), origin == .agent ? Self.outTime : Self.onTime, dot: .request, bird: carrier, now: now)
                // 放下点：它在那里等回答
                release(carrier, at: cursor)
                carrier = nil
                hold(.holdSeat(seat, pulsing: true), dot: .request, bird: nil, now: now)
                step = .held(index)
            case .held(let i):
                let attempt = route.tries[i]
                guard attempt.done else { return }
                close(now: now)
                let seat = route.seatKey(of: attempt)
                if attempt.ok {
                    hold(.holdSeat(seat, pulsing: false), dot: .request, bird: nil, now: now)
                    step = .answered(i)
                    continue
                }
                hits.append(FlightHit(seat: seat, at: cursor, status: attempt.status, fail: attempt.fail))
                says.append(FlightSay(at: cursor, attempt: i, lo: false))
                let back = bird(at: cursor)
                if attempt.rest == nil && !attempt.credits && (attempt.again == 0 || attempt.gone) {
                    // 那就是回答：Agent 拿到错误
                    fly(.home(seat: seat), Self.failHomeTime, dot: .error, bird: back, now: now)
                    release(back, at: cursor)
                    ticks.append(FlightTick(node: .agent, at: cursor))
                    step = .ended
                    return
                }
                fly(.bounce(seat: seat), Self.bounceTime, dot: .error, bird: back, now: now)
                release(back, at: cursor)
                origin = .hubFromSeat(seat)
                index = i + 1
                step = .next
            case .answered(let i):
                guard route.done else { return }
                close(now: now)
                let seat = route.seatKey(of: route.tries[i])
                says.append(FlightSay(at: cursor, attempt: i, lo: true))
                let back = bird(at: cursor)
                fly(.home(seat: seat), Self.homeTime, dot: .answer, bird: back, now: now)
                release(back, at: cursor)
                ticks.append(FlightTick(node: .agent, at: cursor))
                step = .ended
                return
            case .ended:
                return
            }
        }
    }

    /// t 时刻点在哪一段（演完、或还没开始时为 nil）。
    public func segment(at t: TimeInterval) -> FlightSegment? {
        guard let first = segments.first, t >= first.start else { return nil }
        for segment in segments.reversed() where segment.start <= t {
            if let end = segment.end, t > end { return nil }
            return segment
        }
        return nil
    }

    /// t 时刻喜鹊 b 所在的那一段与它在这段里的时刻（松开点之后停在松开的地方）。
    public func place(of bird: FlightBird, at t: TimeInterval) -> (segment: FlightSegment, time: TimeInterval)? {
        let when = min(t, bird.away ?? t)
        let carrying = segments.filter { $0.bird == bird.id }
        guard !carrying.isEmpty else { return nil }
        for segment in carrying.reversed() where segment.start <= when {
            return (segment, min(when, segment.end ?? when))
        }
        return carrying.first.map { ($0, $0.start) }
    }
}
