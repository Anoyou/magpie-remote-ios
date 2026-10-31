import XCTest
@testable import MagpieRemoteCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 读取 Tests/MagpieRemoteCoreTests/Fixtures/web 下的文件。
/// `live-*` 是对真实 magpie v0.1.2438 抓取并脱敏的响应；其余按 magpie 源码（80af3b8）实测形状整理，数据更丰富。
enum WebFixture {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/web")

    static func data(_ name: String) throws -> Data { try Data(contentsOf: directory.appendingPathComponent(name)) }
    static func json(_ name: String) throws -> WebJSON { try WebJSON.decode(data(name)) }
}

final class WebModelTests: XCTestCase {
    func testDecodesProviders() throws {
        let list = WebProviders(json: try WebFixture.json("providers.json"))
        XCTAssertEqual(list.providers.map(\.id), ["deepseek", "relay-one"])
        let relay = try XCTUnwrap(list["relay-one"])
        XCTAssertEqual(relay.name, "Relay One")
        XCTAssertEqual(relay.chosen, ["gpt-4.1", "o3"])
        XCTAssertEqual(relay.keyMasked, "sk-r…1111")
        XCTAssertFalse(relay.isAccount)
        XCTAssertEqual(relay.models.filter(\.on).map(\.id), ["gpt-4.1", "o3"])
        XCTAssertEqual(list.presets.first?.id, "deepseek")
    }

    func testDecodesLiveProviders() throws {
        let list = WebProviders(json: try WebFixture.json("live-providers.json"))
        let mock = try XCTUnwrap(list["mock"])
        XCTAssertTrue(mock.ready)
        XCTAssertFalse(mock.isAccount)
        XCTAssertEqual(mock.models.map(\.id), ["mock-gpt-1", "mock-gpt-mini"])
        XCTAssertEqual(mock.exposed, 2)
    }

    func testDecodesGroups() throws {
        let groups = WebGroups(json: try WebFixture.json("live-groups.json"))
        XCTAssertEqual(groups.groups.map(\.id), ["fast"])
        XCTAssertEqual(groups.groups[0].members, ["mock/mock-gpt-1", "mock/mock-gpt-mini"])
        XCTAssertEqual(groups.groups[0].routing, "order")
        XCTAssertFalse(groups.groups[0].disabled)
        XCTAssertEqual(groups.groups[0].memberInfo.first?.name, "Mock · mock-gpt-1")
        XCTAssertEqual(groups.models.map(\.id), ["mock/mock-gpt-1", "mock/mock-gpt-mini"])
        XCTAssertTrue(WebGroups(json: try WebFixture.json("groups-switch-off.json")).groups[0].disabled)
    }

    func testDecodesAgents() throws {
        let live = WebState(json: try WebFixture.json("live-state.json"))
        XCTAssertEqual(live.agents.map(\.id), ["claude", "codex"])
        XCTAssertEqual(live.agents[1].modelField?.key, "model")
        XCTAssertFalse(live.agents[0].wired) // null
        let state = WebState(json: try WebFixture.json("state-after-set-model.json"))
        let codex = try XCTUnwrap(state.agents.first { $0.id == "codex" })
        XCTAssertTrue(codex.wired)
        XCTAssertEqual(codex.modelField?.value, "relay-one/gpt-4.1")
        XCTAssertEqual(codex.modelField?.currentTitle, "GPT 4.1 (relay)")
        XCTAssertNotNil(state.notice)
    }

    func testDecodesCallerKeys() throws {
        let keys = WebCallerKeys(json: try WebFixture.json("caller-keys.json"))
        XCTAssertNil(keys.secret)
        XCTAssertEqual(keys.keys.map(\.name), ["iPhone", "Magpie"])
        XCTAssertEqual(keys.keys[0].limitSummary, "每月 $20.00，已用 $0.00")
        XCTAssertTrue(keys.keys[1].lan)
        let live = WebCallerKeys(json: try WebFixture.json("live-caller-keys.json"))
        XCTAssertEqual(live.keys.filter(\.issues).count, 1)
        XCTAssertEqual(live.keys.filter(\.readOnly).count, 1)
        let added = WebCallerKeys(json: try WebFixture.json("caller-keys-add-key.json"))
        XCTAssertEqual(added.secret, "sk-magpie-key-EXAMPLE-0123456789abcdef")
    }

    func testDecodesSettingsVersion() throws {
        let settings = WebSettings(json: try WebFixture.json("live-settings.json"))
        XCTAssertEqual(settings.version, "v0.1.2438")
        XCTAssertTrue(settings.lan)
        XCTAssertNil(MagpieCompatibility.check(hostVersion: settings.version))
    }

    func testDecodesIssuedKeys() throws {
        let issued = IssuedKey(json: try WebFixture.json("live-issued-key.json"))
        XCTAssertEqual(issued.name, "contract-temp")
        XCTAssertTrue(issued.key.hasPrefix("sk-magpie-key-"))
        XCTAssertEqual(IssuedKey.list(try WebFixture.json("live-issued-keys.json")).count, 1)
    }

    func testWebJSONRoundTripKeepsIntegers() throws {
        let json = try WebFixture.json("live-groups.json")
        XCTAssertEqual(json, try WebJSON.decode(json.encoded()))
        XCTAssertEqual(String(decoding: try WebJSON.object(["n": .int(3)]).encoded(), as: UTF8.self), "{\"n\":3}")
    }
}

final class WebRequestTests: XCTestCase {
    /// 在 fixture 上加上各种「编辑页不显示、但整份替换时必须保留」的字段。
    private func richRelay() throws -> WebProvider {
        var raw = try XCTUnwrap(WebProviders(json: try WebFixture.json("providers.json"))["relay-one"]).raw
        raw["fallback"] = ["deepseek/deepseek-chat"]
        raw["headers"] = ["X-Org": "org-EXAMPLE", "X-Team": "blue"]
        raw["responses"] = "http://127.0.0.1:13499/v1"
        raw["anthropic"] = "http://127.0.0.1:13499/anthropic"
        raw["balanceURL"] = "http://127.0.0.1:13499/balance"
        raw["balancePath"] = "data.total"
        raw["modelsURL"] = "http://127.0.0.1:13499/v1/models"
        raw["icon"] = "openai"
        raw["baseAPI"] = "chat"
        raw["searches"] = true
        raw["passUserAgent"] = true
        raw["extraBody"] = ["service_tier": "flex"]
        raw["replyHeaders"] = ["x-request-id"]
        return WebProvider(raw: raw)
    }

    func testProviderSaveRoundTripsUnchangedFields() throws {
        let provider = try richRelay()
        let body = WebRequests.providerSave(provider, edits: .init(name: "Relay Renamed"))
        XCTAssertEqual(body["name"], "Relay Renamed")
        // 没改、但主机会整份替换的字段：原样带回
        XCTAssertEqual(body["id"], "relay-one")
        XCTAssertEqual(body["from"], "relay-one")
        XCTAssertEqual(body["new"], false)
        XCTAssertEqual(body["chat"], "http://127.0.0.1:13499/v1")
        XCTAssertEqual(body["responses"], "http://127.0.0.1:13499/v1")
        XCTAssertEqual(body["anthropic"], "http://127.0.0.1:13499/anthropic")
        XCTAssertEqual(body["fallback"], ["deepseek/deepseek-chat"])
        XCTAssertEqual(body["headers"], ["X-Org": "org-EXAMPLE", "X-Team": "blue"])
        XCTAssertEqual(body["models"], ["gpt-4.1", "o3"])
        XCTAssertEqual(body["noModels"], false)
        XCTAssertEqual(body["balanceURL"], "http://127.0.0.1:13499/balance")
        XCTAssertEqual(body["balancePath"], "data.total")
        XCTAssertEqual(body["modelsURL"], "http://127.0.0.1:13499/v1/models")
        XCTAssertEqual(body["icon"], "openai")
        XCTAssertEqual(body["baseAPI"], "chat")
        XCTAssertEqual(body["searches"], true)
        XCTAssertEqual(body["passUserAgent"], true)
        XCTAssertEqual(body["extraBody"], ["service_tier": "flex"])
        XCTAssertEqual(body["replyHeaders"], ["x-request-id"])
        // Key 留空 = 主机保留已保存的；绝不把脱敏对象 {set, masked} 发回去
        XCTAssertEqual(body["key"], "")
        // 「没发即保留」的字段不发
        for absent in ["proxy", "maxConcurrency", "queueLimit", "queueWait", "maxRPM", "priceRate", "rateWindows",
                       "routing", "affinity", "sink", "authHeader", "contexts", "balanceToken", "keyList", "account",
                       "chosen", "exposed", "agents", "insecureTLS", "limitRestOff", "nativeCompaction"] {
            XCTAssertNil(body[absent], "不应发送 \(absent)")
        }
        // models 必须是字符串数组，不能是 providerJSON 里的 modelJSON 对象
        XCTAssertTrue(body["models"]?.array?.allSatisfy { $0.string != nil } ?? false)
    }

    func testProviderSaveWithNoEditsReproducesState() throws {
        // 原样保存一个真实抓取的供应商：可见字段与 GET 时完全一致
        let mock = try XCTUnwrap(WebProviders(json: try WebFixture.json("live-providers.json"))["mock"])
        let body = WebRequests.providerSave(mock)
        XCTAssertEqual(body["name"]?.string, mock.name)
        XCTAssertEqual(body["chat"]?.string, mock.chat)
        XCTAssertEqual(body["models"]?.strings, mock.chosen)
        XCTAssertEqual(body["fallback"]?.strings, mock.fallback)
        XCTAssertEqual(body["headers"], .object([:]))
    }

    func testProviderSaveNewKeyAndURL() throws {
        let body = WebRequests.providerSave(try richRelay(), edits: .init(chat: "http://100.64.0.2:8080/v1", key: "  sk-upstream-EXAMPLE-2222 \n"))
        XCTAssertEqual(body["chat"], "http://100.64.0.2:8080/v1")
        XCTAssertEqual(body["key"], "sk-upstream-EXAMPLE-2222")
        XCTAssertEqual(body["headers"], ["X-Org": "org-EXAMPLE", "X-Team": "blue"])
    }

    func testModelToggles() throws {
        let relay = try XCTUnwrap(WebProviders(json: try WebFixture.json("providers.json"))["relay-one"])
        let on = WebRequests.toggledModels(relay, model: "gpt-4.1-mini", on: true)
        let body = WebRequests.providerSave(relay, edits: .init(enabledModels: on))
        XCTAssertEqual(body["models"]?.strings, ["gpt-4.1", "gpt-4.1-mini", "o3"]) // 按主机列表顺序
        let off = WebRequests.toggledModels(relay, model: "o3", on: false)
        XCTAssertEqual(WebRequests.providerSave(relay, edits: .init(enabledModels: off))["models"], ["gpt-4.1"])
        let none = WebRequests.providerSave(relay, edits: .init(enabledModels: []))
        XCTAssertEqual(none["models"], [])
        XCTAssertEqual(none["noModels"], true)
        XCTAssertEqual(none["bestInFamily"], false)
    }

    func testAccountProviderSaveSendsOnlyModelFields() throws {
        var raw = try XCTUnwrap(WebProviders(json: try WebFixture.json("providers.json"))["relay-one"]).raw
        raw["account"] = ["agent": "codex", "user": "someone@example.com"]
        let body = WebRequests.providerSave(WebProvider(raw: raw), edits: .init(enabledModels: ["o3"]))
        XCTAssertEqual(body["models"], ["o3"])
        XCTAssertNil(body["chat"])
        XCTAssertNil(body["name"])
        XCTAssertNil(body["key"])
        XCTAssertNil(body["new"])
    }

    func testProviderAddBodies() {
        XCTAssertEqual(WebRequests.providerAdd(name: "Relay One", chat: "http://127.0.0.1:13499/v1 ", key: "sk-upstream-EXAMPLE-1"),
                       ["new": true, "name": "Relay One", "chat": "http://127.0.0.1:13499/v1", "key": "sk-upstream-EXAMPLE-1"])
        XCTAssertEqual(WebRequests.providerAdd(name: "", chat: "", key: "k", preset: "deepseek"),
                       ["new": true, "preset": "deepseek", "key": "k"])
        XCTAssertEqual(WebRequests.arrange(["relay-one", "deepseek"]), ["order": ["relay-one", "deepseek"]])
    }

    func testGroupSaveKeepsRulesAndDropsComputed() throws {
        var group = WebGroups(json: try WebFixture.json("live-groups.json")).groups[0]
        group.raw["weights"] = ["mock/mock-gpt-1": 3]
        let body = WebRequests.groupSave(group, id: "fast", name: "Fast 2", members: ["mock/mock-gpt-mini"])
        XCTAssertEqual(body["name"], "Fast 2")
        XCTAssertEqual(body["members"], ["mock/mock-gpt-mini"])
        XCTAssertEqual(body["routing"], "order")
        XCTAssertEqual(body["weights"], ["mock/mock-gpt-1": 3])
        XCTAssertNil(body["from"])
        for computed in ["ready", "memberInfo", "holds", "offers", "shared", "patterns", "ref"] { XCTAssertNil(body[computed]) }
        let renamed = WebRequests.groupSave(group, id: "Quick", name: "Quick", members: [])
        XCTAssertEqual(renamed["id"], "quick")
        XCTAssertEqual(renamed["from"], "fast")
        XCTAssertEqual(WebRequests.groupSave(nil, id: "new", name: "New", members: ["a/b"]), ["id": "new", "name": "New", "members": ["a/b"]])
        XCTAssertEqual(WebRequests.groupSwitch("fast", on: false), ["id": "fast", "on": false])
    }

    func testAgentAndKeyBodies() {
        XCTAssertEqual(WebRequests.setAgent("codex", field: "model", value: "relay-one/gpt-4.1"),
                       ["agent": "codex", "field": "model", "value": "relay-one/gpt-4.1"])
        XCTAssertEqual(WebRequests.callerKeyAdd(name: " iPhone ", readOnly: false), ["name": "iPhone"])
        XCTAssertEqual(WebRequests.callerKeyAdd(name: "看板", readOnly: true), ["name": "看板", "readOnly": true])
        XCTAssertEqual(WebRequests.callerKey("cf3c"), ["key": "cf3c"])
        XCTAssertEqual(WebRequests.issueKey(name: "ios-temp", ttl: "1h", models: ["mock/mock-gpt-1"]),
                       ["name": "ios-temp", "ttl": "1h", "models": ["mock/mock-gpt-1"]])
    }
}

final class WebClientTests: XCTestCase {
    private var session: URLSession!
    private let base = URL(string: "http://100.64.0.1:3430")!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
        StubURLProtocol.handler = nil
        StubURLProtocol.lastRequest = nil
    }

    private var client: WebClient { WebClient(baseURL: base, key: "web-key-EXAMPLE-0123", session: session) }

    func testRequestUsesCookieNeverQueryKey() throws {
        let request = try client.makeRequest("/api/providers", query: [URLQueryItem(name: "k", value: "leak"), URLQueryItem(name: "wait", value: "1")])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "magpie_web_3430=web-key-EXAMPLE-0123")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
        XCTAssertEqual(request.url?.absoluteString, "http://100.64.0.1:3430/api/providers?wait=1")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(WebClient(baseURL: URL(string: "http://my-mac.tailnet.example:13430")!, key: "x").cookieName, "magpie_web_13430")
    }

    func testPostSendsJSONBody() async throws {
        StubURLProtocol.handler = { _ in (200, ["Content-Type": "application/json"], try WebFixture.data("caller-keys-add-key.json")) }
        let keys = try await client.callerKey(.add, WebRequests.callerKeyAdd(name: "iPhone", readOnly: false))
        XCTAssertEqual(keys.secret, "sk-magpie-key-EXAMPLE-0123456789abcdef")
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/caller-keys/add-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testPlainText401IsWebKeyInvalid() async throws {
        StubURLProtocol.handler = { _ in (401, ["Content-Type": "text/plain; charset=utf-8"], try WebFixture.data("live-err-web-no-cookie.txt")) }
        do {
            _ = try await client.providers()
            XCTFail("应当失败")
        } catch let error as MagpieError {
            XCTAssertEqual(error, .webKeyInvalid)
            XCTAssertEqual(error.title, "页面密钥无效")
        }
    }

    func testForbiddenVariants() {
        let own = WebClient.error(status: 403, contentType: "text/plain", body: Data("magpie's API answers magpie's own window only".utf8))
        XCTAssertEqual(own, .webForbidden(ownWindowOnly: true, detail: nil))
        let allow = WebClient.error(status: 403, contentType: "text/plain", body: Data("192.0.2.7 is not on magpie's allow list".utf8))
        guard case .webForbidden(false, let detail) = allow else { return XCTFail() }
        XCTAssertEqual(detail, "192.0.2.7 is not on magpie's allow list")
        XCTAssertTrue(allow.message.contains("允许列表"))
    }

    func testBadRequestCarriesMagpieMessage() throws {
        let error = WebClient.error(status: 400, contentType: "application/json", body: try WebFixture.data("error-caller-key-not-found.json"))
        XCTAssertEqual(error, .webRejected(message: "Key not found", code: nil))
        let coded = WebClient.error(status: 400, contentType: "application/json", body: Data(#"{"error":"x","code":"config_blocked"}"#.utf8))
        XCTAssertEqual(coded, .webRejected(message: "x", code: "config_blocked"))
        XCTAssertNotNil(coded.hint)
        XCTAssertEqual(WebClient.error(status: 400, contentType: "text/plain", body: Data("unknown field\n".utf8)),
                       .webRejected(message: "unknown field", code: nil))
        guard case .incompatibleHost = WebClient.error(status: 404, contentType: "text/plain", body: Data("404 page not found".utf8)) else {
            return XCTFail()
        }
    }

    func testCompatibilityCheckThrowsForOldHost() async throws {
        let minimum = MagpieCompatibility.minimumHostVersion
        guard minimum > SemanticVersion(0, 0, 0) else { throw XCTSkip("最低版本尚未设定") }
        let old = "\(minimum.major).\(minimum.minor).\(max(0, minimum.patch - 1))"
        StubURLProtocol.handler = { _ in (200, ["Content-Type": "application/json"], Data("{\"version\":\"\(old)\"}".utf8)) }
        do {
            _ = try await client.checkCompatibility()
            XCTFail("应当不兼容")
        } catch let error as MagpieError {
            guard case .incompatibleHost(let found, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(found, old)
        }
    }

    func testModelsActionRefetchesProviders() async throws {
        StubURLProtocol.handler = { request in
            if request.url?.path == "/api/providers" { return (200, ["Content-Type": "application/json"], try WebFixture.data("providers.json")) }
            return (200, ["Content-Type": "application/json"], Data(#"{"count":3}"#.utf8))
        }
        let list = try await client.provider(.models, WebRequests.providerID("relay-one"))
        XCTAssertEqual(list.providers.count, 2)
    }

    func testPageURLCarriesKeyOnlyWhenAsked() {
        XCTAssertEqual(client.pageURL(.backup, withKey: false)?.absoluteString, "http://100.64.0.1:3430/?view=settings&tab=sync")
        XCTAssertEqual(client.pageURL(.accounts, withKey: true)?.absoluteString, "http://100.64.0.1:3430/?k=web-key-EXAMPLE-0123&view=providers")
        XCTAssertEqual(client.pageURL(.masking, withKey: false)?.absoluteString, "http://100.64.0.1:3430/?view=masking")
    }

    func testIssuedKeyRequests() async throws {
        StubURLProtocol.handler = { _ in (201, ["Content-Type": "application/json"], try WebFixture.data("live-issued-key.json")) }
        let gateway = GatewayClient(baseURL: URL(string: "http://100.64.0.1:3425")!, key: "sk-magpie-key-EXAMPLE", session: session)
        let issued = try await gateway.issueKey(name: "contract-temp", ttl: "1h")
        XCTAssertEqual(issued.id, "9cab48eacf53dfe7159be36d")
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.path, "/v1/magpie/keys")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-magpie-key-EXAMPLE")
        StubURLProtocol.handler = { _ in (200, ["Content-Type": "application/json"], Data(#"{"revoked":"abc"}"#.utf8)) }
        try await gateway.revokeIssuedKey("abc")
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "DELETE")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/v1/magpie/keys/abc")
    }
}
