import Foundation

// 「管理 › 插件」用到的 magpie Web 接口数据（magpie 源码 internal/gui/plugins.go、builtins.go、pluginpage.go，
// 以及 internal/plugin、internal/pluginrt）。契约见 contract/web-contract.json。
// 字段随版本增减，一律宽松解码：缺字段用默认值，并保留 `raw`。

// MARK: 已安装的插件（GET /api/plugins）

/// 插件从哪里装来的（与 magpie 的 plugin.IsPath / IsGit 相同的判断）。
public enum PluginSource: String, Hashable, Sendable {
    case npm, git, folder

    public init(spec: String) {
        if Self.isPath(spec) {
            self = .folder
        } else if Self.isGit(spec) {
            self = .git
        } else {
            self = .npm
        }
    }

    static func isPath(_ spec: String) -> Bool {
        spec.hasPrefix("file://") || spec.hasPrefix(".") || spec.hasPrefix("/") || spec.hasPrefix("\\")
            || spec.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil
    }

    static func isGit(_ spec: String) -> Bool {
        let pattern = #"^(?:(?:github|gitlab|bitbucket):|git\+[a-z]+://|git://)\S+$|^https?://(?:www\.)?(?:github\.com|gitlab\.com|bitbucket\.org)/\S+$|^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9_.-]+(?:#\S+)?$"#
        return !isPath(spec) && spec.range(of: pattern, options: .regularExpression) != nil
    }

    public var title: String {
        switch self {
        case .npm: "npm"
        case .git: "Git 仓库"
        case .folder: "本机文件夹"
        }
    }
}

/// 插件给 magpie 窗口加的页面（`magpie.page`）。
public struct WebPluginPageInfo: Hashable, Sendable {
    public var title: String
    public var replaces: String
    public var reads: [String]
}

public struct WebPlugin: Hashable, Identifiable, Sendable {
    public var raw: WebJSON

    public init(raw: WebJSON) { self.raw = raw }

    /// 安装时写的规格（npm 包名、`github:owner/repo`、路径…），也是所有操作的 `spec`。
    public var spec: String { raw["spec"]?.string ?? "" }
    public var id: String { spec }
    public var off: Bool { raw["off"]?.bool ?? false }
    public var enabled: Bool { !off }
    public var source: PluginSource { PluginSource(spec: spec) }
    /// 加载失败的原因。
    public var error: String? { raw["error"]?.string.flatMap { $0.isEmpty ? nil : $0 } }
    public var providers: [String] { raw["providers"]?.strings ?? [] }
    public var version: String { raw["version"]?.string ?? "" }
    /// npm 上的最新版本（主机上次问到的）。
    public var latest: String { raw["latest"]?.string ?? "" }
    public var icon: String { raw["icon"]?.string ?? "" }
    public var ownName: String { raw["ownName"]?.string ?? "" }
    public var commit: String { raw["commit"]?.string ?? "" }
    public var head: String { raw["head"]?.string ?? "" }
    /// 插件现在的选项（`plugins.json` 里的 options，作为第二个参数交给插件）。
    public var options: [String: WebJSON] { raw["options"]?.object ?? [:] }
    /// 包里建议的选项（还没设置时编辑器从它开始）。
    public var optionsExample: [String: WebJSON] { raw["optionsExample"]?.object ?? [:] }
    public var page: WebPluginPageInfo? {
        guard let page = raw["page"]?.object else { return nil }
        return WebPluginPageInfo(title: page["title"]?.string ?? "", replaces: page["replaces"]?.string ?? "",
                                 reads: page["reads"]?.strings ?? [])
    }
    public var panelTitles: [String] { (raw["panels"]?.array ?? []).compactMap { $0["title"]?.string ?? $0["slot"]?.string } }
    public var toolNames: [String] { (raw["tools"]?.array ?? []).compactMap { $0["name"]?.string } }
    public var isMiddleware: Bool { raw["isMiddleware"]?.bool ?? false }
    public var isGateway: Bool { raw["isGateway"]?.bool ?? false }
    public var isAgent: Bool { raw["isAgent"]?.bool ?? false }

    /// 包名（不带版本）：与 magpie 的 plugin.Name 相同；git 插件用主机给的 `package`。
    public var packageName: String {
        switch source {
        case .folder: return spec
        case .git:
            let package = raw["package"]?.string ?? ""
            return package.isEmpty ? spec : package
        case .npm:
            if let at = spec.lastIndex(of: "@"), at != spec.startIndex { return String(spec[..<at]) }
            return spec
        }
    }

    /// 列表里显示的名字：包自己起的名字，否则它登录的供应商，否则包名。
    public var displayName: String {
        if !ownName.isEmpty { return ownName }
        if providers.count == 1, let only = providers.first, !only.isEmpty { return only }
        return packageName
    }

    /// 主机已知的可用更新（不主动去问 npm）。
    public var hasKnownUpdate: Bool {
        switch source {
        case .npm: return !latest.isEmpty && !version.isEmpty && PluginVersion.isNewer(latest, than: version)
        case .git: return !commit.isEmpty && !head.isEmpty && commit != head
        case .folder: return false
        }
    }

    /// 插件提供了什么（列表副标题）。
    public var kinds: [String] {
        var out: [String] = []
        if !providers.isEmpty { out.append("供应商：" + providers.joined(separator: "、")) }
        if isMiddleware { out.append("网关中间件") }
        if isGateway { out.append("网关") }
        if isAgent { out.append("Agent") }
        if page != nil { out.append("页面") }
        if !panelTitles.isEmpty { out.append("面板") }
        if !toolNames.isEmpty { out.append("工具 \(toolNames.count) 个") }
        return out
    }
}

public struct WebPlugins: Hashable, Sendable {
    public var raw: WebJSON
    public var plugins: [WebPlugin]

    public init(json: WebJSON) {
        raw = json
        plugins = (json["plugins"]?.array ?? []).map(WebPlugin.init(raw:))
    }

    /// 主机上是否已有 Bun（没有时添加第一个插件会先下载 Bun，比较慢）。
    public var bun: Bool { raw["bun"]?.bool ?? false }
    public var bunVersion: String { raw["bunVersion"]?.string ?? "" }
    /// 读不到插件时的原因。
    public var error: String? { raw["error"]?.string.flatMap { $0.isEmpty ? nil : $0 } }
    public var mirror: Bool { raw["mirror"]?.bool ?? false }

    public subscript(spec: String) -> WebPlugin? { plugins.first { $0.spec == spec } }
}

// MARK: 检查更新（POST /api/plugins/check）

public struct PluginVersionCheck: Hashable, Identifiable, Sendable {
    public enum Status: String, Sendable {
        /// 有新版本。
        case update
        case current
        /// 没问到（`why` 说明原因）。
        case unknown
        /// 本机文件夹，没有版本可比。
        case folder
        /// git 仓库，无法比较提交。
        case git
        case other
    }

    public var raw: WebJSON
    public init(raw: WebJSON) { self.raw = raw }

    public var spec: String { raw["spec"]?.string ?? "" }
    public var id: String { spec }
    public var package: String { raw["package"]?.string ?? "" }
    public var version: String { raw["version"]?.string ?? "" }
    public var latest: String { raw["latest"]?.string ?? "" }
    public var status: Status { Status(rawValue: raw["status"]?.string ?? "") ?? .other }
    public var why: String { raw["why"]?.string ?? "" }
    public var error: String { raw["error"]?.string ?? "" }
    public var off: Bool { raw["off"]?.bool ?? false }
    /// magpie 会不会自己更新它（社区官方插件）。
    public var auto: Bool { raw["auto"]?.bool ?? false }

    /// 一行中文说明。
    public var summary: String {
        switch status {
        case .update:
            return latest.isEmpty ? "有更新" : "有更新：v\(latest)"
        case .current:
            return "已是最新"
        case .folder:
            return "本机文件夹，无版本"
        case .git:
            return "无法比较提交"
        case .unknown, .other:
            switch why {
            case "offline": return "检查失败：主机连不上 npm"
            case "limited": return "检查失败：请求太频繁，稍后再试"
            case "registry": return "检查失败：npm 返回错误"
            case "missing": return "检查失败：npm 上没有这个包"
            default: return error.isEmpty ? "无法检查" : "检查失败：\(error)"
            }
        }
    }
}

public struct WebPluginCheck: Hashable, Sendable {
    public var at: String?
    public var checks: [PluginVersionCheck]
    public var state: WebPlugins?

    public init(json: WebJSON) {
        at = json["at"]?.string
        checks = (json["plugins"]?.array ?? []).map(PluginVersionCheck.init(raw:))
        state = json["state"].flatMap { $0.object == nil ? nil : WebPlugins(json: $0) }
    }

    public var updates: [PluginVersionCheck] { checks.filter { $0.status == .update && !$0.off } }

    public var summary: String {
        let asked = checks.filter { [.update, .current, .unknown].contains($0.status) }
        let unknown = asked.filter { $0.status == .unknown }
        if asked.isEmpty { return checks.isEmpty ? "还没有安装插件" : "没有可以检查版本的插件" }
        if unknown.count == asked.count { return unknown[0].summary }
        var text = updates.isEmpty ? (unknown.isEmpty ? "所有插件都是最新的" : "检查到的插件都是最新的") : "\(updates.count) 个插件有更新"
        if !unknown.isEmpty { text += "；\(unknown.count) 个无法检查" }
        return text
    }
}

// MARK: 内置插件（GET/POST /api/plugins/builtin）

/// 内置插件的一项设置（pluginrt.Schema 的一个属性）。
public struct PluginSetting: Hashable, Identifiable, Sendable {
    public enum Kind: String, Sendable { case boolean, integer, number, string, other }

    public var key: String
    public var kind: Kind
    public var title: String
    public var detail: String
    public var choices: [WebJSON]
    public var minimum: Double?
    public var maximum: Double?
    public var defaultValue: WebJSON

    public var id: String { key }

    /// 设置当前值：主机给的 config，否则默认值。
    public func value(in config: [String: WebJSON]) -> WebJSON { config[key] ?? defaultValue }

    /// 把用户在表单里输入的文字转成这项设置的 JSON 值；不合法时为 nil。
    public func parse(_ text: String) -> WebJSON? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .boolean:
            switch trimmed.lowercased() {
            case "true", "1", "on", "是": return .bool(true)
            case "false", "0", "off", "否": return .bool(false)
            default: return nil
            }
        case .integer:
            guard let value = Int64(trimmed), inRange(Double(value)) else { return nil }
            return .int(value)
        case .number:
            guard let value = Double(trimmed), value.isFinite, inRange(value) else { return nil }
            return value.rounded() == value && abs(value) < 1e15 ? .int(Int64(value)) : .double(value)
        case .string:
            if !choices.isEmpty, !choices.contains(.string(text)) { return nil }
            return .string(text)
        case .other:
            return nil
        }
    }

    private func inRange(_ value: Double) -> Bool {
        if let minimum, value < minimum { return false }
        if let maximum, value > maximum { return false }
        return true
    }
}

public struct WebBuiltinPlugin: Hashable, Identifiable, Sendable {
    public var raw: WebJSON
    public init(raw: WebJSON) { self.raw = raw }

    public var id: String { raw["id"]?.string ?? "" }
    /// 主机给的英文名称。
    public var name: String { raw["name"]?.string ?? id }
    public var sub: String { raw["sub"]?.string ?? "" }
    /// 中文名称（magpie 网页的中文译名），不认识的 id 用英文原名。
    public var title: String { BuiltinPluginText.names[id] ?? name }
    public var detail: String { BuiltinPluginText.subs[id] ?? sub }
    /// 正在运行（显示中）。
    public var on: Bool { raw["on"]?.bool ?? false }
    /// 用户自己的选择（plugins.yml）。
    public var chosen: Bool { raw["chosen"]?.bool ?? on }
    public var state: String { raw["state"]?.string ?? "" }
    public var why: String? { raw["why"]?.string.flatMap { $0.isEmpty ? nil : $0 } }
    public var inUse: Int { raw["inUse"]?.int ?? 0 }
    /// 「正在使用」的说明（英文，主机给的）。
    public var use: String? { raw["use"]?.string.flatMap { $0.isEmpty ? nil : $0 } }
    public var broken: String? { raw["broken"]?.string.flatMap { $0.isEmpty ? nil : $0 } }
    public var config: [String: WebJSON] { raw["config"]?.object ?? [:] }

    /// 正在使用的内置插件不能关；plugins.yml 读不了时什么都不能改。
    public var canToggle: Bool { broken == nil && !(chosen && inUse > 0) }

    public var stateText: String {
        switch state {
        case "active": "运行中"
        case "pending": "等待依赖"
        case "failed": "启动失败"
        case "off", "disposed": "已关闭"
        default: state
        }
    }

    /// 设置项，按 `x-order` 排列。
    public var settings: [PluginSetting] {
        guard let schema = raw["schema"], let properties = schema["properties"]?.object else { return [] }
        let order = schema["x-order"]?.strings ?? []
        let keys = order.filter { properties[$0] != nil } + properties.keys.filter { !order.contains($0) }.sorted()
        return keys.compactMap { key in
            guard let property = properties[key] else { return nil }
            return PluginSetting(
                key: key,
                kind: PluginSetting.Kind(rawValue: property["type"]?.string ?? "") ?? .other,
                title: property["title"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? key,
                detail: property["description"]?.string ?? "",
                choices: property["enum"]?.array ?? [],
                minimum: property["minimum"]?.double,
                maximum: property["maximum"]?.double,
                defaultValue: property["default"] ?? .null)
        }
    }
}

public struct WebBuiltinPlugins: Hashable, Sendable {
    public var plugins: [WebBuiltinPlugin]

    public init(json: WebJSON) {
        plugins = (json.array ?? []).map(WebBuiltinPlugin.init(raw:))
    }

    public subscript(id: String) -> WebBuiltinPlugin? { plugins.first { $0.id == id } }
}

/// 内置插件的中文名称与说明（与 magpie 网页 i18n.js 的中文译文一致）。
enum BuiltinPluginText {
    static let names: [String: String] = [
        "budget": "密钥限额", "gateway": "网关页面", "groups": "路由组", "library": "资源库",
        "middleware": "JS 网关插件", "otel": "可观测性", "redact": "隐私遮盖", "rotation": "路由策略",
        "routing": "路由", "search": "联网搜索", "sessions": "会话", "tools": "插件工具",
        "usage": "用量", "warmups": "预热与签到",
    ]
    static let subs: [String: String] = [
        "budget": "让每个网关密钥只用到你为它设的 Token 数或估算费用",
        "gateway": "网关的状态与密钥、客户端如何连接、它的模型和最近的调用",
        "groups": "把几个模型当作一个给 Agent 选：每个请求发给合适的模型，一个失败时换下一个",
        "library": "指令、MCP 服务器、技能和 Hooks，统一管理，分发给每个 Agent",
        "middleware": "运行 JavaScript 网关插件：Agent 请求和回复上的中间件、路由方式和用量观察者",
        "otel": "把每个请求的追踪和指标发送到 OpenTelemetry 收集器，比如 Langfuse",
        "redact": "密钥、个人信息和你自己的词以占位符发给服务商，回来时还原",
        "rotation": "智能以外的路由方式：按顺序、轮流、用量少的优先、重置前用完、按权重、免费优先、速度优先和最便宜优先",
        "routing": "每个请求经网关路由的过程、它比较过的账号和各自的回应，以及你的路由组",
        "search": "不能联网搜索的模型，借能搜索的提供商或搜索 API 来搜",
        "sessions": "Agent 的历史对话：查看、搜索、继续和导出",
        "tools": "把插件提供的工具通过一个 MCP 服务器给每个智能体用",
        "usage": "你的额度、花费及其去向、每个请求，以及上下文窗口里装了什么",
        "warmups": "在你选的时间开启订阅的用量窗口，并领取厂商的每日签到额度",
    ]
}

// MARK: 插件市场（GET /api/plugins/listings）

public struct WebPluginListing: Hashable, Identifiable, Sendable {
    public var raw: WebJSON
    public init(raw: WebJSON) { self.raw = raw }

    public var package: String { raw["package"]?.string ?? "" }
    public var id: String { package }
    public var name: String { raw["name"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? package }
    public var kind: String { raw["kind"]?.string ?? "" }
    public var community: Bool { raw["community"]?.bool ?? false }
    public var replaces: String { raw["replaces"]?.string ?? "" }
    public var providers: [String] { raw["providers"]?.strings ?? [] }
    public var latest: String { raw["npm"]?["version"]?.string ?? "" }
    public var weekly: Int { raw["npm"]?["weekly"]?.int ?? 0 }

    /// 简介：市场的中文简介，否则英文，否则 npm 的 description。
    public var summary: String {
        let summary = raw["summary"]?.object ?? [:]
        for language in ["zh", "en"] {
            if let text = summary[language]?.string, !text.isEmpty { return text }
        }
        return raw["npm"]?["description"]?.string ?? ""
    }

    public var kindTitle: String {
        switch kind {
        case "middleware": "网关中间件"
        case "agent": "Agent"
        case "tools": "工具"
        case "page": "页面"
        default: "供应商"
        }
    }
}

public struct WebPluginListings: Hashable, Sendable {
    public var listings: [WebPluginListing]

    public init(json: WebJSON) {
        listings = (json["listings"]?.array ?? []).map(WebPluginListing.init(raw:)).filter { !$0.package.isEmpty }
    }

    public subscript(package: String) -> WebPluginListing? { listings.first { $0.package == package } }
}

// MARK: 插件页面 / 面板（GET /api/plugin-pages、/api/plugin-panels）

public struct WebPluginPage: Hashable, Identifiable, Sendable {
    public var raw: WebJSON
    public init(raw: WebJSON) { self.raw = raw }

    public var spec: String { raw["spec"]?.string ?? "" }
    /// 网页里的页面键：用 `/?view=<key>` 在 magpie 网页里打开。
    public var key: String { raw["key"]?.string ?? "" }
    public var id: String { key }
    public var name: String { raw["name"]?.string ?? "" }
    public var replaces: String { raw["replaces"]?.string ?? "" }
    public var reads: [String] { raw["reads"]?.strings ?? [] }
    /// 页面文件本身（`/_magpie/plugin/<token>/…`），只供参考：它要在 magpie 网页框架里运行。
    public var url: String { raw["url"]?.string ?? "" }

    /// 标题：中文译名优先。
    public var title: String {
        let titles = raw["titles"]?.object ?? [:]
        for language in ["zh", "zh-CN", "zh-Hans"] {
            if let text = titles[language]?.string, !text.isEmpty { return text }
        }
        if let text = raw["title"]?.string, !text.isEmpty { return text }
        return name.isEmpty ? key : name
    }
}

public struct WebPluginPanel: Hashable, Identifiable, Sendable {
    public var raw: WebJSON
    public init(raw: WebJSON) { self.raw = raw }

    public var spec: String { raw["spec"]?.string ?? "" }
    public var key: String { raw["key"]?.string ?? "" }
    public var id: String { key }
    /// 面板所在的 magpie 页面（如 `providers`、`usage`）。
    public var slot: String { raw["slot"]?.string ?? "" }
    public var title: String {
        let titles = raw["titles"]?.object ?? [:]
        for language in ["zh", "zh-CN", "zh-Hans"] {
            if let text = titles[language]?.string, !text.isEmpty { return text }
        }
        if let text = raw["title"]?.string, !text.isEmpty { return text }
        return raw["name"]?.string ?? key
    }

    public static func list(_ json: WebJSON) -> [WebPluginPanel] {
        (json.array ?? []).map(WebPluginPanel.init(raw:)).filter { !$0.key.isEmpty }
    }
}

extension WebPluginPage {
    public static func list(_ json: WebJSON) -> [WebPluginPage] {
        (json.array ?? []).map(WebPluginPage.init(raw:)).filter { !$0.key.isEmpty }
    }
}

// MARK: 插件供应商的开关（GET /api/providers 的 plugins[].options，POST /api/settings/plugin-option）

public struct PluginProviderOption: Hashable, Identifiable, Sendable {
    /// 插件自己的供应商 id（OpenCode 的 id，开关按它保存）。
    public var provider: String
    public var providerName: String
    public var spec: String
    public var key: String
    public var label: String
    public var detail: String
    /// 打开前要用户同意的说明。
    public var confirm: String
    public var on: Bool

    public var id: String { provider + "/" + key }

    public init(provider: String, providerName: String, spec: String, key: String, label: String,
                detail: String = "", confirm: String = "", on: Bool) {
        self.provider = provider
        self.providerName = providerName
        self.spec = spec
        self.key = key
        self.label = label
        self.detail = detail
        self.confirm = confirm
        self.on = on
    }

    /// `GET /api/providers` 里每个插件供应商声明的开关。
    public static func list(providers json: WebJSON) -> [PluginProviderOption] {
        var out: [PluginProviderOption] = []
        for sub in json["plugins"]?.array ?? [] {
            let pid = sub["pid"]?.string ?? ""
            guard !pid.isEmpty else { continue }
            for option in sub["options"]?.array ?? [] {
                guard let key = option["key"]?.string, !key.isEmpty else { continue }
                out.append(PluginProviderOption(
                    provider: pid, providerName: sub["name"]?.string ?? pid, spec: sub["spec"]?.string ?? "",
                    key: key, label: option["label"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? key,
                    detail: option["description"]?.string ?? "", confirm: option["confirm"]?.string ?? "",
                    on: option["on"]?.bool ?? (option["default"]?.bool ?? false)))
            }
        }
        return out
    }
}

// MARK: 版本比较

public enum PluginVersion {
    /// `a` 是否比 `b` 新（按数字段比较，忽略开头的 v 与预发布后缀）。
    public static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            var s = Substring(s.trimmingCharacters(in: .whitespaces))
            if s.first == "v" || s.first == "V" { s = s.dropFirst() }
            let core = s.split(whereSeparator: { $0 == "-" || $0 == "+" }).first ?? ""
            return core.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
