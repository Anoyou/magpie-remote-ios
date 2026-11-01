import Foundation

// Agent 页补齐官方（internal/gui/assets/app.js）：上移 / 下移 / 隐藏 / 显示（POST /api/agents/arrange，
// moveAgent / setAgentHidden），以及每个 Agent 的「模型列表」放哪些 magpie 模型（GET/POST /api/agent-models/{id}，
// openAgentModels）。文案用官方中文（i18n.js 的 zh）。

// MARK: 排序与隐藏

extension AgentArrangement {
    /// 把 `id` 挪到在用（上面那组）的第 `to` 个；折叠的排在后面不动（官方 moveAgent）。
    /// 返回要保存的新顺序；挪不动时 nil。
    public func moving(_ id: String, to: Int) -> [String]? {
        var ids = shown.map(\.id)
        guard let from = ids.firstIndex(of: id), to >= 0, to < ids.count, to != from else { return nil }
        ids.insert(ids.remove(at: from), at: to)
        return ids + (notSetUp + hidden).map(\.id)
    }

    /// 在用那组里的位置（上移 / 下移是否可用）。
    public func shownIndex(of id: String) -> Int? { shown.firstIndex { $0.id == id } }
}

/// `POST /api/agents/arrange` 的请求体与隐藏 / 显示后的提示。
public enum AgentArrange {
    public static func body(order: [String], hidden: [String], shown: [String] = []) -> WebJSON {
        ["order": .strings(order), "hidden": .strings(hidden), "shown": .strings(shown)]
    }

    /// 隐藏 / 显示一个 Agent（官方 setAgentHidden）：顺序是所有 Agent 现在的顺序，隐藏列表加上或去掉它。
    public static func hiding(_ agent: WebAgent, hide: Bool, all: [WebAgent], order: [String], hidden: [String]) -> (order: [String], hidden: [String]) {
        let sorted = AgentArrangement.sorted(all, order: order)
        var next = hidden.filter { $0 != agent.id }
        if hide { next.append(agent.id) }
        return (sorted.map(\.id), next)
    }

    /// 隐藏 / 显示后的一句话（官方 status）。`stillFolded`：显示后仍在「未设置」里。
    public static func said(_ agent: WebAgent, hide: Bool, stillFolded: Bool) -> String {
        if hide { return "已隐藏 \(agent.name) · 可在列表底部「已隐藏」里找回" }
        if stillFolded {
            return agent.connectable ? "\(agent.name) 已取消隐藏 · 接入前留在「未设置」" : "\(agent.name) 已取消隐藏 · 选好模型前留在「未设置」"
        }
        return "已显示 \(agent.name)"
    }
}

extension AgentArrangement {
    /// 按保存的顺序排（没列出的在后面，保持主机给的先后）。
    public static func sorted(_ agents: [WebAgent], order: [String]) -> [WebAgent] {
        func rank(_ agent: WebAgent) -> Int { order.firstIndex(of: agent.id) ?? order.count }
        return agents.enumerated()
            .sorted { lhs, rhs in
                let (a, b) = (rank(lhs.element), rank(rhs.element))
                return a != b ? a < b : lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}

// MARK: 模型数量

/// `agents[].models`：这个 Agent 的列表里放了几个、一共能放几个（官方 modelCountJSON）。
public struct AgentModelCount: Hashable, Sendable {
    public var shown: Int
    public var listed: Int
    public var names: [String]

    public init?(json: WebJSON?) {
        guard let json, json.object != nil else { return nil }
        shown = json["shown"]?.int ?? 0
        listed = json["listed"]?.int ?? 0
        names = json["names"]?.strings ?? []
    }

    public init(shown: Int, listed: Int, names: [String] = []) {
        self.shown = shown
        self.listed = listed
        self.names = names
    }

    /// 官方 fillModelsEntry：「全部 N 个模型」或「显示 x / y 个模型」。
    public var entry: String { shown >= listed ? "全部 \(listed) 个模型" : "显示 \(shown) / \(listed) 个模型" }
}

extension WebAgent {
    /// 列表里放哪些 magpie 模型：主机给了数量才有这一行（官方 agentModelCount）。
    public var modelCount: AgentModelCount? { AgentModelCount(json: raw["models"]) }
}

// MARK: 模型列表

/// `GET /api/agent-models/{id}`：一个 Agent 的列表里能放的 magpie 模型（路由组 + 各供应商的模型）。
public struct AgentModelList: Hashable, Sendable {
    public struct Model: Hashable, Identifiable, Sendable {
        public var id: String
        public var name: String
        /// 供应商名；路由组是 "Routing groups"。
        public var group: String
        public var icon: String
        public var icons: [String]
        public var logo: String
        public var context: Int
        public var hidden: Bool
        /// Agent 正在用它，不能隐藏。
        public var inUse: Bool
        /// Codex 自己的（ChatGPT 账号的）模型。
        public var own: Bool

        public init(json: WebJSON) {
            id = json["id"]?.string ?? ""
            name = json["name"]?.string ?? id
            group = json["group"]?.string ?? ""
            icon = json["icon"]?.string ?? ""
            icons = json["icons"]?.strings ?? []
            logo = json["logo"]?.string ?? ""
            context = json["context"]?.int ?? 0
            hidden = json["hidden"]?.bool ?? false
            inUse = json["inUse"]?.bool ?? false
            own = json["own"]?.bool ?? false
        }

        public var isRoutingGroup: Bool { group == AgentModelList.routingGroups }
    }

    /// 主机给路由组用的组名（官方 ROUTING_GROUPS）。
    public static let routingGroups = "Routing groups"

    public var models: [Model]
    /// 拖过顺序（不是 magpie 默认的）。
    public var ordered: Bool
    /// 「只显示我勾选的模型」。
    public var only: Bool
    /// 这个 Agent 有自带的模型（显示「显示 X 自带的模型」开关）。
    public var own: Bool
    /// 不显示它自带的模型。
    public var ownHidden: Bool

    public init(json: WebJSON) {
        models = (json["models"]?.array ?? []).map(Model.init(json:)).filter { !$0.id.isEmpty }
        ordered = json["ordered"]?.bool ?? false
        only = json["only"]?.bool ?? false
        own = json["own"]?.bool ?? false
        ownHidden = json["ownHidden"]?.bool ?? false
    }

    /// 合上 POST 的回答：它只带变了的字段（models / only / ordered / ownHidden）。
    public mutating func merge(_ json: WebJSON) {
        if let list = json["models"]?.array { models = list.map(Model.init(json:)).filter { !$0.id.isEmpty } }
        if let value = json["ordered"]?.bool { ordered = value }
        if let value = json["only"]?.bool { only = value }
        if let value = json["ownHidden"]?.bool { ownHidden = value }
    }

    public struct Group: Hashable, Identifiable, Sendable {
        public var name: String
        public var icon: String
        public var models: [Model]
        public var id: String { name }
        public var isRoutingGroup: Bool { name == AgentModelList.routingGroups }
        /// 小节标题（路由组用中文）。
        public var title: String { isRoutingGroup ? "路由组" : name }
        public var shownCount: Int { models.filter { !$0.hidden }.count }
        /// 能整组切换的（不含在用的）。
        public var free: [Model] { models.filter { !$0.inUse } }
        /// 整组按钮：都显示着时「全部隐藏」，否则「全部显示」。
        public var allOn: Bool { free.allSatisfy { !$0.hidden } }
    }

    /// 按主机的分组，路由组排最前（官方 regroup）。
    public var groups: [Group] {
        var out: [Group] = []
        for m in models {
            if let i = out.firstIndex(where: { $0.name == m.group }) { out[i].models.append(m) }
            else { out.append(Group(name: m.group, icon: m.icon, models: [m])) }
        }
        return out.filter(\.isRoutingGroup) + out.filter { !$0.isRoutingGroup }
    }

    /// 一开始折起来的组：供应商多于一个、超过 8 个模型、里面没有在用的（官方 shut）。
    public var initiallyFolded: Set<String> {
        let gs = groups
        let providers = gs.filter { !$0.isRoutingGroup }.count
        return Set(gs.filter { providers > 1 && $0.models.count > 8 && !$0.models.contains(where: \.inUse) }.map(\.name))
    }

    public var shownCount: Int { models.filter { !$0.hidden }.count }
    public var count: AgentModelCount {
        AgentModelCount(shown: shownCount, listed: models.count, names: models.filter { !$0.hidden }.prefix(3).map(\.name))
    }

    /// 「排序」里显示的：显示着的，按拖过的顺序；没拖过时 Codex 自己的排前面（官方 inOrder）。
    public var inOrder: [Model] {
        let shown = models.filter { !$0.hidden }
        return ordered ? shown : shown.filter(\.own) + shown.filter { !$0.own }
    }

    /// 切换一个模型（在用的不动）。
    public mutating func toggle(_ id: String) {
        guard let i = models.firstIndex(where: { $0.id == id }), !models[i].inUse else { return }
        models[i].hidden.toggle()
    }

    /// 整组切换（官方 am-all）。
    public mutating func setGroup(_ name: String, hidden: Bool) {
        for i in models.indices where models[i].group == name && !models[i].inUse { models[i].hidden = hidden }
    }

    /// 全部隐藏 / 全部显示（在用的不动）。
    public mutating func setAll(hidden: Bool) {
        for i in models.indices where !models[i].inUse { models[i].hidden = hidden }
    }

    /// 「排序」里挪动：显示着的按新顺序在前，隐藏的在后（官方 moveTo）。返回要保存的顺序。
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) -> [String] {
        var shown = inOrder
        let moving = source.sorted().map { shown[$0] }
        let before = source.filter { $0 < destination }.count
        for index in source.sorted(by: >) { shown.remove(at: index) }
        shown.insert(contentsOf: moving, at: destination - before)
        models = shown + models.filter(\.hidden)
        ordered = true
        return shown.map(\.id)
    }

    /// 保存勾选的请求体：「只显示我勾选的」时发 shown，否则发 hidden（官方 save）。
    public var visibilityBody: WebJSON {
        only ? ["shown": .strings(models.filter { !$0.hidden }.map(\.id))] : ["hidden": .strings(models.filter(\.hidden).map(\.id))]
    }

    public static func onlyBody(_ on: Bool) -> WebJSON { ["only": .bool(on)] }
    public static func ownHiddenBody(_ hidden: Bool) -> WebJSON { ["ownHidden": .bool(hidden)] }
    public static func orderBody(_ ids: [String]) -> WebJSON { ["order": .strings(ids)] }

    /// 「排序」底部那句（官方 footNote）。
    public static func orderNote(agentID: String, agentName: String) -> String {
        agentID.hasPrefix("codex") ? "拖动排列 \(agentName) 列表中的顺序；新模型排在最后" : "拖动排列 magpie 交给 \(agentName) 的模型顺序；新模型排在最后"
    }
}

/// 上下文长度的简写（官方 ctxShort）：200K、1M、1.0M（不是整百万时保留一位）。
public func agentContextShort(_ tokens: Int) -> String {
    guard tokens > 0 else { return "" }
    if tokens >= 1_000_000 {
        return (tokens % 1_000_000 == 0 ? String(tokens / 1_000_000) : String(format: "%.1f", Double(tokens) / 1_000_000)) + "M"
    }
    return "\(Int((Double(tokens) / 1000).rounded()))K"
}

extension WebClient {
    /// `POST /api/agents/arrange`：Agent 页的顺序与隐藏（magpie 自己的设置，不碰 Agent 的文件）。回答是整份设置。
    public func arrangeAgents(order: [String], hidden: [String], shown: [String] = []) async throws -> WebSettings {
        WebSettings(json: try await post("/api/agents/arrange", AgentArrange.body(order: order, hidden: hidden, shown: shown)))
    }

    public func agentModels(_ id: String) async throws -> AgentModelList {
        AgentModelList(json: try await get("/api/agent-models/\(id)"))
    }

    /// 改一个 Agent 的模型列表；body 只带一个字段（hidden / shown / order / only / ownHidden）。
    public func setAgentModels(_ id: String, _ body: WebJSON) async throws -> WebJSON {
        try await post("/api/agent-models/\(id)", body)
    }
}
