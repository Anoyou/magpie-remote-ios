import Foundation

/// 「管理」页发给 magpie Web 接口的请求体。全部是纯函数，单元测试对照 fixture 校验。
public enum WebRequests {
    // MARK: 供应商

    /// 用户在 App 里能改的供应商字段。nil = 不改。
    public struct ProviderEdits: Hashable, Sendable {
        public var name: String?
        /// OpenAI 兼容的 Base URL（`chat`）。
        public var chat: String?
        /// 新的 API Key；nil 或空字符串 = 保留主机上已保存的。
        public var key: String?
        /// 对 Agent 开放的模型 id 集合。
        public var enabledModels: Set<String>?

        public init(name: String? = nil, chat: String? = nil, key: String? = nil, enabledModels: Set<String>? = nil) {
            self.name = name
            self.chat = chat
            self.key = key
            self.enabledModels = enabledModels
        }
    }

    /// `POST /api/provider/save` 编辑一个已有供应商。
    ///
    /// 主机端是「整份替换」：没发的字段（name、各 URL、models、fallback、headers、searches…）会被清空。
    /// 所以这里以主机返回的当前 `providerJSON` 为基础，按网页端编辑器的做法逐个回填，再叠加用户的修改；
    /// 「留空即保留」的字段（代理、并发、计价等）一律不发，交给主机保留。
    public static func providerSave(_ provider: WebProvider, edits: ProviderEdits = ProviderEdits()) -> WebJSON {
        let raw = provider.raw
        let picks = modelPicks(provider, enabled: edits.enabledModels)
        if provider.isAccount {
            // 订阅账号供应商：与网页端账号编辑器相同，只发模型与路由相关字段。
            var body: [String: WebJSON] = [
                "id": .string(provider.id),
                "models": .strings(picks.models),
                "noModels": .bool(picks.none),
                "bestInFamily": .bool(picks.best),
                "unlisted": .bool(raw["unlisted"]?.bool ?? false),
                "fallback": .strings(provider.fallback),
                "pinUpstream": .bool(raw["pinUpstream"]?.bool ?? false),
                "unredacted": .bool(raw["unredacted"]?.bool ?? false),
                "countFree": .bool(raw["countFree"]?.bool ?? false),
            ]
            if let hidden = raw["hiddenDrawers"], !hidden.isNull { body["hiddenDrawers"] = hidden }
            return .object(body)
        }

        var body: [String: WebJSON] = [
            "id": .string(provider.id),
            "from": .string(provider.id),
            "new": false,
            "name": .string(edits.name ?? provider.name),
            "preset": .string(provider.preset),
            "key": .string(edits.key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""),
            "chat": .string(edits.chat ?? provider.chat),
            "responses": .string(provider.responses),
            "anthropic": .string(provider.anthropic),
            "gemini": .string(provider.gemini),
            "catalog": .string(raw["catalog"]?.string ?? ""),
            "models": .strings(picks.models),
            "noModels": .bool(picks.none),
            "bestInFamily": .bool(picks.best),
            "fallback": .strings(provider.fallback),
            "headers": .object(provider.headers.mapValues(WebJSON.string)),
            "unlisted": .bool(raw["unlisted"]?.bool ?? false),
        ]
        for flag in ["searches", "pinUpstream", "unredacted", "countFree", "passUserAgent"] {
            body[flag] = .bool(raw[flag]?.bool ?? false)
        }
        // 主机在「为空 / 没发」时保留的字段：有值才原样带回。
        for field in ["extraBody", "replyHeaders", "hiddenDrawers"] {
            if let value = raw[field], !value.isNull { body[field] = value }
        }
        for field in ["decide", "baseAPI"] {
            if let value = raw[field]?.string, !value.isEmpty { body[field] = .string(value) }
        }
        if provider.preset.isEmpty {
            // 自定义供应商：图标、余额 / 模型列表地址会被替换，必须带回。
            for field in ["icon", "balanceURL", "balancePath", "balanceMethod", "modelsURL"] {
                if let value = raw[field]?.string, !value.isEmpty { body[field] = .string(value) }
            }
        }
        return .object(body)
    }

    /// 新的模型选择：models 为空且 noModels=false 表示用主机的默认选择。
    static func modelPicks(_ provider: WebProvider, enabled: Set<String>?) -> (models: [String], none: Bool, best: Bool) {
        guard let enabled else {
            let chosen = provider.chosen
            return (chosen, chosen.isEmpty && (provider.raw["noModels"]?.bool ?? false),
                    chosen.isEmpty && (provider.raw["bestInFamily"]?.bool ?? false))
        }
        // 保持主机列表里的顺序；列表里没有、但之前选过的（例如暂时下架）保留在最后。
        var ordered = provider.models.map(\.id).filter(enabled.contains)
        for id in provider.chosen where enabled.contains(id) && !ordered.contains(id) { ordered.append(id) }
        for id in enabled.sorted() where !ordered.contains(id) { ordered.append(id) }
        return (ordered, ordered.isEmpty, false)
    }

    /// 打开 / 关闭某个模型后要提交的模型集合。
    public static func toggledModels(_ provider: WebProvider, model: String, on: Bool) -> Set<String> {
        var current = Set(provider.models.filter(\.on).map(\.id))
        if on { current.insert(model) } else { current.remove(model) }
        return current
    }

    /// `POST /api/provider/save` 添加：自定义（OpenAI 兼容 Base URL）或预设（只需 Key）。
    public static func providerAdd(name: String, chat: String, key: String, preset: String? = nil) -> WebJSON {
        var body: [String: WebJSON] = ["new": true, "key": .string(key.trimmingCharacters(in: .whitespacesAndNewlines))]
        if let preset, !preset.isEmpty {
            body["preset"] = .string(preset)
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { body["name"] = .string(trimmed) }
        } else {
            body["name"] = .string(name.trimmingCharacters(in: .whitespacesAndNewlines))
            body["chat"] = .string(chat.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .object(body)
    }

    /// `POST /api/provider/delete|on|off|key|models` 等只需要 id 的操作。
    public static func providerID(_ id: String) -> WebJSON { ["id": .string(id)] }

    /// `POST /api/providers/arrange`：列表顺序 = 尝试顺序。
    public static func arrange(_ order: [String]) -> WebJSON { ["order": .strings(order)] }

    // MARK: 路由组

    /// `groupJSON` 里只读的展示字段：回写时去掉。
    static let groupComputedFields = ["ready", "memberInfo", "holds", "offers", "shared", "picked", "patterns",
                                      "decides", "ref", "classifierFailed"]

    /// `POST /api/groups/save`：整组覆盖，以主机返回的组为基础（规则、权重、路由方式等原样保留）。
    public static func groupSave(_ group: WebGroup?, id: String, name: String, members: [String]) -> WebJSON {
        var body = (group?.raw ?? [:]).removing(groupComputedFields)
        let newID = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        body["id"] = .string(newID)
        body["name"] = .string(name.trimmingCharacters(in: .whitespacesAndNewlines))
        body["members"] = .strings(members)
        if let group, group.id != newID { body["from"] = .string(group.id) }
        return body
    }

    public static func groupDelete(_ id: String) -> WebJSON { ["id": .string(id)] }
    public static func groupSwitch(_ id: String, on: Bool) -> WebJSON { ["id": .string(id), "on": .bool(on)] }

    // MARK: Agent

    /// `POST /api/set`：切换 Agent 的某个字段（模型是 "model"）。
    public static func setAgent(_ agent: String, field: String, value: String) -> WebJSON {
        ["agent": .string(agent), "field": .string(field), "value": .string(value)]
    }

    // MARK: 网关密钥

    public static func callerKeyAdd(name: String, readOnly: Bool) -> WebJSON {
        var body: [String: WebJSON] = ["name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines))]
        if readOnly { body["readOnly"] = true }
        return .object(body)
    }

    /// rotate-key / copy-key / on-key / off-key / remove-key。
    public static func callerKey(_ id: String) -> WebJSON { ["key": .string(id)] }

    /// rename-key：新名字（去掉首尾空白）。
    public static func callerKeyRename(_ id: String, name: String) -> WebJSON {
        ["key": .string(id), "name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines))]
    }

    /// access-key：`readOnly` 为 true 设为只读，false 恢复完整权限（明确发 false）。
    public static func callerKeyAccess(_ id: String, readOnly: Bool) -> WebJSON { ["key": .string(id), "readOnly": .bool(readOnly)] }

    /// 网关 `POST /v1/magpie/keys`：签发一把临时密钥。
    public static func issueKey(name: String, ttl: String, models: [String] = [], readOnly: Bool = false) -> WebJSON {
        var body: [String: WebJSON] = ["name": .string(name), "ttl": .string(ttl)]
        if !models.isEmpty { body["models"] = .strings(models) }
        if readOnly { body["readOnly"] = true }
        return .object(body)
    }
}

/// 网关密钥的操作（对应 `POST /api/caller-keys/{action}`）。
public enum CallerKeyAction: String, Sendable, CaseIterable {
    case add = "add-key"
    case rotate = "rotate-key"
    case copy = "copy-key"
    case on = "on-key"
    case off = "off-key"
    case remove = "remove-key"
    /// 改名（官方「重命名」）。
    case rename = "rename-key"
    /// 用量清零、重新开始一个周期（官方「重置额度」）。
    case resetLimit = "reset-limit-key"
    /// 只读 / 完整权限（官方「设为只读」「恢复完整权限」）。
    case access = "access-key"
}

/// 供应商的操作（对应 `POST /api/provider/{action}`）。
public enum ProviderAction: String, Sendable {
    case save, delete, on, off, key, models
    /// 多账号 / 多 Key 供应商自己的路由方式、会话保持、限流后排到最后。
    case route, affinity, sink
}

/// 路由组的操作（对应 `POST /api/groups/{action}`）。
public enum GroupAction: String, Sendable {
    case save, delete, `switch`
    /// 路由组顺序、手动路由的选中成员、自动发现开关、复制。
    case arrange, pick, found, copy
}
