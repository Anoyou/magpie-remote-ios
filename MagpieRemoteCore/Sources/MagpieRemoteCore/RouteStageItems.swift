import Foundation

// 舞台上的行怎么折叠（网页 client.js rebuild() / subNode / foldNode / render() 的 together）：
// - 台上不止一条路由（不同的路由组或供应商）时，每条路由的行挂在一个标题下（默认展开，提示「X 在发往这里」）；
// - 组里的子组有自己的标题，它路由到的挂在下面（6 个以上默认折起）；
// - 同一供应商、同一模型并排的 Key 或账号 3 个以上合成一行（Key 默认折起；账号 6 个以上折起）。
// 点标题或合并的行折起 / 展开，记在 magpie.routingKeysOpen / magpie.routingFolded（与网页同名）。
// 折起时它代替下面的行：喜鹊飞向它，失败的标签挂在它上面，它说下面的一起怎样了。
// magpie 以 MIT 许可发布（Copyright (c) 2026 yetone）。

public enum StageItemKind: Hashable, Sendable {
    case row
    /// 一条路由或组里一个子组的标题。
    case heading
    /// 合在一起的 Key / 账号。
    case fold
}

/// 舞台上画出来的一项。
public struct StageItem: Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: StageItemKind
    /// 往里缩几级（网页 --depth，每级 18）。
    public var depth: Int
    /// 它从哪一项的车道挂下来（nil = 从 magpie 下来）。
    public var parent: String?
    /// kind == .row 时的那一行。
    public var row: StageRow?
    /// 标题 / 合并行的名字、地址（组的 group/…，路由的模型）、灰色的数（「3 个密钥」「启用 2 个」）、路由方式小标签。
    public var name = ""
    public var ref = ""
    public var count = ""
    public var mode = ""
    /// 标志：供应商的官方图标名（seat.officialIcon 的原料）；空 = 组（扇形）。
    public var iconOf: TraceSeat?
    /// 一条路由的标题（不是子组）。
    public var route = false
    public var fallback = false
    /// 记住开合用的键（网页 pk）。
    public var persistKey = ""
    public var open = true
    /// 折起时一起的状态（网页 together）。
    public var status = ""
    /// 下面有一行在回答 / 回答了 / 正在答（点在跳）。
    public var lit = false
    public var now = false
    /// 下面的都在休息或暂不使用。
    public var resting = false
    /// 点它时的提示（网页 title）。
    public var tip = ""
    /// 收起 / 展开的说明（无障碍）。
    public var foldHint = ""
    /// 折起时它代替的座位。
    public var seats: [String] = []
}

public struct StageLayout: Hashable, Sendable {
    public var items: [StageItem]
    /// 每个座位：从 magpie 到它这一路经过的项（标题、展开的合并行、它自己）；折起的在那里截止。
    public var chains: [String: [String]]

    /// 座位此刻画在哪一项上（网页 shownRow）。
    public func shown(_ seat: String) -> String? { chains[seat]?.last }
}

/// 网页 isOpen / keepOpen：用户点过的开合，按 pk 记住（不管默认）。
public struct StageFoldMemory: Hashable, Sendable {
    public var opened: Set<String>
    public var shut: Set<String>

    public init(opened: Set<String> = [], shut: Set<String> = []) {
        self.opened = opened
        self.shut = shut
    }

    public func isOpen(_ key: String, default value: Bool) -> Bool {
        if shut.contains(key) { return false }
        if opened.contains(key) { return true }
        return value
    }

    public mutating func keep(_ key: String, open: Bool) {
        if open { opened.insert(key); shut.remove(key) } else { opened.remove(key); shut.insert(key) }
    }
}

extension RouteStageBuilder {
    public static let foldAt = 3
    public static let long = 6

    static func wayOf(_ r: TraceRoute) -> String {
        "\u{2}" + (r.groupID.map { "g:" + $0 } ?? "p:" + r.provider).replacingOccurrences(of: ">", with: "\u{3}")
    }

    /// 把舞台的行排成画出来的样子：标题、合并的行、行。`routes` 是台上的请求（选中的在前，与 build 相同）。
    public static func layout(_ stage: RouteStage, routes: [TraceRoute], memory: StageFoldMemory, agentName: (String) -> String = { $0 }) -> StageLayout {
        // 每个座位属于哪条路由：第一个排到它的请求的
        var wayOfSeat: [String: String] = [:]
        var wayInfo: [String: (name: String, ref: String, routing: String, icon: TraceSeat?, lone: Bool, agents: [String], pk: String)] = [:]
        var wayOrder: [String] = []
        for r in routes.sorted(by: { $0.id < $1.id }) {
            let w = wayOf(r)
            let f = r.order.first { !$0.fallback } ?? r.order.first
            var info = wayInfo[w] ?? (name: "", ref: "", routing: "", icon: nil, lone: false, agents: [], pk: "")
            if let id = r.groupID {
                info.name = r.groupName ?? id
                info.ref = r.groupRef.isEmpty ? "group/" + id : r.groupRef
                info.routing = r.groupRouting
                info.pk = "route/group/" + id
                info.icon = nil
            } else {
                info.name = f?.name ?? r.provider
                info.ref = r.model
                info.routing = f?.routing ?? ""
                info.pk = "route/" + r.provider
                info.icon = f
                info.lone = r.order.filter { !$0.fallback }.count <= 1
            }
            let name = agentName(r.agent)
            if !info.agents.contains(name) { info.agents.append(name) }
            wayInfo[w] = info
            if !wayOrder.contains(w) { wayOrder.append(w) }
        }
        for r in routes { for seat in r.order where wayOfSeat[seat.key] == nil { wayOfSeat[seat.key] = wayOf(r) } }
        let ways = wayOrder.count > 1
        let subInfo = Dictionary(routes.flatMap(\.groupSubs).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // 行：按路由分在一起（路由的先后照它们来的顺序），路由里保持原来的顺序
        var rows = stage.rows
        if ways {
            let rank = Dictionary(uniqueKeysWithValues: wayOrder.enumerated().map { ($1, $0) })
            rows = rows.enumerated().sorted { a, b in
                let x = rank[wayOfSeat[a.element.id] ?? ""] ?? 0, y = rank[wayOfSeat[b.element.id] ?? ""] ?? 0
                return x == y ? a.offset < b.offset : x < y
            }.map(\.element)
        }
        let path: [String: [String]] = Dictionary(uniqueKeysWithValues: rows.map { row in
            (row.id, ways ? [wayOfSeat[row.id] ?? ""] + row.seat.via : row.seat.via)
        })

        // 并排、可合并的 Key / 账号（FOLD_AT 个以上）
        func foldKey(_ row: StageRow) -> String {
            let w = row.seat
            return [path[row.id]!.joined(separator: ">"), w.kind, w.provider, w.model, w.fixed, w.fallback ? "1" : "0", w.aside ? "1" : "0"].joined(separator: "\u{0}")
        }
        func folding(_ row: StageRow) -> Bool { row.seat.kind == "key" || row.seat.kind == "account" }
        var foldOf: [String: String] = [:]
        var folds: [String: StageItem] = [:]
        var run: [StageRow] = []
        func flush() {
            defer { run = [] }
            guard run.count >= foldAt, let first = run.first else { return }
            let w = first.seat, acct = w.kind == "account"
            let key = "f:" + foldKey(first)
            let pk = "\(w.provider)/\(w.model)\(w.fixed.isEmpty ? "" : ":" + w.fixed)\(acct ? "@" : "")"
            let open = memory.isOpen(pk, default: acct && run.count < long)
            var item = StageItem(id: key, kind: .fold, depth: path[first.id]!.count, parent: nil)
            item.name = w.fallback ? w.name : (w.name.isEmpty ? w.provider : w.name)
            item.ref = w.modelLabel
            item.count = rt(acct ? "{n} accounts" : "{n} keys", ["n": "\(run.count)"])
            item.iconOf = w
            item.fallback = w.fallback
            item.persistKey = pk
            item.open = open
            item.seats = run.map(\.id)
            item.foldHint = rt(open ? (acct ? "Fold these accounts into one row" : "Fold these keys into one row") : (acct ? "Show each account" : "Show each key"))
            folds[key] = item
            for row in run { foldOf[row.id] = key }
        }
        for row in rows {
            if folding(row), let head = run.first, foldKey(head) == foldKey(row) { run.append(row) } else {
                flush()
                if folding(row) { run = [row] }
            }
        }
        flush()

        // 每个标题下有几行（LONG 个以上的子组默认折起）
        var under: [String: Int] = [:]
        for row in rows {
            let via = path[row.id]!
            for d in 0..<via.count { under[via[...d].joined(separator: ">"), default: 0] += 1 }
        }

        var items: [StageItem] = []
        var placed = Set<String>()
        var headings: [String: StageItem] = [:]
        var chains: [String: [String]] = [:]
        for row in rows {
            let via = path[row.id]!
            var chain: [String] = []
            var parent: String?
            var shutAt: String?
            for d in 0..<via.count {
                let key = via[...d].joined(separator: ">")
                let id = "h:" + key
                if !placed.contains(id) {
                    placed.insert(id)
                    var h = StageItem(id: id, kind: .heading, depth: d, parent: d == 0 ? nil : "h:" + via[..<d].joined(separator: ">"))
                    if d == 0, ways, let info = wayInfo[via[0]] {
                        h.route = true
                        h.name = info.name
                        h.ref = info.ref
                        h.mode = info.lone ? "" : RouteWords.modeName(info.routing)
                        h.iconOf = info.icon
                        h.persistKey = info.pk
                        h.open = memory.isOpen(info.pk, default: true)
                        h.tip = rt("Sent by {agents}", ["agents": info.agents.joined(separator: ", ")])
                        h.foldHint = rt(h.open ? "Fold this route into one row" : "Show where this route goes")
                    } else {
                        let sub = subInfo[via[d]]
                        h.name = sub?.name ?? via[d]
                        h.ref = (sub?.ref).flatMap { $0.isEmpty ? nil : $0 } ?? "group/" + via[d]
                        h.mode = RouteWords.modeName(sub?.routing ?? "")
                        h.persistKey = "group/" + via[d]
                        h.open = memory.isOpen(h.persistKey, default: (under[key] ?? 0) < long)
                        if let rules = sub?.rules, rules > 0 { h.tip = rt(rules == 1 ? "1 rule" : "{n} rules", ["n": "\(rules)"]) }
                        h.foldHint = rt(h.open ? "Fold this group into one row" : "Show what this group routes to")
                    }
                    headings[id] = h
                    items.append(h)
                }
                chain.append(id)
                parent = id
                headings[id]?.seats.append(row.id)
                if headings[id]?.open == false { shutAt = id; break }
            }
            if shutAt != nil {
                chains[row.id] = chain
                continue
            }
            if let fk = foldOf[row.id], var f = folds[fk] {
                if !placed.contains(fk) {
                    placed.insert(fk)
                    f.parent = parent
                    f.depth = via.count
                    folds[fk] = f
                    items.append(f)
                }
                chain.append(fk)
                if !f.open {
                    chains[row.id] = chain
                    continue
                }
                parent = fk
            }
            chain.append(row.id)
            chains[row.id] = chain
            items.append(StageItem(id: row.id, kind: .row, depth: via.count + (foldOf[row.id] != nil ? 1 : 0), parent: parent, row: row))
        }

        // 折起的说它下面的一起怎样了；展开的标题只在下面有一行亮着时亮（网页 render 的 together / lightRow）
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        func together(_ seats: [String]) -> (status: String, lit: Bool, now: Bool, resting: Bool) {
            let ms = seats.compactMap { byID[$0] }
            let on = ms.first { $0.state == .answering } ?? ms.first { $0.state == .answered }
            let resting = ms.filter { $0.state == .resting }.count
            let held = ms.filter { $0.state == .passedOver }.count
            var parts: [String] = []
            if let on { parts.append("\(RouteStory.who(on.seat)): \(on.status)") }
            if resting + held < ms.count { parts.append(rt("{n} available", ["n": "\(ms.count - resting - held)"])) }
            if resting > 0 { parts.append(rt("{n} resting", ["n": "\(resting)"])) }
            if held > 0 { parts.append(rt("{n} held", ["n": "\(held)"])) }
            return (parts.joined(separator: " · "), on != nil, ms.contains { $0.state == .answering }, !ms.isEmpty && resting + held == ms.count)
        }
        for index in items.indices where items[index].kind != .row {
            var item = items[index]
            if item.kind == .heading { item.seats = headings[item.id]?.seats ?? item.seats }
            let t = together(item.seats)
            item.lit = t.lit
            item.now = t.now
            if item.kind == .fold || !item.open {
                item.status = t.status
                item.resting = t.resting
            }
            if item.kind == .heading && !item.open {
                item.count = rt(item.seats.count == 1 ? "one on" : "{n} on", ["n": "\(item.seats.count)"])
            }
            items[index] = item
        }
        return StageLayout(items: items, chains: chains)
    }
}
