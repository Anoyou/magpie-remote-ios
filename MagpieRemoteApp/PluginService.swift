import Foundation
import MagpieRemoteCore

/// 「管理 › 插件」访问主机 Web 管理接口的方式。真实实现走 `WebClient`，fixture 实现只改内存。
protocol PluginServing: Sendable {
    func plugins() async throws -> WebPlugins
    func plugin(_ action: PluginAction, _ body: WebJSON) async throws -> WebPlugins
    func checkUpdates() async throws -> WebPluginCheck
    func builtins() async throws -> WebBuiltinPlugins
    func builtin(_ body: WebJSON) async throws -> WebBuiltinPlugins
    func listings() async throws -> WebPluginListings
    func agents() async throws -> [String]
    func pages() async throws -> [WebPluginPage]
    func panels() async throws -> [WebPluginPanel]
    func providerOptions() async throws -> [PluginProviderOption]
    func setProviderOption(provider: String, key: String, on: Bool) async throws
    /// 在 App 内打开 magpie 网页的某个页面（`/?view=`）；fixture 下为 nil。
    func webPage(view: String) -> (url: URL, cookieName: String, key: String)?
}

/// 根据「管理」页当前的服务选择插件服务：真实主机用同一个 Web 客户端，示例模式用内存数据。
func makePluginService(for manage: (any ManageServing)?) -> (any PluginServing)? {
    if let live = manage as? LiveManageService { return LivePluginService(web: live.web) }
    if manage is FixtureManageService { return FixturePluginService.shared }
    return nil
}

struct LivePluginService: PluginServing {
    let web: WebClient

    func plugins() async throws -> WebPlugins { try await web.plugins() }
    func plugin(_ action: PluginAction, _ body: WebJSON) async throws -> WebPlugins { try await web.plugin(action, body) }
    func checkUpdates() async throws -> WebPluginCheck { try await web.checkPluginUpdates() }
    func builtins() async throws -> WebBuiltinPlugins { try await web.builtinPlugins() }
    func builtin(_ body: WebJSON) async throws -> WebBuiltinPlugins { try await web.builtinPlugin(body) }
    func listings() async throws -> WebPluginListings { try await web.pluginListings() }
    func agents() async throws -> [String] { try await web.pluginAgents() }
    func pages() async throws -> [WebPluginPage] { try await web.pluginPages() }
    func panels() async throws -> [WebPluginPanel] { try await web.pluginPanels() }
    func providerOptions() async throws -> [PluginProviderOption] { try await web.pluginProviderOptions() }
    func setProviderOption(provider: String, key: String, on: Bool) async throws {
        try await web.setPluginProviderOption(provider: provider, key: key, on: on)
    }
    func webPage(view: String) -> (url: URL, cookieName: String, key: String)? {
        web.pageURL(view: view, withKey: true).map { ($0, web.cookieName, web.key) }
    }
}

/// fixture 模式：示例插件、内置插件与市场，全部只在内存里改，不访问网络。
actor FixturePluginService: PluginServing {
    static let shared = FixturePluginService()

    private var installed: [WebJSON]
    private var builtinList: [WebJSON]
    private var providerSwitches: [String: Bool] = ["example/fast-mode": true]
    private let market: [WebJSON]

    init() {
        installed = [
            ["spec": "@magpie-community/example-auth", "version": "1.2.0", "latest": "1.3.0", "ownName": "示例云登录",
             "providers": ["示例云"], "options": ["region": "cn"], "optionsExample": ["region": "global"]],
            ["spec": "github:example-owner/magpie-dash", "version": "0.4.1", "package": "magpie-dash", "ownName": "示例仪表盘",
             "commit": "abc1234", "head": "abc1234", "providers": [], "page": ["title": "仪表盘", "reads": ["usage:summary"]]],
            ["spec": "example-middleware@2", "version": "2.0.0", "off": true, "providers": [], "isMiddleware": true,
             "ownName": "示例中间件"],
        ]
        let endpoint: WebJSON = ["type": "string", "title": "收集器地址", "default": ""]
        let sample: WebJSON = ["type": "number", "title": "采样率", "minimum": 0, "maximum": 1, "default": 1]
        let insecure: WebJSON = ["type": "boolean", "title": "允许明文 HTTP", "default": false]
        let schema: WebJSON = ["type": "object", "x-order": ["endpoint", "sample", "insecure"],
                               "properties": ["endpoint": endpoint, "sample": sample, "insecure": insecure]]
        let config: WebJSON = ["endpoint": "https://collector.example", "sample": .double(0.5)]
        let otel: WebJSON = ["id": "otel", "name": "Observability", "sub": "", "on": true, "chosen": true, "state": "active",
                             "inUse": 0, "schema": schema, "config": config]
        builtinList = [
            ["id": "usage", "name": "Usage", "sub": "", "on": true, "chosen": true, "state": "active", "inUse": 1, "use": "Used by the Usage page"],
            ["id": "sessions", "name": "Sessions", "sub": "", "on": false, "chosen": false, "state": "off", "inUse": 0],
            otel,
        ]
        market = [
            ["package": "@magpie-community/example-auth", "name": "示例云", "community": true,
             "summary": ["zh": "登录示例云，使用它的模型"], "npm": ["version": "1.3.0", "weekly": 120]],
            ["package": "example-search-tools", "name": "示例搜索工具", "kind": "tools",
             "summary": ["zh": "给每个 Agent 提供网页搜索工具"], "npm": ["version": "0.2.0", "weekly": 40]],
            ["package": "example-agent", "name": "示例 Agent", "kind": "agent",
             "summary": ["zh": "一个可以在 magpie 里运行的 Agent"], "npm": ["version": "1.0.0", "weekly": 8]],
        ]
    }

    private func pause() async throws { try await Task.sleep(for: .milliseconds(80)) }
    private var state: WebPlugins { WebPlugins(json: ["plugins": .array(installed), "bun": true, "bunVersion": "1.3.0"]) }

    private func index(_ spec: String) throws -> Int {
        guard let index = installed.firstIndex(where: { $0["spec"]?.string == spec }) else {
            throw MagpieError.webRejected(message: "no plugin \"\(spec)\"", code: nil)
        }
        return index
    }

    func plugins() async throws -> WebPlugins { try await pause(); return state }

    func plugin(_ action: PluginAction, _ body: WebJSON) async throws -> WebPlugins {
        try await pause()
        let spec = body["spec"]?.string ?? ""
        switch action {
        case .add:
            guard installed.firstIndex(where: { $0["spec"]?.string == spec }) == nil else { return state }
            let listing = market.first { $0["package"]?.string == spec }
            var entry: WebJSON = ["spec": .string(spec), "version": listing?["npm"]?["version"] ?? "1.0.0", "providers": []]
            if let name = listing?["name"] { entry["ownName"] = name }
            installed.append(entry)
        case .remove:
            installed.remove(at: try index(spec))
        case .off:
            let i = try index(spec)
            installed[i]["off"] = .bool(body["off"]?.bool ?? false)
        case .options:
            let i = try index(spec)
            let options = body["options"]?.object ?? [:]
            if options.isEmpty {
                installed[i] = installed[i].removing(["options"])
            } else {
                installed[i]["options"] = .object(options)
            }
        case .upgrade:
            let i = try index(spec)
            if let latest = installed[i]["latest"] { installed[i]["version"] = latest }
        case .update:
            for i in installed.indices { if let latest = installed[i]["latest"] { installed[i]["version"] = latest } }
        }
        return state
    }

    func checkUpdates() async throws -> WebPluginCheck {
        try await pause()
        let checks: [WebJSON] = installed.map { entry in
            let version = entry["version"]?.string ?? ""
            let latest = entry["latest"]?.string ?? version
            return ["spec": entry["spec"] ?? "", "package": entry["spec"] ?? "", "version": .string(version), "latest": .string(latest),
                    "status": .string(PluginVersion.isNewer(latest, than: version) ? "update" : "current"), "off": entry["off"] ?? false]
        }
        return WebPluginCheck(json: ["at": "2026-11-01T07:10:00+08:00", "plugins": .array(checks), "state": state.raw])
    }

    func builtins() async throws -> WebBuiltinPlugins { try await pause(); return WebBuiltinPlugins(json: .array(builtinList)) }

    func builtin(_ body: WebJSON) async throws -> WebBuiltinPlugins {
        try await pause()
        let id = body["id"]?.string ?? ""
        guard let i = builtinList.firstIndex(where: { $0["id"]?.string == id }) else {
            throw MagpieError.webRejected(message: "no built-in plugin \"\(id)\"", code: nil)
        }
        if let on = body["on"]?.bool {
            if !on, (builtinList[i]["inUse"]?.int ?? 0) > 0 {
                throw MagpieError.webRejected(message: "\(builtinList[i]["name"]?.string ?? id) is in use and stays on", code: nil)
            }
            builtinList[i]["on"] = .bool(on)
            builtinList[i]["chosen"] = .bool(on)
            builtinList[i]["state"] = .string(on ? "active" : "off")
        }
        if let config = body["config"]?.object {
            var current = builtinList[i]["config"]?.object ?? [:]
            current.merge(config) { _, new in new }
            builtinList[i]["config"] = .object(current)
        }
        return WebBuiltinPlugins(json: .array(builtinList))
    }

    func listings() async throws -> WebPluginListings { try await pause(); return WebPluginListings(json: ["listings": .array(market)]) }

    func agents() async throws -> [String] {
        let have = Set(installed.compactMap { $0["spec"]?.string })
        return market.filter { $0["kind"]?.string == "agent" && !have.contains($0["package"]?.string ?? "") }.compactMap { $0["name"]?.string }
    }

    func pages() async throws -> [WebPluginPage] {
        installed.compactMap { entry -> WebPluginPage? in
            guard entry["off"]?.bool != true, let page = entry["page"], let spec = entry["spec"]?.string else { return nil }
            let key = entry["package"]?.string ?? spec
            return WebPluginPage(raw: ["spec": .string(spec), "key": .string(key), "name": .string(key), "title": page["title"] ?? "",
                                       "url": "/_magpie/plugin/0123456789abcdef0123456789abcdef/index.html", "reads": page["reads"] ?? []])
        }
    }

    func panels() async throws -> [WebPluginPanel] { [] }

    func providerOptions() async throws -> [PluginProviderOption] {
        guard installed.contains(where: { $0["spec"]?.string == "@magpie-community/example-auth" }) else { return [] }
        return [
            PluginProviderOption(provider: "example", providerName: "示例云", spec: "@magpie-community/example-auth", key: "fast-mode",
                                 label: "快速模式", detail: "使用更快的接口", confirm: "", on: providerSwitches["example/fast-mode"] ?? false),
        ]
    }

    func setProviderOption(provider: String, key: String, on: Bool) async throws {
        try await pause()
        providerSwitches[provider + "/" + key] = on
    }

    nonisolated func webPage(view: String) -> (url: URL, cookieName: String, key: String)? { nil }
}
