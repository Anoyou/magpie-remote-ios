import Foundation

/// `GET /v1/models` 里的一行：一个模型，或一个路由组（id 以 `group/` 或 `auto/` 开头）。
///
/// 只解码对话页用得到的字段，其余字段（价格、推理档位等）忽略；缺字段时按「未知」处理，不报错。
public struct GatewayModel: Decodable, Hashable, Identifiable, Sendable {
    public var id: String
    public var displayName: String?
    /// magpie 自己的选择器显示的名字，例如 `Claude Sonnet 4.6 · Anthropic`、`coding · routing group`。
    public var label: String?
    public var ownedBy: String?
    /// `modalities.input`；缺失时为空（视为只支持文字）。
    public var inputModalities: [String]

    public init(id: String, displayName: String? = nil, label: String? = nil, ownedBy: String? = nil, inputModalities: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.label = label
        self.ownedBy = ownedBy
        self.inputModalities = inputModalities
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName = "display_name", label = "magpie_label", ownedBy = "owned_by", modalities
    }

    private struct Modalities: Decodable {
        var input: [String]?
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try? container.decodeIfPresent(String.self, forKey: .displayName)
        label = try? container.decodeIfPresent(String.self, forKey: .label)
        ownedBy = try? container.decodeIfPresent(String.self, forKey: .ownedBy)
        inputModalities = ((try? container.decodeIfPresent(Modalities.self, forKey: .modalities)) ?? nil)?.input ?? []
    }

    /// 路由组：`group/…` 或 magpie 自己找到的 `auto/…`。
    public var isRoutingGroup: Bool { id.hasPrefix("group/") || id.hasPrefix("auto/") }

    /// 能否发图片：`modalities.input` 含 `image`。
    public var supportsImages: Bool { inputModalities.contains { $0.lowercased() == "image" } }

    /// id 里 `/` 前面的部分（供应商 id，或 `group` / `auto`）。
    public var providerID: String {
        guard let slash = id.firstIndex(of: "/") else { return ownedBy ?? "" }
        return String(id[..<slash])
    }

    /// 列表里显示的名字。
    public var title: String {
        if let displayName, !displayName.isEmpty { return displayName }
        if let labelName = labelParts?.name { return labelName }
        guard let slash = id.firstIndex(of: "/") else { return id }
        return String(id[id.index(after: slash)...])
    }

    /// 分组用的供应商名：优先取 `magpie_label` 里 ` · ` 之后的部分（如 `Anthropic`），否则用 id 前缀。
    public var providerName: String {
        if let provider = labelParts?.provider, !provider.isEmpty, !isRoutingGroup { return provider }
        let prefix = providerID
        return prefix.isEmpty ? "其它" : prefix
    }

    private var labelParts: (name: String, provider: String)? {
        guard let label, let range = label.range(of: " · ", options: .backwards) else { return nil }
        return (String(label[..<range.lowerBound]), String(label[range.upperBound...]))
    }
}

/// 一个供应商下的模型（模型选择器里的一个分区）。
public struct ModelProviderSection: Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var models: [GatewayModel]
}

/// `/v1/models` 整理后的结果：路由组单独一组，其余按供应商分组；都保持主机返回的顺序。
public struct ModelCatalog: Hashable, Sendable {
    public var models: [GatewayModel]

    public init(models: [GatewayModel]) {
        self.models = models
    }

    /// 解码 `{"object":"list","data":[…]}`；`data` 缺失按空列表处理。
    public static func decode(_ data: Data) throws -> ModelCatalog {
        struct Envelope: Decodable { var data: [GatewayModel]? }
        do {
            return ModelCatalog(models: try JSONDecoder().decode(Envelope.self, from: data).data ?? [])
        } catch {
            throw MagpieError.decoding(String(describing: error))
        }
    }

    public var isEmpty: Bool { models.isEmpty }

    public var routingGroups: [GatewayModel] { models.filter(\.isRoutingGroup) }

    public var providers: [ModelProviderSection] {
        var order: [String] = []
        var grouped: [String: ModelProviderSection] = [:]
        for model in models where !model.isRoutingGroup {
            let key = model.providerID
            if grouped[key] == nil {
                order.append(key)
                grouped[key] = ModelProviderSection(id: key, name: model.providerName, models: [])
            }
            grouped[key]?.models.append(model)
        }
        return order.compactMap { grouped[$0] }
    }

    public func model(id: String?) -> GatewayModel? {
        guard let id else { return nil }
        return models.first { $0.id == id }
    }

    /// 新对话默认用的模型：上次用过且仍在列表里的，否则第一个路由组，否则第一个模型。
    public func defaultModel(preferring id: String?) -> GatewayModel? {
        model(id: id) ?? routingGroups.first ?? models.first
    }
}
