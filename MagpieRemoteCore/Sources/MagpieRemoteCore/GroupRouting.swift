import Foundation

// 路由组页面（magpie 网页「路由」页下半部分）在 App 里的数据：路由方式、会话保持、成员状态、
// 多账号 / 多 Key 供应商的路由、各模型近 7 天的速度（`GET /api/model-speeds`）。
// 字段与中文文案对照 magpie v0.1.2438 的 internal/gui/groups.go、internal/provider/group.go、
// internal/gui/assets/plugins/routing/client.js（GROUP_ROUTE_OPTS / GROUP_HINT / AFF_OPTS …）与 i18n.js。

// MARK: 路由方式

/// 一个路由组（或一个多账号供应商）在成员之间分配请求的方式（`routing` 字段）。
public enum GroupRouting: Hashable, Sendable, Identifiable {
    case smart, order, rotate, usage, pace, free, fast, cheap, weight, manual
    /// 插件提供的（`<plugin>/<name>`）或 App 不认识的路由方式：原样保留，不改写。
    case other(String)

    public init(raw: String) {
        switch raw {
        case "": self = .smart
        case "order": self = .order
        case "rotate": self = .rotate
        case "usage": self = .usage
        case "pace": self = .pace
        case "free": self = .free
        case "fast": self = .fast
        case "cheap": self = .cheap
        case "weight": self = .weight
        case "manual": self = .manual
        default: self = .other(raw)
        }
    }

    public var raw: String {
        switch self {
        case .smart: ""
        case .order: "order"
        case .rotate: "rotate"
        case .usage: "usage"
        case .pace: "pace"
        case .free: "free"
        case .fast: "fast"
        case .cheap: "cheap"
        case .weight: "weight"
        case .manual: "manual"
        case .other(let value): value
        }
    }

    public var id: String { raw.isEmpty ? "smart" : raw }

    /// 路由组可选的方式，顺序与网页一致。
    public static let groupChoices: [GroupRouting] = [.smart, .order, .rotate, .usage, .pace, .free, .fast, .cheap, .weight, .manual]
    /// 多账号 / 多 Key 供应商可选的方式（没有「最便宜优先」和「手动」）。
    public static let poolChoices: [GroupRouting] = [.smart, .order, .rotate, .usage, .pace, .free, .fast, .weight]

    public var title: String {
        switch self {
        case .smart: "智能"
        case .order: "按顺序"
        case .rotate: "轮流"
        case .usage: "最少使用"
        case .pace: "重置前用完"
        case .free: "免费优先"
        case .fast: "速度优先"
        case .cheap: "最便宜优先"
        case .weight: "按权重"
        case .manual: "手动"
        case .other(let value): value
        }
    }

    public var symbol: String {
        switch self {
        case .smart: "sparkles"
        case .order: "list.number"
        case .rotate: "arrow.triangle.2.circlepath"
        case .usage: "gauge.with.dots.needle.33percent"
        case .pace: "calendar.badge.clock"
        case .free: "gift"
        case .fast: "hare"
        case .cheap: "yensign.circle"
        case .weight: "scalemass"
        case .manual: "hand.point.up.left"
        case .other: "puzzlepiece.extension"
        }
    }

    /// 网页里每种方式下方的说明（magpie 自带的中文）。
    public var hint: String {
        switch self {
        case .smart: "智能：成员的账号和 Key 统一排序。有余量的订阅中额度最先重置的排第一，以周额度为准；只有 5 小时额度的账号（如 Claude Enterprise）按 5 小时重置，排在更晚重置的周额度之前；失败后休息中的排最后。"
        case .order: "按顺序：先用第一个模型，无法响应再换下一个；各成员按其供应商的路由在自己的账号或 Key 间分配。"
        case .rotate: "轮流：会话的每一轮交给下一个成员的账号或 Key，均摊负载。"
        case .usage: "最少使用优先：剩余额度最多的账号或 Key 排第一。"
        case .pace: "重置前用完：按周剩余额度 ÷ 距重置小时数排序，越高越先用。只有 5 小时额度的账号（如 Claude Enterprise）按 5 小时窗口计算，几乎总排第一；Key 按最近发给它的 token 数排。"
        case .free: "免费优先：成员中那个模型不花订阅额度或积分的排在前面，其余在后；每个成员整体尝试，各自按其供应商的路由在自己的账号或 Key 间分配。"
        case .fast: "速度优先：最近回答最快的成员先上，按首字时间和输出速度算；相差不到一成的保持列出的顺序，最近没测过的每五个请求分到一个，好重新测一次。"
        case .cheap: "最便宜优先：此刻模型最便宜的成员先用，看此时每百万输入、输出 token 的价格；价格相同的按列出的顺序，不知道价格的排最后。"
        case .weight: "按权重：每个模型按旁边设置的权重分得请求——权重 3 的模型每接 3 个，权重 1 的接 1 个，均匀穿插。失败后休息中的模型退出这一轮，其余模型分担它的请求；某个模型失败时，由下一个模型接替。"
        case .manual: "手动：所有请求发给在路由组卡片上选中的模型（在其账号或 Key 间路由）；改选前其他模型和规则不生效，失败时也不切换。"
        case .other(let value): "由插件提供的路由方式（\(value)）。插件没在运行时，按列出的顺序尝试。"
        }
    }

    /// 「被限流时排到最后」只对这些方式有意义（网页 `sinkable`）。
    public var sinkable: Bool { self != .rotate && self != .weight && self != .manual }
    /// 成员摘要用「→」连接（按顺序），其余用「·」。
    public var separator: String { self == .order ? " → " : " · " }
}

// MARK: 会话保持

public enum GroupAffinity: String, Hashable, Sendable, CaseIterable, Identifiable {
    case auto = "", session, turn, off, strict

    public init(raw: String) { self = GroupAffinity(rawValue: raw) ?? .auto }
    public var id: String { rawValue.isEmpty ? "auto" : rawValue }

    public var title: String {
        switch self {
        case .auto: "自动"
        case .session: "整个会话"
        case .turn: "一轮之内"
        case .off: "关闭"
        case .strict: "严格"
        }
    }

    public var hint: String {
        switch self {
        case .auto: "厂商缓存仍有价值时，会话留在回答过它的账号或 Key 上：一轮之内始终保持，跨轮则在缓存新鲜时保持。"
        case .session: "会话始终留在回答过它的账号或 Key 上，只要它仍能回答。"
        case .turn: "一轮之内（Agent 回传工具结果时）不换；你再次发言时，路由重新决定。"
        case .off: "每个请求都重新路由，不论之前由谁回答。"
        case .strict: "会话始终留在回答它的账号或 Key 上，绝不换到别的，即使超过用量上限也一样：被限流或额度用完时，错误直接交给 Agent。新会话照常路由。"
        }
    }
}

/// 「迟迟不出字」（`firstToken`，秒）与「成员全都忙」（`patience`，秒；-1 = 关闭）的预设，与网页相同。
public struct GroupTimeout: Hashable, Sendable, Identifiable {
    public var seconds: Int
    public var title: String
    public var id: Int { seconds }

    public init(_ seconds: Int, _ title: String) {
        self.seconds = seconds
        self.title = title
    }
}

public enum GroupTimeouts {
    public static let firstToken: [GroupTimeout] = [.init(0, "一直等"), .init(30, "30 秒"), .init(60, "1 分钟"), .init(120, "2 分钟")]
    public static let patience: [GroupTimeout] = [.init(-1, "关闭"), .init(0, "1 分钟"), .init(120, "2 分钟"), .init(240, "4 分钟")]

    public static func firstTokenTitle(_ seconds: Int) -> String {
        firstToken.first { $0.seconds == seconds }?.title ?? durationText(seconds)
    }

    public static func patienceTitle(_ seconds: Int) -> String {
        let normalized = seconds == 60 ? 0 : seconds
        return patience.first { $0.seconds == normalized }?.title ?? durationText(seconds)
    }

    static func durationText(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) 秒" }
        if seconds % 60 == 0 { return "\(seconds / 60) 分钟" }
        return String(format: "%.1f 分钟", Double(seconds) / 60)
    }
}

// MARK: 成员

/// 路由组里的一个成员（`memberInfo[]` 与组本身的 off / fast / weights / matched 合起来）。
public struct GroupMemberDetail: Hashable, Identifiable, Sendable {
    /// 成员 id：`provider/model[:effort]` 或 `group/<id>`。
    public var id: String
    public var ready: Bool
    /// 供应商 id 与名字（成员是路由组时 `providerName` 是那个组的名字）。
    public var provider: String
    public var providerName: String
    /// 实际向厂商请求的模型名。
    public var model: String
    /// 去掉固定推理强度后的 `provider/model`（查速度用）。
    public var of: String
    /// 固定的推理强度（"high"、"low+high"…）；空 = 跟随分组。
    public var effort: String
    /// 供应商有几个账号或 Key 在用。
    public var accounts: Int
    public var isGroup: Bool
    /// 它的供应商被关掉了：组会跳过它。
    public var providerOff: Bool
    public var fast: Bool
    public var canFast: Bool
    public var context: Int?
    public var images: Bool
    public var imagesUnknown: Bool
    /// 在组里被关掉（`off`）：保留位置，不发请求。
    public var off: Bool
    /// 由模式匹配进来（`matched`）：不能移除，只能关掉。
    public var matched: Bool
    /// 按权重路由时的权重（至少 1）。
    public var weight: Int

    public init(id: String, ready: Bool = true, provider: String = "", providerName: String = "", model: String = "", of: String = "",
                effort: String = "", accounts: Int = 1, isGroup: Bool = false, providerOff: Bool = false, fast: Bool = false,
                canFast: Bool = false, context: Int? = nil, images: Bool = false, imagesUnknown: Bool = false, off: Bool = false,
                matched: Bool = false, weight: Int = 1) {
        self.id = id
        self.ready = ready
        self.provider = provider
        self.providerName = providerName
        self.model = model
        self.of = of
        self.effort = effort
        self.accounts = accounts
        self.isGroup = isGroup
        self.providerOff = providerOff
        self.fast = fast
        self.canFast = canFast
        self.context = context
        self.images = images
        self.imagesUnknown = imagesUnknown
        self.off = off
        self.matched = matched
        self.weight = weight
    }

    /// 为编辑器里新加进来、主机还没给 memberInfo 的成员拼一个详情。
    public static func candidate(_ id: String, models: [WebModelRef], groups: [WebGroup]) -> GroupMemberDetail {
        if id.hasPrefix("group/") {
            let inner = groups.first { $0.ref == id || "group/" + $0.id == id }
            return GroupMemberDetail(id: id, ready: inner?.ready ?? false, providerName: inner?.name ?? "", isGroup: true)
        }
        let ref = models.first { $0.id == id }
        let provider = String(id.split(separator: "/").first ?? "")
        let model = String(id.split(separator: "/", maxSplits: 1).last ?? "")
        return GroupMemberDetail(id: id, ready: ref != nil, provider: provider, providerName: ref?.providerName ?? provider,
                                 model: ref.map { $0.id.split(separator: "/", maxSplits: 1).last.map(String.init) ?? $0.name } ?? model, of: id)
    }

    /// 名称一行：模型名（成员是组时是组名）。
    public var title: String {
        if isGroup { return providerName.isEmpty ? String(id.dropFirst("group/".count)) : providerName }
        if !model.isEmpty { return model }
        return id
    }

    /// 副标题：供应商 · 推理强度 · 快速。
    public var subtitle: String {
        var parts: [String] = []
        if isGroup { parts.append("路由组") } else if !providerName.isEmpty { parts.append(providerName) }
        if !effort.isEmpty { parts.append(effort.split(separator: "+").joined(separator: " / ") + " 推理") }
        if fast { parts.append("快速") }
        return parts.joined(separator: " · ")
    }

    /// 不可用的原因；可用时为 nil。
    public var unavailableReason: String? {
        if providerOff { return "\(providerName.isEmpty ? provider : providerName) 已关闭：组会跳过它，直到重新打开" }
        if !ready { return "现在没有供应商提供 \(of.isEmpty ? id : of)，会被跳过" }
        return nil
    }

    /// 查 `/api/model-speeds` 用的键（`provider/model`）。
    public var speedKeys: [String] {
        var keys: [String] = []
        if !of.isEmpty { keys.append(of) }
        if !provider.isEmpty, !model.isEmpty { keys.append("\(provider)/\(model)") }
        if !keys.contains(id) { keys.append(id) }
        return keys
    }
}

public struct GroupPattern: Hashable, Sendable {
    public var pattern: String
    /// 现在匹配到几个模型。
    public var models: Int
}

extension WebGroup {
    public var routingKind: GroupRouting { GroupRouting(raw: routing) }
    public var affinity: GroupAffinity { GroupAffinity(raw: raw["affinity"]?.string ?? "") }
    public var sink: Bool { raw["sink"]?.bool ?? false }
    public var firstToken: Int { raw["firstToken"]?.int ?? 0 }
    public var patience: Int { raw["patience"]?.int ?? 0 }
    public var unlists: Bool { raw["unlists"]?.bool ?? false }
    public var off: [String] { raw["off"]?.strings ?? [] }
    public var fast: [String] { raw["fast"]?.strings ?? [] }
    public var matched: [String] { raw["matched"]?.strings ?? [] }
    /// 组点名的成员（不含模式匹配进来的）。
    public var named: [String] { members.filter { !matched.contains($0) } }
    public var weights: [String: Int] { (raw["weights"]?.object ?? [:]).compactMapValues(\.int) }
    public var ruleCount: Int { raw["rules"]?.array?.count ?? 0 }
    public var classifier: String { raw["classifier"]?.string ?? "" }
    public var patterns: [GroupPattern] {
        (raw["patterns"]?.array ?? []).compactMap { item in
            guard let pattern = item["pattern"]?.string else { return nil }
            return GroupPattern(pattern: pattern, models: item["models"]?.int ?? 0)
        }
    }
    /// 分类模型上次没能回答的原因（网页卡片上的红字）。
    public var classifierFailure: String? {
        guard let failure = raw["classifierFailed"], let error = failure["error"]?.string, !error.isEmpty else { return nil }
        return error
    }
    /// 手动路由时所有请求发往的成员。
    public var pickedMember: String? {
        if let picked = raw["picked"]?.string, !picked.isEmpty { return picked }
        if let pick = raw["pick"]?.string, members.contains(pick) { return pick }
        return members.first
    }

    public func weight(of member: String) -> Int { max(weights[member] ?? 1, 1) }

    /// 每个成员的详情，按组里的顺序。
    public var memberDetails: [GroupMemberDetail] {
        let info = raw["memberInfo"]?.array ?? []
        let off = Set(self.off), fast = Set(self.fast), matched = Set(self.matched)
        return members.map { id in
            let item = info.first { $0["id"]?.string == id } ?? .null
            let isGroup = item["group"]?.bool ?? id.hasPrefix("group/")
            return GroupMemberDetail(
                id: id,
                ready: item["ready"]?.bool ?? false,
                provider: item["provider"]?.string ?? (isGroup ? "" : String(id.split(separator: "/").first ?? "")),
                providerName: item["name"]?.string ?? "",
                model: item["model"]?.string ?? (isGroup ? "" : String(id.split(separator: "/", maxSplits: 1).last ?? "")),
                of: item["of"]?.string ?? "",
                effort: item["effort"]?.string ?? "",
                accounts: item["on"]?.int ?? 0,
                isGroup: isGroup,
                providerOff: item["providerOff"]?.bool ?? false,
                fast: item["fast"]?.bool ?? fast.contains(id),
                canFast: item["canFast"]?.bool ?? false,
                context: item["context"]?.int,
                images: item["images"]?.bool ?? false,
                imagesUnknown: item["imagesUnknown"]?.bool ?? false,
                off: off.contains(id),
                matched: matched.contains(id),
                weight: weight(of: id))
        }
    }

    /// 卡片上的一行成员摘要（按顺序用「→」，其余「·」，关掉的标「（已关闭）」）。
    public var memberSummary: String {
        let details = memberDetails
        guard !details.isEmpty else { return patterns.isEmpty ? "还没有成员" : "按模式匹配" }
        return details.map { detail in
            var text = detail.isGroup ? "路由组 · \(detail.title)" : (detail.providerName.isEmpty ? detail.title : "\(detail.providerName) · \(detail.title)")
            if detail.off { text += "（已关闭）" }
            return text
        }.joined(separator: routingKind.separator)
    }

    /// 关掉的成员数（组内 `off`）。
    public var offCount: Int { off.filter(members.contains).count }

    /// 份额：按权重路由时这个成员占开着的成员的百分比。
    public func share(of member: String) -> Int {
        let on = members.filter { !off.contains($0) }
        let total = on.reduce(0) { $0 + weight(of: $1) }
        guard total > 0, on.contains(member) else { return 0 }
        return Int((100 * Double(weight(of: member)) / Double(total)).rounded())
    }
}

// MARK: 多账号 / 多 Key 的供应商

/// `GET /api/groups` → `pools[]`：有几个账号或 Key 同时在用的供应商，它自己在这些账号间路由。
public struct WebGroupPool: Hashable, Identifiable, Sendable {
    public var provider: String
    public var name: String
    /// "account" 或 "key"。
    public var kind: String
    public var who: [String]
    public var routing: GroupRouting
    public var affinity: GroupAffinity
    public var sink: Bool
    /// 只给某个协议用的 Key 自成一组时的协议名。
    public var `protocol`: String

    public var id: String { provider + "|" + `protocol` }

    public var countText: String {
        if !`protocol`.isEmpty { return "\(who.count) 个 \(`protocol`) Key" }
        return kind == "account" ? "\(who.count) 个账号" : "\(who.count) 个 Key"
    }
}

extension WebGroups {
    public var pools: [WebGroupPool] {
        (raw["pools"]?.array ?? []).compactMap { pool in
            guard let provider = pool["provider"]?.string else { return nil }
            return WebGroupPool(provider: provider,
                                name: pool["name"]?.string ?? provider,
                                kind: pool["kind"]?.string ?? "key",
                                who: pool["who"]?.strings ?? [],
                                routing: GroupRouting(raw: pool["routing"]?.string ?? ""),
                                affinity: GroupAffinity(raw: pool["affinity"]?.string ?? ""),
                                sink: pool["sink"]?.bool ?? false,
                                protocol: pool["protocol"]?.string ?? "")
        }
    }

    /// magpie 是否自动把多个供应商都提供的同一模型组成 auto/… 组。
    public var found: Bool { raw["found"]?.bool ?? true }

    /// 网页列出的组（自动发现后被移除的不列出）。
    public var visible: [WebGroup] { groups.filter { !$0.hidden } }

    public subscript(group id: String) -> WebGroup? { groups.first { $0.id == id } }

    /// 把组 `id` 挪到可见组里的 `to` 位置后的整份顺序（隐藏的排在最后），即 `POST /api/groups/arrange` 的 `order`。
    public func order(moving source: IndexSet, to destination: Int) -> [String] {
        let ids = WebGroups.moved(visible.map(\.id), from: source, to: destination)
        return ids + groups.filter(\.hidden).map(\.id)
    }
}

extension WebGroups {
    /// 与 SwiftUI 的 `move(fromOffsets:toOffset:)` 相同的语义（Core 不依赖 SwiftUI）。
    public static func moved<T>(_ items: [T], from source: IndexSet, to destination: Int) -> [T] {
        let picked = source.filter { $0 < items.count }.map { items[$0] }
        var rest: [T] = []
        var insertAt = destination
        for (index, item) in items.enumerated() {
            if source.contains(index) {
                if index < destination { insertAt -= 1 }
            } else {
                rest.append(item)
            }
        }
        insertAt = max(0, min(insertAt, rest.count))
        rest.insert(contentsOf: picked, at: insertAt)
        return rest
    }
}

// MARK: 速度（GET /api/model-speeds）

/// 一个模型在一个供应商上近 7 天的平均速度：首字时间（毫秒）与输出速度（token/秒）。
public struct ModelSpeed: Hashable, Sendable {
    public var ttft: Int?
    public var tps: Double?
    /// 统计了几次计时的回答。
    public var samples: Int

    public init(ttft: Int? = nil, tps: Double? = nil, samples: Int = 0) {
        self.ttft = ttft
        self.tps = tps
        self.samples = samples
    }

    /// 例：「首字 1.2 秒 · 48 tok/s」。
    public var text: String {
        var parts: [String] = []
        if let ttft, ttft > 0 {
            parts.append(ttft < 1000 ? "首字 \(ttft) 毫秒" : String(format: "首字 %.1f 秒", Double(ttft) / 1000))
        }
        if let tps, tps > 0 { parts.append(tps >= 10 ? "\(Int(tps.rounded())) tok/s" : String(format: "%.1f tok/s", tps)) }
        return parts.joined(separator: " · ")
    }
}

public struct ModelSpeeds: Hashable, Sendable {
    public var byRef: [String: ModelSpeed]

    public init(byRef: [String: ModelSpeed] = [:]) { self.byRef = byRef }

    public init(json: WebJSON) {
        var out: [String: ModelSpeed] = [:]
        for (ref, value) in json.object ?? [:] {
            let ttft = value["ttft"]?.int
            let tps = value["tps"]?.double
            guard (ttft ?? 0) > 0 || (tps ?? 0) > 0 else { continue }
            out[ref] = ModelSpeed(ttft: ttft, tps: tps, samples: value["n"]?.int ?? 0)
        }
        byRef = out
    }

    public func speed(for member: GroupMemberDetail) -> ModelSpeed? {
        for key in member.speedKeys { if let speed = byRef[key] { return speed } }
        return nil
    }

    /// 组里最近最快的成员（首字时间最短；没有首字时间时看输出速度）。
    public func fastest(in members: [GroupMemberDetail]) -> String? {
        let timed = members.compactMap { member in speed(for: member).map { (member.id, $0) } }
        if let best = timed.filter({ ($0.1.ttft ?? 0) > 0 }).min(by: { ($0.1.ttft ?? .max) < ($1.1.ttft ?? .max) }) { return best.0 }
        return timed.max { ($0.1.tps ?? 0) < ($1.1.tps ?? 0) }?.0
    }
}

// MARK: 请求体

/// 在 App 里能改的路由组设置；nil = 不改，沿用主机上的。
public struct GroupEdits: Hashable, Sendable {
    public var id: String?
    public var name: String?
    /// 成员的完整顺序（含模式匹配进来的）。
    public var members: [String]?
    public var routing: GroupRouting?
    public var affinity: GroupAffinity?
    public var sink: Bool?
    public var off: Set<String>?
    public var weights: [String: Int]?
    public var fast: Set<String>?
    public var firstToken: Int?
    public var patience: Int?
    public var unlists: Bool?

    public init(id: String? = nil, name: String? = nil, members: [String]? = nil, routing: GroupRouting? = nil,
                affinity: GroupAffinity? = nil, sink: Bool? = nil, off: Set<String>? = nil, weights: [String: Int]? = nil,
                fast: Set<String>? = nil, firstToken: Int? = nil, patience: Int? = nil, unlists: Bool? = nil) {
        self.id = id
        self.name = name
        self.members = members
        self.routing = routing
        self.affinity = affinity
        self.sink = sink
        self.off = off
        self.weights = weights
        self.fast = fast
        self.firstToken = firstToken
        self.patience = patience
        self.unlists = unlists
    }
}

extension WebRequests {
    /// 读出来时才有、保存时不该发回的字段（除了 `groupComputedFields`，还有派生的 auto / matched）。
    static let groupDerivedFields = groupComputedFields + ["auto", "matched"]

    /// `POST /api/groups/save`：整组覆盖。以主机返回的组为基础，只改 `edits` 里给出的设置，
    /// 规则、模式、分类模型、推理等级、上下文等原样带回（与网页编辑器的保存相同）。
    ///
    /// 成员：`members` 只发点名的（模式匹配进来的由主机重新匹配），`placed` 发完整顺序，
    /// 这样挪动模式匹配进来的成员也能保存；off / fast / weights 去掉已不在组里的成员。
    public static func groupSave(_ group: WebGroup?, edits: GroupEdits) -> WebJSON {
        var body = (group?.raw ?? [:]).removing(groupDerivedFields)
        let matched = group?.matched ?? []
        let order = edits.members ?? group?.members ?? []
        let newID = (edits.id ?? group?.id ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        body["id"] = .string(newID)
        let name = (edits.name ?? group?.name ?? newID).trimmingCharacters(in: .whitespacesAndNewlines)
        body["name"] = .string(name.isEmpty ? newID : name)
        body["members"] = .strings(order.filter { !matched.contains($0) })
        if !matched.isEmpty || group?.raw["placed"] != nil { body["placed"] = .strings(order) }
        if let group, group.id != newID { body["from"] = .string(group.id) }

        let routing = edits.routing ?? group?.routingKind ?? .smart
        body["routing"] = routing.raw.isEmpty ? nil : .string(routing.raw)
        if let affinity = edits.affinity { body["affinity"] = affinity.rawValue.isEmpty ? nil : .string(affinity.rawValue) }
        let sink = (edits.sink ?? group?.sink ?? false) && routing.sinkable
        body["sink"] = sink ? true : nil
        if let firstToken = edits.firstToken { body["firstToken"] = firstToken > 0 ? .int(Int64(firstToken)) : nil }
        if let patience = edits.patience { body["patience"] = patience != 0 ? .int(Int64(patience)) : nil }
        if let unlists = edits.unlists { body["unlists"] = unlists ? true : nil }

        let present = Set(order)
        let off = (edits.off.map { Array($0) } ?? group?.off ?? []).filter(present.contains)
        body["off"] = off.isEmpty ? nil : .strings(order.filter(off.contains))
        let fast = (edits.fast.map { Array($0) } ?? group?.fast ?? []).filter(present.contains)
        body["fast"] = fast.isEmpty ? nil : .strings(order.filter(fast.contains))
        let weights = (edits.weights ?? group?.weights ?? [:]).filter { present.contains($0.key) && $0.value > 1 }
        body["weights"] = weights.isEmpty ? nil : .object(weights.mapValues { .int(Int64(min($0, 1000))) })
        if let pick = body["pick"]?.string, !pick.isEmpty, !present.contains(pick) { body["pick"] = nil }
        return body
    }

    /// `POST /api/groups/pick`：手动路由的组改发给另一个成员（只改这一项）。
    public static func groupPick(_ id: String, member: String) -> WebJSON { ["id": .string(id), "pick": .string(member)] }
    /// `POST /api/groups/arrange`：路由组的顺序（Agent 的模型列表也按它排）。
    public static func groupArrange(_ order: [String]) -> WebJSON { ["order": .strings(order)] }
    /// `POST /api/groups/found`：自动发现路由组的总开关。
    public static func groupFound(_ on: Bool) -> WebJSON { ["on": .bool(on)] }
    /// `POST /api/groups/copy`：复制一个组（模型、路由、规则都带上），排在它后面。
    public static func groupCopy(_ id: String, name: String) -> WebJSON { ["id": .string(id), "name": .string(name)] }

    /// `POST /api/provider/route|affinity|sink`：多账号 / 多 Key 供应商自己的路由设置。
    public static func providerRouting(_ id: String, routing: GroupRouting) -> WebJSON { ["id": .string(id), "routing": .string(routing.raw)] }
    public static func providerAffinity(_ id: String, affinity: GroupAffinity) -> WebJSON { ["id": .string(id), "affinity": .string(affinity.rawValue)] }
    public static func providerSink(_ id: String, sink: Bool) -> WebJSON { ["id": .string(id), "sink": .bool(sink)] }
}
