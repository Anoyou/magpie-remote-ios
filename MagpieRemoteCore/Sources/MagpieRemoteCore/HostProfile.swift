import Foundation

/// 一台运行 magpie 的主机（通常是自己的 Mac）。
///
/// - `gatewayURL`：magpie 网关，默认端口 3425（开启「在局域网共享」后才对外可达）。
/// - `webURL`：`magpie daemon web on` 打开的 Web 管理接口，默认端口 3430。
///
/// 密钥（网关密钥 / 签发密钥 / Web 密钥）不在这里保存，统一放进 Keychain，见 `KeychainStore`。
public struct HostProfile: Codable, Hashable, Identifiable, Sendable {
    public static let defaultGatewayPort = 3425
    public static let defaultWebPort = 3430

    public var id: UUID
    public var name: String
    public var gatewayURL: URL
    public var webURL: URL

    public init(id: UUID = UUID(), name: String, gatewayURL: URL, webURL: URL) {
        self.id = id
        self.name = name
        self.gatewayURL = gatewayURL
        self.webURL = webURL
    }

    /// 只填主机地址（如 `100.64.0.1`、`my-mac.tailnet.example`）时，按默认端口生成两个地址。
    public init?(id: UUID = UUID(), name: String, address: String) {
        guard let gateway = Self.normalizedURL(address, defaultPort: Self.defaultGatewayPort),
              let web = Self.normalizedURL(address, defaultPort: Self.defaultWebPort) else { return nil }
        self.init(id: id, name: name, gatewayURL: gateway, webURL: web)
    }

    /// 把用户输入整理成 URL：补 `http://`、补默认端口、去掉末尾斜杠。
    /// 输入里已经写了端口则保留；无法解析或没有主机名时返回 nil。
    public static func normalizedURL(_ raw: String, defaultPort: Int) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else { return nil }
        components.scheme = scheme
        if components.port == nil { components.port = defaultPort }
        if components.path == "/" { components.path = "" }
        return components.url
    }

    /// 地址里的主机部分（用于显示）。
    public var hostLabel: String { gatewayURL.host ?? gatewayURL.absoluteString }
}

/// Keychain 里按主机分开保存的三种密钥。
public enum HostSecretKind: String, CaseIterable, Codable, Sendable {
    /// 网关密钥：在 magpie「网络与共享」里创建，调用网关（额度、对话）时用 `Authorization: Bearer`。
    case gatewayKey = "gateway-key"
    /// 签发密钥：用于在 App 里管理（签发 / 吊销）网关密钥。TODO(spec): 以 spec/ 中的接口契约为准。
    case issuerKey = "issuer-key"
    /// Web 密钥：主机上 `MAGPIE_WEB_KEY` 的值，访问 3430 端口的 Web 管理接口。
    case webKey = "web-key"

    public var title: String {
        switch self {
        case .gatewayKey: "网关密钥"
        case .issuerKey: "签发密钥"
        case .webKey: "Web 密钥"
        }
    }
}
