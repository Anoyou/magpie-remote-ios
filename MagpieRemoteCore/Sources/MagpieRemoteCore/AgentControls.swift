import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Agent 页照 magpie 官方网页（internal/gui/assets/app.js 的 cliTag / updateCLI / paintUpdateAll / connectSwitch /
// driftFix / askDisconnect / renderProfiles）补齐的部分：命令行程序的版本与「更新」、「全部更新」、「接入 magpie」开关、
// 「重新应用」、方案（profiles）。文案取官方 i18n.js 的简体中文。

// MARK: 命令行程序（GET /api/agents/cli）

/// 一个 Agent 命令行程序的版本信息（magpie `agent.CLI`）。
public struct AgentCLI: Hashable, Sendable {
    public var version: String
    /// 最新版本（从它的安装方式那里查到的）。
    public var latest: String
    /// 用什么更新：npm、bun、pnpm、brew、self；空 = magpie 看不出它是怎么装的。
    public var via: String
    /// 更新命令（给人看的样子）。
    public var command: String
    /// 有新版本，而且 magpie 知道怎么更新。
    public var update: Bool
    /// 旁边装的桌面 App 的版本（例如 Codex App）。
    public var app: String
    /// 要管理员权限（Windows）。
    public var admin: Bool
    public var path: String
    /// 在 magpie 自己加的 PATH 目录里找到的，终端里找不到。
    public var offPath: Bool
    /// 没有单独装 Claude Code，用的是 Claude Desktop 里内置的。
    public var inDesktop: Bool
    public var desktopVersion: String

    public init(json: WebJSON) {
        version = json["version"]?.string ?? ""
        latest = json["latest"]?.string ?? ""
        via = json["via"]?.string ?? ""
        command = json["command"]?.string ?? ""
        update = json["update"]?.bool ?? false
        app = json["app"]?.string ?? ""
        admin = json["admin"]?.bool ?? false
        path = json["path"]?.string ?? ""
        offPath = json["offPath"]?.bool ?? false
        inDesktop = json["inDesktop"]?.bool ?? false
        desktopVersion = json["desktopVersion"]?.string ?? ""
    }

    /// 有没有可显示的东西（官方：没有 version / app / inDesktop 就什么都不画）。
    public var isEmpty: Bool { version.isEmpty && app.isEmpty && !inDesktop }

    /// 名字后面的版本标签：只有 CLI 时是「0.1.2」，旁边有 App 时是「CLI 0.1.2」。
    public var versionTag: String? {
        guard !version.isEmpty else { return nil }
        return app.isEmpty ? version : "CLI \(version)"
    }

    /// 版本标签的说明（官方 `v.title`）。
    public func versionNote(agent: String) -> String {
        if via.isEmpty { return "\(agent) \(version) · 无法判断安装方式，请按原安装方式更新" }
        if update { return "已安装 \(agent) \(version) · \(latest) 已发布" }
        return "\(agent) \(version) · 已是最新"
    }

    /// 更新按钮的字（官方 `paintCLIButton`）。
    public func buttonTitle(busy: Bool) -> String { busy ? "更新中…" : "更新到 \(latest)" }

    /// 更新按钮的说明：通过哪个命令更新。
    public var commandNote: String {
        admin ? "通过 \(command) 以管理员身份更新：Windows 会先询问" : "通过 \(command) 更新"
    }
}

/// `GET /api/agents/cli` 的回答：各 Agent 的命令行程序，`pending` = 还有在问的，过一会儿再读。
public struct AgentCLIs: Hashable, Sendable {
    public var agents: [String: AgentCLI]
    public var pending: Bool

    public init(agents: [String: AgentCLI] = [:], pending: Bool = false) {
        self.agents = agents
        self.pending = pending
    }

    public init(json: WebJSON) {
        var agents: [String: AgentCLI] = [:]
        for (id, value) in json["agents"]?.object ?? [:] { agents[id] = AgentCLI(json: value) }
        self.agents = agents
        pending = json["pending"]?.bool ?? false
    }
}

/// 更新提示的文案（官方 updateCLI / versionChange / updatedSay / paintUpdateAll）。
public enum AgentCLIText {
    /// 一个更新完成后的提示。
    public static func updated(agent: String, from: String?, to: String) -> String {
        if let from, !from.isEmpty, from != to { return "\(agent) 已更新：\(from) → \(to)" }
        return "\(agent) 已更新到 \(to)"
    }

    /// 「Pi 1.0.9 → 1.1.0」，旧版本不知道或没变时只写名字和现在的版本。
    public static func change(agent: String, from: String?, to: String) -> String {
        if let from, !from.isEmpty, !to.isEmpty, from != to { return "\(agent) \(from) → \(to)" }
        return [agent, to].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// 列表上方那一行（没在跑「全部更新」时）：哪些有新版本。
    public static func behind(_ names: [String]) -> String {
        switch names.count {
        case 0: "所有 Agent 都已是最新"
        case 1: "\(names[0]) 有新版本"
        default: "\(names.count) 个 Agent 有新版本：\(names.joined(separator: ", "))"
        }
    }
}

/// 「全部更新」的一次运行：一个接一个地更新（两个全局 npm 安装同时跑会互相踩到目录），记下每个的结果。
public struct AgentUpdateRun: Hashable, Sendable {
    public struct Failure: Hashable, Sendable {
        public var name: String
        public var message: String
    }

    public var total: Int
    public var done = 0
    /// 正在更新的那个的名字。
    public var now: String
    public var failed: [Failure] = []
    /// 「Pi 1.0.9 → 1.1.0」这样的变化。
    public var changed: [String] = []

    public init(names: [String]) {
        total = names.count
        now = names.first ?? ""
    }

    public var running: Bool { done < total }

    /// 正在跑时的那一行。
    public var progress: String { "正在更新 \(now)…（\(done + 1)/\(total)）" }

    /// 跑完后的那一行（官方 `updatedSay`）。
    public var summary: String {
        let ok = total - failed.count
        let list = changed.joined(separator: ", ")
        if failed.isEmpty { return "已更新 \(ok) 个 Agent：\(list)" }
        let names = failed.map(\.name).joined(separator: ", ")
        return ok > 0 ? "\(total) 个 Agent 中已更新 \(ok) 个：\(list) · \(failed.count) 个未成功：\(names)"
            : "\(total) 个 Agent 中已更新 \(ok) 个 · \(failed.count) 个未成功：\(names)"
    }
}

// MARK: Agent 的状态（GET /api/state 里的 agents[]）

/// 接入后配置又被改了（magpie `agent.Drift`）。
public struct AgentDrift: Hashable, Sendable {
    /// unwired / replaced / bypassed / unreachable / proxied。
    public var kind: String
    public var field: String
    public var want: String
    public var now: String
    /// 主机给的英文说明（原样显示在详情里）。
    public var detail: String
    /// 改用的地址（unreachable / proxied 时可能有）。
    public var move: String

    public init(json: WebJSON) {
        kind = json["kind"]?.string ?? "unwired"
        field = json["field"]?.string ?? ""
        want = json["want"]?.string ?? ""
        now = json["now"]?.string ?? ""
        detail = json["detail"]?.string ?? ""
        move = json["move"]?.string ?? ""
    }

    /// 连不上 magpie 的那两种：「重新应用」没用，要先修地址或代理（官方 `deaf`）。
    public var deaf: Bool { kind == "unreachable" || kind == "proxied" }

    /// 一句话说明（官方 `DRIFT_WHY`）。
    public func reason(agent: String, model: String) -> String {
        switch kind {
        case "replaced": "\(agent) 已在 magpie 之外换掉 \(model)"
        case "bypassed": "\(agent) 最近绕过了 magpie，重新应用后请重启"
        case "unreachable": "\(agent) 已设好，但它连 magpie 用的地址没有回应"
        case "proxied": "\(agent) 经代理连 magpie，但这个代理没把它的请求转给 magpie"
        default: "\(agent) 已不经过 magpie：配置已变更"
        }
    }

    /// 修复按钮的字：能改用别的地址时是「改用 …」，否则「重新应用」；连不上又没别的地址时只能「如何修复」。
    public var fixTitle: String {
        if deaf && !move.isEmpty {
            let shown = move.replacingOccurrences(of: "^https?://", with: "", options: .regularExpression)
            return "改用 \(shown)"
        }
        return deaf ? "如何修复" : "重新应用"
    }

    /// 修复按钮会不会真的去「重新应用」（`deaf` 且没有新地址时只解释）。
    public var canReapply: Bool { !deaf || !move.isEmpty }
}

extension WebAgent {
    public var drift: AgentDrift? { raw["drift"]?.object != nil ? raw["drift"].map(AgentDrift.init(json:)) : nil }
    /// magpie 内建运行时管理的 Agent（例如 Aside）：断开前必须先读到预览。
    public var isNative: Bool { raw["native"]?.object != nil }
    /// 模型列表里显示 / 一共的 magpie 模型数（官方 `a.models`）。
    public var modelsShown: Int? { raw["models"]?["shown"]?.int }
    public var modelsListed: Int? { raw["models"]?["listed"]?.int }
    /// 自己的模型菜单就是这里挑的列表（Claude Desktop 等，主机给 `menu`）。
    public var listsMenu: Bool { raw["menu"]?.bool ?? false || ["claude-desktop", "cursor-local"].contains(id) }

    /// 有没有字段当前选的是 magpie 的模型（官方 Apply again 菜单项的条件之一）。
    public var usesMagpieModel: Bool {
        (raw["fields"]?.array ?? []).contains { field in
            let value = field["value"]?.string ?? ""
            return !value.isEmpty && (field["options"]?.array ?? []).contains { $0["value"]?.string == value && !($0["ref"]?.string ?? "").isEmpty }
        }
    }

    /// 能「重新应用」（官方：CLI 在，并且接入后被改过或者选的是 magpie 的模型）。
    public var canReapply: Bool { !cliMissing && (drifted || usesMagpieModel) }

    /// 在 Agent 里用什么命令选 magpie 的模型（官方 `PICKS_IN`）。
    public var picksIn: String? {
        let kind = id.components(separatedBy: "@wsl:").first ?? id
        let table = ["codex": "/model", "claude": "/model", "opencode": "/models", "pi": "/model", "droid": "/model", "kimi": "/model",
                     "grok": "/model", "minimax-code": "/model", "dsh": "/model", "crush": "ctrl+p", "omp": "/model", "qwen": "/model",
                     "mimocode": "/model", "deveco": "/models"]
        return table[kind]
    }

    /// 「接入」开关旁的一句话（官方 `connectSaid`）。
    public var connectSaid: String {
        if !wired { return "未接入 · 用 \(name) 自己的设置" }
        if listsMenu, let shown = modelsShown { return "已接入 · \(name) 的模型菜单里有 \(shown) 个模型" }
        if let command = picksIn { return "已接入 · 在 \(name) 里用 \(command) 选 magpie 的模型" }
        return "已接入 · magpie 的模型在 \(name) 的模型列表里"
    }

    /// 打开「接入」开关之后的提示（官方 `connectedSaid`，`how` 来自回答里的 `connected.how`）。
    public func connectedSaid(how: String?) -> String {
        let plain = "\(name) 已接入 magpie"
        guard let how else { return plain }
        if how == "joined" {
            return isNative ? plain : "\(name) 已接入 magpie · 仍用它上次选的模型，magpie 的模型已加入 \(picksIn ?? "/model")"
        }
        let field = modelField
        let model = field.flatMap { field in field.value.isEmpty ? nil : field.options.first { $0.value == field.value }?.title ?? field.value } ?? ""
        guard !model.isEmpty else { return plain }
        switch how {
        case "again": return "\(name) 已接入 magpie · 回到上次断开前用的 \(model)"
        case "same", "alike": return "\(name) 已接入 magpie · 经 magpie 继续用它原来的模型 \(model)"
        case "default": return "\(name) 已接入 magpie · 原先未设模型，改用它自己列表中的第一个：\(model)"
        case "first": return "\(name) 已接入 magpie · magpie 没有它原来的模型，改用 \(model)"
        default: return plain
        }
    }

    /// 页面上要列出的字段：有选项的、或者已经设了值的（官方不画既没选项也没值的强度、子代理、登录等）。
    public var shownFields: [WebAgentField] {
        fields.filter { !$0.options.isEmpty || !$0.value.isEmpty }
    }
}

/// 字段名与取值的中文（官方 i18n.js 简体中文；没有翻译的原样显示）。
public enum AgentFieldText {
    static let labels: [String: String] = [
        "model": "模型", "effort": "推理强度", "thinking": "思考", "subagents": "子代理", "subagent model": "子代理模型",
        "subagent effort": "子代理推理强度", "memories": "记忆整理模型", "sign-in": "登录方式", "auto mode": "自动模式",
        "large": "大模型", "small": "小模型", "planner": "规划模型", "executor": "执行模型", "account": "账号", "auth": "认证",
        "opus effort": "opus 推理强度", "sonnet effort": "sonnet 推理强度", "haiku effort": "haiku 推理强度", "fable effort": "fable 推理强度",
        "provider": "供应商",
    ]
    static let values: [String: String] = [
        "off": "关闭", "none": "不思考", "minimal": "最低", "low": "低", "medium": "中", "high": "高", "xhigh": "很高", "max": "最高",
        "on": "开启", "auto": "自动", "Auto": "自动", "Always ChatGPT": "始终 ChatGPT", "Adaptive": "自适应",
    ]

    public static func label(_ label: String) -> String { labels[label] ?? label }

    /// 选项显示的名字：有 label 用 label（能翻译就翻译），否则翻译值（推理强度的 low / high…）。
    public static func option(_ option: WebAgentOption) -> String {
        let text = option.label.isEmpty ? option.value : option.label
        return values[text] ?? text
    }

    /// 字段当前值的显示：空 = 默认。
    public static func value(of field: WebAgentField) -> String {
        if field.value.isEmpty { return "默认" }
        if let match = field.options.first(where: { $0.value == field.value }) { return Self.option(match) }
        return values[field.value] ?? field.value
    }
}

// MARK: 方案（GET /api/state 的 profiles[]，POST /api/profile/{action}）

/// 一个保存下来的方案（magpie `profileJSON`）。
public struct WebProfile: Hashable, Identifiable, Sendable {
    public struct Field: Hashable, Sendable {
        public var key: String
        public var label: String
        public var value: String
        /// 看起来像密钥，没有给出。
        public var hidden: Bool
        /// 跟随的主字段（Claude Code 的档位跟主模型）。
        public var follows: String
    }

    public struct Agent: Hashable, Identifiable, Sendable {
        public var id: String
        public var name: String
        public var icon: String
        public var fields: [Field]
    }

    public var name: String
    public var summary: String
    public var inUse: Bool
    public var agents: [Agent]
    public var id: String { name }

    public init(json: WebJSON) {
        name = json["name"]?.string ?? ""
        summary = json["summary"]?.string ?? ""
        inUse = json["inUse"]?.bool ?? false
        agents = (json["agents"]?.array ?? []).map { agent in
            Agent(id: agent["id"]?.string ?? "", name: agent["name"]?.string ?? "", icon: agent["icon"]?.string ?? "",
                  fields: (agent["fields"]?.array ?? []).map { field in
                      Field(key: field["key"]?.string ?? "", label: field["label"]?.string ?? "", value: field["value"]?.string ?? "",
                            hidden: field["hidden"]?.bool ?? false, follows: field["follows"]?.string ?? "")
                  })
        }
    }

    /// 详情里一个字段的显示（官方 `profileDetail`）。
    public static func display(_ field: Field, in agent: Agent) -> String {
        if field.hidden { return "••••••" }
        if !field.follows.isEmpty {
            let main = agent.fields.first { $0.key == field.follows && !$0.hidden }?.value ?? ""
            return main.isEmpty ? "跟随主模型" : "跟随主模型（\(main)）"
        }
        if field.value.isEmpty { return "Agent 默认值" }
        return AgentFieldText.values[field.value] ?? field.value
    }

    /// 应用后的提示（官方 profileAction use）。
    public static func appliedSaid(name: String, changed: Int) -> String { "已应用 \(name) · 更改了 \(changed) 项设置" }
}

public enum ProfileAction: String, Sendable, CaseIterable {
    case save, use, delete
}

/// `POST /api/agents/{action}/{id}`。
public enum AgentAction: String, Sendable, CaseIterable {
    /// 把 magpie 设的值重新写回 Agent 的配置。
    case reapply
    /// 「保留当前设置」：接受在 magpie 之外换掉的模型。
    case keep
    /// 打开「接入 magpie」。
    case connect
    /// 断开并还原接入前的设置。
    case disconnect
}

// MARK: 断开预览（GET /api/agents/preview/{id}）

public struct AgentDisconnectPreview: Hashable, Sendable {
    public struct Change: Hashable, Sendable {
        public var path: String
        /// 断开后这个文件会被删掉（接入时新建的）。
        public var removed: Bool
        public var created: Bool
        /// 改回的行数。
        public var lines: Int
    }

    public var changes: [Change]
    /// 内建运行时的 Agent 必须有它才能断开。
    public var revision: String
    public var error: String?

    public init(json: WebJSON) {
        changes = (json["changes"]?.array ?? []).map { change in
            Change(path: change["path"]?.string ?? "", removed: change["removed"]?.bool ?? false,
                   created: change["created"]?.bool ?? false, lines: change["lines"]?.array?.count ?? 0)
        }
        revision = json["revision"]?.string ?? ""
        error = json["error"]?.string.flatMap { $0.isEmpty ? nil : $0 }
    }
}

// MARK: 接口

extension WebClient {
    /// 一个 Agent 命令行程序的更新最多跑 10 分钟（magpie `updateTimeout`），请求要等得比它久。
    public static let cliUpdateTimeout: TimeInterval = 11 * 60

    public func agentCLIs() async throws -> AgentCLIs { AgentCLIs(json: try await get("/api/agents/cli")) }

    /// 按原来的安装方式更新一个 Agent 的命令行程序，返回更新后的版本信息；失败时主机给 400 + 原因。
    public func updateAgentCLI(_ id: String) async throws -> AgentCLI {
        var request = try makeRequest("/api/agents/cli/\(id)", method: "POST", body: [:])
        request.timeoutInterval = Self.cliUpdateTimeout
        return AgentCLI(json: try await send(request))
    }

    /// 重新查找这台电脑上的 Agent（网页右上角的刷新按钮）。
    public func rescanAgents() async throws -> WebState { WebState(json: try await post("/api/agents/rescan", [:])) }

    public func agentAction(_ action: AgentAction, _ id: String) async throws -> WebState {
        WebState(json: try await post("/api/agents/\(action.rawValue)/\(id)", [:]))
    }

    public func agentDisconnectPreview(_ id: String) async throws -> AgentDisconnectPreview {
        AgentDisconnectPreview(json: try await get("/api/agents/preview/\(id)"))
    }

    /// 方案：保存当前（同名即覆盖）/ 应用 / 删除。回答是整份状态加 `changed`（应用时改了几项）。
    public func profile(_ action: ProfileAction, name: String) async throws -> WebState {
        WebState(json: try await post("/api/profile/\(action.rawValue)", ["name": .string(name)]))
    }
}

// MARK: 供应商「测试」（POST /api/provider/test）

/// 向供应商的一个端点发的最小请求的结果（magpie `provider.Result`）。
public struct ProviderTestResult: Hashable, Sendable {
    /// 多账号供应商：测的是哪个账号。
    public var account: String
    /// chat / responses / anthropic / gemini / decide。
    public var api: String
    public var ok: Bool
    public var status: Int
    public var millis: Int
    public var model: String
    public var error: String

    public init(json: WebJSON) {
        account = json["account"]?.string ?? ""
        api = json["protocol"]?.string ?? ""
        ok = json["ok"]?.bool ?? false
        status = json["status"]?.int ?? 0
        millis = json["ms"]?.int ?? 0
        model = json["model"]?.string ?? ""
        error = json["error"]?.string ?? ""
    }

    /// 端点在网页上的名字（官方 PROTOS）。
    public var apiName: String {
        switch api {
        case "chat": "OpenAI"
        case "responses": "Responses"
        case "anthropic": "Anthropic"
        case "gemini": "Gemini"
        case "decide": "System One"
        default: api
        }
    }

    /// 结果一句话（官方：成功显示用时，失败显示「状态码 · 原因」；多账号前面加「已测试 某账号：」）。
    public var summary: String {
        let took = millis < 1000 ? "\(millis) ms" : String(format: millis < 10_000 ? "%.1f s" : "%.0f s", Double(millis) / 1000)
        let result = ok ? took : status > 0 ? "\(status) · \(error)" : error
        return account.isEmpty ? result : "已测试 \(account)：\(result)"
    }
}

extension WebClient {
    /// 「测试」：向供应商已保存的每个端点各发一个最小请求（主机最多等 25 秒）。
    public func testProvider(_ id: String) async throws -> [ProviderTestResult] {
        var request = try makeRequest("/api/provider/test", method: "POST", body: ["id": .string(id)])
        request.timeoutInterval = 40
        return (try await send(request)["results"]?.array ?? []).map(ProviderTestResult.init(json:))
    }
}
