import XCTest
@testable import MagpieRemoteCore

/// 「主页 › Agent」的分组，按官方网页版 app.js 的 arrangeAgents / agentUsed / onMagpie / connectable。
final class AgentArrangementTests: XCTestCase {
    private func option(_ value: String, ref: String = "") -> WebJSON {
        ref.isEmpty ? ["value": .string(value)] : ["value": .string(value), "ref": .string(ref)]
    }

    private func agent(_ id: String, wired: Bool? = nil, model: String = "", connectable: Bool = true,
                       extra: [String: WebJSON] = [:]) -> WebAgent {
        let options: WebJSON = connectable ? [option("magpie/gpt-4.1", ref: "relay/gpt-4.1")] : [option("own-model")]
        var raw: [String: WebJSON] = ["id": .string(id), "name": .string(id.capitalized), "path": .string("~/.\(id)"),
                                      "fields": [["key": "model", "label": "model", "value": .string(model), "options": options]]]
        if let wired { raw["wired"] = .bool(wired) } else { raw["wired"] = .null }
        for (key, value) in extra { raw[key] = value }
        return WebAgent(raw: .object(raw))
    }

    func testWiredAgentStaysUpAndOthersFold() {
        let list = [agent("claude"), agent("codex", wired: true), agent("gemini")]
        let arranged = AgentArrangement(agents: list)
        XCTAssertEqual(arranged.shown.map(\.id), ["codex"])
        XCTAssertEqual(arranged.notSetUp.map(\.id), ["claude", "gemini"])
        XCTAssertTrue(arranged.hidden.isEmpty)
        XCTAssertEqual(arranged.foldedCount, 2)
    }

    /// 一台新 magpie（还没有 Agent 接入）：全部显示，不折叠。
    func testNothingWiredShowsEveryone() {
        let arranged = AgentArrangement(agents: [agent("claude", model: "x"), agent("codex")])
        XCTAssertEqual(arranged.shown.map(\.id), ["claude", "codex"])
        XCTAssertEqual(arranged.foldedCount, 0)
    }

    func testHiddenByHandFoldsUnderHiddenEvenWhenWired() {
        let list = [agent("claude", wired: true), agent("codex", wired: true), agent("gemini")]
        let arranged = AgentArrangement(agents: list, hidden: ["codex"])
        XCTAssertEqual(arranged.shown.map(\.id), ["claude"])
        XCTAssertEqual(arranged.notSetUp.map(\.id), ["gemini"])
        XCTAssertEqual(arranged.hidden.map(\.id), ["codex"])
    }

    func testOrderFromSettingsThenHostOrder() {
        let list = [agent("a", wired: true), agent("b", wired: true), agent("c", wired: true)]
        XCTAssertEqual(AgentArrangement(agents: list, order: ["c"]).shown.map(\.id), ["c", "a", "b"])
        XCTAssertEqual(AgentArrangement(agents: list, order: ["b", "a"]).shown.map(\.id), ["b", "a", "c"])
    }

    /// 没有能接入的 Agent 时（例如只有 Cursor），设置过模型就算在用。
    func testWithoutConnectableAgentsAModelCounts() {
        let list = [agent("cursor", model: "own-model", connectable: false), agent("goose", connectable: false)]
        let arranged = AgentArrangement(agents: list)
        XCTAssertEqual(arranged.shown.map(\.id), ["cursor"])
        XCTAssertEqual(arranged.notSetUp.map(\.id), ["goose"])
    }

    /// 只调了思考强度不算设置过；命令行没了的只在仍接入时留在上面；接入后被改掉（drift）的留在上面。
    func testTweaksCliMissingAndDrift() {
        let tweakOnly = WebAgent(raw: ["id": "cursor", "fields": [["key": "effort", "value": "high", "options": []]]])
        XCTAssertFalse(tweakOnly.isUsed)
        let gone = agent("claude", model: "x", connectable: false, extra: ["cliMissing": true])
        XCTAssertTrue(gone.cliMissing)
        XCTAssertFalse(gone.isUsed)
        let goneWired = agent("claude", wired: true, extra: ["cliMissing": true])
        XCTAssertTrue(goneWired.isUsed)
        let drifted = agent("codex", extra: ["drift": ["kind": "unwired"]])
        XCTAssertTrue(drifted.onMagpie)
        let launchOnly = WebAgent(raw: ["id": "agy", "launch": "agy --magpie", "fields": []])
        XCTAssertTrue(launchOnly.isUsed)
        let arranged = AgentArrangement(agents: [agent("a", wired: true), drifted, gone])
        XCTAssertEqual(arranged.shown.map(\.id), ["a", "codex"])
        XCTAssertEqual(arranged.notSetUp.map(\.id), ["claude"])
    }

    /// 真实 magpie v0.1.2438 的 /api/state 与 /api/settings（两个 Agent 都没接入、命令行不在；设置里顺序 / 隐藏为 null）。
    func testLiveFixtureDecodes() throws {
        let state = WebState(json: try JSONDecoder().decode(WebJSON.self, from: LiveFixture.data("web-state.json")))
        let settings = WebSettings(json: try JSONDecoder().decode(WebJSON.self, from: LiveFixture.data("web-settings.json")))
        XCTAssertEqual(settings.agentOrder, [])
        XCTAssertEqual(settings.agentsHidden, [])
        XCTAssertTrue(state.agents.allSatisfy(\.cliMissing))
        let arranged = AgentArrangement(agents: state.agents, order: settings.agentOrder, hidden: settings.agentsHidden)
        XCTAssertEqual(arranged.shown.count, state.agents.count)
        XCTAssertEqual(arranged.foldedCount, 0)
    }
}
