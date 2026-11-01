import Foundation
import MagpieRemoteCore

/// 「插件」页访问主机 Web 管理接口的方式。真实实现走 `WebClient`，fixture 实现只改内存。
protocol PluginServing: Sendable {
    func plugins() async throws -> WebPlugins
    func plugin(_ action: PluginAction, _ body: WebJSON) async throws -> WebPlugins
    func checkUpdates() async throws -> WebPluginCheck
    func builtins() async throws -> WebBuiltinPlugins
    func builtin(_ body: WebJSON) async throws -> WebBuiltinPlugins
    func listings() async throws -> WebPluginListings
    func agents() async throws -> [String]
    func tagged(again: Bool) async throws -> WebTaggedRepos
    func npm(names: [String]) async throws -> [String: WebPluginNPM]
    func gitHeads() async throws -> [String: String]
    func search(_ query: String) async throws -> [WebPluginListing]
    func readme(_ name: String) async throws -> WebPluginReadme
    func setMirror(_ on: Bool) async throws -> Bool
    func setRegistry(_ url: String) async throws -> PluginRegistry
    func move(_ id: String) async throws
    func pages() async throws -> [WebPluginPage]
    func panels() async throws -> [WebPluginPanel]
    func pluginProviders() async throws -> WebPluginProviders
    func setProviderOption(provider: String, key: String, on: Bool) async throws
    /// 主机保存的图片（`file:` 开头的图标）。
    func icon(_ name: String) async throws -> Data?
    /// 在 App 内打开 magpie 网页的某个页面（`/?view=`）；fixture 下为 nil。
    func webPage(view: String, extra: [URLQueryItem]) -> (url: URL, cookieName: String, key: String)?
}

extension PluginServing {
    func webPage(view: String) -> (url: URL, cookieName: String, key: String)? { webPage(view: view, extra: []) }
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
    func tagged(again: Bool) async throws -> WebTaggedRepos { try await web.taggedPlugins(again: again) }
    func npm(names: [String]) async throws -> [String: WebPluginNPM] { try await web.pluginNPM(names: names) }
    func gitHeads() async throws -> [String: String] { try await web.pluginGitHeads() }
    func search(_ query: String) async throws -> [WebPluginListing] { try await web.searchPlugins(query) }
    func readme(_ name: String) async throws -> WebPluginReadme { try await web.pluginReadme(name) }
    func setMirror(_ on: Bool) async throws -> Bool { try await web.setPluginMirror(on) }
    func setRegistry(_ url: String) async throws -> PluginRegistry { try await web.setPluginRegistry(url) }
    func move(_ id: String) async throws { try await web.movePluginProvider(id) }
    func pages() async throws -> [WebPluginPage] { try await web.pluginPages() }
    func panels() async throws -> [WebPluginPanel] { try await web.pluginPanels() }
    func pluginProviders() async throws -> WebPluginProviders { try await web.pluginProviders() }
    func setProviderOption(provider: String, key: String, on: Bool) async throws {
        try await web.setPluginProviderOption(provider: provider, key: key, on: on)
    }
    func icon(_ name: String) async throws -> Data? { try await web.pluginIcon(name) }
    func webPage(view: String, extra: [URLQueryItem]) -> (url: URL, cookieName: String, key: String)? {
        web.pageURL(view: view, extra: extra, withKey: true).map { ($0, web.cookieName, web.key) }
    }
}

/// fixture 模式：示例插件、内置插件、市场、GitHub 与 npm，全部只在内存里改，不访问网络。
actor FixturePluginService: PluginServing {
    static let shared = FixturePluginService()

    private var installed: [WebJSON]
    private var builtinList: [WebJSON]
    private var providerSwitches: [String: Bool] = ["example/fast-mode": true]
    private var mirror = false
    private var registry: WebJSON = ["url": "https://registry.npmjs.org", "from": "default"]
    private let market: [WebJSON]
    private let repos: [WebJSON]
    private let npmInfo: [String: WebJSON]

    init() {
        installed = [
            ["spec": "@magpie-community/example-auth", "version": "1.2.0", "latest": "1.3.0", "ownName": "示例云登录",
             "providers": ["示例云"], "moved": [], "named": true, "options": ["region": "cn"]],
            ["spec": "github:example-owner/magpie-dash", "version": "0.4.1", "package": "magpie-dash", "ownName": "示例仪表盘",
             "commit": "abc1234", "head": "abc1234", "providers": [], "moved": [], "inMagpieOnly": true,
             "page": ["title": "仪表盘", "reads": ["usage:summary"]], "panels": [["slot": "usage", "title": "花费"]], "panelReads": ["usage:summary"]],
            ["spec": "example-middleware@2", "version": "2.0.0", "off": true, "providers": [], "moved": [], "isMiddleware": true,
             "middlewareOnly": true, "ownName": "示例中间件", "optionsExample": ["level": 1]],
        ]
        let endpoint: WebJSON = ["type": "string", "title": "收集器地址", "default": ""]
        let sample: WebJSON = ["type": "number", "title": "采样率", "minimum": 0, "maximum": 1, "default": 1]
        let insecure: WebJSON = ["type": "boolean", "title": "允许明文 HTTP", "default": false]
        let proto: WebJSON = ["type": "string", "title": "协议", "enum": ["grpc", "http"], "default": "http"]
        let schema: WebJSON = ["type": "object", "x-order": ["endpoint", "sample", "insecure", "protocol"],
                               "properties": ["endpoint": endpoint, "sample": sample, "insecure": insecure, "protocol": proto]]
        let config: WebJSON = ["endpoint": "https://collector.example", "sample": .double(0.5)]
        let otel: WebJSON = ["id": "otel", "name": "Observability", "sub": "", "on": true, "chosen": true, "state": "active",
                             "inUse": 0, "schema": schema, "config": config]
        builtinList = [
            ["id": "usage", "name": "Usage", "sub": "", "on": true, "chosen": true, "state": "active", "inUse": 1, "use": "Used by the Usage page"],
            ["id": "sessions", "name": "Sessions", "sub": "", "on": false, "chosen": false, "state": "off", "inUse": 0],
            otel,
        ]
        market = [
            ["package": "@magpie-community/example-auth", "name": "示例云", "community": true, "providers": ["example"],
             "summary": ["zh": "登录示例云，使用它的模型"]],
            ["package": "@magpie-community/example-guard", "name": "示例守卫", "kind": "middleware", "community": true,
             "summary": ["zh": "在网关里检查每个请求，拦下不该发出的内容"]],
            ["package": "example-search-tools", "name": "示例搜索工具", "kind": "tools", "community": true,
             "summary": ["zh": "给每个 Agent 提供网页搜索工具"]],
            ["package": "example-agent", "name": "示例 Agent", "kind": "agent", "community": true,
             "summary": ["zh": "一个可以在 magpie 里运行的 Agent"]],
        ]
        npmInfo = [
            "@magpie-community/example-auth": ["version": "1.3.0", "publisher": "magpie-bot", "license": "MIT", "weekly": 15230,
                                               "repository": "https://github.com/magpie-community/plugins"],
            "@magpie-community/example-guard": ["version": "0.2.0", "publisher": "magpie-bot", "license": "MIT", "weekly": 820],
            "example-search-tools": ["version": "0.2.0", "publisher": "example-dev", "license": "Apache-2.0", "weekly": 40],
            "example-agent": ["weekly": 0],
        ]
        repos = [
            ["spec": "github:example-owner/magpie-dash", "repo": "example-owner/magpie-dash", "url": "https://github.com/example-owner/magpie-dash",
             "owner": "example-owner", "description": "magpie 的仪表盘页面", "stars": 128, "license": "MIT",
             "pushed": "2026-10-30T08:12:45Z", "package": "magpie-dash", "version": "0.4.1", "kind": "page"],
            ["spec": "github:example-owner/relay-auth", "repo": "example-owner/relay-auth", "url": "https://github.com/example-owner/relay-auth",
             "owner": "example-owner", "description": "登录示例中转站", "stars": 12, "license": "MIT",
             "pushed": "2026-09-01T00:00:00Z", "package": "example-relay-auth", "version": "1.0.0"],
        ]
    }

    private func pause() async throws { try await Task.sleep(for: .milliseconds(80)) }
    private var state: WebPlugins {
        WebPlugins(json: ["plugins": .array(installed), "bun": true, "bunVersion": "1.3.0", "picker": false, "movable": [],
                          "mirror": .bool(mirror), "registry": registry])
    }

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
            let name = PluginSpec.name(spec)
            if let old = installed.firstIndex(where: { PluginSpec.name($0["spec"]?.string ?? "") == name }) { installed.remove(at: old) }
            let listing = market.first { $0["package"]?.string == name }
            var entry: WebJSON = ["spec": .string(spec), "version": npmInfo[name]?["version"] ?? "1.0.0", "providers": [], "moved": []]
            if let repo = repos.first(where: { $0["spec"]?.string == spec }) {
                entry["package"] = repo["package"] ?? .string(spec)
                entry["commit"] = "0a1b2c3"
                entry["head"] = "0a1b2c3"
                if repo["kind"]?.string == "page" { entry["page"] = ["title": repo["repo"] ?? "", "reads": []] }
            }
            switch listing?["kind"]?.string {
            case "middleware":
                entry["isMiddleware"] = .bool(true)
                entry["middlewareOnly"] = .bool(true)
            case "agent":
                entry["isAgent"] = .bool(true)
                entry["inMagpieOnly"] = .bool(true)
            case "tools":
                entry["tools"] = [["name": "search", "mcp": "example_search", "description": "搜索网页"]]
            default:
                break
            }
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
            if let head = installed[i]["head"] { installed[i]["commit"] = head }
        case .update:
            for i in installed.indices where installed[i]["off"]?.bool != true {
                if let latest = installed[i]["latest"] { installed[i]["version"] = latest }
            }
        case .prefer:
            _ = try index(spec)
        }
        return state
    }

    func checkUpdates() async throws -> WebPluginCheck {
        try await pause()
        let checks: [WebJSON] = installed.map { entry in
            let spec = entry["spec"]?.string ?? ""
            let version = entry["version"]?.string ?? ""
            let latest = entry["latest"]?.string ?? version
            return ["spec": .string(spec), "package": .string(PluginSpec.name(spec)), "version": .string(version), "latest": .string(latest),
                    "status": .string(PluginVersion.isNewer(latest, than: version) ? "update" : "current"), "off": entry["off"] ?? .bool(false)]
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
        let have = Set(installed.compactMap { $0["spec"]?.string.map(PluginSpec.name) })
        return market.filter { $0["kind"]?.string == "agent" && !have.contains($0["package"]?.string ?? "") }.compactMap { $0["name"]?.string }
    }

    func tagged(again: Bool) async throws -> WebTaggedRepos {
        try await pause()
        return WebTaggedRepos(json: ["repos": .array(repos), "topic": "magpie-plugin"])
    }

    func npm(names: [String]) async throws -> [String: WebPluginNPM] {
        var out: [String: WebPluginNPM] = [:]
        for name in names { if let info = npmInfo[name] { out[name] = WebPluginNPM(raw: info) } }
        return out
    }

    func gitHeads() async throws -> [String: String] {
        var out: [String: String] = [:]
        for e in installed {
            if let spec = e["spec"]?.string, PluginSpec.isGit(spec), let head = e["head"]?.string { out[spec] = head }
        }
        return out
    }

    func search(_ query: String) async throws -> [WebPluginListing] {
        try await pause()
        let hits: [WebJSON] = [
            ["package": "opencode-example-auth", "version": "0.3.1", "description": "示例服务的 OpenCode 登录插件", "publisher": "someone", "weekly": 2400],
            ["package": "pi-example-tools", "version": "1.1.0", "description": "示例工具包", "publisher": "someone", "weekly": 90],
        ]
        let q = query.lowercased()
        return hits.filter { ($0["package"]?.string ?? "").contains(q) || ($0["description"]?.string ?? "").lowercased().contains(q) }
            .compactMap(WebPluginListing.hit)
    }

    func readme(_ name: String) async throws -> WebPluginReadme {
        try await pause()
        let text = "# \(name)\n\n这是示例插件的说明，展示 README 的排版：**粗体**、`代码` 和 [链接](https://example.com)。\n\n## 使用\n\n"
            + "1. 安装插件\n2. 在「供应商」里登录\n\n```sh\nmagpie plugin add \(name)\n```\n\n> 只安装你信任的插件。\n"
        return WebPluginReadme(readme: text, updated: "2026-10-28T09:30:00+08:00")
    }

    func setMirror(_ on: Bool) async throws -> Bool { try await pause(); mirror = on; return on }

    func setRegistry(_ url: String) async throws -> PluginRegistry {
        try await pause()
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !(trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://")) {
            throw MagpieError.webRejected(message: "a registry is an http(s) address", code: nil)
        }
        registry = trimmed.isEmpty ? ["url": "https://registry.npmjs.org", "from": "default"] : ["url": .string(trimmed), "from": "magpie"]
        return PluginRegistry(json: registry)
    }

    func move(_ id: String) async throws { try await pause() }

    func pages() async throws -> [WebPluginPage] {
        installed.compactMap { entry -> WebPluginPage? in
            guard entry["off"]?.bool != true, let page = entry["page"], let spec = entry["spec"]?.string else { return nil }
            let key = entry["package"]?.string ?? spec
            return WebPluginPage(raw: ["spec": .string(spec), "key": .string(key), "name": .string(key), "title": page["title"] ?? "",
                                       "url": "/_magpie/plugin/0123456789abcdef0123456789abcdef/index.html", "reads": page["reads"] ?? []])
        }
    }

    func panels() async throws -> [WebPluginPanel] { [] }

    func pluginProviders() async throws -> WebPluginProviders {
        let spec = "@magpie-community/example-auth"
        guard installed.contains(where: { $0["spec"]?.string == spec }) else { return WebPluginProviders() }
        return WebPluginProviders(
            subs: [PluginSub(id: "plugin-example", pid: "example", name: "示例云", spec: spec, signedIn: true)],
            options: [PluginProviderOption(provider: "example", providerName: "示例云", spec: spec, key: "fast-mode",
                                           label: "快速模式", detail: "使用更快的接口", confirm: "", on: providerSwitches["example/fast-mode"] ?? false)])
    }

    func setProviderOption(provider: String, key: String, on: Bool) async throws {
        try await pause()
        providerSwitches[provider + "/" + key] = on
    }

    func icon(_ name: String) async throws -> Data? { nil }

    nonisolated func webPage(view: String, extra: [URLQueryItem]) -> (url: URL, cookieName: String, key: String)? { nil }
}
