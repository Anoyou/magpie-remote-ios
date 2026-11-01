import Foundation
import MagpieRemoteCore

/// 「管理」页访问主机 Web 管理接口（3430）与网关临时密钥接口的方式。真实实现走 `WebClient`，fixture 实现只改内存。
protocol ManageServing: Sendable {
    func settings() async throws -> WebSettings
    func providers() async throws -> WebProviders
    func provider(_ action: ProviderAction, _ body: WebJSON) async throws -> WebProviders
    func arrangeProviders(_ order: [String]) async throws -> WebProviders
    /// 供应商的多把 Key：增删改（`POST /api/keys/{action}`）。
    func providerKeys(_ action: ProviderKeyAction, _ body: WebJSON) async throws -> WebProviders
    /// 按需取一把 Key 的明文（`POST /api/provider/key`）。只用于显示 / 复制，不缓存、不记录。
    func providerKeySecret(_ provider: String, account: String?) async throws -> String
    func groups() async throws -> WebGroups
    func group(_ action: GroupAction, _ body: WebJSON) async throws -> WebGroups
    /// 路由页：各模型近 7 天的速度、网关的实时路由记录。
    func modelSpeeds() async throws -> ModelSpeeds
    func trace(after seq: Int64, wait: Bool) async throws -> TraceSnapshot
    func state() async throws -> WebState
    func setAgent(_ agent: String, field: String, value: String) async throws -> WebState
    /// Agent 页（对齐官方网页）：命令行程序的版本与更新、重新查找、接入 / 断开 / 重新应用、断开预览、方案。
    func agentCLIs() async throws -> AgentCLIs
    func updateAgentCLI(_ id: String) async throws -> AgentCLI
    func rescanAgents() async throws -> WebState
    func agentAction(_ action: AgentAction, _ id: String) async throws -> WebState
    func agentDisconnectPreview(_ id: String) async throws -> AgentDisconnectPreview
    func profile(_ action: ProfileAction, name: String) async throws -> WebState
    /// 供应商「测试」：每个端点一个最小请求。
    func testProvider(_ id: String) async throws -> [ProviderTestResult]
    /// 对齐官方第二轮：Agent 排序 / 隐藏、每个 Agent 的模型列表、停用的模型、逐个模型测试、密钥可限定的模型与账号。
    func arrangeAgents(order: [String], hidden: [String], shown: [String]) async throws -> WebSettings
    func agentModels(_ id: String) async throws -> AgentModelList
    func setAgentModels(_ id: String, _ body: WebJSON) async throws -> WebJSON
    func setDisabledModels(_ models: [String]) async throws -> WebSettings
    func testProviderModels(_ id: String, models: [String], run: String) async throws -> [ProviderTestResult]
    func stopProviderTest(run: String) async throws
    func callerKeyModels() async throws -> CallerKeyModels
    func callerKeys() async throws -> WebCallerKeys
    func callerKey(_ action: CallerKeyAction, _ body: WebJSON) async throws -> WebCallerKeys
    /// 填了签发密钥才能签发临时密钥。
    var canIssue: Bool { get }
    func issuedKeys() async throws -> [IssuedKey]
    func issueKey(name: String, ttl: String) async throws -> IssuedKey
    func revokeIssuedKey(_ id: String) async throws
    /// 网页兜底：地址（带一次 ?k=）与要注入 WKWebView 的 Cookie；fixture 下为 nil。
    func page(_ page: MagpieWebPage) -> (url: URL, cookieName: String, key: String)?
}

struct LiveManageService: ManageServing {
    let web: WebClient
    let gateway: GatewayClient?

    init(host: HostProfile, webKey: String, issuerKey: String?) {
        web = WebClient(baseURL: host.webURL, key: webKey)
        gateway = issuerKey.flatMap { $0.isEmpty ? nil : GatewayClient(baseURL: host.gatewayURL, key: $0, timeout: 20) }
    }

    func settings() async throws -> WebSettings { try await web.settings() }
    func providers() async throws -> WebProviders { try await web.providers() }
    func provider(_ action: ProviderAction, _ body: WebJSON) async throws -> WebProviders { try await web.provider(action, body) }
    func arrangeProviders(_ order: [String]) async throws -> WebProviders { try await web.arrangeProviders(order) }
    func providerKeys(_ action: ProviderKeyAction, _ body: WebJSON) async throws -> WebProviders { try await web.providerKeys(action, body) }
    func providerKeySecret(_ provider: String, account: String?) async throws -> String { try await web.providerKey(provider, account: account) }
    func groups() async throws -> WebGroups { try await web.groups() }
    func group(_ action: GroupAction, _ body: WebJSON) async throws -> WebGroups { try await web.group(action, body) }
    func modelSpeeds() async throws -> ModelSpeeds { try await web.modelSpeeds() }
    func trace(after seq: Int64, wait: Bool) async throws -> TraceSnapshot { try await web.trace(after: seq, wait: wait) }
    func state() async throws -> WebState { try await web.state() }
    func setAgent(_ agent: String, field: String, value: String) async throws -> WebState {
        try await web.setAgent(agent, field: field, value: value)
    }
    func agentCLIs() async throws -> AgentCLIs { try await web.agentCLIs() }
    func updateAgentCLI(_ id: String) async throws -> AgentCLI { try await web.updateAgentCLI(id) }
    func rescanAgents() async throws -> WebState { try await web.rescanAgents() }
    func agentAction(_ action: AgentAction, _ id: String) async throws -> WebState { try await web.agentAction(action, id) }
    func agentDisconnectPreview(_ id: String) async throws -> AgentDisconnectPreview { try await web.agentDisconnectPreview(id) }
    func profile(_ action: ProfileAction, name: String) async throws -> WebState { try await web.profile(action, name: name) }
    func testProvider(_ id: String) async throws -> [ProviderTestResult] { try await web.testProvider(id) }
    func arrangeAgents(order: [String], hidden: [String], shown: [String]) async throws -> WebSettings {
        try await web.arrangeAgents(order: order, hidden: hidden, shown: shown)
    }
    func agentModels(_ id: String) async throws -> AgentModelList { try await web.agentModels(id) }
    func setAgentModels(_ id: String, _ body: WebJSON) async throws -> WebJSON { try await web.setAgentModels(id, body) }
    func setDisabledModels(_ models: [String]) async throws -> WebSettings { try await web.setDisabledModels(models) }
    func testProviderModels(_ id: String, models: [String], run: String) async throws -> [ProviderTestResult] {
        try await web.testProviderModels(id, models: models, run: run)
    }
    func stopProviderTest(run: String) async throws { try await web.stopProviderTest(run: run) }
    func callerKeyModels() async throws -> CallerKeyModels { try await web.callerKeyModels() }
    func callerKeys() async throws -> WebCallerKeys { try await web.callerKeys() }
    func callerKey(_ action: CallerKeyAction, _ body: WebJSON) async throws -> WebCallerKeys { try await web.callerKey(action, body) }

    var canIssue: Bool { gateway != nil }
    func issuedKeys() async throws -> [IssuedKey] {
        guard let gateway else { return [] }
        return try await gateway.issuedKeys()
    }
    func issueKey(name: String, ttl: String) async throws -> IssuedKey {
        guard let gateway else { throw MagpieError.missingKey(.issuerKey) }
        return try await gateway.issueKey(name: name, ttl: ttl)
    }
    func revokeIssuedKey(_ id: String) async throws {
        guard let gateway else { throw MagpieError.missingKey(.issuerKey) }
        try await gateway.revokeIssuedKey(id)
    }

    func page(_ page: MagpieWebPage) -> (url: URL, cookieName: String, key: String)? {
        web.pageURL(page, withKey: true).map { ($0, web.cookieName, web.key) }
    }
}

/// fixture 模式：示例供应商、路由组、Agent、网关密钥，全部只在内存里改，不访问网络。
actor FixtureManageService: ManageServing {
    static let shared = FixtureManageService()

    private var providerList: [WebJSON]
    private var groupList: [WebJSON]
    private var agentList: [WebJSON]
    private var keyList: [WebJSON]
    private var issued: [WebJSON] = []
    /// Agent 命令行程序的示例版本（Codex、Claude Code 有新版本，可以试「全部更新」）。
    private var clis: [String: WebJSON] = [
        "codex": ["version": "0.163.0", "latest": "0.164.2", "via": "npm", "command": "npm install -g @openai/codex", "update": true],
        "claude": ["version": "2.1.40", "latest": "2.1.42", "via": "self", "command": "claude update", "update": true],
        "gemini": ["version": "0.21.0", "latest": "0.21.0", "via": "brew", "command": "brew upgrade gemini-cli"],
    ]
    /// 示例方案。
    private var profileList: [WebJSON] = [
        ["name": "工作", "summary": "Codex：GPT 4.1", "inUse": true,
         "agents": [["id": "codex", "name": "Codex", "icon": "codex-color",
                     "fields": [["key": "model", "label": "model", "value": "relay-example/gpt-4.1"], ["key": "effort", "label": "effort", "value": "high"]]]]],
    ]
    private var fixturePools: [WebJSON] = RoutesFixture.pools
    /// Agent 页的顺序与隐藏、停用的模型（magpie 自己的设置）。
    private var agentOrder: [String] = []
    private var agentsHidden: [String] = ["gemini"]
    private var disabledModels: [String] = ["*preview*"]
    /// 每个 Agent 的模型列表：隐藏了哪些、只显示勾选的、拖过的顺序。
    private var agentHiddenModels: [String: [String]] = ["codex": ["relay-example/o3"]]
    private var agentOnlyPicked: [String: [String]] = [:]
    private var agentModelOrder: [String: [String]] = [:]
    /// 每把网关密钥的限额，以及每条已用的（Token、费用）。
    private var keyLimits: [String: [WebJSON]] = ["key-iphone": [["period": "month", "cost": 20]]]
    private var keyUsed: [String: [(tokens: Int, cost: Double)]] = ["key-iphone": [(184_000, 3.5)]]
    private var foundGroups = true
    /// fixture 里各 Key 的「明文」（全是假值），按 Key 的 id。
    private var keySecrets: [String: String] = ["fx-key-1": "sk-relay-EXAMPLE-MAIN1", "fx-key-2": "sk-relay-EXAMPLE-BACK2",
                                                "fx-key-3": "sk-deepseek-EXAMPLE-EXMP"]
    private let traceStart = Date()
    /// 逐帧截图时上次答到第几步。
    private var servedStep = -1
    private var counter = 0

    init() {
        func model(_ id: String, _ name: String, _ on: Bool) -> WebJSON { ["id": .string(id), "name": .string(name), "on": .bool(on)] }
        let provider1: WebJSON =
            ["id": "relay-example", "name": "示例中转", "preset": "", "host": "relay.example", "chat": "https://relay.example/v1",
             "ready": true, "off": false, "chosen": ["gpt-4.1", "o3"], "fallback": [], "headers": ["X-Org": "org-EXAMPLE"],
             "key": ["set": true, "masked": "sk-r…AIN1", "optional": false], "account": nil,
             "responses": "https://relay.example/v1",
             "keyList": [["id": "fx-key-1", "name": "主力", "masked": "sk-r…AIN1", "active": true, "on": true],
                         ["id": "fx-key-2", "name": "备用", "masked": "sk-r…ACK2", "active": false, "on": true]],
             "models": [model("gpt-4.1", "GPT 4.1", true), model("gpt-4.1-mini", "GPT 4.1 mini", false), model("o3", "OpenAI o3", true)]]
        let provider2: WebJSON =
            ["id": "deepseek", "name": "示例 DeepSeek", "preset": "deepseek", "host": "api.deepseek.example", "chat": "https://api.deepseek.example/v1",
             "ready": true, "off": false, "chosen": [], "fallback": [], "key": ["set": true, "masked": "sk-d…EXMP", "optional": false],
             "keyList": [["id": "fx-key-3", "masked": "sk-d…EXMP", "active": true, "on": true]],
             "models": [model("deepseek-chat", "DeepSeek Chat", true), model("deepseek-reasoner", "DeepSeek Reasoner", true)]]
        let provider3: WebJSON =
            ["id": "codex", "name": "示例 Codex 订阅", "preset": "codex", "host": "", "chat": "", "ready": true, "off": true,
             "chosen": [], "fallback": [], "key": ["set": false, "masked": "", "optional": true],
             "account": ["agent": "codex", "user": "someone@example.com"],
             "models": [model("gpt-5", "GPT-5", true)]]
        providerList = [provider1, provider2, provider3]
        groupList = RoutesFixture.groups
        func option(_ value: String, _ label: String, _ group: String) -> WebJSON {
            ["value": .string(value), "label": .string(label), "note": .string(group + " · via magpie"), "group": .string(group), "ref": .string(value)]
        }
        let options: WebJSON = [option("group/smart", "聪明组", "路由组"), option("relay-example/gpt-4.1", "GPT 4.1", "示例中转"),
                                option("relay-example/o3", "OpenAI o3", "示例中转"), option("deepseek/deepseek-chat", "DeepSeek Chat", "示例 DeepSeek")]
        agentList = [
            ["id": "codex", "name": "Codex", "path": "~/.codex/config.toml", "wired": true,
             "fields": [["key": "model", "label": "model", "value": "relay-example/gpt-4.1", "options": options],
                        ["key": "effort", "label": "effort", "value": "high",
                         "options": [["value": "low"], ["value": "medium"], ["value": "high"], ["value": "xhigh"]]]]],
            ["id": "claude", "name": "Claude Code", "path": "~/.claude/settings.json", "wired": nil,
             "fields": [["key": "model", "label": "model", "value": "", "options": options]]],
            // 在网页版里手动隐藏的（见 settings 的 agentsHidden）：和未设置的 Claude Code 一起默认折叠。
            ["id": "gemini", "name": "Gemini CLI", "path": "~/.gemini/settings.json", "wired": nil,
             "fields": [["key": "model", "label": "model", "value": "", "options": options]]],
        ]
        keyList = [
            ["id": "key-iphone", "name": "iPhone", "masked": "sk-magpie-key-…EXMP01"],
            ["id": "key-old", "name": "旧电脑", "masked": "sk-magpie-key-…EXMP02", "off": true],
            ["id": "key-lan", "name": "Magpie", "masked": "sk-magpie-key-…EXMP03", "lan": true],
        ]
    }

    private func pause() async throws { try await Task.sleep(for: .milliseconds(80)) }
    private var providersJSON: WebProviders { WebProviders(json: ["providers": .array(providerList), "presets": [["id": "deepseek", "name": "DeepSeek"]]]) }
    private var groupsJSON: WebGroups {
        RoutesFixture.groupsJSON(groups: groupList, providers: providerList, pools: fixturePools, found: foundGroups)
    }
    private func keys(secret: String? = nil) -> WebCallerKeys {
        let rows = keyList.map { key -> WebJSON in
            var key = key
            let id = key["id"]?.string ?? ""
            let limits = keyLimits[id] ?? []
            key["limit"] = limits.first
            key["moreLimits"] = limits.count > 1 ? .array(Array(limits.dropFirst())) : nil
            let used = limits.enumerated().map { i, limit in Self.usage(limit, used: keyUsed[id].flatMap { i < $0.count ? $0[i] : nil } ?? (0, 0)) }
            key["usedAll"] = used.isEmpty ? nil : .array(used)
            key["used"] = used.first
            return key
        }
        var names: [String: WebJSON] = [:]
        for provider in providerList {
            for k in provider["keyList"]?.array ?? [] {
                names[(provider["id"]?.string ?? "") + "/" + (k["id"]?.string ?? "")] = .string((provider["id"]?.string ?? "") + "/" + (k["masked"]?.string ?? ""))
            }
        }
        return WebCallerKeys(json: ["keys": .array(rows), "accountNames": .object(names), "secret": .string(secret ?? "")])
    }

    /// 一条限额现在的用量（magpie budget.Status 的形状）：周期从现在算起。
    private static func usage(_ limit: WebJSON, used: (tokens: Int, cost: Double)) -> WebJSON {
        let period = limit["period"]?.string ?? "day"
        let calendar = Calendar.current
        let now = Date()
        let start: Date
        let reset: Date
        switch period {
        case "week":
            start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? now
            reset = calendar.date(byAdding: .day, value: 7, to: start) ?? now
        case "month":
            start = calendar.dateInterval(of: .month, for: now)?.start ?? now
            reset = calendar.date(byAdding: .month, value: 1, to: start) ?? now
        case "days":
            start = now.addingTimeInterval(-3600)
            reset = start.addingTimeInterval(Double(limit["days"]?.int ?? 1) * 86_400)
        case "hours":
            start = now.addingTimeInterval(-600)
            reset = start.addingTimeInterval(Double(limit["hours"]?.int ?? 1) * 3600)
        default:
            start = calendar.startOfDay(for: now)
            reset = calendar.date(byAdding: .day, value: 1, to: start) ?? now
        }
        let iso = ISO8601DateFormatter()
        let tokenLimit = limit["tokens"]?.int ?? 0, costLimit = limit["cost"]?.double ?? 0
        let spent = (tokenLimit > 0 && used.tokens >= tokenLimit) || (costLimit > 0 && used.cost >= costLimit)
        var out: [String: WebJSON] = ["period": .string(period), "start": .string(iso.string(from: start)), "reset": .string(iso.string(from: reset)),
                                      "calls": 12, "tokens": .int(Int64(used.tokens)), "cost": .double(used.cost),
                                      "tokensLeft": .int(Int64(max(0, tokenLimit - used.tokens))), "costLeft": .double(max(0, costLimit - used.cost)),
                                      "spent": .bool(spent)]
        if tokenLimit > 0 { out["tokenLimit"] = .int(Int64(tokenLimit)) }
        if costLimit > 0 { out["costLimit"] = .double(costLimit) }
        if let days = limit["days"] { out["days"] = days }
        if let hours = limit["hours"] { out["hours"] = hours }
        return .object(out)
    }
    private func newSecret() -> String {
        counter += 1
        return "sk-magpie-key-EXAMPLE-NEW\(counter)"
    }

    func settings() async throws -> WebSettings { settingsJSON }

    private var settingsJSON: WebSettings {
        let hits: [String: WebJSON] = Dictionary(uniqueKeysWithValues: disabledModels.map { pattern in
            (pattern, WebJSON.strings(allModelIDs.filter { Self.matches(pattern, $0) }))
        })
        var models: [WebJSON] = groupList.map { ["id": .string("group/" + ($0["id"]?.string ?? "")), "name": $0["name"] ?? "", "provider": "", "providerName": $0["name"] ?? ""] }
        for provider in providerList {
            for model in provider["models"]?.array ?? [] {
                models.append(["id": .string((provider["id"]?.string ?? "") + "/" + (model["id"]?.string ?? "")), "name": model["name"] ?? "",
                               "provider": provider["id"] ?? "", "providerName": provider["name"] ?? ""])
            }
        }
        return WebSettings(json: ["version": "v0.1.2438", "lan": true, "agentOrder": .strings(agentOrder), "agentsHidden": .strings(agentsHidden),
                                  "agentsShown": [], "disabledModels": .strings(disabledModels), "disabledHits": .object(hits), "titleModels": .array(models)])
    }

    /// 所有供应商的模型（provider/model）。
    private var allModelIDs: [String] {
        providerList.flatMap { p in (p["models"]?.array ?? []).map { (p["id"]?.string ?? "") + "/" + ($0["id"]?.string ?? "") } }
    }

    /// 停用规则：不分大小写，* 通配（magpie provider/disabled.go 的写法之一）。
    private static func matches(_ pattern: String, _ id: String) -> Bool {
        let p = pattern.lowercased(), v = id.lowercased()
        guard p.contains("*") else { return p == v || v.hasSuffix("/" + p) }
        let parts = p.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        var rest = Substring(v)
        for (i, part) in parts.enumerated() where !part.isEmpty {
            guard let range = rest.range(of: part) else { return false }
            if i == 0 && range.lowerBound != rest.startIndex { return false }
            rest = rest[range.upperBound...]
        }
        return parts.last?.isEmpty != false || v.hasSuffix(parts.last ?? "")
    }

    func arrangeAgents(order: [String], hidden: [String], shown: [String]) async throws -> WebSettings {
        try await pause()
        agentOrder = order
        agentsHidden = hidden
        return settingsJSON
    }

    func setDisabledModels(_ models: [String]) async throws -> WebSettings {
        try await pause()
        disabledModels = models
        return settingsJSON
    }

    // MARK: 每个 Agent 的模型列表（fixture）

    /// 一个 Agent 列表里能放的：路由组，然后各供应商开着的模型。
    private func agentModelRows(_ id: String) -> [WebJSON] {
        let values = Set((agentList.first { $0["id"]?.string == id }?["fields"]?.array ?? []).compactMap { $0["value"]?.string })
        let hidden = Set(agentHiddenModels[id] ?? [])
        let only = agentOnlyPicked[id]
        var rows: [WebJSON] = groupList.filter { $0["auto"]?.bool != true }.map { group in
            let ref = "group/" + (group["id"]?.string ?? "")
            return ["id": .string(ref), "name": group["name"] ?? "", "group": .string(AgentModelList.routingGroups), "icons": ["openai", "deepseek-color"]]
        }
        for provider in providerList where provider["off"]?.bool != true {
            for model in provider["models"]?.array ?? [] where model["on"]?.bool == true {
                let ref = (provider["id"]?.string ?? "") + "/" + (model["id"]?.string ?? "")
                rows.append(["id": .string(ref), "name": model["name"] ?? "", "group": provider["name"] ?? "", "icon": "openai",
                             "context": ref.contains("deepseek") ? 128_000 : 1_047_576])
            }
        }
        rows = rows.filter { row in !disabledModels.contains { Self.matches($0, row["id"]?.string ?? "") } }
        for i in rows.indices {
            let ref = rows[i]["id"]?.string ?? ""
            let inUse = values.contains(ref)
            if inUse { rows[i]["inUse"] = true }
            let off = only.map { !$0.contains(ref) } ?? hidden.contains(ref)
            if off && !inUse { rows[i]["hidden"] = true }
        }
        if let order = agentModelOrder[id], !order.isEmpty {
            rows.sort { (order.firstIndex(of: $0["id"]?.string ?? "") ?? .max) < (order.firstIndex(of: $1["id"]?.string ?? "") ?? .max) }
        }
        return rows
    }

    private func agentModelsJSON(_ id: String) -> WebJSON {
        ["models": .array(agentModelRows(id)), "ordered": .bool(!(agentModelOrder[id] ?? []).isEmpty),
         "only": .bool(agentOnlyPicked[id] != nil), "own": false, "ownHidden": false]
    }

    private func agentModelCount(_ id: String) -> WebJSON {
        let rows = agentModelRows(id)
        let shown = rows.filter { $0["hidden"]?.bool != true }
        return ["shown": .int(Int64(shown.count)), "listed": .int(Int64(rows.count)), "names": .array(shown.prefix(3).map { $0["name"] ?? "" })]
    }

    func agentModels(_ id: String) async throws -> AgentModelList {
        try await pause()
        guard agentList.contains(where: { $0["id"]?.string == id }) else { throw MagpieError.webRejected(message: "no agent \(id)", code: nil) }
        return AgentModelList(json: agentModelsJSON(id))
    }

    func setAgentModels(_ id: String, _ body: WebJSON) async throws -> WebJSON {
        try await pause()
        if let order = body["order"]?.array {
            agentModelOrder[id] = order.compactMap(\.string)
            return ["models": .array(agentModelRows(id)), "ordered": .bool(!order.isEmpty)]
        }
        if let only = body["only"]?.bool {
            let shown = agentModelRows(id).filter { $0["hidden"]?.bool != true }.compactMap { $0["id"]?.string }
            agentOnlyPicked[id] = only ? shown : nil
            if !only { agentHiddenModels[id] = agentModelRows(id).filter { !shown.contains($0["id"]?.string ?? "") }.compactMap { $0["id"]?.string } }
        } else if let shown = body["shown"]?.array {
            let picks = shown.compactMap(\.string)
            if agentOnlyPicked[id] != nil { agentOnlyPicked[id] = picks } else {
                agentHiddenModels[id] = agentModelRows(id).compactMap { $0["id"]?.string }.filter { !picks.contains($0) }
            }
        } else if let hidden = body["hidden"]?.array {
            agentHiddenModels[id] = hidden.compactMap(\.string)
        }
        return ["models": .array(agentModelRows(id)), "count": agentModelCount(id), "only": .bool(agentOnlyPicked[id] != nil)]
    }

    // MARK: 测试模型（fixture）

    func testProviderModels(_ id: String, models: [String], run: String) async throws -> [ProviderTestResult] {
        try await Task.sleep(for: .milliseconds(700))
        return models.map { model in
            let failing = model == "o3"
            let json: WebJSON = failing
                ? ["protocol": "chat", "ok": false, "status": 404, "ms": 210, "model": .string(model), "error": "model not found"]
                : ["protocol": "chat", "ok": true, "status": 200, "ms": .int(Int64(300 + model.count * 37)), "model": .string(model)]
            return ProviderTestResult(json: json)
        }
    }

    func stopProviderTest(run: String) async throws {}

    func callerKeyModels() async throws -> CallerKeyModels {
        try await pause()
        var models: [WebJSON] = groupList.filter { $0["auto"]?.bool != true }.map { ["id": .string("group/" + ($0["id"]?.string ?? "")), "name": $0["name"] ?? "", "group": true] }
        var accounts: [WebJSON] = []
        for provider in providerList where provider["off"]?.bool != true {
            for model in provider["models"]?.array ?? [] where model["on"]?.bool == true {
                models.append(["id": .string((provider["id"]?.string ?? "") + "/" + (model["id"]?.string ?? "")), "name": model["name"] ?? "",
                               "provider": provider["id"] ?? "", "providerName": provider["name"] ?? ""])
            }
            for key in provider["keyList"]?.array ?? [] {
                accounts.append(["id": .string((provider["id"]?.string ?? "") + "/" + (key["id"]?.string ?? "")),
                                 "name": key["name"] ?? key["masked"] ?? "", "provider": provider["id"] ?? "", "providerName": provider["name"] ?? "", "key": true])
            }
        }
        return CallerKeyModels(json: ["models": .array(models), "accounts": .array(accounts)])
    }
    func providers() async throws -> WebProviders { try await pause(); return providersJSON }

    func provider(_ action: ProviderAction, _ body: WebJSON) async throws -> WebProviders {
        try await pause()
        let id = body["id"]?.string ?? ""
        switch action {
        case .delete:
            providerList.removeAll { $0["id"]?.string == id }
        case .on, .off:
            update(id) { $0["off"] = .bool(action == .off) }
        case .save where body["new"]?.bool == true:
            let name = body["name"]?.string ?? body["preset"]?.string ?? "新供应商"
            let newID = name.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
            providerList.append(["id": .string(newID.isEmpty ? "provider-\(providerList.count)" : newID), "name": .string(name),
                                 "preset": body["preset"] ?? "", "chat": body["chat"] ?? "", "host": "relay.example",
                                 "ready": true, "off": false, "chosen": [], "fallback": [],
                                 "key": ["set": true, "masked": "sk-…EXMP", "optional": false],
                                 "models": [["id": "example-model", "name": "示例模型", "on": true]]])
        case .save:
            update(id) { provider in
                if let name = body["name"] { provider["name"] = name }
                if let chat = body["chat"] { provider["chat"] = chat }
                if let picks = body["models"]?.strings {
                    let all = body["noModels"]?.bool != true && picks.isEmpty
                    provider["chosen"] = .strings(picks)
                    provider["models"] = .array((provider["models"]?.array ?? []).map { model in
                        var model = model
                        model["on"] = .bool(all || picks.contains(model["id"]?.string ?? ""))
                        return model
                    })
                }
            }
        case .key, .models:
            break
        case .route, .affinity, .sink:
            if let index = fixturePools.firstIndex(where: { $0["provider"]?.string == id }) {
                for field in ["routing", "affinity", "sink"] { if let value = body[field] { fixturePools[index][field] = value } }
            }
        }
        return providersJSON
    }

    private func update(_ id: String, _ change: (inout WebJSON) -> Void) {
        guard let index = providerList.firstIndex(where: { $0["id"]?.string == id }) else { return }
        change(&providerList[index])
    }

    // MARK: 供应商的 Key（fixture）

    func providerKeySecret(_ provider: String, account: String?) async throws -> String {
        try await pause()
        let keys = providerList.first(where: { $0["id"]?.string == provider })?["keyList"]?.array ?? []
        let id = account ?? keys.first?["id"]?.string ?? ""
        guard let secret = keySecrets[id], keys.contains(where: { $0["id"]?.string == id }) else {
            throw MagpieError.webRejected(message: "no such key", code: nil)
        }
        return secret
    }

    func providerKeys(_ action: ProviderKeyAction, _ body: WebJSON) async throws -> WebProviders {
        try await pause()
        let id = body["id"]?.string ?? ""
        let ref = body["ref"]?.string ?? ""
        var keys = providerList.first(where: { $0["id"]?.string == id })?["keyList"]?.array ?? []
        let index = keys.firstIndex { $0["id"]?.string == ref }
        /// 主机的 promote：第一把让位给后面第一把在用的；没有就报错。
        func promote() throws -> WebJSON {
            guard let next = keys.indices.dropFirst().first(where: { keys[$0]["on"]?.bool == true }) else {
                throw MagpieError.webRejected(message: "that's the only key in use; turn another on first", code: nil)
            }
            let old = keys.removeFirst()
            let promoted = keys.remove(at: next - 1)
            keys.insert(promoted, at: 0)
            return old
        }
        func masked(_ key: String) -> String { key.count <= 8 ? String(repeating: "•", count: key.count) : "\(key.prefix(4))…\(key.suffix(4))" }
        func append(_ key: String, name: String) throws {
            if keys.contains(where: { keySecrets[$0["id"]?.string ?? ""] == key }) {
                throw MagpieError.webRejected(message: "already has this key", code: nil)
            }
            counter += 1
            let newID = "fx-key-new\(counter)"
            keySecrets[newID] = key
            var row: WebJSON = ["id": .string(newID), "masked": .string(masked(key)), "active": .bool(keys.isEmpty), "on": true]
            if !name.isEmpty { row["name"] = .string(name) }
            keys.append(row)
        }
        switch action {
        case .add:
            let key = body["key"]?.string ?? ""
            guard !key.isEmpty else { throw MagpieError.webRejected(message: "paste the key to add", code: nil) }
            try append(key, name: body["name"]?.string ?? "")
        case .import:
            for key in WebRequests.splitKeys(body["key"]?.string ?? "") { try? append(key, name: "") }
        case .use:
            if let index {
                let row = keys.remove(at: index)
                keys.insert(row, at: 0)
            }
        case .remove:
            if index == 0 { _ = try promote() } else if let index { keys.remove(at: index) }
        case .removeMany:
            let refs = Set(body["refs"]?.strings ?? [])
            keys.removeAll { refs.contains($0["id"]?.string ?? "") }
        case .rename:
            if let index {
                let name = body["name"]?.string ?? ""
                keys[index]["name"] = name.isEmpty ? nil : .string(name)
            }
        case .replace:
            if let index, let key = body["key"]?.string, !key.isEmpty {
                keySecrets[ref] = key
                keys[index]["masked"] = .string(masked(key))
            }
        case .on, .off:
            if index == 0 && action == .off {
                var old = try promote()
                old["on"] = false
                keys.insert(old, at: 1)
            } else if let index {
                keys[index]["on"] = .bool(action == .on)
            }
        }
        // 第一把总是 active、在用（与主机一致）
        for i in keys.indices { keys[i]["active"] = .bool(i == 0) }
        if !keys.isEmpty { keys[0]["on"] = true }
        update(id) { provider in
            provider["keyList"] = .array(keys)
            provider["key"] = ["set": .bool(!keys.isEmpty), "masked": keys.first?["masked"] ?? "", "optional": false]
        }
        return providersJSON
    }

    func arrangeProviders(_ order: [String]) async throws -> WebProviders {
        providerList.sort { (order.firstIndex(of: $0["id"]?.string ?? "") ?? .max) < (order.firstIndex(of: $1["id"]?.string ?? "") ?? .max) }
        return providersJSON
    }

    func groups() async throws -> WebGroups { try await pause(); return groupsJSON }

    func group(_ action: GroupAction, _ body: WebJSON) async throws -> WebGroups {
        try await pause()
        let id = body["id"]?.string ?? ""
        let index = groupList.firstIndex { $0["id"]?.string == id }
        switch action {
        case .delete:
            groupList.removeAll { $0["id"]?.string == id }
        case .switch:
            if let index { groupList[index]["disabled"] = .bool(body["on"]?.bool == false) }
        case .save:
            let from = body["from"]?.string ?? id
            var group = body.removing(["from", "placed"])
            if let placed = body["placed"] { group["members"] = placed }
            if let old = groupList.first(where: { $0["id"]?.string == from }) { group["disabled"] = old["disabled"] }
            if let at = groupList.firstIndex(where: { $0["id"]?.string == from }) {
                groupList[at] = group
            } else {
                groupList.append(group)
            }
        case .pick:
            if let index { groupList[index]["pick"] = body["pick"] }
        case .arrange:
            let order = body["order"]?.strings ?? []
            groupList.sort { (order.firstIndex(of: $0["id"]?.string ?? "") ?? .max) < (order.firstIndex(of: $1["id"]?.string ?? "") ?? .max) }
        case .found:
            foundGroups = body["on"]?.bool ?? true
        case .copy:
            if let index {
                var copy = groupList[index]
                copy["id"] = .string(id + "-copy")
                copy["name"] = body["name"] ?? .string(id + " 副本")
                copy["auto"] = nil
                groupList.insert(copy, at: index + 1)
            }
        }
        return groupsJSON
    }

    func modelSpeeds() async throws -> ModelSpeeds { ModelSpeeds(json: RoutesFixture.speeds) }

    func trace(after seq: Int64, wait: Bool) async throws -> TraceSnapshot {
        if RoutesClock.frozen {
            // 逐帧截图：长轮询等到时钟走下一步（见 RoutesClock）
            if wait { await RoutesClock.shared.nextStep(after: servedStep) }
            let start = traceStart
            let (step, elapsed, now) = await MainActor.run {
                (RoutesClock.shared.currentStep, RoutesClock.shared.fixtureElapsed(since: start), RoutesClock.shared.date)
            }
            servedStep = step
            return TraceSnapshot(json: RoutesFixture.trace(elapsed: elapsed, now: now))
        }
        // 一次挂起最多 1.5 秒，模拟网页的长轮询；示例请求按时间推进（见 RoutesFixture.trace）
        if wait { try await Task.sleep(for: .milliseconds(700)) }
        return TraceSnapshot(json: RoutesFixture.trace(elapsed: Date().timeIntervalSince(traceStart), now: Date()))
    }

    func state() async throws -> WebState { try await pause(); return stateJSON() }

    private func stateJSON(_ extra: [String: WebJSON] = [:]) -> WebState {
        let agents = agentList.map { agent -> WebJSON in
            var agent = agent
            if let id = agent["id"]?.string, id != "gemini" { agent["models"] = agentModelCount(id) }
            return agent
        }
        var json: [String: WebJSON] = ["agents": .array(agents), "profiles": .array(profileList)]
        json.merge(extra) { $1 }
        return WebState(json: .object(json))
    }

    func agentCLIs() async throws -> AgentCLIs { AgentCLIs(json: ["agents": .object(clis)]) }

    func updateAgentCLI(_ id: String) async throws -> AgentCLI {
        guard var cli = clis[id] else { throw MagpieError.webRejected(message: "magpie can't find \(id)'s CLI", code: nil) }
        try await Task.sleep(for: .milliseconds(600))
        cli["version"] = cli["latest"] ?? cli["version"] ?? ""
        cli["update"] = nil
        clis[id] = cli
        return AgentCLI(json: cli)
    }

    func rescanAgents() async throws -> WebState { try await pause(); return stateJSON() }

    func agentAction(_ action: AgentAction, _ id: String) async throws -> WebState {
        try await pause()
        guard let index = agentList.firstIndex(where: { $0["id"]?.string == id }) else {
            throw MagpieError.webRejected(message: "no agent \(id)", code: nil)
        }
        switch action {
        case .connect:
            agentList[index]["wired"] = true
            return stateJSON(["connected": ["how": "again"]])
        case .disconnect:
            agentList[index]["wired"] = nil
        case .reapply, .keep:
            agentList[index]["drift"] = nil
        }
        return stateJSON()
    }

    func agentDisconnectPreview(_ id: String) async throws -> AgentDisconnectPreview {
        let path = agentList.first { $0["id"]?.string == id }?["path"]?.string ?? "~/.config"
        return AgentDisconnectPreview(json: ["changes": [["path": .string(path), "lines": [["op": "-", "text": "model_provider = \"magpie\""]]]]])
    }

    func testProvider(_ id: String) async throws -> [ProviderTestResult] {
        try await Task.sleep(for: .milliseconds(400))
        let provider = providerList.first { $0["id"]?.string == id }
        var results: [WebJSON] = [["protocol": "chat", "ok": true, "status": 200, "ms": 412, "model": "example-model"]]
        if !(provider?["responses"]?.string ?? "").isEmpty {
            results.append(["protocol": "responses", "ok": false, "status": 404, "ms": 120, "error": "404 page not found"])
        }
        return results.map(ProviderTestResult.init(json:))
    }

    func profile(_ action: ProfileAction, name: String) async throws -> WebState {
        try await pause()
        switch action {
        case .save:
            var saved: [WebJSON] = []
            for agent in agentList {
                var fields: [WebJSON] = []
                for field in agent["fields"]?.array ?? [] {
                    let item: WebJSON = ["key": field["key"] ?? "", "label": field["label"] ?? "", "value": field["value"] ?? ""]
                    fields.append(item)
                }
                let entry: WebJSON = ["id": agent["id"] ?? "", "name": agent["name"] ?? "", "fields": .array(fields)]
                saved.append(entry)
            }
            let current: WebJSON = ["name": .string(name), "summary": "", "agents": .array(saved)]
            profileList.removeAll { $0["name"]?.string == name }
            profileList.append(current)
            profileList.sort { ($0["name"]?.string ?? "") < ($1["name"]?.string ?? "") }
            for i in profileList.indices { profileList[i]["inUse"] = .bool(profileList[i]["name"]?.string == name) }
        case .use:
            for i in profileList.indices { profileList[i]["inUse"] = .bool(profileList[i]["name"]?.string == name) }
            return stateJSON(["changed": 1])
        case .delete:
            profileList.removeAll { $0["name"]?.string == name }
        }
        return stateJSON(["changed": 0])
    }

    func setAgent(_ agent: String, field: String, value: String) async throws -> WebState {
        try await pause()
        if let index = agentList.firstIndex(where: { $0["id"]?.string == agent }), var fields = agentList[index]["fields"]?.array,
           let fieldIndex = fields.firstIndex(where: { $0["key"]?.string == field }) {
            fields[fieldIndex]["value"] = .string(value)
            agentList[index]["fields"] = .array(fields)
        }
        return WebState(json: ["agents": .array(agentList), "notice": "Codex builds its model list at start-up — restart the Codex app to see this."])
    }

    func callerKeys() async throws -> WebCallerKeys { try await pause(); return keys() }

    func callerKey(_ action: CallerKeyAction, _ body: WebJSON) async throws -> WebCallerKeys {
        try await pause()
        let id = body["key"]?.string ?? ""
        let index = keyList.firstIndex { $0["id"]?.string == id }
        switch action {
        case .add:
            let secret = newSecret()
            keyList.append(["id": .string("key-new-\(counter)"), "name": body["name"] ?? "新密钥",
                            "masked": .string("sk-magpie-key-…" + secret.suffix(6)), "readOnly": body["readOnly"] ?? false])
            return keys(secret: secret)
        case .rotate:
            guard let index else { throw MagpieError.webRejected(message: "Key not found", code: nil) }
            let secret = newSecret()
            keyList[index]["masked"] = .string("sk-magpie-key-…" + secret.suffix(6))
            return keys(secret: secret)
        case .copy:
            guard index != nil else { throw MagpieError.webRejected(message: "Key not found", code: nil) }
            return keys(secret: "sk-magpie-key-EXAMPLE-COPY")
        case .on, .off:
            guard let index else { throw MagpieError.webRejected(message: "Key not found", code: nil) }
            keyList[index]["off"] = .bool(action == .off)
        case .remove:
            keyList.removeAll { $0["id"]?.string == id }
        case .rename:
            guard let index else { throw MagpieError.webRejected(message: "Key not found", code: nil) }
            keyList[index]["name"] = body["name"] ?? keyList[index]["name"]
        case .resetLimit:
            guard index != nil else { throw MagpieError.webRejected(message: "Key not found", code: nil) }
            let count = keyLimits[id]?.count ?? 0
            guard count > 0 else { throw MagpieError.webRejected(message: "This key has no limit to reset", code: nil) }
            var used = keyUsed[id] ?? Array(repeating: (0, 0), count: count)
            if let n = body["index"]?.int { if n < used.count { used[n] = (0, 0) } } else { used = Array(repeating: (0, 0), count: count) }
            keyUsed[id] = used
        case .limit:
            guard index != nil else { throw MagpieError.webRejected(message: "Key not found", code: nil) }
            var limits = keyLimits[id] ?? []
            var used = keyUsed[id] ?? Array(repeating: (0, 0), count: limits.count)
            while used.count < limits.count { used.append((0, 0)) }
            let limit = body["limit"].flatMap { $0.object == nil ? nil : $0 }
            if let n = body["index"]?.int {
                guard n >= 0, n <= limits.count, n < limits.count || limit != nil else {
                    throw MagpieError.webRejected(message: "This key has no such limit", code: nil)
                }
                if let limit {
                    if n == limits.count {
                        guard limits.count < CallerKeyLimit.maxLimits else { throw MagpieError.webRejected(message: "A key can have at most 5 limits", code: nil) }
                        limits.append(limit); used.append((0, 0))
                    } else { limits[n] = limit }
                } else { limits.remove(at: n); used.remove(at: n) }
            } else {
                limits = limit.map { [$0] } ?? []
                used = Array(used.prefix(limits.count))
            }
            let periods = limits.map { "\($0["period"]?.string ?? "")\($0["days"]?.int ?? 0)\($0["hours"]?.int ?? 0)" }
            if Set(periods).count != periods.count {
                throw MagpieError.webRejected(message: "This key already has a limit in that window: change that one instead", code: nil)
            }
            keyLimits[id] = limits
            keyUsed[id] = used
        case .models:
            guard let index else { throw MagpieError.webRejected(message: "Key not found", code: nil) }
            let models = body["models"]?.strings ?? []
            keyList[index]["models"] = models.isEmpty ? nil : .strings(models)
        case .accounts:
            guard let index else { throw MagpieError.webRejected(message: "Key not found", code: nil) }
            let accounts = body["accounts"]?.strings ?? []
            keyList[index]["accounts"] = accounts.isEmpty ? nil : .strings(accounts)
        case .quotas:
            guard let index else { throw MagpieError.webRejected(message: "Key not found", code: nil) }
            keyList[index]["quotas"] = body["quotas"]?.bool == true ? true : nil
        case .access:
            guard let index else { throw MagpieError.webRejected(message: "Key not found", code: nil) }
            if keyList[index]["lan"]?.bool == true { throw MagpieError.webRejected(message: "the sharing key can't be read-only", code: nil) }
            keyList[index]["readOnly"] = .bool(body["readOnly"]?.bool ?? false)
        }
        return keys()
    }

    nonisolated var canIssue: Bool { true }

    func issuedKeys() async throws -> [IssuedKey] { issued.map(IssuedKey.init(json:)) }

    func issueKey(name: String, ttl: String) async throws -> IssuedKey {
        try await pause()
        let secret = newSecret()
        let key: WebJSON = ["id": .string("issued-\(counter)"), "name": .string(name), "key": .string(secret), "expires": .string("\(ttl) 后到期")]
        var masked = key
        masked["key"] = .string("sk-magpie-key-…" + secret.suffix(6))
        issued.append(masked)
        return IssuedKey(json: key)
    }

    func revokeIssuedKey(_ id: String) async throws { issued.removeAll { $0["id"]?.string == id } }

    nonisolated func page(_ page: MagpieWebPage) -> (url: URL, cookieName: String, key: String)? { nil }
}
