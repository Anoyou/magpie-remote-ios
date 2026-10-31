import XCTest
@testable import MagpieRemoteCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 拦截 URLSession 请求，返回预设响应。测试类串行执行，静态 handler 不会并发访问。
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, [String: String], Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        do {
            let (status, headers, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class GatewayClientTests: XCTestCase {
    private var session: URLSession!
    private let base = URL(string: "http://100.64.0.1:3425")!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
        StubURLProtocol.handler = nil
        StubURLProtocol.lastRequest = nil
    }

    func testRequestBuildsPathAndBearer() throws {
        let client = GatewayClient(baseURL: URL(string: "http://100.64.0.1:3425/prefix/")!, key: "sk-magpie-key-EXAMPLE", session: session)
        let request = try client.makeRequest("/v1/models", query: [URLQueryItem(name: "a", value: "1")])
        XCTAssertEqual(request.url?.absoluteString, "http://100.64.0.1:3425/prefix/v1/models?a=1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-magpie-key-EXAMPLE")
        XCTAssertNil(try GatewayClient(baseURL: base, key: nil, session: session).makeRequest("x").value(forHTTPHeaderField: "Authorization"))
    }

    func testConnectionSucceeds() async throws {
        StubURLProtocol.handler = { _ in (200, ["X-Magpie-Version": "9.9.9"], Data(#"{"data":[{"id":"a"},{"id":"b"}]}"#.utf8)) }
        let report = try await GatewayClient(baseURL: base, key: "sk-magpie-key-EXAMPLE", session: session).testConnection()
        XCTAssertEqual(report.modelCount, 2)
        XCTAssertEqual(report.hostVersion, "9.9.9")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, MagpieEndpoint.probe)
    }

    func testConnectionWithoutKeyFailsFast() async {
        do {
            _ = try await GatewayClient(baseURL: base, key: nil, session: session).testConnection()
            XCTFail("应当失败")
        } catch {
            XCTAssertEqual(error as? MagpieError, .missingKey(.gatewayKey))
        }
    }

    func testUnauthorizedMapsToInvalidKey() async {
        StubURLProtocol.handler = { _ in (401, [:], Data(#"{"error":{"message":"invalid key"}}"#.utf8)) }
        do {
            _ = try await GatewayClient(baseURL: base, key: "sk-magpie-key-EXAMPLE", session: session).testConnection()
            XCTFail("应当失败")
        } catch {
            XCTAssertEqual(error as? MagpieError, .invalidKey)
        }
    }

    func testTransportErrorMapsToUnreachable() async {
        StubURLProtocol.handler = { _ in throw URLError(.timedOut) }
        do {
            _ = try await GatewayClient(baseURL: base, key: "sk-magpie-key-EXAMPLE", session: session).testConnection()
            XCTFail("应当失败")
        } catch {
            XCTAssertEqual(error as? MagpieError, .unreachable(.timedOut))
        }
    }

    func testDecodingFailureIsTyped() async {
        struct Wanted: Decodable { let required: Int }
        StubURLProtocol.handler = { _ in (200, [:], Data("{}".utf8)) }
        do {
            _ = try await GatewayClient(baseURL: base, key: "k", session: session).get(Wanted.self, path: "/x")
            XCTFail("应当失败")
        } catch {
            guard case .decoding = error as? MagpieError else { return XCTFail("\(error)") }
        }
    }

    func testEventsStreamParsesSSE() async throws {
        StubURLProtocol.handler = { _ in (200, ["Content-Type": "text/event-stream"], Data("data: a\n\ndata: b\ndata: c\n\ndata: [DONE]\n\n".utf8)) }
        let client = GatewayClient(baseURL: base, key: "k", session: session)
        var received: [String] = []
        for try await event in client.events(try client.makeRequest(MagpieEndpoint.chatCompletions, method: "POST", body: Data("{}".utf8))) {
            received.append(event.data)
        }
        XCTAssertEqual(received, ["a", "b\nc", "[DONE]"])
    }
}
