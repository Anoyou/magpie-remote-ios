import XCTest
@testable import MagpieRemoteCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 「管理 › 插件」：Fixtures/web/plugin*.json 按 magpie 源码（80af3b8，internal/gui/plugins.go、builtins.go、pluginpage.go）的形状整理，数据为虚构。
final class PluginModelTests: XCTestCase {
    func testDecodesInstalledPlugins() throws {
        let state = WebPlugins(json: try WebFixture.json("plugins.json"))
        XCTAssertTrue(state.bun)
        XCTAssertEqual(state.plugins.map(\.spec), ["@magpie-community/example-auth", "github:example-owner/magpie-dash", "example-middleware@2"])

        let auth = try XCTUnwrap(state["@magpie-community/example-auth"])
        XCTAssertEqual(auth.source, .npm)
        XCTAssertEqual(auth.packageName, "@magpie-community/example-auth")
        XCTAssertEqual(auth.displayName, "示例云登录")
        XCTAssertTrue(auth.enabled)
        XCTAssertTrue(auth.hasKnownUpdate)
        XCTAssertEqual(auth.options["region"], .string("cn"))
        XCTAssertEqual(auth.optionsExample["region"], .string("global"))

        let dash = try XCTUnwrap(state["github:example-owner/magpie-dash"])
        XCTAssertEqual(dash.source, .git)
        XCTAssertEqual(dash.packageName, "magpie-dash")
        XCTAssertFalse(dash.enabled)
        XCTAssertTrue(dash.hasKnownUpdate) // commit ≠ head
        XCTAssertEqual(dash.page?.title, "Dash")
        XCTAssertEqual(dash.panelTitles, ["Spend"])
        XCTAssertTrue(dash.kinds.contains("页面"))

        let middleware = try XCTUnwrap(state["example-middleware@2"])
        XCTAssertEqual(middleware.packageName, "example-middleware")
        XCTAssertEqual(middleware.displayName, "example-middleware")
        XCTAssertNotNil(middleware.error)
        XCTAssertFalse(middleware.hasKnownUpdate)
        XCTAssertEqual(middleware.toolNames, ["lookup"])
    }

    func testSourceMatchesMagpieRules() {
        XCTAssertEqual(PluginSource(spec: "/Users/someone/my-plugin"), .folder)
        XCTAssertEqual(PluginSource(spec: "file://./x"), .folder)
        XCTAssertEqual(PluginSource(spec: "./x"), .folder)
        XCTAssertEqual(PluginSource(spec: "github:owner/repo#main"), .git)
        XCTAssertEqual(PluginSource(spec: "owner/repo"), .git)
        XCTAssertEqual(PluginSource(spec: "https://github.com/owner/repo"), .git)
        XCTAssertEqual(PluginSource(spec: "git+https://example.com/x.git"), .git)
        XCTAssertEqual(PluginSource(spec: "@scope/name"), .npm) // 作用域包不是 owner/repo
        XCTAssertEqual(PluginSource(spec: "left-pad@" + "1.0.0"), .npm)
    }

    func testEmptyAndUnknownShapesDecode() {
        let empty = WebPlugins(json: ["plugins": [], "bun": false])
        XCTAssertTrue(empty.plugins.isEmpty)
        XCTAssertFalse(empty.bun)
        XCTAssertTrue(WebPlugins(json: .null).plugins.isEmpty)
        XCTAssertTrue(WebBuiltinPlugins(json: ["not": "a list"]).plugins.isEmpty)
        XCTAssertTrue(WebPluginPage.list(.null).isEmpty)
        XCTAssertNil(WebPlugins(json: ["error": ""]).error)
    }

    func testVersionComparison() {
        XCTAssertTrue(PluginVersion.isNewer("1.3.0", than: "1.2.9"))
        XCTAssertTrue(PluginVersion.isNewer("v1.10.0", than: "1.9.0"))
        XCTAssertFalse(PluginVersion.isNewer("2.0", than: "1.9.9"), "不是 x.y.z 的版本不算新（与 magpie 相同）")
        XCTAssertTrue(PluginVersion.isNewer("1.2.0", than: "1.2.0-beta.1"), "正式版比预发布新")
        XCTAssertTrue(PluginVersion.isNewer("1.2.0-beta.10", than: "1.2.0-beta.9"), "预发布里的数字按数字比")
        XCTAssertTrue(PluginVersion.isNewer("1.2.0-beta", than: "1.2.0-1"), "数字排在单词前")
        XCTAssertTrue(PluginVersion.isNewer("1.2.0-beta.1", than: "1.2.0-beta"), "短的在前")
        XCTAssertFalse(PluginVersion.isNewer("1.2.0+build.2", than: "1.2.0+build.1"), "忽略构建信息")
        XCTAssertFalse(PluginVersion.isNewer("1.2.0", than: "1.2.0"))
        XCTAssertFalse(PluginVersion.isNewer("1.2.0-beta.1", than: "1.2.0"))
        XCTAssertFalse(PluginVersion.isNewer("1.0.0", than: "1.0.1"))
    }

    func testDecodesUpdateCheck() throws {
        let check = WebPluginCheck(json: try WebFixture.json("plugins-check.json"))
        XCTAssertEqual(check.checks.count, 3)
        XCTAssertEqual(check.updates.map(\.spec), ["@magpie-community/example-auth"])
        XCTAssertEqual(check.checks[0].summary, "v1.3.0 可用")
        XCTAssertEqual(check.checks[1].status, .current)
        XCTAssertEqual(check.checks[2].summary, "无法检查：无法连接 npm，请检查网络或代理")
        XCTAssertEqual(check.summary, "1 个插件有更新 · 1 个无法检查：无法连接 npm，请检查网络或代理")
        XCTAssertTrue(check.hasUnknown)
        XCTAssertEqual(check.state?.plugins.count, 3)
        XCTAssertEqual(WebPluginCheck(json: ["plugins": []]).summary, "还没有安装插件")
    }

    func testDecodesBuiltins() throws {
        let list = WebBuiltinPlugins(json: try WebFixture.json("plugins-builtin.json"))
        XCTAssertEqual(list.plugins.map(\.id), ["usage", "sessions", "otel", "newfuture"])

        let usage = try XCTUnwrap(list["usage"])
        XCTAssertEqual(usage.title, "用量")
        XCTAssertTrue(usage.detail.hasPrefix("你的额度"))
        XCTAssertFalse(usage.canToggle, "正在使用的内置插件不能关")
        XCTAssertEqual(usage.stateText, "运行中")

        let sessions = try XCTUnwrap(list["sessions"])
        XCTAssertFalse(sessions.on)
        XCTAssertTrue(sessions.canToggle)
        XCTAssertTrue(sessions.settings.isEmpty)

        let otel = try XCTUnwrap(list["otel"])
        XCTAssertEqual(otel.settings.map(\.key), ["endpoint", "sample", "insecure", "protocol"])
        let sample = otel.settings[1]
        XCTAssertEqual(sample.kind, .number)
        XCTAssertEqual(sample.value(in: otel.config), .double(0.5))
        XCTAssertEqual(otel.settings[2].value(in: otel.config), .bool(false)) // 默认值
        XCTAssertEqual(otel.settings[3].choices, ["grpc", "http"])

        let future = try XCTUnwrap(list["newfuture"])
        XCTAssertEqual(future.title, "Something New") // 不认识的 id 用英文原名
        XCTAssertEqual(future.why, "needs gateway")
        XCTAssertEqual(future.stateText, "启动失败")
    }

    func testSettingParsing() throws {
        let otel = try XCTUnwrap(WebBuiltinPlugins(json: try WebFixture.json("plugins-builtin.json"))["otel"])
        let sample = otel.settings[1], insecure = otel.settings[2], protocolSetting = otel.settings[3]
        XCTAssertEqual(sample.parse("0.25"), .double(0.25))
        XCTAssertEqual(sample.parse("1"), .int(1))
        XCTAssertNil(sample.parse("2"), "超出最大值")
        XCTAssertNil(sample.parse("abc"))
        XCTAssertEqual(insecure.parse("true"), .bool(true))
        XCTAssertNil(insecure.parse("maybe"))
        XCTAssertEqual(protocolSetting.parse("grpc"), .string("grpc"))
        XCTAssertNil(protocolSetting.parse("smtp"), "不在可选值里")
    }

    func testDecodesListings() throws {
        let market = WebPluginListings(json: try WebFixture.json("plugins-listings.json"))
        XCTAssertEqual(market.listings.map(\.package), ["@magpie-community/example-auth", "example-agent", "example-tools"])
        XCTAssertEqual(market.listings[0].summary, "登录示例云")
        XCTAssertEqual(market.listings[0].latest, "1.3.0")
        XCTAssertEqual(market.listings[0].kindTitle, "供应商")
        XCTAssertEqual(market.listings[1].summary, "An agent")
        XCTAssertEqual(market.listings[1].kindTitle, "Agent")
        XCTAssertEqual(market.listings[2].name, "example-tools")
        XCTAssertEqual(market.listings[2].summary, "Tools from npm")
    }

    func testDecodesPagesAndPanels() throws {
        let pages = WebPluginPage.list(try WebFixture.json("plugin-pages.json"))
        XCTAssertEqual(pages.map(\.key), ["magpie-dash", "example-page"])
        XCTAssertEqual(pages[0].title, "仪表盘")
        XCTAssertEqual(pages[1].title, "example-page")
        XCTAssertEqual(pages[1].replaces, "usage")
        let panels = WebPluginPanel.list(try WebFixture.json("plugin-panels.json"))
        XCTAssertEqual(panels.first?.title, "花费")
        XCTAssertEqual(panels.first?.slot, "usage")
    }

    func testDecodesProviderOptions() throws {
        let options = PluginProviderOption.list(providers: try WebFixture.json("providers-plugin-options.json"))
        XCTAssertEqual(options.map(\.id), ["example/fast-mode", "example/share-usage"])
        XCTAssertTrue(options[0].on)
        XCTAssertEqual(options[0].spec, "@magpie-community/example-auth")
        XCTAssertFalse(options[1].on)
        XCTAssertEqual(options[1].confirm, "Sends usage to the vendor")
        XCTAssertTrue(PluginProviderOption.list(providers: try WebFixture.json("providers.json")).isEmpty)
    }
}

final class PluginRequestTests: XCTestCase {
    func testBodies() throws {
        XCTAssertEqual(PluginRequests.spec("x"), ["spec": "x"])
        XCTAssertEqual(PluginRequests.setEnabled("x", false), ["spec": "x", "off": true])
        XCTAssertEqual(PluginRequests.setEnabled("x", true), ["spec": "x", "off": false])
        XCTAssertEqual(PluginRequests.options("x", ["a": 1]), ["spec": "x", "options": ["a": 1]])
        XCTAssertEqual(PluginRequests.builtin("sessions", on: true), ["id": "sessions", "on": true])
        XCTAssertEqual(PluginRequests.builtin("otel", config: ["sample": .double(0.25)]), ["id": "otel", "config": ["sample": .double(0.25)]])
        XCTAssertEqual(PluginRequests.providerOption(provider: "example", key: "fast-mode", on: true),
                       ["provider": "example", "key": "fast-mode", "on": true])
        // 主机按 Go 字段名解码（大小写不敏感），键必须是这些。
        let encoded = String(decoding: try PluginRequests.setEnabled("x", true).encoded(), as: UTF8.self)
        XCTAssertEqual(encoded, #"{"off":false,"spec":"x"}"#)
    }

    func testNormalizedSpec() {
        XCTAssertEqual(PluginRequests.normalizedSpec("  @scope/name@" + "1.2.0 \n"), "@scope/name@" + "1.2.0")
        XCTAssertEqual(PluginRequests.normalizedSpec("npm i example-plugin"), "example-plugin")
        XCTAssertEqual(PluginRequests.normalizedSpec("bun add github:owner/repo"), "github:owner/repo")
        XCTAssertEqual(PluginRequests.normalizedSpec("https://www.npmjs.com/package/@scope/name"), "@scope/name")
        XCTAssertEqual(PluginRequests.normalizedSpec("https://www.npmjs.com/package/example/v/1.0.0"), "example@" + "1.0.0")
        XCTAssertEqual(PluginRequests.normalizedSpec("https://github.com/owner/repo"), "https://github.com/owner/repo")
        XCTAssertNil(PluginRequests.normalizedSpec("   "))
        XCTAssertNil(PluginRequests.normalizedSpec("two words"))
    }
}

final class PluginClientTests: XCTestCase {
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

    private func stub(_ file: String) {
        StubURLProtocol.handler = { _ in (200, ["Content-Type": "application/json"], try WebFixture.data(file)) }
    }

    private func body(_ request: URLRequest?) throws -> WebJSON {
        let request = try XCTUnwrap(request)
        if let data = request.httpBody { return try WebJSON.decode(data) }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return try WebJSON.decode(data)
    }

    func testListUsesCookieAndLongTimeout() async throws {
        stub("plugins.json")
        let state = try await client.plugins()
        XCTAssertEqual(state.plugins.count, 3)
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.path, "/api/plugins")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "magpie_web_3430=web-key-EXAMPLE-0123")
        XCTAssertNil(request.url?.query)
    }

    func testActionsPostToOpPath() async throws {
        stub("plugins.json")
        _ = try await client.plugin(.off, PluginRequests.setEnabled("example-middleware@2", false))
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/plugins/off")
        XCTAssertEqual(try body(StubURLProtocol.lastRequest), ["spec": "example-middleware@2", "off": true])

        _ = try await client.plugin(.add, PluginRequests.spec("example-plugin"))
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/plugins/add")
        XCTAssertGreaterThanOrEqual(StubURLProtocol.lastRequest?.timeoutInterval ?? 0, WebClient.pluginInstallTimeout)

        _ = try await client.plugin(.remove, PluginRequests.spec("example-plugin"))
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/plugins/remove")
    }

    func testCheckAndBuiltins() async throws {
        stub("plugins-check.json")
        let check = try await client.checkPluginUpdates()
        XCTAssertEqual(check.updates.count, 1)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/plugins/check")
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "POST")

        stub("plugins-builtin.json")
        let builtins = try await client.builtinPlugin(PluginRequests.builtin("sessions", on: true))
        XCTAssertEqual(builtins.plugins.count, 4)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/plugins/builtin")
        XCTAssertEqual(try body(StubURLProtocol.lastRequest), ["id": "sessions", "on": true])
    }

    func testProviderOptionPostsToSettings() async throws {
        StubURLProtocol.handler = { _ in (200, ["Content-Type": "application/json"], Data(#"{"version":"v0.1.2438"}"#.utf8)) }
        try await client.setPluginProviderOption(provider: "example", key: "fast-mode", on: false)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/settings/plugin-option")
        XCTAssertEqual(try body(StubURLProtocol.lastRequest), ["provider": "example", "key": "fast-mode", "on": false])
    }

    func testRejectedAddCarriesHostMessage() async throws {
        StubURLProtocol.handler = { _ in (400, ["Content-Type": "application/json"], Data(#"{"error":"no plugin \"nope\""}"#.utf8)) }
        do {
            _ = try await client.plugin(.remove, PluginRequests.spec("nope"))
            XCTFail("应当抛错")
        } catch let error as MagpieError {
            XCTAssertEqual(error, .webRejected(message: #"no plugin "nope""#, code: nil))
        }
    }

    func testPageURLForPluginView() {
        let url = client.pageURL(view: "magpie-dash", withKey: true)
        XCTAssertEqual(url?.absoluteString, "http://100.64.0.1:3430/?k=web-key-EXAMPLE-0123&view=magpie-dash")
        XCTAssertEqual(client.pageURL(view: "plugins", withKey: false)?.absoluteString, "http://100.64.0.1:3430/?view=plugins")
    }
}
