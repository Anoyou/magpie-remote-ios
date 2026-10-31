import Foundation

// 各页面用到的数据模型（占位）。
// TODO(spec): 字段名与 JSON 形状以 spec/ 中从 magpie 源码推导出的接口契约为准；
// 契约确定后补上 CodingKeys / 解码测试，并让 contract.yml 用真实 magpie 校验。

/// 「对话」页：一条消息。
public struct ChatMessage: Codable, Hashable, Identifiable, Sendable {
    public enum Role: String, Codable, Sendable { case system, user, assistant }
    public var id: UUID
    public var role: Role
    public var text: String

    public init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

/// 「管理」页：一把网关密钥（主机返回的是脱敏后的值）。
public struct GatewayKeySummary: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var masked: String
    public var enabled: Bool

    public init(id: String, name: String, masked: String, enabled: Bool) {
        self.id = id
        self.name = name
        self.masked = masked
        self.enabled = enabled
    }
}
