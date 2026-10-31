import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// App 用到的接口路径。
///
/// TODO(spec): 这些路径与返回 JSON 的确切形状正在另行整理到 spec/（由 contract.yml 对真实 magpie 校验）。
/// 契约确定后在这里集中修改，各页面只通过 `GatewayClient` 的类型化方法访问。
public enum MagpieEndpoint {
    /// 连接测试：带网关密钥请求一个只读接口，能区分 401 / 403 / 连不上。
    public static let probe = "/v1/models"
    /// 对话（OpenAI 兼容，流式 SSE）。
    public static let chatCompletions = "/v1/chat/completions"
    /// TODO(spec): 额度、用量、密钥管理接口。
    public static let quota = "/api/balance"
    public static let usage = "/api/usage"
    public static let callerKeys = "/api/caller-keys"
}

/// 连接测试的结果（给「测试连接」按钮显示）。
public struct ConnectionReport: Equatable, Sendable {
    public var hostVersion: String?
    public var modelCount: Int?
    public var latency: Duration

    public init(hostVersion: String?, modelCount: Int?, latency: Duration) {
        self.hostVersion = hostVersion
        self.modelCount = modelCount
        self.latency = latency
    }
}

/// 访问 magpie 网关 / Web 接口的最小客户端：拼 URL、带 Bearer、把各种失败统一成 `MagpieError`。
public struct GatewayClient: Sendable {
    public let baseURL: URL
    public let key: String?
    public let session: URLSession
    public let timeout: TimeInterval

    public init(baseURL: URL, key: String?, session: URLSession = .shared, timeout: TimeInterval = 10) {
        self.baseURL = baseURL
        self.key = key
        self.session = session
        self.timeout = timeout
    }

    public func makeRequest(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw MagpieError.invalidURL }
        let prefix = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = prefix + (path.hasPrefix("/") ? path : "/" + path)
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw MagpieError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(ClientIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        if let key, !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// 发请求；非 2xx 转成 `MagpieError`。
    public func send(_ request: URLRequest, model: String? = nil) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MagpieError.from(error)
        }
        guard let http = response as? HTTPURLResponse else { throw MagpieError.unreachable(.other) }
        guard (200..<300).contains(http.statusCode) else {
            throw MagpieError.from(status: http.statusCode, body: data, model: model)
        }
        return (data, http)
    }

    public func get<T: Decodable>(_ type: T.Type, path: String, query: [URLQueryItem] = []) async throws -> T {
        let (data, _) = try await send(makeRequest(path, query: query))
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw MagpieError.decoding(String(describing: error))
        }
    }

    /// 测试连接：要求已填网关密钥。
    public func testConnection() async throws -> ConnectionReport {
        guard let key, !key.isEmpty else { throw MagpieError.missingKey(.gatewayKey) }
        let clock = ContinuousClock()
        let start = clock.now
        let (data, response) = try await send(makeRequest(MagpieEndpoint.probe))
        let latency = clock.now - start
        // TODO(spec): 主机版本从哪里读（响应头或专门接口）以契约为准；这里先尝试常见的响应头。
        let version = response.value(forHTTPHeaderField: "X-Magpie-Version")
            ?? response.value(forHTTPHeaderField: "Server").flatMap { $0.lowercased().hasPrefix("magpie/") ? String($0.dropFirst(7)) : nil }
        if let incompatible = MagpieCompatibility.check(hostVersion: version) { throw incompatible }
        let models = (try? JSONDecoder().decode(ModelList.self, from: data))?.data.count
        return ConnectionReport(hostVersion: version, modelCount: models, latency: latency)
    }

    /// 读取 SSE 流（对话）。Apple 平台逐字节读取；其它平台（仅单元测试）整体读取后解析。
    public func events(_ request: URLRequest, model: String? = nil) -> AsyncThrowingStream<SSEEvent, any Error> {
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var parser = SSEParser()
                    var request = request
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    #if canImport(Darwin)
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw MagpieError.unreachable(.other) }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = Data()
                        for try await byte in bytes { body.append(byte); if body.count > 64_000 { break } }
                        throw MagpieError.from(status: http.statusCode, body: body, model: model)
                    }
                    // 不用 `bytes.lines`：它会吞掉空行，而空行正是 SSE 的事件分隔符。按字节攒到换行再整行交给解析器。
                    var line = Data()
                    for try await byte in bytes {
                        line.append(byte)
                        if byte == 0x0A {
                            for event in parser.feed(chunk: String(decoding: line, as: UTF8.self)) { continuation.yield(event) }
                            line.removeAll(keepingCapacity: true)
                        }
                    }
                    if !line.isEmpty {
                        for event in parser.feed(chunk: String(decoding: line, as: UTF8.self) + "\n") { continuation.yield(event) }
                    }
                    #else
                    let (data, response) = try await session.data(for: request)
                    guard let http = response as? HTTPURLResponse else { throw MagpieError.unreachable(.other) }
                    guard (200..<300).contains(http.statusCode) else {
                        throw MagpieError.from(status: http.statusCode, body: data, model: model)
                    }
                    for event in parser.feed(chunk: String(decoding: data, as: UTF8.self)) { continuation.yield(event) }
                    #endif
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: MagpieError.from(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// OpenAI 兼容 `/v1/models` 的最小形状。
struct ModelList: Decodable {
    struct Model: Decodable { let id: String }
    let data: [Model]
}
