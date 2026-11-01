import XCTest
@testable import MagpieRemoteCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Agent 页补齐官方网页的部分：命令行程序版本与更新、全部更新、接入开关、重新应用、断开预览、方案。
final class AgentControlsTests: XCTestCase {
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

    // MARK: 版本与更新

    func testDecodesCLIs() throws {
        let clis = AgentCLIs(json: try WebFixture.json("agents-cli.json"))
        XCTAssertTrue(clis.pending)
        let codex = try XCTUnwrap(clis.agents["codex"])
        XCTAssertTrue(codex.update)
        XCTAssertEqual(codex.versionTag, "CLI 0.163.0") // 旁边有 Codex App
        XCTAssertEqual(codex.app, "26.1.0")
        XCTAssertEqual(codex.buttonTitle(busy: false), "更新到 0.164.2")
        XCTAssertEqual(codex.buttonTitle(busy: true), "更新中…")
        XCTAssertEqual(codex.commandNote, "通过 npm install -g @openai/codex 更新")
        XCTAssertEqual(codex.versionNote(agent: "Codex"), "已安装 Codex 0.163.0 · 0.164.2 已发布")
        let gemini = try XCTUnwrap(clis.agents["gemini"])
        XCTAssertFalse(gemini.update)
        XCTAssertEqual(gemini.versionTag, "0.21.0")
        XCTAssertEqual(gemini.versionNote(agent: "Gemini CLI"), "Gemini CLI 0.21.0 · 已是最新")
        let pi = try XCTUnwrap(clis.agents["pi"])
        XCTAssertTrue(pi.offPath)
        XCTAssertEqual(pi.versionNote(agent: "Pi"), "Pi 1.0.9 · 无法判断安装方式，请按原安装方式更新")
        XCTAssertTrue(AgentCLI(json: [:]).isEmpty)
    }

    func testUpdateTexts() {
        XCTAssertEqual(AgentCLIText.updated(agent: "Codex", from: "0.163.0", to: "0.164.2"), "Codex 已更新：0.163.0 → 0.164.2")
        XCTAssertEqual(AgentCLIText.updated(agent: "Codex", from: nil, to: "0.164.2"), "Codex 已更新到 0.164.2")
        XCTAssertEqual(AgentCLIText.updated(agent: "Codex", from: "0.164.2", to: "0.164.2"), "Codex 已更新到 0.164.2")
        XCTAssertEqual(AgentCLIText.change(agent: "Pi", from: "1.0.9", to: "1.1.0"), "Pi 1.0.9 → 1.1.0")
        XCTAssertEqual(AgentCLIText.change(agent: "Pi", from: nil, to: "1.1.0"), "Pi 1.1.0")
        XCTAssertEqual(AgentCLIText.behind([]), "所有 Agent 都已是最新")
        XCTAssertEqual(AgentCLIText.behind(["Codex"]), "Codex 有新版本")
        XCTAssertEqual(AgentCLIText.behind(["Codex", "Claude Code"]), "2 个 Agent 有新版本：Codex, Claude Code")
    }

    func testUpdateAllRun() {
        var run = AgentUpdateRun(names: ["Codex", "Claude Code"])
        XCTAssertTrue(run.running)
        XCTAssertEqual(run.progress, "正在更新 Codex…（1/2）")
        run.changed.append("Codex 0.163.0 → 0.164.2")
        run.done = 1
        run.now = "Claude Code"
        XCTAssertEqual(run.progress, "正在更新 Claude Code…（2/2）")
        run.failed.append(.init(name: "Claude Code", message: "claude update: permission denied"))
        run.done = 2
        XCTAssertFalse(run.running)
        XCTAssertEqual(run.summary, "2 个 Agent 中已更新 1 个：Codex 0.163.0 → 0.164.2 · 1 个未成功：Claude Code")
        var ok = AgentUpdateRun(names: ["Codex"])
        ok.changed = ["Codex 0.163.0 → 0.164.2"]
        ok.done = 1
        XCTAssertEqual(ok.summary, "已更新 1 个 Agent：Codex 0.163.0 → 0.164.2")
        var none = AgentUpdateRun(names: ["Codex"])
        none.failed = [.init(name: "Codex", message: "x")]
        none.done = 1
        XCTAssertEqual(none.summary, "1 个 Agent 中已更新 0 个 · 1 个未成功：Codex")
    }

    func testUpdateCLIRequest() async throws {
        StubURLProtocol.handler = { _ in (200, ["Content-Type": "application/json"], try WebFixture.data("agents-cli-update.json")) }
        let cli = try await client.updateAgentCLI("codex")
        XCTAssertEqual(cli.version, "0.164.2")
        XCTAssertFalse(cli.update)
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/agents/cli/codex")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "magpie_web_3430=web-key-EXAMPLE-0123")
        XCTAssertGreaterThanOrEqual(request.timeoutInterval, 600) // 主机最多跑 10 分钟
        XCTAssertNil(request.url?.query)
    }

    func testUpdateCLIErrorCarriesHostMessage() async throws {
        StubURLProtocol.handler = { _ in (400, ["Content-Type": "application/json"], try WebFixture.data("agents-cli-update-error.json")) }
        do {
            _ = try await client.updateAgentCLI("codex")
            XCTFail("应该失败")
        } catch let error as MagpieError {
            XCTAssertEqual(error, .webRejected(message: "npm install -g @openai/codex: npm error code EACCES", code: nil))
        }
    }

    func testCLIListRequest() async throws {
        StubURLProtocol.handler = { _ in (200, ["Content-Type": "application/json"], try WebFixture.data("agents-cli.json")) }
        let clis = try await client.agentCLIs()
        XCTAssertEqual(clis.agents.count, 4)
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "GET")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/agents/cli")
    }

    // MARK: 状态、接入、重新应用

    func testDecodesFullState() throws {
        let state = WebState(json: try WebFixture.json("state-agents-full.json"))
        XCTAssertEqual(state.connectedHow, "again")
        XCTAssertEqual(state.changed, 2)
        let codex = try XCTUnwrap(state.agents.first { $0.id == "codex" })
        XCTAssertTrue(codex.connectable)
        XCTAssertEqual(codex.connectSaid, "已接入 · 在 Codex 里用 /model 选 magpie 的模型")
        let drift = try XCTUnwrap(codex.drift)
        XCTAssertEqual(drift.kind, "replaced")
        XCTAssertTrue(drift.canReapply)
        XCTAssertEqual(drift.fixTitle, "重新应用")
        XCTAssertEqual(drift.reason(agent: "Codex", model: "GPT 4.1"), "Codex 已在 magpie 之外换掉 GPT 4.1")
        XCTAssertTrue(codex.canReapply)
        // 子代理既没选项也没值：不列出
        XCTAssertEqual(codex.shownFields.map(\.key), ["model", "effort", "login"])
        let effort = try XCTUnwrap(codex.fields.first { $0.key == "effort" })
        XCTAssertEqual(AgentFieldText.label(effort.label), "推理强度")
        XCTAssertEqual(AgentFieldText.value(of: effort), "高")
        XCTAssertEqual(effort.options.map(AgentFieldText.option), ["低", "中", "高", "很高"])
        let login = try XCTUnwrap(codex.fields.first { $0.key == "login" })
        XCTAssertEqual(AgentFieldText.label(login.label), "登录方式")
        XCTAssertEqual(AgentFieldText.value(of: login), "magpie API")

        let claude = try XCTUnwrap(state.agents.first { $0.id == "claude" })
        XCTAssertFalse(claude.wired)
        XCTAssertEqual(claude.connectSaid, "未接入 · 用 Claude Code 自己的设置")
        let deaf = try XCTUnwrap(claude.drift)
        XCTAssertTrue(deaf.deaf)
        XCTAssertEqual(deaf.fixTitle, "改用 127.0.0.1:3425")
        XCTAssertTrue(deaf.canReapply)
        var noMove = deaf
        noMove.move = ""
        XCTAssertEqual(noMove.fixTitle, "如何修复")
        XCTAssertFalse(noMove.canReapply)

        // Cursor 只用自己的模型：没有「接入」开关
        let cursor = try XCTUnwrap(state.agents.first { $0.id == "cursor" })
        XCTAssertFalse(cursor.connectable)
        XCTAssertFalse(cursor.canReapply)
    }

    func testConnectedSaid() throws {
        let state = WebState(json: try WebFixture.json("state-agents-full.json"))
        var codex = try XCTUnwrap(state.agents.first { $0.id == "codex" })
        XCTAssertEqual(codex.connectedSaid(how: nil), "Codex 已接入 magpie")
        // 当前模型 gpt-5 不在选项里：原样显示
        XCTAssertEqual(codex.connectedSaid(how: "again"), "Codex 已接入 magpie · 回到上次断开前用的 gpt-5")
        XCTAssertEqual(codex.connectedSaid(how: "joined"), "Codex 已接入 magpie · 仍用它上次选的模型，magpie 的模型已加入 /model")
        codex.raw = WebJSON.object((codex.raw.object ?? [:]).merging(["fields": [["key": "model", "label": "model", "value": "relay-example/gpt-4.1",
            "options": [["value": "relay-example/gpt-4.1", "label": "GPT 4.1", "ref": "relay-example/gpt-4.1"]]]]]) { $1 })
        XCTAssertEqual(codex.connectedSaid(how: "first"), "Codex 已接入 magpie · magpie 没有它原来的模型，改用 GPT 4.1")
        XCTAssertEqual(codex.connectedSaid(how: "default"), "Codex 已接入 magpie · 原先未设模型，改用它自己列表中的第一个：GPT 4.1")
        XCTAssertEqual(codex.connectedSaid(how: "same"), "Codex 已接入 magpie · 经 magpie 继续用它原来的模型 GPT 4.1")
    }

    func testAgentActionRequests() async throws {
        StubURLProtocol.handler = { _ in (200, ["Content-Type": "application/json"], try WebFixture.data("state-agents-full.json")) }
        for action in AgentAction.allCases {
            let state = try await client.agentAction(action, "codex")
            XCTAssertEqual(state.agents.count, 3)
            XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "POST")
            XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/agents/\(action.rawValue)/codex")
        }
        _ = try await client.rescanAgents()
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/agents/rescan")
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "POST")
    }

    func testDisconnectPreview() async throws {
        StubURLProtocol.handler = { _ in (200, ["Content-Type": "application/json"], try WebFixture.data("agents-preview.json")) }
        let preview = try await client.agentDisconnectPreview("codex")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/agents/preview/codex")
        XCTAssertEqual(preview.changes.map(\.path), ["~/.codex/config.toml", "~/.codex/magpie-catalog.json"])
        XCTAssertEqual(preview.changes[0].lines, 2)
        XCTAssertTrue(preview.changes[1].removed)
        XCTAssertNil(preview.error)
        XCTAssertEqual(preview.revision, "")
        let failed = AgentDisconnectPreview(json: ["error": "Aside isn't running"])
        XCTAssertEqual(failed.error, "Aside isn't running")
    }

    // MARK: 方案

    func testDecodesProfiles() throws {
        let state = WebState(json: try WebFixture.json("state-agents-full.json"))
        XCTAssertEqual(state.profiles.map(\.name), ["Work", "Cheap"])
        let work = state.profiles[0]
        XCTAssertTrue(work.inUse)
        XCTAssertFalse(state.profiles[1].inUse)
        let codex = try XCTUnwrap(work.agents.first)
        XCTAssertEqual(codex.fields.map { WebProfile.display($0, in: codex) },
                       ["relay-example/gpt-4.1", "很高", "跟随主模型（relay-example/gpt-4.1）", "••••••"])
        XCTAssertEqual(WebProfile.appliedSaid(name: "Work", changed: 2), "已应用 Work · 更改了 2 项设置")
    }

    func testProfileRequests() async throws {
        StubURLProtocol.handler = { _ in (200, ["Content-Type": "application/json"], try WebFixture.data("state-agents-full.json")) }
        for action in ProfileAction.allCases {
            let state = try await client.profile(action, name: "Work")
            XCTAssertEqual(state.changed, 2)
            let request = StubURLProtocol.lastRequest
            XCTAssertEqual(request?.httpMethod, "POST")
            XCTAssertEqual(request?.url?.path, "/api/profile/\(action.rawValue)")
            XCTAssertEqual(try body(request)["name"]?.string, "Work")
        }
    }
}
