import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// 一个供应商的多把 API Key（magpie internal/provider/keys.go）。
//
// - `GET /api/providers` 的 `keyList` 只给脱敏信息（id = Key 的指纹、name、masked、active、on…），从不给明文。
// - 明文按需取：`POST /api/provider/key {id, account: <key id>}` → `{"key": "..."}`（网页端编辑器的「显示」和每行的复制按钮）。
// - 增删改走 `POST /api/keys/{action}`，每次只动一把 Key，返回完整的 providersJSON。
// - `POST /api/provider/save` 里 `key` 留空 = 保留第一把；其余的 Key 主机始终原样保留（`in.Keys = old.Keys`），
//   所以 App 保存基本信息时不会丢掉没加载明文的 Key。

/// `keyList` 里的一把 Key（`provider.KeyInfo`）。顺序 = 请求尝试的顺序，第一把是 `active`。
public struct WebProviderKey: Hashable, Identifiable, Sendable {
    public var raw: WebJSON

    public init(raw: WebJSON) { self.raw = raw }

    /// Key 的指纹（sha256 前 5 字节的十六进制），作为各操作里的 `ref` / `account`。
    public var id: String { raw["id"]?.string ?? "" }
    public var name: String { raw["name"]?.string ?? "" }
    /// 主机给的脱敏写法（前 4 位…后 4 位；8 位以内全是圆点）。
    public var masked: String { raw["masked"]?.string ?? "" }
    /// 第一把：请求先发给它。
    public var active: Bool { raw["active"]?.bool ?? false }
    /// 在用（勾选）：第一把，或排在后面候补的。
    public var on: Bool { raw["on"]?.bool ?? false }
    /// 只用于某一种协议（空 = 都可以）。
    public var keyProtocol: String { raw["protocol"]?.string ?? "" }
    public var weight: Int { raw["weight"]?.int ?? 0 }
    public var plan: String { raw["plan"]?.string ?? "" }
    /// 网关因为失败暂时跳过它的原因（rate / credit / quota / auth …）；nil = 正常接请求。
    public var restWhy: String? { raw["rest"]?["why"]?.string }
    public var restUntil: Date? { raw["rest"]?["until"]?.string.flatMap(QuotaTime.parse) }

    /// 列表里显示的名字：有名字用名字，否则用脱敏写法（与网页端相同）。
    public var label: String { name.isEmpty ? masked : name }

    /// 是否正在休息（休息到的时间还没过）。
    public func resting(now: Date = Date()) -> Bool {
        guard restWhy != nil else { return false }
        guard let until = restUntil else { return true }
        return until > now
    }
}

/// 一把 Key 在列表里能做的操作，与网页端 renderKeyAccounts 的规则一致。
public struct ProviderKeyPermissions: Hashable, Sendable {
    /// 「停用 / 启用」：停用的 Key 总能启用；在用的只有在多把在用时才能停用（最后一把交给供应商自己的开关）。
    public var canSwitch: Bool
    /// 「删除」：不是第一把，或者有多把在用。
    public var canRemove: Bool
    /// 「设为首选」：在用但不是第一把。
    public var canMakeFirst: Bool
}

extension WebProvider {
    /// 它的 Key，按尝试顺序。订阅账号供应商没有 Key。
    public var keyList: [WebProviderKey] {
        (raw["keyList"]?.array ?? []).map(WebProviderKey.init(raw:)).filter { !$0.id.isEmpty }
    }

    /// 在用的 Key 有几把。
    public var keysOn: Int { keyList.filter(\.on).count }

    /// Key 留空时网页端「添加 Key」会用的公开 Key（例如 OpenCode Zen 的免费 Key）。
    public var anonKey: String? { raw["anonKey"]?.string.flatMap { $0.isEmpty ? nil : $0 } }

    public func permissions(for key: WebProviderKey) -> ProviderKeyPermissions {
        let several = keysOn > 1
        return ProviderKeyPermissions(canSwitch: !key.on || several,
                                      canRemove: !key.active || several,
                                      canMakeFirst: !key.active && key.on)
    }

    /// 已保存的 Base URL（按协议），只列出有值的。
    public var baseURLs: [ProviderBaseURL] {
        [ProviderBaseURL(api: "OpenAI Chat", url: chat), ProviderBaseURL(api: "OpenAI Responses", url: responses),
         ProviderBaseURL(api: "Anthropic", url: anthropic), ProviderBaseURL(api: "Gemini", url: gemini)]
            .filter { !$0.url.isEmpty }
    }
}

/// 供应商的一个 Base URL：哪种接口、地址。
public struct ProviderBaseURL: Hashable, Identifiable, Sendable {
    public var api: String
    public var url: String
    public var id: String { api }

    public init(api: String, url: String) {
        self.api = api
        self.url = url
    }
}

/// 一把 Key 的操作（对应 `POST /api/keys/{action}`）。
public enum ProviderKeyAction: String, Sendable, CaseIterable {
    /// 添加一把（可带名字）。
    case add
    /// 一次粘贴多把（换行、逗号、空格分隔），已有的跳过。
    case `import`
    /// 设为第一把（Make first）。
    case use
    case remove
    case removeMany = "remove-many"
    case rename
    /// 换成新的值（在供应商那边轮换了），名字、位置、设置不变。
    case replace
    case on, off
}

extension WebRequests {
    /// 与 magpie `provider.SplitKeys` / 网页端 `splitKeys` 相同：按 , ; ， ； 空白 全角空格 拆开，去掉两端引号，去重保序。
    public static func splitKeys(_ text: String) -> [String] {
        let separators: Set<Character> = [",", ";", "，", "；", " ", "\t", "\n", "\r", "\r\n", "\u{3000}"]
        var out: [String] = []
        for piece in text.split(whereSeparator: { separators.contains($0) }) {
            let key = piece.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            if !key.isEmpty && !out.contains(key) { out.append(key) }
        }
        return out
    }

    /// `POST /api/keys/add`：添加一把 Key。名字可空；protocol 空 = 任意协议（网页端默认）。
    public static func providerKeyAdd(_ provider: String, name: String, key: String, protocol keyProtocol: String = "") -> WebJSON {
        ["id": .string(provider), "name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines)),
         "key": .string(key.trimmingCharacters(in: .whitespacesAndNewlines)), "protocol": .string(keyProtocol)]
    }

    /// `POST /api/keys/import`：一次添加多把（原文照发，由主机拆分）。
    public static func providerKeyImport(_ provider: String, keys: String, protocol keyProtocol: String = "") -> WebJSON {
        ["id": .string(provider), "key": .string(keys), "protocol": .string(keyProtocol)]
    }

    /// `POST /api/keys/use|remove|on|off`：只需供应商 id 与 Key 的指纹。
    public static func providerKeyRef(_ provider: String, ref: String) -> WebJSON {
        ["id": .string(provider), "ref": .string(ref)]
    }

    /// `POST /api/keys/rename`：空名字 = 去掉名字。
    public static func providerKeyRename(_ provider: String, ref: String, name: String) -> WebJSON {
        ["id": .string(provider), "ref": .string(ref), "name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines))]
    }

    /// `POST /api/keys/replace`：换成新的值。
    public static func providerKeyReplace(_ provider: String, ref: String, key: String) -> WebJSON {
        ["id": .string(provider), "ref": .string(ref), "key": .string(key.trimmingCharacters(in: .whitespacesAndNewlines))]
    }

    /// `POST /api/keys/remove-many`。
    public static func providerKeyRemoveMany(_ provider: String, refs: [String]) -> WebJSON {
        ["id": .string(provider), "refs": .strings(refs)]
    }

    /// `POST /api/provider/key`：取一把 Key 的明文。`account` 为 Key 的指纹；nil = 第一把（与网页端一致）。
    public static func providerKeyReveal(_ provider: String, account: String? = nil) -> WebJSON {
        var body: [String: WebJSON] = ["id": .string(provider)]
        if let account, !account.isEmpty { body["account"] = .string(account) }
        return .object(body)
    }
}

extension WebClient {
    /// `POST /api/keys/{action}`：返回完整的供应商列表（`added` / `had` / `removed` 也在里面）。
    public func providerKeys(_ action: ProviderKeyAction, _ body: WebJSON) async throws -> WebProviders {
        let json = try await post("/api/keys/\(action.rawValue)", body)
        if json["providers"] == nil { return try await providers() }
        return WebProviders(json: json)
    }

    /// 取某一把 Key 的明文（按需，用完即弃，不缓存、不写日志）。
    public func providerKey(_ id: String, account: String?) async throws -> String {
        try await post("/api/provider/key", WebRequests.providerKeyReveal(id, account: account))["key"]?.string ?? ""
    }
}

extension WebProviders {
    /// `keys/import` 的结果：新加了几把、已有几把。
    public var keysAdded: Int { raw["added"]?.int ?? 0 }
    public var keysHad: Int { raw["had"]?.int ?? 0 }
}
