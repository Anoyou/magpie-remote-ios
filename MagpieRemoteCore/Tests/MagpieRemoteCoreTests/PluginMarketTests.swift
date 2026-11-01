import XCTest
@testable import MagpieRemoteCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 插件页与官方 plugins.js 对齐的规则。Fixtures/web/plugins-*.json 按 magpie 源码（internal/gui/plugins.go、
/// internal/plugin/market.go、github.go、registry.go、updates.go）的形状整理，数据为虚构。
final class PluginMarketTests: XCTestCase {
    private func market(subs: [PluginSub] = []) throws -> PluginMarket {
        let tagged = WebTaggedRepos(json: try WebFixture.json("plugins-github.json")).repos.map(WebPluginListing.github)
        return PluginMarket(state: WebPlugins(json: try WebFixture.json("plugins.json")),
                            listings: WebPluginListings(json: try WebFixture.json("plugins-listings.json")).listings,
                            tagged: tagged, npm: WebPluginNPM.map(try WebFixture.json("plugins-npm.json")),
                            heads: [:], subs: subs)
    }

    func testSpecHelpersMatchPluginsJS() {
        XCTAssertEqual(PluginSpec.name("left-pad@" + "1.0.0"), "left-pad")
        XCTAssertEqual(PluginSpec.name("@scope/name"), "@scope/name")
        XCTAssertEqual(PluginSpec.name("@scope/name@" + "2.1.0"), "@scope/name")
        XCTAssertEqual(PluginSpec.name(#"C:\Users\me@corp\plugin"#), #"C:\Users\me@corp\plugin"#, "文件夹路径里的 @ 不是版本")
        XCTAssertEqual(PluginSpec.label("/Users/someone/my-plugin/"), "my-plugin")
        XCTAssertEqual(PluginSpec.githubRepo("github:Owner/Repo#main"), "owner/repo")
        XCTAssertEqual(PluginSpec.githubRepo("https://github.com/owner/repo.git"), "owner/repo")
        XCTAssertEqual(PluginSpec.githubRepo("owner/repo"), "owner/repo")
        XCTAssertEqual(PluginSpec.githubRepo("@scope/name"), "")
        XCTAssertEqual(PluginSpec.gitWeb("github:owner/repo#v1"), "https://github.com/owner/repo")
        XCTAssertEqual(PluginSpec.gitWeb("git+https://gitlab.com/a/b.git"), "https://gitlab.com/a/b")
        XCTAssertEqual(PluginSpec.gitWeb("owner/repo"), "https://github.com/owner/repo")
        XCTAssertTrue(PluginSpec.sameCommit("abc1234", "abc1234def"))
        XCTAssertFalse(PluginSpec.sameCommit("abc1234", ""))
    }

    func testDecodesGitHubNPMGitSearchPageMirrorRegistry() throws {
        let gh = WebTaggedRepos(json: try WebFixture.json("plugins-github.json"))
        XCTAssertEqual(gh.repos.map(\.spec), ["github:example-owner/magpie-dash", "example-relay-auth", "github:someone-else/listed-twice"])
        XCTAssertEqual(gh.repos[0].license, "MIT", "NOASSERTION 时用 package.json 的许可证")
        XCTAssertEqual(gh.reason(kept: true), "GitHub 上还有 2 个插件没能读取：GitHub 响应超时")
        XCTAssertEqual(WebTaggedRepos(json: ["error": "dial tcp"]).reason(kept: false), "无法连接 GitHub：dial tcp")

        let card = WebPluginListing.github(gh.repos[0])
        XCTAssertEqual(card.package, "github:example-owner/magpie-dash")
        XCTAssertEqual(card.name, "magpie-dash")
        XCTAssertEqual(card.pluginKind, .page)
        XCTAssertEqual(card.author, "example-owner")
        XCTAssertEqual(card.npm?.license, "MIT")
        XCTAssertEqual(card.summary, "A dashboard page for magpie")

        let npm = WebPluginNPM.map(try WebFixture.json("plugins-npm.json"))
        XCTAssertEqual(npm["@magpie-community/example-auth"]?.weekly, 15230)
        XCTAssertEqual(npm["example-agent"]?.version, "")

        let hits = try WebFixture.json("plugins-search.json")["hits"]?.array?.compactMap(WebPluginListing.hit) ?? []
        XCTAssertEqual(hits.map(\.package), ["opencode-example-auth", "@magpie-community/example-auth"])
        XCTAssertEqual(hits[0].author, "someone")
        XCTAssertEqual(hits[0].summary, "OpenCode auth plugin for Example")

        let page = WebPluginReadme(json: try WebFixture.json("plugins-page.json"))
        XCTAssertNotNil(page.updatedDate, "纳秒的 RFC3339 也能读")
        XCTAssertNil(WebPluginReadme(readme: "", updated: "0001-01-01T00:00:00Z").updatedDate)

        let registry = PluginRegistry(json: try WebFixture.json("plugins-registry.json")["registry"] ?? .null)
        XCTAssertEqual(registry.fromText, "在此设置")
        XCTAssertTrue(registry.setHere)
        let full = WebPlugins(json: try WebFixture.json("plugins-installed-full.json"))
        XCTAssertEqual(full.registry?.fromText, "来自 ~/.bunfig.toml")
        XCTAssertTrue(full.mirror)
        XCTAssertEqual(full.movable.first?.accounts, 2)
        XCTAssertNil(WebPlugins(json: ["plugins": []]).registry, "旧版 magpie 没有 npm 源")
    }

    func testInstalledEntryFields() throws {
        let state = WebPlugins(json: try WebFixture.json("plugins-installed-full.json"))
        let auth = try XCTUnwrap(state["@magpie-community/example-auth"])
        XCTAssertEqual(auth.moved, ["example"])
        XCTAssertEqual(auth.autoUpdated?.to, "1.2.0")
        XCTAssertEqual(auth.clashes.first?.with, ["./my-example-auth"])
        XCTAssertEqual(auth.kindChips.map(\.kind), [.provider])
        XCTAssertTrue(auth.updateOffered)

        let mw = try XCTUnwrap(state["example-middleware@2"])
        XCTAssertEqual(mw.kindChips.map(\.kind), [.middleware], "只有中间件：没有「供应商」标签")
        XCTAssertEqual(mw.logoKind, .middleware)
        XCTAssertTrue(mw.hasOptionsEditor)
        let line = PluginFormat.middlewareLine(try XCTUnwrap(mw.middleware))
        XCTAssertEqual(line.text, "网关中间件：onRequest、onResponse · 调用 12,345 次，平均每次 4.2 µs · 路由：cheapest · 已调用 7 次 · 用量观察：99 条")
        XCTAssertEqual(line.failures, ["3 次失败", "丢弃 2 条"])

        let hook = try XCTUnwrap(state["example-context-hook"])
        XCTAssertEqual(hook.kindChips.map(\.title), ["请求 Hook"])
        XCTAssertTrue(hook.hasOptionsEditor)
        XCTAssertEqual(PluginFormat.gatewayLine(try XCTUnwrap(hook.gateway)), "网关请求 Hook：已注入上下文 · 调用 10 次，平均每次 12.3 ms · 已注入 2,048 字节 · 1 次失败")

        let agent = try XCTUnwrap(state["example-agent"])
        XCTAssertEqual(agent.logoKind, .agent)
        XCTAssertEqual(PluginFormat.agentLine(try XCTUnwrap(agent.agent)).text, "把 Example Agent 加到 Agent 页")

        let tools = try XCTUnwrap(state["example-search-tools"])
        XCTAssertEqual(tools.kindChips.map(\.kind), [.tools])
        XCTAssertEqual(tools.logoKind, .tools)
        XCTAssertEqual(PluginFormat.toolsLine(tools.tools), "给每个智能体的工具：example_search")

        let dash = try XCTUnwrap(state["github:example-owner/magpie-dash"])
        XCTAssertFalse(dash.gitBehind, "短 sha 是同一个提交")
        XCTAssertFalse(dash.updateOffered)
        XCTAssertEqual(dash.kindChips.map(\.kind), [.page, .panels])
        XCTAssertEqual(PluginFormat.pageLine(try XCTUnwrap(dash.page)), "取代「用量」页面，可以读取你的用量合计（按模型）、你的服务商名称")
        XCTAssertEqual(PluginFormat.panelsLine(dash.panels, reads: dash.panelReads), "在「用量」页面、每个服务商的编辑页中添加面板，不读取 magpie 的任何内容")
        XCTAssertEqual(PluginFormat.actionsLine(dash.actions), "在供应商的菜单中添加菜单项，点击后打开它的页面")
        XCTAssertFalse(dash.hasOptionsEditor)
    }

    func testClashLinesNameOtherCopy() throws {
        let state = WebPlugins(json: try WebFixture.json("plugins-installed-full.json"))
        let m = PluginMarket(state: state, listings: [])
        let auth = try XCTUnwrap(state["@magpie-community/example-auth"])
        let mine = try XCTUnwrap(state["./my-example-auth"])
        let nameOf: (String) -> String = { spec in state[spec].map(m.shownName) ?? PluginSpec.label(spec) }
        XCTAssertEqual(PluginFormat.clashLines(auth, ownName: m.shownName(auth), nameOf: nameOf).map(\.text),
                       ["my-example-auth 也能登录 Example Cloud，现由这个插件提供"])
        let other = PluginFormat.clashLines(mine, ownName: m.shownName(mine), nameOf: nameOf)
        XCTAssertEqual(other.map(\.text), ["Example Cloud 由同样登录它的 @magpie-community/example-auth 提供"])
        XCTAssertFalse(other[0].here)
    }

    func testMergeAndEntryMatching() throws {
        let m = try market()
        XCTAssertEqual(m.mergedListings?.first?.npm?.weekly, 15230, "npm 的回答进到卡片里")
        let auth = try XCTUnwrap(m.installed.first { $0.spec == "@magpie-community/example-auth" })
        XCTAssertEqual(auth.latest, "1.4.0", "也进到已安装插件里")
        XCTAssertEqual(m.entry(for: "github:example-owner/magpie-dash")?.spec, "github:example-owner/magpie-dash", "GitHub 卡片按仓库找")
        XCTAssertNil(m.entry(for: "example-relay-auth"))
        XCTAssertEqual(m.shownName(auth), "Example Cloud", "市场的名字优先")
        let behind = PluginMarket(state: m.state, listings: m.listings, heads: ["github:example-owner/magpie-dash": "fff0000"])
        XCTAssertTrue(behind.installed[1].gitBehind)
        XCTAssertEqual(behind.outdated.map(\.spec), ["@magpie-community/example-auth"], "停用的 git 插件不算在「有新版本」里")
    }

    func testCardActions() throws {
        let sub = PluginSub(id: "plugin-example", pid: "example", name: "Example Cloud", spec: "@magpie-community/example-auth", signedIn: false)
        var m = try market(subs: [sub])
        let listings = try XCTUnwrap(m.mergedListings)
        XCTAssertEqual(m.action(for: "@magpie-community/example-auth", listing: listings[0], busy: [:]), .signIn(sub), "没登录时先登录")
        m.subs = [PluginSub(id: "plugin-example", pid: "example", name: "Example Cloud", spec: "@magpie-community/example-auth", signedIn: true)]
        XCTAssertEqual(m.action(for: "@magpie-community/example-auth", listing: listings[0], busy: [:]),
                       .update(spec: "@magpie-community/example-auth", to: "1.4.0"), "登录后有更新就显示「更新」")
        XCTAssertEqual(m.action(for: "@magpie-community/example-auth", listing: listings[0], busy: ["@magpie-community/example-auth": "upgrade"]), .updating)
        XCTAssertEqual(m.action(for: "example-agent", listing: listings[1], busy: [:]), .comingSoon, "npm 说没有版本：即将上线")
        XCTAssertEqual(m.action(for: "example-tools", listing: listings[2].with(npm: .unknownAnswer), busy: [:]), .install, "npm 没说：仍可安装")
        let unasked = WebPluginListing(raw: ["package": "example-unasked", "name": "x"])
        XCTAssertEqual(m.action(for: "example-unasked", listing: unasked, busy: [:]), .waiting)
        XCTAssertEqual(m.action(for: "example-unasked", listing: nil, busy: ["example-unasked": "add"]), .installing("安装中…"))
        XCTAssertEqual(m.action(for: "github:example-owner/magpie-dash", listing: nil, busy: [:]), .switchOn(spec: "github:example-owner/magpie-dash"))
        XCTAssertEqual(PluginMarket(state: nil, listings: []).action(for: "x", listing: nil, busy: [:]), .waiting)
        let full = PluginMarket(state: WebPlugins(json: try WebFixture.json("plugins-installed-full.json")), listings: [])
        guard case .move(let c, here: false) = full.action(for: "example-other-auth", listing: nil, busy: [:]) else { return XCTFail("应当是迁移") }
        XCTAssertEqual(c.name, "Other Cloud")
        XCTAssertEqual(full.action(for: "example-middleware", listing: nil, busy: [:]), .installed)
    }

    func testDiscoverSectionsSearchAndGitHub() throws {
        let m = try market()
        let sections = m.discoverSections()
        XCTAssertEqual(sections.map(\.id), [.subscriptions], "不搜索时只列 magpie 社区的")
        XCTAssertEqual(sections[0].title, "订阅")
        XCTAssertEqual(m.suggested(matching: "agent").map(\.package), ["example-agent"])
        XCTAssertEqual(m.suggested(matching: "Sign in to Example").map(\.package), ["@magpie-community/example-auth"], "英文简介也能搜到")
        XCTAssertEqual(m.githubCards(matching: "").map(\.package), ["github:example-owner/magpie-dash", "example-relay-auth"],
                       "市场已列出的包不在 GitHub 区重复")
        XCTAssertEqual(m.githubCards(matching: "relay").map(\.package), ["example-relay-auth"])
        let hits = try WebFixture.json("plugins-search.json")["hits"]?.array?.compactMap(WebPluginListing.hit) ?? []
        XCTAssertEqual(m.npmCards(hits).map(\.package), ["opencode-example-auth"], "上面已有的包不再出现在 npm 区")

        let cards = m.githubCards(matching: "")
        XCTAssertFalse(PluginGitHubFilter.shows(for: cards))
        XCTAssertEqual(PluginGitHubFilter.kinds(in: cards), [.provider, .page])
        let isInstalled: (WebPluginListing) -> Bool = { m.entry(for: $0.package) != nil }
        let filter = PluginGitHubFilter(kind: nil, installed: false)
        XCTAssertEqual(filter.apply(cards, isInstalled: isInstalled).map(\.package), ["example-relay-auth"])
        XCTAssertEqual(filter.count(cards, kind: .page, installed: true, isInstalled: isInstalled), 1)
        XCTAssertEqual(PluginGitHubFilter(query: "someone").apply(cards, isInstalled: isInstalled).count, 1, "按作者筛选")
    }

    func testNamesakeAsksBeforeReplacing() throws {
        let m = try market()
        let gh = WebPluginListing.github(WebTaggedRepo(raw: ["spec": "github:fork/example-auth", "repo": "fork/example-auth",
                                                               "package": "@magpie-community/example-auth"]))
        let withFork = PluginMarket(state: m.state, listings: m.listings, tagged: [gh])
        let r = try XCTUnwrap(withFork.namesake(of: "github:fork/example-auth"))
        XCTAssertEqual(r.old, "npm:@magpie-community/example-auth")
        XCTAssertEqual(r.new, "github:fork/example-auth")
        XCTAssertEqual(r.title, "用 github:fork/example-auth 替换 npm:@magpie-community/example-auth？")
        XCTAssertNil(m.namesake(of: "@magpie-community/example-auth@" + "1.0.0"), "npm 上同一个包的另一个版本不算替换")
        XCTAssertNil(m.namesake(of: "example-middleware", typed: true), "输入框里写的不带作用域的名字不问")
    }

    func testSortAndCountFormatting() throws {
        let m = PluginMarket(state: WebPlugins(json: try WebFixture.json("plugins-installed-full.json")), listings: [])
        XCTAssertEqual(m.sorted(.nameAscending).first?.spec, "@magpie-community/example-auth")
        XCTAssertEqual(m.sorted(.nameDescending).first?.spec, "./my-example-auth")
        XCTAssertTrue(m.canCheck)
        XCTAssertEqual(PluginFormat.count(999), "999")
        XCTAssertEqual(PluginFormat.count(1_234), "1.2k")
        XCTAssertEqual(PluginFormat.count(15_230), "15k")
        XCTAssertEqual(PluginFormat.count(2_500_000), "2.5M")
    }

    func testVersionCheckWhyText() {
        let git = PluginVersionCheck(raw: ["spec": "github:a/b", "status": "unknown", "limited": ["token": true]])
        XCTAssertEqual(git.whyText, "无法向 github:a/b 查询最新提交：你的 GitHub token 的请求额度暂时用完了")
        let missing = PluginVersionCheck(raw: ["spec": "x", "status": "unknown", "why": "missing"])
        XCTAssertEqual(missing.whyText, "npm 上没有这个包")
        XCTAssertEqual(PluginVersionCheck(raw: ["spec": "github:a/b", "status": "update"]).summary, "有新提交")
        let all = WebPluginCheck(json: ["plugins": [["spec": "x", "status": "unknown", "why": "limited"]]])
        XCTAssertEqual(all.summary, "无法检查更新：npm 暂时拒绝请求（请求过多），请几分钟后再试")
    }

    func testReadmeBlocks() throws {
        let page = WebPluginReadme(json: try WebFixture.json("plugins-page.json"))
        let blocks = PluginReadme.blocks(page.readme)
        XCTAssertEqual(blocks.first, .heading(level: 1, text: "Example Cloud", slug: "example-cloud"))
        XCTAssertEqual(blocks[1], .paragraph("Sign in to **Example Cloud** with `magpie`."), "徽章和 HTML 注释去掉")
        XCTAssertEqual(blocks[2], .heading(level: 2, text: "💡 Quick start", slug: "-quick-start"))
        XCTAssertEqual(blocks[3], .list(ordered: true, items: ["Install it", "Sign in — see [docs](https://example.com/docs) or [the next part](#usage)"]))
        XCTAssertEqual(blocks[4], .list(ordered: false, items: ["✓ done", "☐ todo continued"]))
        XCTAssertEqual(blocks[5], .quote("NOTE: Keep your key safe."))
        XCTAssertEqual(blocks[6], .code(language: "sh", text: "magpie plugin add x"))
        XCTAssertEqual(blocks[7], .table(rows: [["Option", "Default"], ["region", "`cn`"]]))
        XCTAssertEqual(blocks[8], .rule)
        XCTAssertEqual(blocks[9], .paragraph("Read [the site](https://example.com) or local."), "图片、相对链接、script 都不显示")
        XCTAssertEqual(blocks.count, 10)
        XCTAssertTrue(PluginReadme.blocks("").isEmpty)
    }
}

final class PluginMarketClientTests: XCTestCase {
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

    private func query(_ name: String) -> String? {
        StubURLProtocol.lastRequest?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == name }?.value
    }

    private func body() throws -> WebJSON {
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
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

    func testDiscoverReads() async throws {
        stub("plugins-github.json")
        let gh = try await client.taggedPlugins(again: true)
        XCTAssertEqual(gh.repos.count, 3)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/plugins/github")
        XCTAssertEqual(query("again"), "1")
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Cookie"), "magpie_web_3430=web-key-EXAMPLE-0123")

        stub("plugins-npm.json")
        let npm = try await client.pluginNPM(names: ["example-agent", "@magpie-community/example-auth", "example-agent", ""])
        XCTAssertEqual(npm.count, 2)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/plugins/npm")
        XCTAssertEqual(query("names"), "@magpie-community/example-auth,example-agent")
        StubURLProtocol.lastRequest = nil
        let none = try await client.pluginNPM(names: [])
        XCTAssertTrue(none.isEmpty)
        XCTAssertNil(StubURLProtocol.lastRequest, "没有包名时不问")

        stub("plugins-git.json")
        let heads = try await client.pluginGitHeads()
        XCTAssertEqual(heads["github:example-owner/magpie-dash"], "def5678")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/plugins/git")

        stub("plugins-search.json")
        let hits = try await client.searchPlugins("example auth")
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/plugins/search")
        XCTAssertEqual(query("q"), "example auth")

        stub("plugins-page.json")
        let readme = try await client.pluginReadme("@magpie-community/example-auth")
        XCTAssertTrue(readme.readme.hasPrefix("# Example Cloud"))
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/plugins/page")
        XCTAssertEqual(query("name"), "@magpie-community/example-auth")
    }

    func testSettingsWrites() async throws {
        stub("plugins-mirror.json")
        let mirror = try await client.setPluginMirror(true)
        XCTAssertTrue(mirror)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/plugins/mirror")
        XCTAssertEqual(try body(), ["on": true])

        stub("plugins-registry.json")
        let registry = try await client.setPluginRegistry(" https://registry.npmmirror.example \n")
        XCTAssertEqual(registry.url, "https://registry.npmmirror.example")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/plugins/registry")
        XCTAssertEqual(try body(), ["url": "https://registry.npmmirror.example"])

        stub("plugins.json")
        _ = try await client.plugin(.prefer, PluginRequests.prefer("./my-example-auth", provider: "example"))
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/plugins/prefer")
        XCTAssertEqual(try body(), ["spec": "./my-example-auth", "provider": "example"])
        _ = try await client.plugin(.options, PluginRequests.clearOptions("x"))
        XCTAssertEqual(try body(), ["spec": "x", "options": .null], "清空选项发 null")

        stub("providers.json")
        try await client.movePluginProvider("other")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/provider/move")
        XCTAssertEqual(try body(), ["id": "other"])
        XCTAssertGreaterThanOrEqual(StubURLProtocol.lastRequest?.timeoutInterval ?? 0, WebClient.pluginInstallTimeout)
    }

    func testPluginProvidersAndIcon() async throws {
        stub("providers-plugin-options.json")
        let providers = try await client.pluginProviders()
        XCTAssertEqual(providers.options.count, 2)
        XCTAssertEqual(providers.subs.first?.pid, "example")
        XCTAssertEqual(providers.subs.first?.signedIn, true)
        StubURLProtocol.handler = { _ in (200, ["Content-Type": "image/png"], Data([0x89, 0x50])) }
        let data = try await client.pluginIcon("file:abc123.png")
        XCTAssertEqual(data, Data([0x89, 0x50]))
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/icons/abc123.png")
        let bundled = try await client.pluginIcon("zcode")
        XCTAssertNil(bundled, "内置图标名不走网络")
    }
}
