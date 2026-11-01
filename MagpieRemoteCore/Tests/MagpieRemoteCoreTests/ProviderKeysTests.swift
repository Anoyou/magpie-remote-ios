import XCTest
@testable import MagpieRemoteCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 一个供应商的多把 Key：keyList 解码、各操作的请求体、按需取明文、保存基本信息时不丢 Key。
final class ProviderKeysTests: XCTestCase {
    private func relay() throws -> WebProvider {
        try XCTUnwrap(WebProviders(json: try WebFixture.json("keys-import.json"))["relay"])
    }

    func testDecodesKeyListInTryOrder() throws {
        let provider = try relay()
        let keys = provider.keyList
        XCTAssertEqual(keys.map(\.id), ["fdbfd1d51e", "1864038f31", "a74efa6261"])
        XCTAssertEqual(keys.map(\.label), ["主力", "备用", "sk-r…0003"])
        XCTAssertEqual(keys.map(\.active), [true, false, false])
        XCTAssertEqual(keys.map(\.on), [true, true, false])
        XCTAssertEqual(provider.keysOn, 2)
        XCTAssertEqual(keys[1].keyProtocol, "openai")
        XCTAssertEqual(keys[1].restWhy, "quota")
        XCTAssertTrue(keys[1].resting(now: Date()))
        XCTAssertFalse(keys[0].resting())
        XCTAssertFalse(keys[1].resting(now: Date(timeIntervalSince1970: 5_000_000_000)))
        // 明文从不出现在列表里：只有脱敏写法
        for key in keys { XCTAssertFalse(key.masked.contains("EXAMPLE")) }
        let list = WebProviders(json: try WebFixture.json("keys-import.json"))
        XCTAssertEqual(list.keysAdded, 2)
        XCTAssertEqual(list.keysHad, 1)
        XCTAssertEqual(list["solo"]?.keyList.count, 0)
    }

    func testKeyListFromRecordedProviders() throws {
        let list = WebProviders(json: try WebFixture.json("providers.json"))
        let relay = try XCTUnwrap(list["relay-one"])
        XCTAssertEqual(relay.keyList.map(\.label), ["sk-r…1111", "backup"])
        let mock = try XCTUnwrap(WebProviders(json: try WebFixture.json("live-providers.json"))["mock"])
        XCTAssertEqual(mock.keyList.count, 1)
        XCTAssertTrue(mock.keyList[0].active)
    }

    func testPermissionsMatchWebEditor() throws {
        let provider = try relay()
        let keys = provider.keyList
        // 两把在用：第一把可以停用、删除，但已是首选
        XCTAssertEqual(provider.permissions(for: keys[0]), .init(canSwitch: true, canRemove: true, canMakeFirst: false))
        XCTAssertEqual(provider.permissions(for: keys[1]), .init(canSwitch: true, canRemove: true, canMakeFirst: true))
        // 停用的：能启用、能删，但不能设为首选
        XCTAssertEqual(provider.permissions(for: keys[2]), .init(canSwitch: true, canRemove: true, canMakeFirst: false))
        // 只剩一把在用：它既不能停用也不能删（交给供应商自己的开关 / 删除供应商）
        var raw = provider.raw
        raw["keyList"] = .array([keys[0].raw, keys[2].raw])
        let single = WebProvider(raw: raw)
        XCTAssertEqual(single.permissions(for: single.keyList[0]), .init(canSwitch: false, canRemove: false, canMakeFirst: false))
        XCTAssertEqual(single.permissions(for: single.keyList[1]), .init(canSwitch: true, canRemove: true, canMakeFirst: false))
    }

    func testBaseURLsListOnlySavedOnes() throws {
        let urls = try relay().baseURLs
        XCTAssertEqual(urls.map(\.api), ["OpenAI Chat", "OpenAI Responses", "Anthropic"])
        XCTAssertEqual(urls.first?.url, "http://100.64.0.1:8080/v1")
    }

    func testSplitKeysMatchesHost() {
        XCTAssertEqual(WebRequests.splitKeys("sk-a, sk-b, sk-c, sk-b"), ["sk-a", "sk-b", "sk-c"])
        XCTAssertEqual(WebRequests.splitKeys("sk-a\nsk-c\r\nsk-d"), ["sk-a", "sk-c", "sk-d"])
        XCTAssertEqual(WebRequests.splitKeys(" \"sk-a\"；'sk-b'，`sk-c`\u{3000}sk-d\tsk-e "), ["sk-a", "sk-b", "sk-c", "sk-d", "sk-e"])
        XCTAssertEqual(WebRequests.splitKeys("sk-only"), ["sk-only"])
        XCTAssertEqual(WebRequests.splitKeys(" , \n"), [])
    }

    func testKeyRequestBodies() {
        XCTAssertEqual(WebRequests.providerKeyAdd("relay", name: " 团队 ", key: "  sk-relay-EXAMPLE-0004\n"),
                       ["id": "relay", "name": "团队", "key": "sk-relay-EXAMPLE-0004", "protocol": ""])
        XCTAssertEqual(WebRequests.providerKeyImport("relay", keys: "sk-a\nsk-b"),
                       ["id": "relay", "key": "sk-a\nsk-b", "protocol": ""])
        XCTAssertEqual(WebRequests.providerKeyRef("relay", ref: "1864038f31"), ["id": "relay", "ref": "1864038f31"])
        XCTAssertEqual(WebRequests.providerKeyRename("relay", ref: "1864038f31", name: " "), ["id": "relay", "ref": "1864038f31", "name": ""])
        XCTAssertEqual(WebRequests.providerKeyReplace("relay", ref: "1864038f31", key: " sk-relay-EXAMPLE-0005 "),
                       ["id": "relay", "ref": "1864038f31", "key": "sk-relay-EXAMPLE-0005"])
        XCTAssertEqual(WebRequests.providerKeyRemoveMany("relay", refs: ["a", "b"]), ["id": "relay", "refs": ["a", "b"]])
        XCTAssertEqual(WebRequests.providerKeyReveal("relay", account: "1864038f31"), ["id": "relay", "account": "1864038f31"])
        XCTAssertEqual(WebRequests.providerKeyReveal("relay"), ["id": "relay"])
        XCTAssertEqual(ProviderKeyAction.removeMany.rawValue, "remove-many")
        XCTAssertEqual(ProviderKeyAction.allCases.map(\.rawValue).sorted(),
                       ["add", "import", "off", "on", "remove", "remove-many", "rename", "replace", "use"])
    }

    /// 保存基本信息：key 留空（主机保留第一把，其余的 Key 主机始终保留），绝不把 keyList 发回去。
    func testProviderSaveNeverSendsOrDropsKeys() throws {
        let provider = try relay()
        let body = WebRequests.providerSave(provider, edits: .init(name: "Relay 2", chat: "http://100.64.0.1:9090/v1"))
        XCTAssertEqual(body["key"], "")
        XCTAssertNil(body["keyList"])
        XCTAssertNil(body["keys"])
        XCTAssertEqual(body["chat"], "http://100.64.0.1:9090/v1")
        XCTAssertEqual(body["responses"], "http://100.64.0.1:8080/v1")
        XCTAssertEqual(body["anthropic"], "http://100.64.0.1:8080")
        let encoded = String(decoding: try body.encoded(), as: UTF8.self)
        XCTAssertFalse(encoded.contains("sk-"), "保存的请求体里不应出现任何 Key")
    }
}

/// 存下桩服务器收到的请求体（处理函数在别的线程里调用）。
private final class SentBody: @unchecked Sendable {
    var value: WebJSON?
}

final class ProviderKeysClientTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
        StubURLProtocol.handler = nil
        StubURLProtocol.lastRequest = nil
    }

    private var client: WebClient {
        WebClient(baseURL: URL(string: "http://100.64.0.1:3430")!, key: "web-key-EXAMPLE-0123", session: session)
    }

    private static func body(of request: URLRequest) -> WebJSON? {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                collected.append(buffer, count: read)
            }
            stream.close()
            data = collected
        }
        return data.flatMap { try? WebJSON.decode($0) }
    }

    func testRevealPostsAccountAndReturnsPlaintext() async throws {
        let sent = SentBody()
        StubURLProtocol.handler = { request in
            sent.value = Self.body(of: request)
            return (200, ["Content-Type": "application/json"], try WebFixture.data("provider-key.json"))
        }
        let key = try await client.providerKey("relay", account: "1864038f31")
        XCTAssertEqual(key, "sk-relay-EXAMPLE-0002")
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/provider/key")
        XCTAssertNil(request.url?.query, "Key 不应出现在网址里")
        XCTAssertEqual(sent.value, ["id": "relay", "account": "1864038f31"])
    }

    func testKeyActionPostsToKeysRoute() async throws {
        let sent = SentBody()
        StubURLProtocol.handler = { request in
            sent.value = Self.body(of: request)
            return (200, ["Content-Type": "application/json"], try WebFixture.data("keys-import.json"))
        }
        let list = try await client.providerKeys(.import, WebRequests.providerKeyImport("relay", keys: "sk-a, sk-b"))
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/keys/import")
        XCTAssertEqual(sent.value, ["id": "relay", "key": "sk-a, sk-b", "protocol": ""])
        XCTAssertEqual(list["relay"]?.keyList.count, 3)
        XCTAssertEqual(list.keysAdded, 2)
        _ = try await client.providerKeys(.removeMany, WebRequests.providerKeyRemoveMany("relay", refs: ["a74efa6261"]))
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/keys/remove-many")
    }
}
