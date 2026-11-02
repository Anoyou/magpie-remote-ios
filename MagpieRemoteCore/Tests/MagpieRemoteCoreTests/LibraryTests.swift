import XCTest
@testable import MagpieRemoteCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 资源库页（官方 Library：指令、MCP 服务器、技能、Hooks、子代理、RTK）。
final class LibraryTests: XCTestCase {
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

    private func body(_ request: URLRequest?) throws -> WebJSON {
        guard let request else { return .null }
        if let data = request.httpBody { return try WebJSON.decode(data) }
        guard let stream = request.httpBodyStream else { return .null }
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

    private func page() throws -> LibrarySnapshot { LibrarySnapshot(json: try WebFixture.json("library.json")) }

    // MARK: 解码

    func testDecodesWholePage() throws {
        let lib = try page()
        XCTAssertEqual(lib.agents.map(\.id), ["claude", "codex", "cursor", "claude-desktop", "workbuddy"])
        XCTAssertEqual(lib.servers.map(\.name), ["github", "filesystem", "events"])
        XCTAssertEqual(lib.skills.count, 4)
        XCTAssertEqual(lib.hooks.count, 3)
        XCTAssertEqual(lib.subagents.first?.skills, ["pdf"])
        XCTAssertEqual(lib.instructions.sets.count, 2)
        XCTAssertEqual(lib.instructions.inUse?.id, "default")
        XCTAssertEqual(lib.instructions.sets[1].title, "公司规范")
        XCTAssertEqual(lib.instructions.sets[0].title, "默认")
        XCTAssertEqual(lib.instructions.sets[0].firstLine, "规范")
        XCTAssertEqual(lib.instructions.sets[1].firstLine, "空")
        XCTAssertEqual(lib.projects.first?.skills["pdf"], ["claude"])
        XCTAssertTrue(lib.checkDue)
        XCTAssertNil(lib.result)
        XCTAssertEqual(lib.tilde("/Users/someone/.claude/CLAUDE.md"), "~/.claude/CLAUDE.md")
        XCTAssertEqual(lib.count(.mcp), 3)
        XCTAssertEqual(lib.count(.skills), 4)
        XCTAssertNil(lib.count(.rtk))
    }

    func testAgentsShownPerTab() throws {
        let lib = try page()
        // 已卸载的 WorkBuddy 不显示；只在还有它的行上补上
        XCTAssertEqual(lib.shownAgents().map(\.id), ["claude", "codex", "cursor", "claude-desktop"])
        XCTAssertEqual(lib.mcpAgents().map(\.id), ["claude", "codex", "cursor", "claude-desktop"])
        XCTAssertEqual(lib.skillAgents().map(\.id), ["claude", "codex", "cursor"])
        XCTAssertEqual(lib.skillAgents(hidden: ["codex"]).map(\.id), ["claude", "cursor"])
        let fs = lib.servers[1]
        XCTAssertEqual(lib.withGone(lib.mcpAgents(), on: fs.agents).map(\.id).last, "workbuddy")
        XCTAssertEqual(lib.hookTargets().map(\.id), ["claude", "codex", "cursor", "claude-desktop"])
        XCTAssertEqual(lib.subagentTargets().map(\.id), ["claude", "codex", "cursor", "claude-desktop"])
    }

    func testServerFieldsAndBlocked() throws {
        let lib = try page()
        let github = lib.servers[0]
        XCTAssertTrue(github.isRemote)
        XCTAssertTrue(github.signedIn)
        XCTAssertTrue(github.usesEnvRefs)
        XCTAssertEqual(github.oauthClientID, "client-EXAMPLE")
        XCTAssertEqual(github.line, "https://api.example.com/mcp/")
        let desktop = try XCTUnwrap(lib.agent("claude-desktop"))
        XCTAssertEqual(github.blocked(for: desktop), "Claude Desktop 的配置文件只支持命令启动的服务器 — 远程服务器请在它的「连接器」里添加")
        XCTAssertNil(github.blocked(for: try XCTUnwrap(lib.agent("claude"))))
        let events = lib.servers[2]
        XCTAssertEqual(events.blocked(for: try XCTUnwrap(lib.agent("codex"))), "Codex 不支持 SSE 服务器 — 只支持命令或 Streamable HTTP")
        XCTAssertEqual(events.startupTimeout, 45)
        let fs = lib.servers[1]
        XCTAssertEqual(fs.line, "npx -y @example/server-filesystem '/Users/someone/My Projects'")
        XCTAssertTrue(fs.local)
        XCTAssertEqual(fs.problems["cursor"], "mcp.json isn't valid JSON")
        XCTAssertEqual(fs.disabledTools, ["delete_file"])
    }

    func testServerSaveKeepsUnknownFieldsAndDropsViewOnes() throws {
        var github = try page().servers[0]
        github.agents = ["claude"]
        github.headers["X-Extra"] = "1"
        let saved = github.saveBody
        XCTAssertEqual(saved["oauth"]?["clientId"]?.string, "client-EXAMPLE")
        XCTAssertNil(saved["signIn"])
        XCTAssertNil(saved["icon"])
        XCTAssertNil(saved["problems"])
        XCTAssertNil(saved["command"])
        XCTAssertEqual(saved["agents"]?.strings, ["claude"])
        XCTAssertEqual(saved["headers"]?["X-Extra"]?.string, "1")
        var fs = try page().servers[1]
        fs.args = LibraryShell.words("-y @example/server-filesystem '/Users/someone/My Projects'")
        XCTAssertEqual(fs.saveBody["args"]?.strings, ["-y", "@example/server-filesystem", "/Users/someone/My Projects"])
        XCTAssertEqual(fs.saveBody["disabledTools"]?.strings, ["delete_file"])
        XCTAssertNil(fs.saveBody["url"])
    }

    func testSkillStates() throws {
        let lib = try page()
        let pdf = lib.skills[0]
        XCTAssertTrue(pdf.hasUpdate)
        XCTAssertTrue(pdf.canUpdate)
        XCTAssertEqual(pdf.behind, ["codex"])
        XCTAssertEqual(pdf.sourceLine, "example-org/skills/tree/main/pdf")
        let old = lib.skills[2]
        XCTAssertTrue(old.isGone)
        XCTAssertFalse(old.canUpdate)
        let notes = lib.skills[3]
        XCTAssertTrue(notes.offHere)
        XCTAssertEqual(notes.sourceLine, "链接自 /Users/someone/skills/notes")
        XCTAssertNotNil(notes.alwaysNote(for: try XCTUnwrap(lib.agent("cursor"))))
        XCTAssertEqual(lib.skillsWithUpdates.map(\.name), ["pdf"])
        XCTAssertEqual(lib.goneSkills.map(\.name), ["old-tool"])
        // 同一仓库三个成组，其余放「其他」（空仓库名）
        let groups = lib.skillGroups()
        XCTAssertEqual(groups.map(\.repo), ["example-org/skills", ""])
        XCTAssertEqual(groups[0].skills.map(\.name), ["docx", "old-tool", "pdf"])
        XCTAssertEqual(lib.skillGroups(filter: "word").flatMap { $0.skills.map(\.name) }, ["docx"])
    }

    func testHooksAndSubagents() throws {
        let lib = try page()
        let notify = lib.hooks[0]
        XCTAssertEqual(notify.line(), "一轮结束时")
        let format = lib.hooks[1]
        XCTAssertTrue(format.isToolEvent)
        XCTAssertEqual(format.line(), "工具运行后 · 文件编辑")
        let own = lib.hooks[2]
        XCTAssertEqual(own.ownAgent, "codex")
        XCTAssertEqual(own.line(agentName: lib.name(of:)), "Codex · PermissionRequest · shell")
        XCTAssertEqual(lib.hookBlocked(own, agent: try XCTUnwrap(lib.agent("claude"))), "PermissionRequest 是 Codex 自己的事件：只有它能运行这个 Hook")
        XCTAssertEqual(lib.hookBlocked(notify, agent: try XCTUnwrap(lib.agent("claude-desktop"))), "Claude Desktop 没有 magpie 能写入的 Hook")
        XCTAssertNil(lib.hookBlocked(notify, agent: try XCTUnwrap(lib.agent("claude"))))
        XCTAssertTrue(lib.hookAgent("codex")?.off ?? false)
        XCTAssertEqual(notify.saveBody["timeout"]?.int, 0)
        let sub = lib.subagents[0]
        XCTAssertEqual(sub.line, "技能：pdf · MCP 服务器：github")
        XCTAssertEqual(lib.subagentBlocked(try XCTUnwrap(lib.agent("claude-desktop"))), "Claude Desktop 没有 magpie 能写入的子代理")
        XCTAssertTrue(LibraryShell.validSubagentName("code-reviewer"))
        XCTAssertFalse(LibraryShell.validSubagentName("Code Reviewer"))
        XCTAssertTrue(LibraryShell.validName("my_server-2"))
        XCTAssertFalse(LibraryShell.validName("my server"))
    }

    func testProblemsByTab() throws {
        let lib = try page()
        XCTAssertEqual(lib.problems(on: .mcp).map(\.what), ["mcp:filesystem"])
        XCTAssertEqual(lib.problems(on: .instructions).map(\.what), ["instructions"])
        XCTAssertEqual(lib.problemCounts(except: .mcp).map(\.tab), [.instructions])
        XCTAssertEqual(LibraryWords.problemWhat("mcp:filesystem"), "MCP 服务器 filesystem")
        XCTAssertEqual(LibraryWords.problemWhat("skill:pdf"), "技能 pdf")
        XCTAssertEqual(LibraryWords.problemWhat("instructions"), "指令")
        XCTAssertEqual(lib.problem(for: "mcp:filesystem", agent: "cursor"), "mcp.json isn't valid JSON")
    }

    func testRTK() throws {
        let rtk = LibraryRTK(json: try WebFixture.json("library-rtk.json"))
        XCTAssertTrue(rtk.installed)
        XCTAssertTrue(rtk.behind)
        XCTAssertEqual(rtk.versionNote, "v0.52.0 可升级")
        XCTAssertEqual(rtk.gainLine, "1280 条命令共节省 7.3M token，平均省 75%")
        XCTAssertEqual(rtk.tag(rtk.agents[2]), "需更新 RTK")
        XCTAssertEqual(rtk.tag(rtk.agents[3]), "RTK 暂不支持")
        XCTAssertNil(rtk.tag(rtk.agents[0]))
        XCTAssertTrue(LibraryRTK.newer("0.10.0", than: "0.9.9"))
        XCTAssertFalse(LibraryRTK.newer("v0.52.0", than: "0.52.0"))
        let missing = LibraryRTK(json: ["agents": [], "url": "https://rtk-ai.app"])
        XCTAssertFalse(missing.installed)
        XCTAssertEqual(missing.gainLine, "还没有节省记录：打开后重启 Agent，它的命令就会经过 RTK。")
    }

    func testHealthWordsLikeOfficial() throws {
        let json = try WebFixture.json("library-mcp-check.json")["servers"]
        let ok = LibraryServerHealth(json: try XCTUnwrap(json?["github"]))
        XCTAssertEqual(ok.words(transport: "http").short, "2 个工具")
        XCTAssertEqual(ok.toolList.map(\.name), ["search_code", "create_issue"])
        let slow = LibraryServerHealth(json: try XCTUnwrap(json?["filesystem"]))
        XCTAssertEqual(slow.words(transport: "stdio").short, "tools/list 无响应")
        XCTAssertEqual(slow.words(transport: "stdio").long, "等了 30 秒，tools/list 仍没有响应\nnpm warn exec")
        let auth = LibraryServerHealth(json: try XCTUnwrap(json?["events"]))
        XCTAssertEqual(auth.words(transport: "sse", name: { $0 == "claude" ? "Claude Code" : $0 }).short, "已在 Claude Code 登录")
        let refused = LibraryServerHealth(json: ["state": "auth", "code": 403])
        XCTAssertEqual(refused.words(transport: "http").long, "服务器拒绝了 magpie（HTTP 403）— Headers 里的密钥可能缺失或有误")
        let novar = LibraryServerHealth(json: ["state": "fail", "why": "novar", "detail": "API_KEY"])
        XCTAssertTrue(novar.isUnknown)
        XCTAssertEqual(novar.words(transport: "stdio").short, "API_KEY 未设置")
    }

    func testProbeAndMarket() throws {
        let probe = LibraryProbe(json: try WebFixture.json("library-probe.json"))
        XCTAssertEqual(probe.candidates.map(\.name), ["pdf", "xlsx", "skill-creator"])
        XCTAssertTrue(probe.candidates[0].have)
        XCTAssertEqual(probe.candidates[2].addsAs, "skill-creator-example-org")
        XCTAssertEqual(probe.left.first?.path, "huge")
        let market = LibraryMarket(json: try WebFixture.json("library-market-servers.json"), item: LibraryMarketServer.init(json:))
        XCTAssertEqual(market.items.count, 2)
        XCTAssertEqual(market.failed, "registry")
        XCTAssertEqual(market.items[0].unready, "Settings › Models › Web search isn't set up")
        XCTAssertEqual(market.items[1].runsLabel, "远程 · 需登录")
        XCTAssertEqual(market.items[1].inputs.first?.place, "header")
        XCTAssertEqual(market.items[1].have, "notion")
    }

    func testPastedServers() {
        let readme = """
        {"mcpServers": {"github": {"command": "npx", "args": ["-y", "@example/github"], "env": {"TOKEN": "${GITHUB_TOKEN}"}},
                        "docs": {"url": "https://docs.example.com/sse"},}}
        """
        let list = LibraryShell.servers(fromPasted: readme)
        XCTAssertEqual(list?.map(\.name), ["docs", "github"])
        XCTAssertEqual(list?[0].transport, "sse")
        XCTAssertEqual(list?[1].args, ["-y", "@example/github"])
        XCTAssertEqual(list?[1].env["TOKEN"], "${GITHUB_TOKEN}")
        let one = LibraryShell.servers(fromPasted: #""weather": {"type": "http", "url": "https://w.example.com/mcp"}"#)
        XCTAssertEqual(one?.first?.name, "weather")
        XCTAssertEqual(one?.first?.transport, "http")
        XCTAssertNil(LibraryShell.servers(fromPasted: "not json"))
    }

    func testShellWords() {
        XCTAssertEqual(LibraryShell.words(#"npx -y "a b" 'c d' e\ f"#), ["npx", "-y", "a b", "c d", "e f"])
        XCTAssertEqual(LibraryShell.words("  "), [])
        XCTAssertEqual(LibraryShell.words("a ''"), ["a", ""])
        XCTAssertEqual(LibraryShell.quote("it's"), #"'it'\''s'"#)
        XCTAssertEqual(LibraryShell.quote("@scope/pkg"), "@scope/pkg")
    }

    // MARK: 文案

    func testReportLikeOfficial() throws {
        let name: (String) -> String = { ["claude": "Claude Code", "codex": "Codex"][$0] ?? $0 }
        func result(_ json: WebJSON) -> LibraryResult { LibraryResult(json: json) }
        XCTAssertEqual(LibraryWords.report(result(["changed": ["claude"]]), done: nil, name: name)?.text, "已写入 Claude Code")
        XCTAssertEqual(LibraryWords.report(result(["changed": ["claude", "codex"]]), done: nil, name: name)?.text, "已写入 2 个 Agent")
        XCTAssertEqual(LibraryWords.report(result(["changed": []]), done: nil, name: name)?.text, "已保存 — Agent 中已是最新")
        XCTAssertEqual(LibraryWords.report(result(["changed": ["codex"]]), done: nil, given: ["claude"], name: name)?.text, "已从 Codex 中移除")
        let problem = LibraryWords.report(result(["changed": [], "problems": [["agent": "codex", "what": "mcp:x", "error": "no SSE"], ["agent": "claude", "what": "mcp:x", "error": "e"]]]), done: "已保存 x", name: name)
        XCTAssertEqual(problem?.text, "Codex：no SSE （另有 1 项）")
        XCTAssertEqual(problem?.warn, true)
        let installed = LibraryWords.report(result(["installed": ["xlsx"], "had": ["pdf"], "skipped": [["agent": "", "what": "skill:big", "error": "too big"]]]), done: nil, name: name)
        XCTAssertEqual(installed?.text, "已安装 1 个技能 · 资源库里已有：pdf · 已跳过 big：too big")
        XCTAssertEqual(LibraryWords.report(result(["gone": ["old-tool"]]), done: nil, name: name)?.text, "old-tool 已从来源中删除")
        XCTAssertEqual(LibraryWords.report(result(["changed": ["claude"]]), done: "已移除 pdf", name: name)?.text, "已移除 pdf")
    }

    func testConfirmationTexts() throws {
        let lib = try page()
        XCTAssertEqual(LibraryWords.removeOneMessage(agents: []), "它会从资源库中删除；目前没有 Agent 启用它。")
        XCTAssertEqual(LibraryWords.removeServerMessage(lib.servers[0], agents: ["Claude Code", "Codex"], projects: 1),
                       "它会从资源库中删除，并从 Claude Code、Codex 中移除。\nmagpie 放进 1 个项目里的它也会一并移除。\nmagpie 对它的登录也会一并清除。\nAgent 自己的、不在资源库中的服务器保持不变。")
        XCTAssertEqual(LibraryWords.removeSkillMessage(lib.skills[3]), "将从所有已启用的 Agent 中移除，链接的原文件夹保持不动。")
        XCTAssertEqual(LibraryWords.updateEdited(lib.skills[1]).title, "用 GitHub 的版本替换你对 docx 的改动？")
        XCTAssertEqual(LibraryWords.removeGone([lib.skills[2]]).title, "移除 old-tool？")
        XCTAssertEqual(LibraryWords.everyOff(.skills, count: 4, agents: ["Claude Code"]).title, "关闭全部 4 个技能？")
        XCTAssertEqual(LibraryWords.removeEvery(.mcp, count: 3, agents: []).title, "删除全部 3 个服务器？")
        let found = lib.foundServers[0]
        XCTAssertEqual(LibraryWords.removeFoundServerMessage(found, name: lib.name(of:)),
                       "将从 Codex 的 MCP 配置中移除。每个文件改动前都会先复制到 magpie 的备份。\nClaude Code 中有另一个同名服务器，那个保持不动。")
        XCTAssertEqual(lib.listedFoundServers.map(\.id), ["postgres"])
        XCTAssertEqual(LibraryWords.checked(lib), "1 个技能有更新 · 同一仓库里还有 1 个技能")
    }

    // MARK: 请求

    func testGlanceQueryAndCookie() async throws {
        StubURLProtocol.handler = { _ in (200, ["Content-Type": "application/json"], try WebFixture.data("library.json")) }
        let lib = try await client.library(glance: true)
        XCTAssertEqual(lib.servers.count, 3)
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.path, "/api/library")
        XCTAssertEqual(request.url?.query, "glance=1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "magpie_web_3430=web-key-EXAMPLE-0123")
    }

    func testChangeBodiesMatchOfficial() async throws {
        StubURLProtocol.handler = { _ in (200, ["Content-Type": "application/json"], try WebFixture.data("library.json")) }
        let lib = try page()
        _ = try await client.library(.serversAgents, LibraryRequests.agents("github", ["claude"]), current: lib)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/library/servers/agents")
        XCTAssertEqual(try body(StubURLProtocol.lastRequest), ["name": "github", "agents": ["claude"]])
        _ = try await client.library(.skillsUpdate, LibraryRequests.update("docx", replace: true), current: lib)
        XCTAssertEqual(try body(StubURLProtocol.lastRequest), ["name": "docx", "replace": true])
        _ = try await client.library(.skillsHere, LibraryRequests.here("notes", on: true), current: lib)
        XCTAssertEqual(try body(StubURLProtocol.lastRequest), ["name": "notes", "on": true])
        _ = try await client.library(.skillsAgentsAll, LibraryRequests.every(agents: ["claude", "codex"], on: false), current: lib)
        XCTAssertEqual(try body(StubURLProtocol.lastRequest), ["agents": ["claude", "codex"], "on": false])
        _ = try await client.library(.skillsInstall, LibraryRequests.install(source: "example-org/skills", paths: ["xlsx"], agents: ["claude"]), current: lib)
        XCTAssertEqual(try body(StubURLProtocol.lastRequest), ["source": "example-org/skills", "paths": ["xlsx"], "agents": ["claude"]])
        _ = try await client.library(.hooksSave, LibraryRequests.saveHook(old: "", LibraryHook(name: "n", event: "turn-end", command: "say hi", agents: ["claude"])), current: lib)
        let hook = try body(StubURLProtocol.lastRequest)
        XCTAssertEqual(hook["old"], "")
        XCTAssertEqual(hook["hook"]?["command"], "say hi")
        _ = try await client.library(.subagentsSave, LibraryRequests.saveSubagent(old: "code-reviewer", lib.subagents[0]), current: lib)
        XCTAssertEqual(try body(StubURLProtocol.lastRequest)["subagent"]?["mcp"], ["github"])
        _ = try await client.library(.marketServer, LibraryRequests.marketServer(id: "io.example/notion", values: ["NOTION_TOKEN": "tok-EXAMPLE"], agents: ["claude"]), current: lib)
        XCTAssertEqual(try body(StubURLProtocol.lastRequest), ["id": "io.example/notion", "values": ["NOTION_TOKEN": "tok-EXAMPLE"], "agents": ["claude"]])
        XCTAssertEqual(StubURLProtocol.lastRequest?.timeoutInterval, 180)
    }

    func testInstructionChangeMergesOnlyItsPart() async throws {
        StubURLProtocol.handler = { _ in (200, ["Content-Type": "application/json"], try WebFixture.data("library-instructions-answer.json")) }
        let lib = try page()
        let next = try await client.library(.instructionsSave, LibraryRequests.instructionAgents(["claude", "codex"]), current: lib)
        XCTAssertEqual(try body(StubURLProtocol.lastRequest), ["agents": ["claude", "codex"]])
        XCTAssertEqual(next.instructions.agents.filter(\.on).map(\.agent), ["claude", "codex"])
        XCTAssertEqual(next.servers.count, 3, "其余部分保持原样")
        XCTAssertEqual(next.result?.changed, ["codex"])
        XCTAssertEqual(LibraryRequests.createSet(id: "s1", name: "公司规范", file: "~/.agents/AGENTS.md"),
                       ["create": ["id": "s1", "name": "公司规范", "file": "~/.agents/AGENTS.md"]])
        XCTAssertEqual(LibraryRequests.activate("s1", texts: ["default": "x"]), ["activate": "s1", "texts": ["default": "x"]])
        XCTAssertEqual(LibraryRequests.saveTexts([:], extra: ["claude": "y"]), ["extra": ["claude": "y"]])
        XCTAssertEqual(LibraryRequests.rewrite("codex"), ["rewrite": ["codex"]])
        XCTAssertTrue(LibraryRequests.newSetID(now: Date(timeIntervalSince1970: 1_793_500_000)).hasPrefix("s"))
    }

    func testCheckServersAndRTKRequests() async throws {
        StubURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/library/mcp/check": (200, ["Content-Type": "application/json"], try WebFixture.data("library-mcp-check.json"))
            default: (200, ["Content-Type": "application/json"], try WebFixture.data("library-rtk.json"))
            }
        }
        let health = try await client.checkLibraryServers(["github"], fresh: true)
        XCTAssertEqual(health["github"]?.tools, 2)
        XCTAssertEqual(try body(StubURLProtocol.lastRequest), ["names": ["github"], "fresh": true])
        let rtk = try await client.setLibraryRTK(agent: "codex", on: true)
        XCTAssertEqual(rtk.agents.count, 4)
        XCTAssertEqual(try body(StubURLProtocol.lastRequest), ["agent": "codex", "on": true])
        _ = try await client.libraryRTK(.upgrade)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/library/rtk/upgrade")
    }

    func testErrorBecomesRejected() async throws {
        StubURLProtocol.handler = { _ in (400, ["Content-Type": "application/json"], Data(#"{"error":"a server called github is in the library already"}"#.utf8)) }
        do {
            _ = try await client.library(.serversSave, LibraryRequests.saveServer(old: "", LibraryServer.blank(agents: [])), current: nil)
            XCTFail("应当失败")
        } catch let MagpieError.webRejected(message, _) {
            XCTAssertEqual(message, "a server called github is in the library already")
        }
    }

    func testFixtureDataDecodes() {
        let lib = LibrarySnapshot(json: LibraryFixtureData.page)
        XCTAssertFalse(lib.servers.isEmpty)
        XCTAssertFalse(lib.skills.isEmpty)
        XCTAssertFalse(lib.hooks.isEmpty)
        XCTAssertFalse(lib.subagents.isEmpty)
        XCTAssertFalse(lib.instructions.sets.isEmpty)
        XCTAssertTrue(LibraryRTK(json: LibraryFixtureData.rtk).installed)
        XCTAssertFalse(LibraryProbe(json: LibraryFixtureData.probe(source: "example-org/skills")).candidates.isEmpty)
    }
}
