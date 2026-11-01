import Foundation

/// magpie 官方标志（供应商 / 模型厂商 / Agent 的 logo）怎么画，照搬网页 `internal/gui/assets/app.js` 的 `icon()`：
/// 主机在数据里直接给图标名（`icon` / `agentIcon` / `groupIcon`，即网页 `icons/` 下的文件名），
/// 名字以 `-color` 结尾或在 `pngIcons` 里的是彩色图，其余是单色图（跟随文字颜色）；
/// `generic` 是通用的立方体轮廓；空名字留一个空位，不编造图标。
/// 打包了哪些图、各 Agent / 预设对应哪个图，见生成的 `OfficialIconNames.swift`（scripts/gen-official-icons.py）。
public enum OfficialIcon {
    public enum Mark: Hashable, Sendable {
        /// 没有图标：留空位（网页 `.ic.blank`）。
        case blank
        /// 通用图标（网页 `generic`：立方体轮廓，次要文字颜色）。
        case generic
        /// 彩色标志，原样显示。`asset` 是资源目录里的名字（`Brand/…`）；`shrunk` 时画成 82% 大小。
        case color(asset: String, shrunk: Bool)
        /// 单色标志，按文字颜色着色。
        case mono(asset: String, shrunk: Bool)
    }

    /// 主机给的图标名 → 怎么画。
    public static func mark(_ name: String?) -> Mark {
        let name = (name ?? "").trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return .blank }
        if name == "generic" { return .generic }
        // `file:…` 是用户给自己供应商挑的图片，存在主机上；URL 也一样，App 不去取：画通用图标。
        if name.contains(":") || name.contains("/") { return .generic }
        // 网页里单色图加载失败会换成通用图标；没打包的名字同样处理。
        guard bundled.contains(name) else { return .generic }
        let asset = "Brand/" + name
        let small = shrunk.contains(name)
        if name.hasSuffix("-color") || pngIcons.contains(name) || name.hasPrefix("app-") {
            return .color(asset: asset, shrunk: small)
        }
        return .mono(asset: asset, shrunk: small)
    }

    /// 网页 `appIcon(id)`：导入应用（Agent 应用）的图标名。
    public static func app(_ id: String) -> String {
        switch id {
        case "claude-code": "claudecode-color"
        case "codex": "codex-color"
        case "opencode": "opencode"
        default: "app-\(id)"
        }
    }

    /// 模型厂商的标志：照 `internal/agent/icons.go` 的 `byFamily` 按模型 id 前缀认（"vendor/model" 取后半）。
    /// 认不出时返回 ""（不编造）。用于主机没给图标的地方。
    public static func model(_ modelID: String) -> String {
        var id = modelID.lowercased()
        if let slash = id.firstIndex(of: "/") { id = String(id[id.index(after: slash)...]) }
        for (prefix, icon) in byFamily where id.hasPrefix(prefix) { return icon }
        return ""
    }

    static let byFamily: [(String, String)] = [
        ("claude", "claude-color"),
        ("gpt", "openai"), ("o1", "openai"), ("o3", "openai"), ("o4", "openai"), ("codex", "openai"),
        ("gemini", "gemini-color"), ("gemma", "gemini-color"),
        ("deepseek", "deepseek-color"),
        ("grok", "xai"),
        ("kimi", "kimi"), ("moonshot", "kimi"),
        ("glm", "zhipu-color"),
        ("qwen", "qwen-color"), ("qwq", "qwen-color"),
        ("mistral", "mistral-color"), ("codestral", "mistral-color"), ("devstral", "mistral-color"), ("magistral", "mistral-color"),
        ("minimax", "minimax-color"),
        ("mimo", "mimocode"), ("xiaomi", "mimocode"),
        ("step", "stepfun-color"),
    ]

    /// 订阅账号的标志：照 `internal/provider/cards_kept.go` 的 `accountCard`、`google.go` 与
    /// `plugin_usage.go` 的 `movedCards`。不是订阅账号返回 ""。
    public static func account(_ provider: String) -> String {
        switch provider {
        case "claude": "claude-color"
        case "codex": "codex-color"
        case "copilot": "githubcopilot"
        case "qoder", "qoder-cn": "qoder"
        case "gemini": "geminicli-color"
        case "antigravity": "antigravity-color"
        case "zed": "zed"
        case "factory": "factory"
        case "mimo-app": "mimocode"
        case "commandcode-plan": "commandcode"
        case "kiro": "kiro-color"
        case "zcode": "zcode"
        case "workbuddy", "workbuddy-ai": "workbuddy-color"
        case "cursor": "cursor"
        case "grok": "xai"
        case "devin": "devin"
        default: ""
        }
    }

    /// 主机没给图标时，按供应商 id 认标志（照 `KnownFace`：先认订阅账号，再认供应商预设），
    /// 再否则 id 本身就是打包了的图标名。认不出返回 ""。
    public static func provider(_ id: String) -> String {
        let known = account(id)
        if !known.isEmpty { return known }
        if let preset = presetIcons[id] { return preset }
        return bundled.contains(id) ? id : ""
    }

    /// 主机没给图标时，按 Agent id 认标志（magpie 各 Agent 定义里的 Icon；很多 Agent 的图标名就是它的 id）。
    public static func agent(_ id: String) -> String {
        if let icon = agentIcons[id] { return icon }
        return bundled.contains(id) ? id : ""
    }

    /// 页面的官方导航图标（网页 index.html `#nav` 的线条图），按 `AppPage.rawValue` 认；
    /// 网页没有对应导航的页面返回 nil（继续用 SF Symbol）。按字符串认，页面增删时不用改这里。
    public static func navGlyph(page: String) -> String? {
        switch page {
        // 「主页」（Agent、供应商、额度合在一起，0.4.0 起）用网页默认首页 Agent 的导航图标；
        // agents / providers 是 0.3 存下的旧值，保留以便按字符串认。
        case "home", "agents": "Nav/nav-agents"
        case "sessions": "Nav/nav-sessions"
        case "providers": "Nav/nav-providers"
        case "routes": "Nav/nav-routing"
        case "keys": "Nav/nav-gateway"
        case "usage": "Nav/nav-usage"
        case "plugins": "Nav/nav-plugins"
        default: nil
        }
    }
}

// MARK: 各数据的标志（主机给的优先，没给时按官方的对应关系认）

public extension WebAgent {
    /// Agent 的标志名（`/api/state` 的 `icon`）。
    var officialIcon: String {
        if let icon = raw["icon"]?.string, !icon.isEmpty { return icon }
        return OfficialIcon.agent(id)
    }
}

public extension WebProvider {
    /// 供应商的标志名（`/api/providers` 的 `icon`；没有时按预设、再按 id 认）。
    var officialIcon: String {
        if !icon.isEmpty { return icon }
        let byPreset = preset.isEmpty ? "" : OfficialIcon.provider(preset)
        return byPreset.isEmpty ? OfficialIcon.provider(id) : byPreset
    }
}

public extension QuotaAccount {
    /// 额度卡的标志名（主机额度卡的 `icon`；旧版主机没有时按供应商 id 认）。
    var officialIcon: String {
        if let icon = cards.first?.icon, !icon.isEmpty { return icon }
        return OfficialIcon.provider(provider)
    }
}

public extension TraceSeat {
    /// 路由舞台上账号 / Key 行的标志（网页 `w.icon || w.preset || "generic"`）：主机给的 `icon` 优先，
    /// 再按 `preset` 认；旧版主机两样都没给时按供应商 id 认，认不出是 generic。
    var officialIcon: String {
        if !icon.isEmpty { return icon }
        if !preset.isEmpty {
            let byPreset = OfficialIcon.provider(preset)
            return byPreset.isEmpty ? preset : byPreset
        }
        let known = OfficialIcon.provider(provider)
        return known.isEmpty ? "generic" : known
    }
}

public extension UsageSummary {
    /// 用量分组（`breakdown(_:)` 的一项）的标志名：主机给的 `icon`，没有时按模型 / Agent / 供应商 id 认；
    /// 认不出返回 nil（不编造，留空位）。
    func officialIcon(for item: UsageBreakdownItem, in dimension: UsageDimension) -> String? {
        func given(_ groups: [UsageGroup]) -> String? {
            guard let icon = groups.first(where: { $0.id == item.id })?.icon, !icon.isEmpty else { return nil }
            return icon
        }
        let icon: String?
        switch dimension {
        case .model: icon = given(models) ?? OfficialIcon.model(models.first { $0.id == item.id }?.model ?? item.id)
        case .agent: icon = given(agents) ?? OfficialIcon.agent(item.id)
        case .account: icon = given(accounts) ?? accounts.first { $0.id == item.id }?.provider.map(OfficialIcon.provider)
        case .provider: icon = OfficialIcon.provider(item.id)
        case .callerKey: icon = given(callerKeys)
        }
        guard let icon, !icon.isEmpty else { return nil }
        return icon
    }
}
