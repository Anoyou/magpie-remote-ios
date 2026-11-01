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
            ["id": "key-iphone", "name": "iPhone", "masked": "sk-magpie-key-…EXMP01", "limit": ["period": "month", "cost": 20],
             "used": ["cost": .double(3.5)]],
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
        WebCallerKeys(json: ["keys": .array(keyList), "secret": .string(secret ?? "")])
    }
    private func newSecret() -> String {
        counter += 1
        return "sk-magpie-key-EXAMPLE-NEW\(counter)"
    }

    func settings() async throws -> WebSettings {
        WebSettings(json: ["version": "v0.1.2438", "lan": true, "agentOrder": nil, "agentsHidden": ["gemini"]])
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
        var json: [String: WebJSON] = ["agents": .array(agentList), "profiles": .array(profileList)]
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

    func profile(_ action: ProfileAction, name: String) async throws -> WebState {
        try await pause()
        switch action {
        case .save:
            let current: WebJSON = ["name": .string(name), "summary": "", "agents": .array(agentList.map { agent in
                ["id": agent["id"] ?? "", "name": agent["name"] ?? "", "fields": .array((agent["fields"]?.array ?? []).map { field in
                    ["key": field["key"] ?? "", "label": field["label"] ?? "", "value": field["value"] ?? ""]
                })]
            })]
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
