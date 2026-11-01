import Foundation

/// 插件操作（`POST /api/plugins/{op}`）。每个都返回整份插件列表。
public enum PluginAction: String, Sendable {
    /// 安装：`{spec}`，spec 可以是 npm 包名（可带 @版本）、`github:owner/repo`、Git 地址。
    case add
    /// 卸载：`{spec}`。
    case remove
    /// 更新一个：`{spec}`。
    case upgrade
    /// 全部更新：`{}`。
    case update
    /// 开关：`{spec, off}`。
    case off
    /// 选项（整份替换）：`{spec, options}`。
    case options
}

/// 插件接口的请求体。magpie 用不带 json 标签的 Go 结构体解码（大小写不敏感），这里统一用小写键。
public enum PluginRequests {
    public static func spec(_ spec: String) -> WebJSON { ["spec": .string(spec)] }

    public static func setEnabled(_ spec: String, _ enabled: Bool) -> WebJSON {
        ["spec": .string(spec), "off": .bool(!enabled)]
    }

    /// 选项整份替换：空对象 = 清除（主机会存成没有选项）。
    public static func options(_ spec: String, _ options: [String: WebJSON]) -> WebJSON {
        ["spec": .string(spec), "options": .object(options)]
    }

    public static func builtin(_ id: String, on: Bool) -> WebJSON { ["id": .string(id), "on": .bool(on)] }

    /// 内置插件设置：只发改过的项，主机按 schema 校验后合并。
    public static func builtin(_ id: String, config: [String: WebJSON]) -> WebJSON {
        ["id": .string(id), "config": .object(config)]
    }

    public static func providerOption(provider: String, key: String, on: Bool) -> WebJSON {
        ["provider": .string(provider), "key": .string(key), "on": .bool(on)]
    }

    /// 用户在「添加插件」里输入的内容整理成 spec：去掉空白；`npm i xxx` / `bun add xxx` 之类只留包名；
    /// npm 包页面地址转成包名。空或含空白（多个词）时为 nil。
    public static func normalizedSpec(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["npm install ", "npm i ", "bun add ", "bun install ", "pnpm add ", "yarn add "] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        for prefix in ["https://www.npmjs.com/package/", "https://npmjs.com/package/", "http://www.npmjs.com/package/"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
            if let cut = text.firstIndex(where: { $0 == "?" || $0 == "#" }) { text = String(text[..<cut]) }
            while text.hasSuffix("/") { text.removeLast() }
            if text.contains("/v/") { text = text.replacingOccurrences(of: "/v/", with: "@") }
        }
        guard !text.isEmpty, text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        return text
    }
}

extension WebClient {
    /// 安装 / 更新插件可能要几分钟（第一次还要下载 Bun）；主机最多等 5 分钟。
    public static let pluginInstallTimeout: TimeInterval = 330

    private func patient() -> WebClient {
        WebClient(baseURL: baseURL, key: key, session: session, timeout: max(timeout, Self.pluginInstallTimeout))
    }

    public func plugins() async throws -> WebPlugins { WebPlugins(json: try await patient().get("/api/plugins")) }

    public func plugin(_ action: PluginAction, _ body: WebJSON) async throws -> WebPlugins {
        let client = [.add, .upgrade, .update].contains(action) ? patient() : self
        return WebPlugins(json: try await client.post("/api/plugins/\(action.rawValue)", body))
    }

    /// 立刻问 npm / 仓库每个插件的最新版本，不安装任何东西。
    public func checkPluginUpdates() async throws -> WebPluginCheck {
        WebPluginCheck(json: try await patient().post("/api/plugins/check", [:]))
    }

    public func builtinPlugins() async throws -> WebBuiltinPlugins { WebBuiltinPlugins(json: try await get("/api/plugins/builtin")) }

    public func builtinPlugin(_ body: WebJSON) async throws -> WebBuiltinPlugins {
        WebBuiltinPlugins(json: try await post("/api/plugins/builtin", body))
    }

    /// 市场里推荐的插件（主机缓存的列表，不等 npm）。
    public func pluginListings() async throws -> WebPluginListings { WebPluginListings(json: try await get("/api/plugins/listings")) }

    /// 市场里有、但这里没装的 Agent 插件名称。
    public func pluginAgents() async throws -> [String] { try await get("/api/plugins/agents").strings }

    public func pluginPages() async throws -> [WebPluginPage] { WebPluginPage.list(try await get("/api/plugin-pages")) }

    public func pluginPanels() async throws -> [WebPluginPanel] { WebPluginPanel.list(try await get("/api/plugin-panels")) }

    /// 插件供应商声明的开关（来自 `GET /api/providers` 的 `plugins`）。
    public func pluginProviderOptions() async throws -> [PluginProviderOption] {
        PluginProviderOption.list(providers: try await get("/api/providers"))
    }

    /// 打开一个开关；返回设置（这里不需要），之后重新读开关状态。
    public func setPluginProviderOption(provider: String, key: String, on: Bool) async throws {
        _ = try await post("/api/settings/plugin-option", PluginRequests.providerOption(provider: provider, key: key, on: on))
    }

    /// 在 WKWebView 里打开 magpie 网页的某个页面（`/?view=<key>`）。`withKey` 时带一次 `?k=`，主机 303 去掉它并写 Cookie。
    public func pageURL(view: String, extra: [URLQueryItem] = [], withKey: Bool) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + "/"
        var items = [URLQueryItem(name: "view", value: view)] + extra
        if withKey { items.insert(URLQueryItem(name: "k", value: key), at: 0) }
        components.queryItems = items
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}
