import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// magpie Web 管理接口（`magpie daemon web on --lan`，默认端口 3430）的客户端。
///
/// 认证只有一种方式适合原生 App：每个请求都带 `Cookie: magpie_web_<端口>=<Web 密钥>`。
/// 不要在接口请求上加 `?k=`：主机会对任何带 `k` 的请求回 303 跳转，POST 会被系统改成 GET。
/// `?k=` 只用于在 WKWebView 里第一次打开网页（见 `pageURL`）。
public struct WebClient: Sendable {
    public let baseURL: URL
    public let key: String
    public let session: URLSession
    public let timeout: TimeInterval

    public init(baseURL: URL, key: String, session: URLSession = .shared, timeout: TimeInterval = 20) {
        self.baseURL = baseURL
        self.key = key
        self.session = session
        self.timeout = timeout
    }

    /// 网页正在监听的端口（Cookie 名字里用的就是它）。
    public var port: Int {
        if let port = baseURL.port { return port }
        if baseURL.scheme?.lowercased() == "https" { return 443 }
        return HostProfile.defaultWebPort
    }

    public var cookieName: String { "magpie_web_\(port)" }

    public func makeRequest(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: WebJSON? = nil) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw MagpieError.invalidURL }
        let prefix = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = prefix + (path.hasPrefix("/") ? path : "/" + path)
        let items = query.filter { $0.name != "k" }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { throw MagpieError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue(ClientIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("\(cookieName)=\(key)", forHTTPHeaderField: "Cookie")
        if let body {
            request.httpBody = try body.encoded()
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// 发请求并解析 JSON；非 2xx 转成 `MagpieError`。204 / 空响应返回 `.null`。
    public func send(_ request: URLRequest) async throws -> WebJSON {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MagpieError.from(error)
        }
        guard let http = response as? HTTPURLResponse else { throw MagpieError.unreachable(.other) }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type"), body: data)
        }
        if http.statusCode == 204 || data.isEmpty { return .null }
        do {
            return try WebJSON.decode(data)
        } catch {
            throw MagpieError.decoding(String(describing: error))
        }
    }

    public func get(_ path: String, query: [URLQueryItem] = []) async throws -> WebJSON {
        try await send(makeRequest(path, query: query))
    }

    public func post(_ path: String, _ body: WebJSON) async throws -> WebJSON {
        try await send(makeRequest(path, method: "POST", body: body))
    }

    /// Web 接口的错误约定（spec/web-api.md §1.4–1.6）。
    public static func error(status: Int, contentType: String?, body: Data) -> MagpieError {
        let isJSON = contentType?.lowercased().contains("json") ?? false
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        switch status {
        case 401:
            // 纯文本 401 = 密钥被拒；JSON 错误从不用 401。
            return .webKeyInvalid
        case 403:
            if text.lowercased().contains("own window") { return .webForbidden(ownWindowOnly: true, detail: nil) }
            return .webForbidden(ownWindowOnly: false, detail: text.isEmpty ? nil : String(text.prefix(300)))
        case 400:
            if isJSON || text.hasPrefix("{"), let json = try? WebJSON.decode(body), let message = json["error"]?.string {
                return .webRejected(message: message, code: json["code"]?.string)
            }
            return .webRejected(message: text.isEmpty ? "请求无效" : String(text.prefix(300)), code: nil)
        default:
            return MagpieError.from(status: status, body: body)
        }
    }

    // MARK: 接口

    public func settings() async throws -> WebSettings { WebSettings(json: try await get("/api/settings")) }

    /// 读版本并检查兼容性；不兼容时抛 `.incompatibleHost`。
    public func checkCompatibility() async throws -> WebSettings {
        let settings = try await settings()
        if let problem = MagpieCompatibility.check(hostVersion: settings.version) { throw problem }
        return settings
    }

    public func providers() async throws -> WebProviders { WebProviders(json: try await get("/api/providers")) }

    /// 供应商操作；save / delete / on / off 等都返回完整的供应商列表。
    public func provider(_ action: ProviderAction, _ body: WebJSON) async throws -> WebProviders {
        let json = try await post("/api/provider/\(action.rawValue)", body)
        // models 操作返回 {"count", "provider"}、key 返回 {"key"}；其余返回 providersJSON。
        if json["providers"] == nil { return try await providers() }
        return WebProviders(json: json)
    }

    /// 读取供应商已保存的原始 Key（编辑页「显示」用）。
    public func providerKey(_ id: String) async throws -> String {
        try await post("/api/provider/key", WebRequests.providerID(id))["key"]?.string ?? ""
    }

    public func arrangeProviders(_ order: [String]) async throws -> WebProviders {
        WebProviders(json: try await post("/api/providers/arrange", WebRequests.arrange(order)))
    }

    public func groups() async throws -> WebGroups { WebGroups(json: try await get("/api/groups")) }

    public func group(_ action: GroupAction, _ body: WebJSON) async throws -> WebGroups {
        WebGroups(json: try await post("/api/groups/\(action.rawValue)", body))
    }

    public func state() async throws -> WebState { WebState(json: try await get("/api/state")) }

    public func setAgent(_ agent: String, field: String, value: String) async throws -> WebState {
        WebState(json: try await post("/api/set", WebRequests.setAgent(agent, field: field, value: value)))
    }

    public func callerKeys() async throws -> WebCallerKeys { WebCallerKeys(json: try await get("/api/caller-keys")) }

    public func callerKey(_ action: CallerKeyAction, _ body: WebJSON) async throws -> WebCallerKeys {
        WebCallerKeys(json: try await post("/api/caller-keys/\(action.rawValue)", body))
    }

    // MARK: 网页兜底

    /// 在 WKWebView 里打开的网页地址。`withKey` 为 true 时带一次 `?k=`，主机 303 跳回不带 k 的地址并写入 Cookie。
    public func pageURL(_ page: MagpieWebPage, withKey: Bool) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path) + "/"
        var items = page.query
        if withKey { items.insert(URLQueryItem(name: "k", value: key), at: 0) }
        components.queryItems = items
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}

/// 只能在网页里完成的功能。
public enum MagpieWebPage: String, CaseIterable, Identifiable, Sendable {
    case accounts, backup, masking

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .accounts: "账号登录"
        case .backup: "备份与同步"
        case .masking: "脱敏"
        }
    }

    public var detail: String {
        switch self {
        case .accounts: "登录 Codex、Claude、Copilot 等订阅账号"
        case .backup: "导出、导入备份，WebDAV 同步"
        case .masking: "查看脱敏记录与规则"
        }
    }

    public var symbol: String {
        switch self {
        case .accounts: "person.badge.key"
        case .backup: "externaldrive.badge.icloud"
        case .masking: "eye.slash"
        }
    }

    public var query: [URLQueryItem] {
        switch self {
        case .accounts: [URLQueryItem(name: "view", value: "providers")]
        case .backup: [URLQueryItem(name: "view", value: "settings"), URLQueryItem(name: "tab", value: "sync")]
        case .masking: [URLQueryItem(name: "view", value: "masking")]
        }
    }
}

// MARK: 临时密钥（网关）

extension GatewayClient {
    /// `POST /v1/magpie/keys`：用签发密钥签发一把临时网关密钥（明文只在这次返回）。
    public func issueKey(name: String, ttl: String, models: [String] = [], readOnly: Bool = false) async throws -> IssuedKey {
        let body = try WebRequests.issueKey(name: name, ttl: ttl, models: models, readOnly: readOnly).encoded()
        let (data, _) = try await send(makeRequest("/v1/magpie/keys", method: "POST", body: body))
        return IssuedKey(json: try Self.decodeWebJSON(data))
    }

    /// `GET /v1/magpie/keys`：这把签发密钥签发过的临时密钥。
    public func issuedKeys() async throws -> [IssuedKey] {
        let (data, _) = try await send(makeRequest("/v1/magpie/keys"))
        return IssuedKey.list(try Self.decodeWebJSON(data))
    }

    /// `DELETE /v1/magpie/keys/{id}`：吊销。
    public func revokeIssuedKey(_ id: String) async throws {
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
        _ = try await send(makeRequest("/v1/magpie/keys/" + escaped, method: "DELETE"))
    }

    static func decodeWebJSON(_ data: Data) throws -> WebJSON {
        do { return try WebJSON.decode(data) } catch { throw MagpieError.decoding(String(describing: error)) }
    }
}
