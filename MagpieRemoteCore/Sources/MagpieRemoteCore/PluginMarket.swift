import Foundation

// 插件页（magpie 网页 internal/gui/assets/plugins.js、registry.js）的数据与规则，照官方实现移植：
// 「发现」的分区与卡片、GitHub 上的非官方插件、npm 搜索与 README、「已安装」每行的状态与说明。
// 接口：GET /api/plugins/github、/api/plugins/npm、/api/plugins/git、/api/plugins/search、/api/plugins/page，
// POST /api/plugins/mirror、/api/plugins/registry、/api/plugins/prefer、/api/provider/move。

// MARK: 规格（plugins.js 的 name / isPath / isGit / label / ghRepo / gitWeb）

public enum PluginSpec {
    /// 包名（去掉版本）。文件夹的路径整个就是名字（C:\Users\me@corp\… 里的 @ 不是版本）。
    public static func name(_ spec: String) -> String {
        if PluginSource.isPath(spec) { return spec }
        guard let at = spec.lastIndex(of: "@"), at > spec.startIndex else { return spec }
        let rest = spec[spec.index(after: at)...]
        return rest.contains("/") ? spec : String(spec[..<at])
    }

    /// 列表里的名字：文件夹用最后一级目录名。
    public static func label(_ spec: String) -> String {
        let n = name(spec)
        guard PluginSource.isPath(n) else { return n }
        var trimmed = n
        while let last = trimmed.last, last == "/" || last == "\\" { trimmed.removeLast() }
        let last = trimmed.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        return last.isEmpty ? n : last
    }

    public static func isPath(_ spec: String) -> Bool { PluginSource.isPath(spec) }
    public static func isGit(_ spec: String) -> Bool { PluginSource.isGit(spec) }
    /// npm 上有它的版本（文件夹、git 仓库都没有）。
    public static func onNPM(_ spec: String) -> Bool { !isPath(spec) && !isGit(spec) }

    /// 规格指向的 GitHub 仓库（owner/repo，小写）；不是 GitHub 时为空。
    public static func githubRepo(_ spec: String) -> String {
        let pattern = #"^(?:github:|(?:git\+)?(?:https?|ssh|git)://(?:[^@/\s]+@)?(?:www\.|ssh\.)?github\.com(?::\d+(?=/))?[/:])([^/#\s]+/[^/#\s]+?)(?:\.git)?(?:[/#].*)?$"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: spec, range: NSRange(spec.startIndex..., in: spec)),
           let range = Range(match.range(at: 1), in: spec) {
            return spec[range].lowercased()
        }
        if isGit(spec), let regex = try? NSRegularExpression(pattern: #"^([^:/#]+/[^:/#]+)(?:#.*)?$"#),
           let match = regex.firstMatch(in: spec, range: NSRange(spec.startIndex..., in: spec)),
           let range = Range(match.range(at: 1), in: spec) {
            return spec[range].lowercased()
        }
        return ""
    }

    /// git 插件在网页上的地址（「源码」链接）。
    public static func gitWeb(_ spec: String) -> String {
        var s = spec
        if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]) }
        let hosts = ["github": "github.com", "gitlab": "gitlab.com", "bitbucket": "bitbucket.org"]
        if let colon = s.firstIndex(of: ":"), let host = hosts[String(s[..<colon])] {
            return "https://\(host)/" + s[s.index(after: colon)...]
        }
        if !s.contains(":"), s.split(separator: "/", omittingEmptySubsequences: false).count >= 2, !s.hasPrefix("/") {
            return "https://github.com/" + s
        }
        var u = s
        if u.hasPrefix("git+") { u.removeFirst(4) }
        if u.hasSuffix(".git") { u.removeLast(4) }
        return u.hasPrefix("http://") || u.hasPrefix("https://") ? u : ""
    }

    /// 两个提交是否相同（短 sha 是长 sha 的前缀）。
    public static func sameCommit(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a.count > b.count ? a.hasPrefix(b) : b.hasPrefix(a)
    }

    /// 「安装」会替换的同名插件用的来源写法（plugins.js 的 sourceOf）。
    static func source(_ spec: String) -> String {
        if isGit(spec) { return spec }
        var s = spec
        if s.hasPrefix("npm:") { s = String(s.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
        return "npm:" + name(s)
    }
}

// MARK: 插件的种类

/// 插件是什么（plugins.js 的 KINDS）：供应商、网关中间件、Agent、工具、页面、面板。
public enum PluginKind: String, CaseIterable, Hashable, Sendable {
    case provider = "pv", middleware = "mw", agent = "ag", tools = "tl", page = "pg", panels = "pn"

    /// 市场里的 kind 字段对应的种类。
    public init(listing kind: String) {
        switch kind {
        case "middleware", "hooks": self = .middleware
        case "agent": self = .agent
        case "tools": self = .tools
        case "page": self = .page
        default: self = .provider
        }
    }

    public var title: String {
        switch self {
        case .provider: "供应商"
        case .middleware: "中间件"
        case .agent: "Agent"
        case .tools: "工具"
        case .page: "页面"
        case .panels: "面板"
        }
    }

    public var detail: String {
        switch self {
        case .provider: "登录一个订阅，提供它的模型"
        case .middleware: "在 magpie 网关里运行，处理智能体发出的请求和收到的回复"
        case .agent: "添加一个 magpie 没有内置的 Agent：在 Agent 页选好模型，它就走 magpie"
        case .tools: "通过 magpie 的 MCP 服务器，给每个 Agent 提供它自己的工具"
        case .page: "为侧边栏添加一个自己的页面。它与 magpie 的其余部分隔离运行，只能读取这一行列出的内容"
        case .panels: "在 magpie 自己的页面中添加面板。面板与 magpie 的其他部分隔离运行，只能读取其条目列出的内容"
        }
    }

    /// 没有图标时显示的 SF Symbol。
    public var symbol: String {
        switch self {
        case .provider: "powerplug"
        case .middleware: "point.3.connected.trianglepath.dotted"
        case .agent: "terminal"
        case .tools: "wrench.adjustable"
        case .page, .panels: "macwindow"
        }
    }
}

// MARK: npm 说的（GET /api/plugins/npm、市场 listings[].npm、搜索结果）

public struct WebPluginNPM: Hashable, Sendable {
    public var raw: WebJSON
    public init(raw: WebJSON) { self.raw = raw }

    /// npm 上的最新版本；没有这个包时为空。
    public var version: String { raw["version"]?.string ?? "" }
    public var description: String { raw["description"]?.string ?? "" }
    public var publisher: String { raw["publisher"]?.string ?? "" }
    public var license: String { raw["license"]?.string ?? "" }
    public var homepage: String { raw["homepage"]?.string ?? "" }
    public var repository: String { raw["repository"]?.string ?? "" }
    public var weekly: Int { raw["weekly"]?.int ?? 0 }
    public var icon: String { raw["icon"]?.string ?? "" }
    /// 问过 npm 但它什么都没说（官方页面标成 `u`）：当作「可以安装」，过一会儿再问。
    public var unknown: Bool { raw["u"] != nil }

    public static let unknownAnswer = WebPluginNPM(raw: ["weekly": 0, "u": 1])

    /// `GET /api/plugins/npm` 的回答：包名 → npm 说的。
    public static func map(_ json: WebJSON) -> [String: WebPluginNPM] {
        (json["npm"]?.object ?? [:]).mapValues(WebPluginNPM.init(raw:))
    }
}

// MARK: GitHub 上打了 magpie-plugin 标签的仓库（GET /api/plugins/github）

public struct WebTaggedRepo: Hashable, Sendable {
    public var raw: WebJSON
    public init(raw: WebJSON) { self.raw = raw }

    /// 「安装」用的规格：npm 上有就用包名，否则 github:owner/repo。
    public var spec: String { raw["spec"]?.string ?? "" }
    public var repo: String { raw["repo"]?.string ?? "" }
    public var url: String { raw["url"]?.string ?? "" }
    public var owner: String { raw["owner"]?.string ?? "" }
    public var description: String { raw["description"]?.string ?? "" }
    public var stars: Int { raw["stars"]?.int ?? 0 }
    public var license: String {
        let license = raw["license"]?.string ?? ""
        return license.isEmpty || license == "NOASSERTION" ? (raw["pkgLicense"]?.string ?? license) : license
    }
    public var pushed: String { raw["pushed"]?.string ?? "" }
    /// 仓库 package.json 里的包名。
    public var package: String { raw["package"]?.string ?? "" }
    public var version: String { raw["version"]?.string ?? "" }
    public var kind: String { raw["kind"]?.string ?? "" }
    public var icon: String { raw["icon"]?.string ?? "" }
}

public struct WebTaggedRepos: Hashable, Sendable {
    public var repos: [WebTaggedRepo]
    public var topic: String
    /// 列表不是 GitHub 完整回答的原因（连不上、限流…）。
    public var error: String
    /// slow / limited / 空。
    public var why: String
    /// 找到但没能读取的仓库数。
    public var missing: Int

    public init(json: WebJSON) {
        repos = (json["repos"]?.array ?? []).map(WebTaggedRepo.init(raw:)).filter { !$0.spec.isEmpty && !$0.repo.isEmpty }
        topic = json["topic"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "magpie-plugin"
        error = json["error"]?.string ?? ""
        why = json["why"]?.string ?? ""
        missing = json["missing"]?.int ?? 0
    }

    /// 页面上的原因（官方 ghWhy）：`kept` = 仍显示着之前的卡片。
    public func reason(kept: Bool) -> String {
        let error: String
        switch why {
        case "slow": error = "GitHub 响应超时"
        case "limited": error = "GitHub 暂时限制了请求"
        default: error = self.error
        }
        if missing > 0 {
            return kept ? "GitHub 上还有 \(missing) 个插件没能读取：\(error)" : "GitHub 找到了 \(missing) 个仓库，但一个都没能读取：\(error)"
        }
        return kept ? "无法连接 GitHub，下面是之前获取的列表：\(error)" : "无法连接 GitHub：\(error)"
    }
}

// MARK: 市场里的一张卡片（推荐列表、GitHub 仓库、npm 搜索结果共用）

extension WebPluginListing {
    public var icon: String { raw["icon"]?.string ?? "" }
    public var npm: WebPluginNPM? { raw["npm"].flatMap { $0.object == nil ? nil : WebPluginNPM(raw: $0) } }
    /// GitHub 上的非官方插件。
    public var github: WebTaggedRepo? { raw["github"].flatMap { $0.object == nil ? nil : WebTaggedRepo(raw: $0) } }
    public var pluginKind: PluginKind { PluginKind(listing: kind) }
    /// 卡片上的图标：市场给的，否则 npm 包给的。
    public var logo: String { icon.isEmpty ? (npm?.icon ?? "") : icon }
    /// 作者一栏：社区插件写「magpie 社区」，否则 npm 发布者，否则包名。
    public var author: String { community ? "magpie 社区" : (npm?.publisher).flatMap { $0.isEmpty ? nil : $0 } ?? package }

    /// npm 的回答放进卡片（官方 merge）。
    public func with(npm: WebPluginNPM?) -> WebPluginListing {
        guard let npm else { return self }
        var raw = self.raw
        raw["npm"] = npm.raw
        return WebPluginListing(raw: raw)
    }

    /// GitHub 仓库当作市场卡片（官方 ghListing）。
    public static func github(_ repo: WebTaggedRepo) -> WebPluginListing {
        var raw: WebJSON = [
            "package": .string(repo.spec), "name": .string(repo.repo.split(separator: "/").last.map(String.init) ?? repo.repo),
            "kind": .string(repo.kind), "github": repo.raw,
            "npm": ["version": .string(repo.version), "publisher": .string(repo.owner), "repository": .string(repo.url),
                    "license": .string(repo.license), "weekly": 0],
        ]
        if !repo.icon.isEmpty { raw["icon"] = .string(repo.icon) }
        if !repo.description.isEmpty { raw["summary"] = ["en": .string(repo.description)] }
        return WebPluginListing(raw: raw)
    }

    /// npm 搜索的一条结果当作卡片。
    public static func hit(_ hit: WebJSON) -> WebPluginListing? {
        guard let package = hit["package"]?.string, !package.isEmpty else { return nil }
        return WebPluginListing(raw: ["package": .string(package), "name": .string(package), "npm": hit])
    }

    /// 已安装但市场里没有的插件，为详情页凑一张卡片（官方 installedRow 的 onclick）。
    public static func installed(_ plugin: WebPlugin, name: String) -> WebPluginListing {
        if plugin.source == .git {
            return WebPluginListing(raw: ["package": .string(plugin.spec), "name": .string(name), "icon": .string(plugin.icon),
                                          "npm": ["version": .string(plugin.version), "repository": .string(PluginSpec.gitWeb(plugin.spec))]])
        }
        var npm: WebJSON = [:]
        if !plugin.latest.isEmpty { npm["version"] = .string(plugin.latest) }
        return WebPluginListing(raw: ["package": .string(PluginSpec.name(plugin.spec)), "name": .string(name),
                                      "icon": .string(plugin.icon), "npm": npm])
    }

    /// 搜索框的匹配（官方 match）。
    public func matches(_ query: String) -> Bool {
        let f = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !f.isEmpty else { return true }
        let words = [name, package, summary, providers.joined(separator: " "), npm?.publisher ?? ""]
        if words.joined(separator: " ").lowercased().contains(f) { return true }
        // 市场的英文简介也能搜到
        return (raw["summary"]?.object ?? [:]).values.compactMap(\.string).joined(separator: " ").lowercased().contains(f)
    }
}

// MARK: 已安装插件的更多字段（GET /api/plugins，pluginEntryJSON）

public struct PluginAutoUpdate: Hashable, Sendable {
    public var from: String
    public var to: String
    public var at: String
}

public struct PluginMiddlewareState: Hashable, Sendable {
    public var raw: WebJSON
    public var hooks: [String] { raw["hooks"]?.strings ?? [] }
    public var events: [String] { raw["events"]?.strings ?? [] }
    public var error: String { raw["error"]?.string ?? "" }
    public var calls: Int { raw["calls"]?.int ?? 0 }
    public var avgMicros: Double { raw["avgMicros"]?.double ?? 0 }
    public var failures: Int { raw["failures"]?.int ?? 0 }
    public var lastError: String { raw["lastError"]?.string ?? "" }
    public var strategies: [String] { raw["strategies"]?.strings ?? [] }
    public var orders: Int { raw["orders"]?.int ?? 0 }
    public var usage: Bool { raw["usage"]?.bool ?? false }
    public var rows: Int { raw["rows"]?.int ?? 0 }
    public var dropped: Int { raw["dropped"]?.int ?? 0 }
}

public struct PluginGatewayState: Hashable, Sendable {
    public var raw: WebJSON
    public var calls: Int { raw["calls"]?.int ?? 0 }
    public var failures: Int { raw["failures"]?.int ?? 0 }
    public var avgMillis: Double { raw["avgMillis"]?.double ?? 0 }
    public var lastOutcome: String { raw["lastOutcome"]?.string ?? "idle" }
    public var lastBytes: Int { raw["lastBytes"]?.int ?? 0 }
}

public struct PluginAgentInfo: Hashable, Sendable {
    public var id: String
    public var name: String
    public var icon: String
    public var error: String
}

public struct PluginClash: Hashable, Sendable {
    /// 供应商 id（OpenCode 的）。
    public var id: String
    /// 现在承载它的插件规格。
    public var by: String
    public var with: [String]
    public var name: String
}

public struct PluginTool: Hashable, Sendable {
    public var name: String
    public var description: String
    /// 在 MCP 服务器上的名字。
    public var mcp: String
    public var shown: String { mcp.isEmpty ? name : mcp }
}

public struct PluginPlace: Hashable, Sendable {
    /// 面板的位置（slot）或菜单项所在的菜单（menu）。
    public var place: String
    public var title: String
}

extension WebPlugin {
    public var autoUpdated: PluginAutoUpdate? {
        guard let u = raw["autoUpdated"], let to = u["to"]?.string else { return nil }
        return PluginAutoUpdate(from: u["from"]?.string ?? "", to: to, at: u["at"]?.string ?? "")
    }
    /// 迁到它上面的内置订阅（id）。
    public var moved: [String] { raw["moved"]?.strings ?? [] }
    public var serves: [String] { raw["serves"]?.strings ?? [] }
    public var middleware: PluginMiddlewareState? { raw["middleware"].flatMap { $0.object == nil ? nil : PluginMiddlewareState(raw: $0) } }
    public var gateway: PluginGatewayState? { raw["gateway"].flatMap { $0.object == nil ? nil : PluginGatewayState(raw: $0) } }
    public var agent: PluginAgentInfo? {
        guard let a = raw["agent"], a.object != nil else { return nil }
        return PluginAgentInfo(id: a["id"]?.string ?? "", name: a["name"]?.string ?? "", icon: a["icon"]?.string ?? "", error: a["error"]?.string ?? "")
    }
    public var middlewareOnly: Bool { raw["middlewareOnly"]?.bool ?? false }
    public var gatewayOnly: Bool { raw["gatewayOnly"]?.bool ?? false }
    public var inMagpieOnly: Bool { raw["inMagpieOnly"]?.bool ?? false }
    /// 供应商列表是插件自己的回答（不是旧的空列表）。
    public var named: Bool { raw["named"]?.bool ?? false }
    public var panels: [PluginPlace] {
        (raw["panels"]?.array ?? []).map { PluginPlace(place: $0["slot"]?.string ?? "", title: $0["title"]?.string ?? "") }
    }
    public var panelReads: [String] { raw["panelReads"]?.strings ?? [] }
    public var actions: [PluginPlace] {
        (raw["actions"]?.array ?? []).map { PluginPlace(place: $0["menu"]?.string ?? "", title: $0["title"]?.string ?? "") }
    }
    public var clashes: [PluginClash] {
        (raw["clashes"]?.array ?? []).compactMap { c in
            guard let id = c["id"]?.string else { return nil }
            return PluginClash(id: id, by: c["by"]?.string ?? "", with: c["with"]?.strings ?? [], name: c["name"]?.string ?? id)
        }
    }
    public var tools: [PluginTool] {
        (raw["tools"]?.array ?? []).compactMap { t in
            guard let name = t["name"]?.string else { return nil }
            return PluginTool(name: name, description: t["description"]?.string ?? "", mcp: t["mcp"]?.string ?? "")
        }
    }

    /// 有更新（npm 新版本，或 git 仓库有新提交）——停用的插件不提供「更新」（官方 updateButton）。
    public var updateOffered: Bool { !off && (npmUpdate || gitBehind) }
    public var npmUpdate: Bool { !latest.isEmpty && !version.isEmpty && PluginVersion.isNewer(latest, than: version) }
    public var gitBehind: Bool { source == .git && !commit.isEmpty && !head.isEmpty && !PluginSpec.sameCommit(commit, head) }

    /// 只有工具，不登录任何东西。
    var toolsOnly: Bool { !tools.isEmpty && providers.isEmpty }

    /// 行上的种类标签（官方 installedRow 的 kindChip 顺序）。
    public var kindChips: [(kind: PluginKind, title: String)] {
        var out: [(PluginKind, String)] = []
        if middleware != nil || isMiddleware { out.append((.middleware, PluginKind.middleware.title)) }
        if gateway != nil || isGateway { out.append((.middleware, "请求 Hook")) }
        if agent != nil || isAgent { out.append((.agent, PluginKind.agent.title)) }
        if !tools.isEmpty { out.append((.tools, PluginKind.tools.title)) }
        if page != nil { out.append((.page, PluginKind.page.title)) }
        if !panels.isEmpty { out.append((.panels, PluginKind.panels.title)) }
        let notProvider = gatewayOnly || middlewareOnly || inMagpieOnly || toolsOnly || (middleware != nil && !isMiddleware) || (agent != nil && !isAgent)
        if !providers.isEmpty || !notProvider { out.append((.provider, PluginKind.provider.title)) }
        return out
    }

    /// 没有图标时用的种类（官方 logo 的第三个参数）。
    public var logoKind: PluginKind {
        if middlewareOnly { return .middleware }
        if inMagpieOnly && isAgent && !isMiddleware { return .agent }
        if inMagpieOnly && (page != nil || !panels.isEmpty) && !isAgent && !isMiddleware { return .page }
        if toolsOnly && page == nil && middleware == nil && agent == nil { return .tools }
        return .provider
    }

    /// 能编辑 JSON 选项（网关中间件、请求 Hook；官方只给这两种「选项」按钮）。
    public var hasOptionsEditor: Bool { !off && (isGateway || (middleware.map { $0.error.isEmpty } ?? isMiddleware)) }
}

/// 可以把内置订阅的账号迁到插件上（`movable`，provider.MoveCandidate）。
public struct PluginMoveCandidate: Hashable, Sendable {
    public var id: String
    public var name: String
    public var package: String
    public var accounts: Int
    public var error: String
}

/// 插件安装和问 npm 用的 npm 源（plugin.RegistryInUse）。
public struct PluginRegistry: Hashable, Sendable {
    public var url: String
    public var from: String
    public var variable: String
    public var path: String

    public init(json: WebJSON) {
        url = json["url"]?.string ?? ""
        from = json["from"]?.string ?? ""
        variable = json["var"]?.string ?? ""
        path = json["path"]?.string ?? ""
    }

    /// 来源说明（registry.js 的 from）。
    public var fromText: String {
        switch from {
        case "magpie": "在此设置"
        case "env": "来自 \(variable)"
        case "shell": "来自终端环境的 \(variable)"
        case "bunfig", "npmrc": "来自 \(path)"
        case "china": "国内镜像"
        default: "npm 官方源"
        }
    }

    /// 是在 magpie 里设置的（才有「使用默认」）。
    public var setHere: Bool { from == "magpie" }

    public var json: WebJSON { ["url": .string(url), "from": .string(from), "var": .string(variable), "path": .string(path)] }
}

extension WebPlugins {
    /// 这台 magpie 能弹出系统的文件夹选择器（App 里用不到，`magpie web` 也没有）。
    public var picker: Bool { raw["picker"]?.bool ?? false }
    public var movable: [PluginMoveCandidate] {
        (raw["movable"]?.array ?? []).compactMap { c in
            guard let id = c["id"]?.string else { return nil }
            return PluginMoveCandidate(id: id, name: c["name"]?.string ?? id, package: c["package"]?.string ?? "",
                                       accounts: c["accounts"]?.int ?? 0, error: c["error"]?.string ?? "")
        }
    }
    /// npm 源；旧版 magpie 没有这一项时为 nil。
    public var registry: PluginRegistry? {
        guard let r = raw["registry"], r.object != nil, !(r["url"]?.string ?? "").isEmpty else { return nil }
        return PluginRegistry(json: r)
    }
}

// MARK: 插件的供应商（GET /api/providers 的 plugins[]）

public struct PluginSub: Hashable, Identifiable, Sendable {
    /// magpie 的供应商 id。
    public var id: String
    /// OpenCode 的 id。
    public var pid: String
    public var name: String
    public var icon: String
    public var spec: String
    public var signedIn: Bool

    public init(id: String, pid: String, name: String, icon: String = "", spec: String, signedIn: Bool) {
        self.id = id
        self.pid = pid
        self.name = name
        self.icon = icon
        self.spec = spec
        self.signedIn = signedIn
    }

    public static func list(providers json: WebJSON) -> [PluginSub] {
        (json["plugins"]?.array ?? []).compactMap { p in
            guard let pid = p["pid"]?.string, !pid.isEmpty else { return nil }
            return PluginSub(id: p["id"]?.string ?? pid, pid: pid, name: p["name"]?.string ?? pid, icon: p["icon"]?.string ?? "",
                             spec: p["spec"]?.string ?? "", signedIn: p["signedIn"]?.bool ?? false)
        }
    }
}

/// `GET /api/providers` 里与插件有关的两部分：它们的供应商与开关。
public struct WebPluginProviders: Hashable, Sendable {
    public var subs: [PluginSub]
    public var options: [PluginProviderOption]

    public init(json: WebJSON) {
        subs = PluginSub.list(providers: json)
        options = PluginProviderOption.list(providers: json)
    }

    public init(subs: [PluginSub] = [], options: [PluginProviderOption] = []) {
        self.subs = subs
        self.options = options
    }
}

// MARK: README（GET /api/plugins/page?name=）

public struct WebPluginReadme: Hashable, Sendable {
    public var readme: String
    /// 最后更新（RFC3339）；0001 开头 = 未知。
    public var updated: String

    public init(json: WebJSON) {
        readme = json["readme"]?.string ?? ""
        updated = json["updated"]?.string ?? ""
    }

    public init(readme: String, updated: String) {
        self.readme = readme
        self.updated = updated
    }

    public var updatedDate: Date? {
        guard !updated.isEmpty, !updated.hasPrefix("0001") else { return nil }
        return PluginFormat.date(updated)
    }
}

// MARK: 一张卡片该显示的按钮（官方 actionFor）

public enum PluginCardAction: Hashable, Sendable {
    /// 还不知道有没有装 / npm 有没有它：转圈。
    case waiting
    case installing(String)
    case updating
    case moving
    /// npm 上还没有。
    case comingSoon
    case install
    /// 把内置订阅的账号迁过来（`here` = 已安装插件上的「迁移到这里」）。
    case move(PluginMoveCandidate, here: Bool)
    case switchOn(spec: String)
    case signIn(PluginSub)
    case update(spec: String, to: String)
    case signedIn(PluginSub)
    case installed

    public var title: String {
        switch self {
        case .waiting: ""
        case .installing(let text): text
        case .updating: "更新中…"
        case .moving: "正在迁移…"
        case .comingSoon: "即将上线"
        case .install: "安装"
        case .move: "迁移"
        case .switchOn: "启用"
        case .signIn: "登录"
        case .update: "更新"
        case .signedIn: "已登录"
        case .installed: "已安装"
        }
    }

    public var isBusy: Bool {
        switch self {
        case .waiting, .installing, .updating, .moving: true
        default: false
        }
    }
}

// MARK: 发现页的分区

public struct PluginSection: Hashable, Identifiable, Sendable {
    public enum ID: String, Sendable {
        case subscriptions, middleware, agents, tools, pages, suggested, github, npm
    }

    public var id: ID
    public var title: String
    public var hint: String
    public var cards: [WebPluginListing]
}

/// 「已安装」的排序（官方 NAME_SORTS）。
public enum PluginSort: String, CaseIterable, Sendable {
    case nameAscending = "name", nameDescending = "-name"

    public var title: String { self == .nameAscending ? "名称 A→Z" : "名称 Z→A" }
}

/// 插件页的全部规则：把已安装、推荐、GitHub、npm 的回答合在一起（官方 plugins.js 的 merge / entryOf / actionFor / drawBody）。
public struct PluginMarket: Sendable {
    public var state: WebPlugins?
    public var listings: [WebPluginListing]?
    public var tagged: [WebPluginListing]?
    public var npm: [String: WebPluginNPM]
    public var heads: [String: String]
    public var subs: [PluginSub]

    public init(state: WebPlugins?, listings: [WebPluginListing]?, tagged: [WebPluginListing]? = nil,
                npm: [String: WebPluginNPM] = [:], heads: [String: String] = [:], subs: [PluginSub] = []) {
        self.state = state
        self.listings = listings
        self.tagged = tagged
        self.npm = npm
        self.heads = heads
        self.subs = subs
    }

    /// npm 的回答放进卡片与已安装插件（官方 merge）。
    public var mergedListings: [WebPluginListing]? { listings?.map { $0.with(npm: npm[$0.package]) } }

    public var installed: [WebPlugin] {
        (state?.plugins ?? []).map { plugin in
            var raw = plugin.raw
            if PluginSpec.onNPM(plugin.spec), let latest = npm[PluginSpec.name(plugin.spec)]?.version, !latest.isEmpty {
                raw["latest"] = .string(latest)
            }
            if plugin.source == .git, let head = heads[plugin.spec], !head.isEmpty { raw["head"] = .string(head) }
            return WebPlugin(raw: raw)
        }
    }

    /// 安装了的那个（按包名，或 GitHub 卡片按仓库；官方 entryOf）。
    public func entry(for package: String) -> WebPlugin? {
        let repo = (tagged ?? []).first { $0.package == package }?.github?.repo.lowercased()
        return installed.first { e in
            PluginSpec.name(e.spec) == package || (repo.map { !$0.isEmpty && PluginSpec.githubRepo(e.spec) == $0 } ?? false)
        }
    }

    public func listing(for plugin: WebPlugin) -> WebPluginListing? {
        let package = PluginSpec.name(plugin.spec)
        return mergedListings?.first { $0.package == package }
    }

    /// 已安装插件显示的名字：市场的，否则 package.json 自己起的，否则包名 / 文件夹名（官方 shownName）。
    public func shownName(_ plugin: WebPlugin) -> String {
        if let name = listing(for: plugin)?.name, !name.isEmpty { return name }
        if !plugin.ownName.isEmpty { return plugin.ownName }
        if plugin.source == .git, let package = plugin.raw["package"]?.string, !package.isEmpty { return package }
        return PluginSpec.label(plugin.spec)
    }

    public func subs(for package: String) -> [PluginSub] { subs.filter { PluginSpec.name($0.spec) == package } }
    public func movable(for package: String) -> [PluginMoveCandidate] { (state?.movable ?? []).filter { $0.package == package } }

    /// 卡片上唯一的按钮（官方 actionFor）。`busy`：包名 / spec → 正在做的操作（add、upgrade、move…）。
    public func action(for package: String, listing: WebPluginListing?, busy: [String: String]) -> PluginCardAction {
        let e = entry(for: package)
        switch busy[package] {
        case "add": return .installing(state?.bun == false ? "正在下载 Bun…" : "安装中…")
        case "upgrade": return .updating
        case "move": return .moving
        default: break
        }
        if let e, busy[e.spec] == "upgrade" { return .updating }
        if state == nil || (e == nil && listing != nil && listing?.npm == nil) { return .waiting }
        guard let e else {
            if let listing, listing.github == nil, let npm = listing.npm, npm.version.isEmpty, !npm.unknown { return .comingSoon }
            if let c = movable(for: package).first { return .move(c, here: false) }
            return .install
        }
        if e.off { return .switchOn(spec: e.spec) }
        let subs = subs(for: package)
        let on = subs.first { $0.signedIn }
        if on == nil, let c = movable(for: package).first { return .move(c, here: true) }
        if on == nil, let out = subs.first(where: { !$0.signedIn }) { return .signIn(out) }
        if e.updateOffered { return .update(spec: e.spec, to: e.npmUpdate ? e.latest : "") }
        if let on { return .signedIn(on) }
        return .installed
    }

    /// 不带搜索词时的「发现」：只有 magpie 社区的，按种类分区（官方 drawBody）。
    public func discoverSections() -> [PluginSection] {
        guard let ls = mergedListings else { return [] }
        let community = ls.filter(\.community)
        func pick(_ kind: PluginKind) -> [WebPluginListing] { community.filter { $0.pluginKind == kind } }
        var out: [PluginSection] = []
        let parts: [(PluginSection.ID, PluginKind, String, String)] = [
            (.subscriptions, .provider, "订阅", "为 magpie 编写，与内置登录对照验证过"),
            (.middleware, .middleware, "网关中间件", "在 magpie 的网关里处理每个 agent 发出的请求和收到的回复，不论由哪个供应商提供"),
            (.agents, .agent, "Agent", "magpie 没有内置的 Agent，接入方式和内置的一样"),
            (.tools, .tools, "给 Agent 的工具", "每个 Agent 都能调用的工具，经由 magpie 的 MCP 服务器"),
            (.pages, .page, "页面", "在 magpie 窗口里自成一页，与其他部分隔离，只能读取它列出的内容"),
        ]
        for (id, kind, title, hint) in parts {
            let cards = pick(kind)
            if !cards.isEmpty { out.append(PluginSection(id: id, title: title, hint: hint, cards: cards)) }
        }
        return out
    }

    /// 带搜索词时的「推荐」（市场里所有匹配的，不限社区）。
    public func suggested(matching query: String) -> [WebPluginListing] { (mergedListings ?? []).filter { $0.matches(query) } }

    /// GitHub 上的非官方插件：市场已经列出的包不重复（官方 gh）。
    public func githubCards(matching query: String) -> [WebPluginListing] {
        let listed = Set((listings ?? []).map(\.package))
        return (tagged ?? []).filter { card in
            let package = card.github?.package ?? ""
            return !(!package.isEmpty && listed.contains(package)) && card.matches(query)
        }
    }

    /// npm 搜索结果里去掉上面已有卡片的包（官方 known）。
    public func npmCards(_ hits: [WebPluginListing]) -> [WebPluginListing] {
        let known = Set((listings ?? []).map(\.package) + (tagged ?? []).map(\.package))
        return hits.filter { !known.contains($0.package) }
    }

    /// 有新版本的已安装插件（官方 drawInstalled 的 outdated）。
    public var outdated: [WebPlugin] { installed.filter { $0.npmUpdate || ($0.gitBehind && !$0.off) } }

    public func sorted(_ sort: PluginSort) -> [WebPlugin] {
        let list = installed.sorted { a, b in
            shownName(a).localizedStandardCompare(shownName(b)) == .orderedAscending
        }
        return sort == .nameAscending ? list : list.reversed()
    }

    /// 能检查更新（npm 包或 git 仓库；文件夹没有版本）。
    public var canCheck: Bool { installed.contains { $0.source != .folder } }

    /// 「安装」会替换的同名插件（官方 namesakeOf）；`typed` = 用户在输入框里写的。
    public func namesake(of spec: String, typed: Bool = false) -> PluginReplacement? {
        let repo = PluginSpec.githubRepo(spec)
        let g = (tagged ?? []).first { $0.package == spec || (!repo.isEmpty && $0.github?.repo.lowercased() == repo) }?.github
        let package: String
        if let g { package = g.package }
        else if spec.hasPrefix("npm:") { package = PluginSpec.name(String(spec.dropFirst(4)).trimmingCharacters(in: .whitespaces)) }
        else if PluginSpec.onNPM(spec), !typed || spec.hasPrefix("@") { package = PluginSpec.name(spec) }
        else { package = "" }
        guard !package.isEmpty else { return nil }
        guard let e = installed.first(where: { x in
            (x.source == .git ? (x.raw["package"]?.string ?? "") : (PluginSpec.onNPM(x.spec) ? PluginSpec.name(x.spec) : "")) == package
        }) else { return nil }
        if repo.isEmpty ? (!PluginSpec.isGit(spec) && e.source != .git) : PluginSpec.githubRepo(e.spec) == repo { return nil }
        return PluginReplacement(old: PluginSpec.source(e.spec), new: PluginSpec.source(spec), package: package, off: e.off)
    }
}

/// 安装会替换掉的同名插件。
public struct PluginReplacement: Hashable, Sendable {
    public var old: String
    public var new: String
    public var package: String
    public var off: Bool

    public var title: String { "用 \(new) 替换 \(old)？" }
    public var message: String {
        let base = "\(new) 和 \(old) 都是 \(package) 这个包，两个只能装一个：\(old) 会被移除，它的选项和登录都会移交给 \(new)。"
        return off ? base + "\(old) 已停用，所以 \(new) 也会以停用状态安装。" : base
    }
}

// MARK: GitHub 区的筛选（官方 drawGh）

public struct PluginGitHubFilter: Hashable, Sendable {
    /// nil = 全部。
    public var kind: PluginKind?
    /// nil = 全部；true = 已安装；false = 未安装。
    public var installed: Bool?
    public var query: String

    public init(kind: PluginKind? = nil, installed: Bool? = nil, query: String = "") {
        self.kind = kind
        self.installed = installed
        self.query = query
    }

    /// 超过 6 个仓库才显示筛选条。
    public static func shows(for all: [WebPluginListing]) -> Bool { all.count > 6 }

    func matches(_ l: WebPluginListing) -> Bool {
        let f = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !f.isEmpty else { return true }
        let words = [l.name, l.github?.repo ?? "", l.github?.owner ?? "", l.package, l.summary]
        return words.joined(separator: " ").lowercased().contains(f)
    }

    /// 出现过的种类（市场顺序）。
    public static func kinds(in list: [WebPluginListing]) -> [PluginKind] {
        [.provider, .middleware, .agent, .tools, .page].filter { k in list.contains { $0.pluginKind == k } }
    }

    /// 各个选项会剩下多少（官方 n(k, h)）。
    public func count(_ list: [WebPluginListing], kind: PluginKind?, installed: Bool?, isInstalled: (WebPluginListing) -> Bool) -> Int {
        list.filter(matches).filter { (kind == nil || $0.pluginKind == kind) && (installed == nil || isInstalled($0) == installed) }.count
    }

    public func apply(_ list: [WebPluginListing], isInstalled: (WebPluginListing) -> Bool) -> [WebPluginListing] {
        list.filter(matches).filter { (kind == nil || $0.pluginKind == kind) && (installed == nil || isInstalled($0) == installed) }
    }
}

// MARK: 文字（官方页面的中文译文）

public enum PluginFormat {
    /// 下载量、Star 数：1.2k、15k、1.3M（官方 count）。
    public static func count(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: n >= 10_000_000 ? "%.0f" : "%.1f", Double(n) / 1e6) + "M" }
        if n >= 1_000 { return String(format: n >= 10_000 ? "%.0f" : "%.1f", Double(n) / 1e3) + "k" }
        return String(max(n, 0))
    }

    public static func date(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: text) { return d }
        // 纳秒：只留 3 位小数
        if let dot = text.firstIndex(of: "."), let end = text[dot...].dropFirst().firstIndex(where: { !$0.isNumber }) {
            let fraction = text[text.index(after: dot)..<end].prefix(3)
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: String(text[..<dot]) + "." + fraction + text[end...])
        }
        return nil
    }

    static let reads = ["usage:summary": "你的用量合计（按模型）", "providers:list": "你的服务商名称"]
    static let pages = ["sessions": "会话", "library": "资源库", "routing": "路由", "usage": "用量"]
    static let slots = ["agents": "「Agent」页面", "usage": "「用量」页面", "settings": "设置", "provider": "每个服务商的编辑页"]
    static let menus = ["provider": "供应商的菜单", "agent": "Agent 的菜单"]

    static func list(_ items: [String]) -> String { items.joined(separator: "、") }

    /// 插件页面能读什么（官方 pageLine）。
    public static func pageLine(_ page: WebPluginPageInfo) -> String {
        let reads = list(page.reads.map { Self.reads[$0] ?? $0 })
        if !page.replaces.isEmpty {
            let name = pages[page.replaces] ?? page.replaces
            return reads.isEmpty ? "取代「\(name)」页面，不读取 magpie 的任何内容" : "取代「\(name)」页面，可以读取\(reads)"
        }
        return reads.isEmpty ? "为侧边栏添加一个页面，不读取 magpie 的任何内容" : "为侧边栏添加一个页面，可读取\(reads)"
    }

    public static func panelsLine(_ panels: [PluginPlace], reads: [String]) -> String {
        var seen: [String] = []
        for p in panels where !seen.contains(p.place) { seen.append(p.place) }
        let places = list(seen.map { slots[$0] ?? $0 })
        let r = list(reads.map { Self.reads[$0] ?? $0 })
        return r.isEmpty ? "在\(places)中添加面板，不读取 magpie 的任何内容" : "在\(places)中添加面板，可以读取\(r)"
    }

    public static func actionsLine(_ actions: [PluginPlace]) -> String {
        var seen: [String] = []
        for a in actions where !seen.contains(a.place) { seen.append(a.place) }
        return "在\(list(seen.map { menus[$0] ?? $0 }))中添加菜单项，点击后打开它的页面"
    }

    static func number(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        f.groupingSize = 3
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    /// 网关中间件的一行：hooks、调用次数和耗时、路由、用量观察；失败另算（官方 mwLine）。
    public static func middlewareLine(_ m: PluginMiddlewareState) -> (text: String, failures: [String], isError: Bool) {
        if !m.error.isEmpty { return ("中间件没有加载：\(m.error)", [], true) }
        var parts: [String] = []
        if !m.hooks.isEmpty {
            var s = "网关中间件：\(list(m.hooks))"
            if m.calls > 0 {
                let us = m.avgMicros < 10 ? String(format: "%.1f", m.avgMicros) : number(Int(m.avgMicros.rounded()))
                s += " · 调用 \(number(m.calls)) 次，平均每次 \(us) µs"
            }
            parts.append(s)
        }
        if !m.strategies.isEmpty { parts.append("路由：\(list(m.strategies))" + (m.orders > 0 ? " · 已调用 \(number(m.orders)) 次" : "")) }
        if m.usage { parts.append("用量观察：\(number(m.rows)) 条") }
        var failures: [String] = []
        if m.failures > 0 { failures.append("\(number(m.failures)) 次失败") }
        if m.dropped > 0 { failures.append("丢弃 \(number(m.dropped)) 条") }
        return (parts.joined(separator: " · "), failures, false)
    }

    static let outcomes = [
        "idle": "等待请求", "ready": "已注入上下文", "empty": "没有匹配的上下文", "unbound": "Scope 未绑定",
        "unauthorized": "认证失败", "unavailable": "上下文服务不可用", "invalid": "上下文响应无效", "skipped": "已跳过请求",
        "cancelled": "请求已取消", "timeout": "召回超时", "error": "请求 Hook 失败",
    ]

    /// 请求 Hook 的一行（官方 gatewayLine）。
    public static func gatewayLine(_ g: PluginGatewayState) -> String {
        var text = "网关请求 Hook：" + (outcomes[g.lastOutcome] ?? "等待请求")
        if g.calls > 0 { text += " · 调用 \(number(g.calls)) 次，平均每次 \(String(format: "%.1f", g.avgMillis)) ms" }
        if g.lastBytes > 0 { text += " · 已注入 \(number(g.lastBytes)) 字节" }
        if g.failures > 0 { text += " · \(number(g.failures)) 次失败" }
        return text
    }

    public static func agentLine(_ a: PluginAgentInfo) -> (text: String, isError: Bool) {
        a.error.isEmpty ? ("把 \(a.name) 加到 Agent 页", false) : ("Agent 没有加载：\(a.error)", true)
    }

    public static func toolsLine(_ tools: [PluginTool]) -> String { "给每个智能体的工具：\(list(tools.map(\.shown)))" }

    /// 两个插件都登录同一个供应商时的一行（官方 clashLine）。
    public static func clashLines(_ plugin: WebPlugin, ownName: String, nameOf: (String) -> String) -> [(text: String, here: Bool)] {
        struct Group { var here: Bool; var others: [String]; var names: [String] }
        var groups: [Group] = []
        for c in plugin.clashes {
            let here = c.by == plugin.spec
            let others = here ? c.with : [c.by]
            if let i = groups.firstIndex(where: { $0.here == here && $0.others == others }) { groups[i].names.append(c.name) }
            else { groups.append(Group(here: here, others: others, names: [c.name])) }
        }
        return groups.map { g in
            let names = list(g.names)
            let copies = g.others.filter { nameOf($0) == ownName }
            if !copies.isEmpty, copies.count == g.others.count {
                let spec = list(copies)
                return (g.here ? "这个插件的另一份（\(spec)）也登录 \(names)；由这一份提供" : "这个插件的另一份（\(spec)）提供 \(names)", g.here)
            }
            let other = list(g.others.map(nameOf))
            return (g.here ? "\(other) 也能登录 \(names)，现由这个插件提供" : "\(names) 由同样登录它的 \(other) 提供", g.here)
        }
    }
}

// MARK: 检查更新的说明（官方 whyText / limitedText）

extension PluginVersionCheck {
    public var head: String { raw["head"]?.string ?? "" }
    public var commit: String { raw["commit"]?.string ?? "" }
    /// GitHub 限流：解除时间与是否带了 token。
    public var limitedUntil: String? { raw["limited"]?["until"]?.string }
    public var limitedWithToken: Bool { raw["limited"]?["token"]?.bool ?? false }
    public var isLimited: Bool { raw["limited"]?.object != nil }

    /// 为什么没问到（官方 whyText）。
    public var whyText: String {
        if PluginSpec.isGit(spec) {
            let reason: String
            if isLimited {
                let time = limitedUntil.flatMap(PluginFormat.date).map(Self.clock) ?? ""
                if limitedWithToken {
                    reason = time.isEmpty ? "你的 GitHub token 的请求额度暂时用完了" : "你的 GitHub token 的请求额度用完了，\(time) 恢复"
                } else {
                    reason = time.isEmpty
                        ? "没有 token 时 GitHub 每小时只允许 60 次请求，暂时用完了。可在 magpie「设置 › 网络与共享」里添加 GitHub token，提高到 5000 次。"
                        : "没有 token 时 GitHub 每小时只允许 60 次请求，已用完，\(time) 恢复。可在 magpie「设置 › 网络与共享」里添加 GitHub token，提高到 5000 次。"
                }
            } else {
                reason = error
            }
            return "无法向 \(spec) 查询最新提交：\(reason)"
        }
        switch why {
        case "offline": return "无法连接 npm，请检查网络或代理"
        case "limited": return "npm 暂时拒绝请求（请求过多），请几分钟后再试"
        case "missing": return "npm 上没有这个包"
        default: return "npm 返回错误：\(error)"
        }
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
