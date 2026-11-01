import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
    /// 选项（整份替换）：`{spec, options}`；`options: null` = 清空。
    case options
    /// 两个插件都登录同一个供应商时，改由这个插件提供：`{spec, provider}`（provider 是 OpenCode 的 id）。
    case prefer
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

    /// 清空选项（官方「清空」发的是 null，主机存成没有选项）。
    public static func clearOptions(_ spec: String) -> WebJSON { ["spec": .string(spec), "options": .null] }

    public static func prefer(_ spec: String, provider: String) -> WebJSON { ["spec": .string(spec), "provider": .string(provider)] }

    /// 「国内镜像」开关：`POST /api/plugins/mirror {on}`。
    public static func mirror(_ on: Bool) -> WebJSON { ["on": .bool(on)] }

    /// npm 源：`POST /api/plugins/registry {url}`，空 = 使用默认（.npmrc、bunfig、终端环境或 npm 官方源）。
    public static func registry(_ url: String) -> WebJSON { ["url": .string(url.trimmingCharacters(in: .whitespacesAndNewlines))] }

    /// 把内置订阅的账号迁到它的插件上：`POST /api/provider/move {id}`。
    public static func move(_ id: String) -> WebJSON { ["id": .string(id)] }

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

    /// GitHub 上打了 magpie-plugin 标签的仓库；`again` = 让主机立刻重新问 GitHub（「重试」）。
    public func taggedPlugins(again: Bool = false) async throws -> WebTaggedRepos {
        WebTaggedRepos(json: try await get("/api/plugins/github", query: again ? [URLQueryItem(name: "again", value: "1")] : []))
    }

    /// npm 说的这些包（最多 100 个）：最新版本、下载量、发布者、许可证…
    public func pluginNPM(names: [String]) async throws -> [String: WebPluginNPM] {
        let list = Array(Set(names.filter { !$0.isEmpty })).sorted().prefix(100)
        guard !list.isEmpty else { return [:] }
        return WebPluginNPM.map(try await get("/api/plugins/npm", query: [URLQueryItem(name: "names", value: list.joined(separator: ","))]))
    }

    /// 每个 git 插件的仓库现在在哪个提交（spec → 短 sha）。
    public func pluginGitHeads() async throws -> [String: String] {
        let json = try await patient().get("/api/plugins/git")
        return (json["heads"]?.object ?? [:]).compactMapValues(\.string)
    }

    /// 在 npm 上搜索插件（OpenCode 插件与 pi 包）。
    public func searchPlugins(_ query: String) async throws -> [WebPluginListing] {
        let json = try await get("/api/plugins/search", query: [URLQueryItem(name: "q", value: query)])
        return (json["hits"]?.array ?? []).compactMap(WebPluginListing.hit)
    }

    /// 插件的 README（npm 上的，文件夹 / git 插件读它自己目录里的）。
    public func pluginReadme(_ name: String) async throws -> WebPluginReadme {
        WebPluginReadme(json: try await get("/api/plugins/page", query: [URLQueryItem(name: "name", value: name)]))
    }

    /// 「国内镜像」：返回主机现在的状态。
    public func setPluginMirror(_ on: Bool) async throws -> Bool {
        let json = try await post("/api/plugins/mirror", PluginRequests.mirror(on))
        return json["mirror"]?.bool ?? on
    }

    /// 设置 npm 源，返回现在用的源。
    public func setPluginRegistry(_ url: String) async throws -> PluginRegistry {
        PluginRegistry(json: try await post("/api/plugins/registry", PluginRequests.registry(url))["registry"] ?? .null)
    }

    /// 把内置订阅（id）的账号迁到它的插件上；插件没装时主机会先装。
    public func movePluginProvider(_ id: String) async throws {
        _ = try await patient().post("/api/provider/move", PluginRequests.move(id))
    }

    /// 插件的供应商（登录状态）与它们声明的开关，都来自 `GET /api/providers`。
    public func pluginProviders() async throws -> WebPluginProviders { WebPluginProviders(json: try await get("/api/providers")) }

    /// 主机保存的图片（`file:<名字>` → `GET /api/icons/<名字>`）。
    public func pluginIcon(_ icon: String) async throws -> Data? {
        guard icon.hasPrefix("file:") else { return nil }
        let name = String(icon.dropFirst(5))
        guard !name.isEmpty, !name.contains("/") else { return nil }
        var request = try makeRequest("/api/icons/" + name)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return data
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
