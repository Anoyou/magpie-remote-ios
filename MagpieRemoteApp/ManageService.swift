import Foundation
import MagpieRemoteCore

/// 「管理」页访问主机 Web 管理接口（3430）与网关临时密钥接口的方式。真实实现走 `WebClient`，fixture 实现只改内存。
protocol ManageServing: Sendable {
    func settings() async throws -> WebSettings
    func providers() async throws -> WebProviders
    func provider(_ action: ProviderAction, _ body: WebJSON) async throws -> WebProviders
    func arrangeProviders(_ order: [String]) async throws -> WebProviders
    func groups() async throws -> WebGroups
    func group(_ action: GroupAction, _ body: WebJSON) async throws -> WebGroups
    func state() async throws -> WebState
    func setAgent(_ agent: String, field: String, value: String) async throws -> WebState
    func callerKeys() async throws -> WebCallerKeys
    func callerKey(_ action: CallerKeyAction, _ body: WebJSON) async throws -> WebCallerKeys
    /// 填了签发密钥才能签发临时密钥。
    var canIssue: Bool { get }
    func issuedKeys() async throws -> [IssuedKey]
    func issueKey(name: String, ttl: String) async throws -> IssuedKey
    func revokeIssuedKey(_ id: String) async throws
    /// 网页兜底：地址（带一次 ?k=）与要注入 WKWebView 的 Cookie；fixture 下为 nil。
    func page(_ page: WebPage) -> (url: URL, cookieName: String, key: String)?
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
    func groups() async throws -> WebGroups { try await web.groups() }
    func group(_ action: GroupAction, _ body: WebJSON) async throws -> WebGroups { try await web.group(action, body) }
    func state() async throws -> WebState { try await web.state() }
    func setAgent(_ agent: String, field: String, value: String) async throws -> WebState {
        try await web.setAgent(agent, field: field, value: value)
    }
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

    func page(_ page: WebPage) -> (url: URL, cookieName: String, key: String)? {
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
    private var counter = 0

    init() {
        func model(_ id: String, _ name: String, _ on: Bool) -> WebJSON { ["id": .string(id), "name": .string(name), "on": .bool(on)] }
        let provider1: WebJSON =
            ["id": "relay-example", "name": "示例中转", "preset": "", "host": "relay.example", "chat": "https://relay.example/v1",
             "ready": true, "off": false, "chosen": ["gpt-4.1", "o3"], "fallback": [], "headers": ["X-Org": "org-EXAMPLE"],
             "key": ["set": true, "masked": "sk-r…EXMP", "optional": false], "account": nil,
             "models": [model("gpt-4.1", "GPT 4.1", true), model("gpt-4.1-mini", "GPT 4.1 mini", false), model("o3", "OpenAI o3", true)]]
        let provider2: WebJSON =
            ["id": "deepseek", "name": "示例 DeepSeek", "preset": "deepseek", "host": "api.deepseek.example", "chat": "https://api.deepseek.example/v1",
             "ready": true, "off": false, "chosen": [], "fallback": [], "key": ["set": true, "masked": "sk-d…EXMP", "optional": false],
             "models": [model("deepseek-chat", "DeepSeek Chat", true), model("deepseek-reasoner", "DeepSeek Reasoner", true)]]
        let provider3: WebJSON =
            ["id": "codex", "name": "示例 Codex 订阅", "preset": "codex", "host": "", "chat": "", "ready": true, "off": true,
             "chosen": [], "fallback": [], "key": ["set": false, "masked": "", "optional": true],
             "account": ["agent": "codex", "user": "someone@example.com"],
             "models": [model("gpt-5", "GPT-5", true)]]
        providerList = [provider1, provider2, provider3]
        groupList = [
            ["id": "smart", "name": "聪明组", "members": ["relay-example/gpt-4.1", "deepseek/deepseek-chat"], "routing": "order",
             "ready": true, "ref": "group/smart"],
        ]
        func option(_ value: String, _ label: String, _ group: String) -> WebJSON {
            ["value": .string(value), "label": .string(label), "note": .string(group + " · via magpie"), "group": .string(group)]
        }
        let options: WebJSON = [option("group/smart", "聪明组", "路由组"), option("relay-example/gpt-4.1", "GPT 4.1", "示例中转"),
                                option("relay-example/o3", "OpenAI o3", "示例中转"), option("deepseek/deepseek-chat", "DeepSeek Chat", "示例 DeepSeek")]
        agentList = [
            ["id": "codex", "name": "Codex", "path": "~/.codex/config.toml", "wired": true,
             "fields": [["key": "model", "label": "model", "value": "relay-example/gpt-4.1", "options": options]]],
            ["id": "claude", "name": "Claude Code", "path": "~/.claude/settings.json", "wired": nil,
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
        var models: [WebJSON] = []
        for provider in providerList {
            for model in provider["models"]?.array ?? [] where model["on"]?.bool == true {
                models.append(["id": .string("\(provider["id"]?.string ?? "")/\(model["id"]?.string ?? "")"),
                               "name": model["name"] ?? "", "providerName": provider["name"] ?? ""])
            }
        }
        return WebGroups(json: ["groups": .array(groupList), "models": .array(models)])
    }
    private func keys(secret: String? = nil) -> WebCallerKeys {
        WebCallerKeys(json: ["keys": .array(keyList), "secret": .string(secret ?? "")])
    }
    private func newSecret() -> String {
        counter += 1
        return "sk-magpie-key-EXAMPLE-NEW\(counter)"
    }

    func settings() async throws -> WebSettings { WebSettings(json: ["version": "v0.1.2438", "lan": true]) }
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
        }
        return providersJSON
    }

    private func update(_ id: String, _ change: (inout WebJSON) -> Void) {
        guard let index = providerList.firstIndex(where: { $0["id"]?.string == id }) else { return }
        change(&providerList[index])
    }

    func arrangeProviders(_ order: [String]) async throws -> WebProviders {
        providerList.sort { (order.firstIndex(of: $0["id"]?.string ?? "") ?? .max) < (order.firstIndex(of: $1["id"]?.string ?? "") ?? .max) }
        return providersJSON
    }

    func groups() async throws -> WebGroups { try await pause(); return groupsJSON }

    func group(_ action: GroupAction, _ body: WebJSON) async throws -> WebGroups {
        try await pause()
        let id = body["id"]?.string ?? ""
        switch action {
        case .delete:
            groupList.removeAll { $0["id"]?.string == id }
        case .switch:
            if let index = groupList.firstIndex(where: { $0["id"]?.string == id }) {
                groupList[index]["disabled"] = .bool(body["on"]?.bool == false)
            }
        case .save:
            let from = body["from"]?.string ?? id
            var group = body.removing(["from"])
            group["ready"] = true
            group["ref"] = .string("group/" + id)
            if let index = groupList.firstIndex(where: { $0["id"]?.string == from }) {
                groupList[index] = group
            } else {
                groupList.append(group)
            }
        }
        return groupsJSON
    }

    func state() async throws -> WebState { try await pause(); return WebState(json: ["agents": .array(agentList)]) }

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

    nonisolated func page(_ page: WebPage) -> (url: URL, cookieName: String, key: String)? { nil }
}
