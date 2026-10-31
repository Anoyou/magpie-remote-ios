import Foundation

// 「管理」页用到的 magpie Web 接口（端口 3430）数据。契约见 spec/web-api.md（contract/web-contract.json）。
// 每个类型都保留 `raw`（主机返回的整份对象）：保存时要以它为基础整份回写。

// MARK: 设置 / 版本

public struct WebSettings: Hashable, Sendable {
    public var version: String?
    public var lan: Bool
    public var gateway: String?
    public var lanURLs: [String]

    public init(json: WebJSON) {
        version = json["version"]?.string
        lan = json["lan"]?.bool ?? false
        gateway = json["gateway"]?.string
        lanURLs = json["lanURLs"]?.strings ?? []
    }
}

// MARK: 供应商

public struct WebProviderModel: Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// 是否对 Agent 开放。
    public var on: Bool

    public var displayName: String { name.isEmpty ? id : name }
}

public struct WebProvider: Hashable, Identifiable, Sendable {
    public var raw: WebJSON

    public init(raw: WebJSON) { self.raw = raw }

    public var id: String { raw["id"]?.string ?? "" }
    public var name: String { raw["name"]?.string ?? id }
    public var icon: String { raw["icon"]?.string ?? "" }
    public var preset: String { raw["preset"]?.string ?? "" }
    public var host: String { raw["host"]?.string ?? "" }
    public var chat: String { raw["chat"]?.string ?? "" }
    public var responses: String { raw["responses"]?.string ?? "" }
    public var anthropic: String { raw["anthropic"]?.string ?? "" }
    public var gemini: String { raw["gemini"]?.string ?? "" }
    public var off: Bool { raw["off"]?.bool ?? false }
    public var ready: Bool { raw["ready"]?.bool ?? false }
    /// 用户明确勾选的模型；空表示用默认选择。
    public var chosen: [String] { raw["chosen"]?.strings ?? [] }
    public var fallback: [String] { raw["fallback"]?.strings ?? [] }
    public var headers: [String: String] {
        (raw["headers"]?.object ?? [:]).compactMapValues(\.string)
    }
    public var exposed: Int { raw["exposed"]?.int ?? models.filter(\.on).count }
    public var keySet: Bool { raw["key"]?["set"]?.bool ?? false }
    public var keyMasked: String { raw["key"]?["masked"]?.string ?? "" }
    /// 订阅账号（Codex / Claude 等登录得来的）供应商：在 App 里只改模型与开关，其余到网页里改。
    public var isAccount: Bool {
        guard let account = raw["account"] else { return false }
        return !account.isNull
    }
    public var listError: String? { raw["listError"]?.string }
    public var models: [WebProviderModel] {
        (raw["models"]?.array ?? []).compactMap { model in
            guard let id = model["id"]?.string else { return nil }
            return WebProviderModel(id: id, name: model["name"]?.string ?? "", on: model["on"]?.bool ?? false)
        }
    }

    /// 地址的简短说明（列表副标题）。
    public var subtitle: String {
        if isAccount { return "订阅账号" }
        if !host.isEmpty { return host }
        return preset.isEmpty ? "自定义" : preset
    }
}

public struct WebProviders: Hashable, Sendable {
    public var providers: [WebProvider]
    public var raw: WebJSON

    public init(json: WebJSON) {
        raw = json
        providers = (json["providers"]?.array ?? []).map(WebProvider.init(raw:))
    }

    public subscript(id: String) -> WebProvider? { providers.first { $0.id == id } }

    /// 可直接添加的预设（只需填 Key）。
    public var presets: [WebPreset] {
        (raw["presets"]?.array ?? []).compactMap { preset in
            guard let id = preset["id"]?.string, !id.isEmpty else { return nil }
            return WebPreset(id: id, name: preset["name"]?.string ?? id)
        }
    }
}

public struct WebPreset: Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
}

// MARK: 路由组

public struct WebGroupMember: Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var ready: Bool
}

public struct WebGroup: Hashable, Identifiable, Sendable {
    public var raw: WebJSON

    public init(raw: WebJSON) { self.raw = raw }

    public var id: String { raw["id"]?.string ?? "" }
    public var name: String { raw["name"]?.string ?? id }
    public var members: [String] { raw["members"]?.strings ?? [] }
    public var routing: String { raw["routing"]?.string ?? "" }
    public var disabled: Bool { raw["disabled"]?.bool ?? false }
    /// magpie 自动发现的组：App 里只能开关，不能编辑或删除。
    public var auto: Bool { raw["auto"]?.bool ?? false }
    public var hidden: Bool { raw["hidden"]?.bool ?? false }
    public var ready: Bool { raw["ready"]?.bool ?? false }
    public var ref: String { raw["ref"]?.string ?? "group/" + id }
    public var memberInfo: [WebGroupMember] {
        (raw["memberInfo"]?.array ?? []).compactMap { member in
            guard let id = member["id"]?.string else { return nil }
            let name: String
            if let provider = member["name"]?.string, let model = member["model"]?.string {
                name = "\(provider) · \(model)"
            } else {
                name = id
            }
            return WebGroupMember(id: id, name: name, ready: member["ready"]?.bool ?? false)
        }
    }
}

/// 可放进路由组的模型（`GET /api/groups` → `models`）。
public struct WebModelRef: Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var providerName: String
}

public struct WebGroups: Hashable, Sendable {
    public var groups: [WebGroup]
    public var models: [WebModelRef]
    public var raw: WebJSON

    public init(json: WebJSON) {
        raw = json
        groups = (json["groups"]?.array ?? []).map(WebGroup.init(raw:))
        models = (json["models"]?.array ?? []).compactMap { model in
            guard let id = model["id"]?.string else { return nil }
            return WebModelRef(id: id,
                               name: model["name"]?.string ?? id,
                               providerName: model["providerName"]?.string ?? model["provider"]?.string ?? "")
        }
    }
}

// MARK: Agent

public struct WebAgentOption: Hashable, Identifiable, Sendable {
    public var value: String
    public var label: String
    public var note: String
    public var group: String
    public var id: String { value }

    public init(value: String, label: String = "", note: String = "", group: String = "") {
        self.value = value
        self.label = label
        self.note = note
        self.group = group
    }

    public var title: String {
        if !label.isEmpty { return label }
        if !note.isEmpty { return note }
        return value.isEmpty ? "默认" : value
    }
}

public struct WebAgentField: Hashable, Identifiable, Sendable {
    public var key: String
    public var label: String
    public var value: String
    public var options: [WebAgentOption]
    public var id: String { key }

    /// 当前值对应的选项名称。
    public var currentTitle: String {
        if value.isEmpty { return "默认" }
        return options.first { $0.value == value }?.title ?? value
    }
}

public struct WebAgent: Hashable, Identifiable, Sendable {
    public var raw: WebJSON

    public init(raw: WebJSON) { self.raw = raw }

    public var id: String { raw["id"]?.string ?? "" }
    public var name: String { raw["name"]?.string ?? id }
    public var path: String { raw["path"]?.string ?? "" }
    /// 已接入 magpie（主机可能给 null）。
    public var wired: Bool { raw["wired"]?.bool ?? false }
    public var fields: [WebAgentField] {
        (raw["fields"]?.array ?? []).compactMap { field in
            guard let key = field["key"]?.string else { return nil }
            let options = (field["options"]?.array ?? []).map { option in
                WebAgentOption(value: option["value"]?.string ?? "",
                               label: option["label"]?.string ?? "",
                               note: option["note"]?.string ?? "",
                               group: option["group"]?.string ?? "")
            }
            return WebAgentField(key: key, label: field["label"]?.string ?? key, value: field["value"]?.string ?? "", options: options)
        }
    }
    /// 模型选择字段（契约：`fields[0]`，key 为 "model"）。
    public var modelField: WebAgentField? { fields.first { $0.key == "model" } ?? fields.first }
}

public struct WebState: Hashable, Sendable {
    public var agents: [WebAgent]
    /// 需要重启 Agent 等提示（英文原文）。
    public var notice: String?

    public init(json: WebJSON) {
        agents = (json["agents"]?.array ?? []).map(WebAgent.init(raw:))
        notice = json["notice"]?.string.flatMap { $0.isEmpty ? nil : $0 }
    }
}

// MARK: 网关密钥

public struct WebCallerKey: Hashable, Identifiable, Sendable {
    public var raw: WebJSON

    public init(raw: WebJSON) { self.raw = raw }

    public var id: String { raw["id"]?.string ?? "" }
    public var name: String { raw["name"]?.string ?? "" }
    public var off: Bool { raw["off"]?.bool ?? false }
    /// 「在局域网共享」自带的密钥（名为 Magpie）。
    public var lan: Bool { raw["lan"]?.bool ?? false }
    public var masked: String { raw["masked"]?.string ?? "" }
    public var readOnly: Bool { raw["readOnly"]?.bool ?? false }
    public var issues: Bool { raw["issues"]?.bool ?? false }
    public var issuer: String? { raw["issuer"]?.string }
    /// 到期时间（主机给的可读文本，原样显示）。
    public var expires: String? { raw["expires"]?.string }
    public var models: [String] { raw["models"]?.strings ?? [] }

    /// 额度一句话（例：「每月 $20.00，已用 $0.00」）。
    public var limitSummary: String? {
        guard let limit = raw["limit"], limit.object != nil else { return nil }
        let period: String
        switch limit["period"]?.string ?? "" {
        case "day": period = "每天"
        case "week": period = "每周"
        case "month": period = "每月"
        case "days": period = "每 \(limit["days"]?.int ?? 0) 天"
        case "hours": period = "每 \(limit["hours"]?.int ?? 0) 小时"
        default: period = ""
        }
        var parts: [String] = []
        if let cost = limit["cost"]?.double, cost > 0 { parts.append(String(format: "$%.2f", cost)) }
        if let tokens = limit["tokens"]?.int, tokens > 0 { parts.append("\(tokens) tokens") }
        guard !parts.isEmpty else { return nil }
        var text = period + " " + parts.joined(separator: " / ")
        if let used = raw["used"], let cost = used["cost"]?.double, limit["cost"]?.double != nil {
            text += String(format: "，已用 $%.2f", cost)
        }
        return text
    }
}

public struct WebCallerKeys: Hashable, Sendable {
    public var keys: [WebCallerKey]
    /// 刚创建 / 轮换 / 复制得到的明文（只出现这一次）；其余操作为 nil。
    public var secret: String?

    public init(json: WebJSON) {
        keys = (json["keys"]?.array ?? []).map(WebCallerKey.init(raw:))
        secret = json["secret"]?.string.flatMap { $0.isEmpty ? nil : $0 }
    }
}

// MARK: 临时密钥（网关 /v1/magpie/keys，需要签发密钥）

public struct IssuedKey: Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// POST 返回明文；GET 返回脱敏值。
    public var key: String
    public var expires: String?
    public var expired: Bool
    public var models: [String]

    public init(json: WebJSON) {
        id = json["id"]?.string ?? ""
        name = json["name"]?.string ?? ""
        key = json["key"]?.string ?? ""
        expires = json["expires"]?.string
        expired = json["expired"]?.bool ?? false
        models = json["models"]?.strings ?? []
    }

    public static func list(_ json: WebJSON) -> [IssuedKey] {
        (json["keys"]?.array ?? []).map(IssuedKey.init(json:))
    }
}
