import XCTest
@testable import MagpieRemoteCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 「Agent 会话记录」：Fixtures/web/sessions-*.json 是按 magpie 源码（80af3b8，internal/gui/sessions*.go）
/// 的输出形状整理的假数据。
final class AgentSessionsModelTests: XCTestCase {
    func testDecodesManageOverview() throws {
        let overview = SessionsOverview(json: try WebFixture.json("sessions-manage-claude.json"))
        XCTAssertEqual(overview.agents.map(\.id), ["claude", "codex", "opencode"])
        XCTAssertEqual(overview.agents[0].name, "Claude Code")
        XCTAssertEqual(overview.agents[0].count, 3)
        XCTAssertFalse(overview.agents[2].deletable)
        XCTAssertEqual(overview.agent, "claude")
        XCTAssertEqual(overview.currentAgent?.name, "Claude Code")
        XCTAssertEqual(overview.trashCount, 1)
        XCTAssertTrue(overview.reads.asked)
        XCTAssertTrue(overview.reads.blocked.isEmpty)
        XCTAssertEqual(overview.sessions.count, 3)

        let first = overview.sessions[0]
        XCTAssertEqual(first.id, "claude|11111111-aaaa-4bbb-8ccc-000000000001")
        XCTAssertEqual(first.displayTitle, "修复登录页的样式问题")
        XCTAssertEqual(first.folderName, "demo-app")
        XCTAssertEqual(first.modelNames, ["claude-sonnet-4-5", "claude-haiku-4-5"])
        XCTAssertEqual(first.size, 1_288_490)
        XCTAssertEqual(first.messages, 86)
        XCTAssertEqual(first.totalTokens, 1500 + 3500 + 56000 + 8000)
        XCTAssertEqual(first.cost, 0.421, accuracy: 1e-9)
        XCTAssertTrue(first.hasTranscript)
        XCTAssertTrue(first.deletable)
        XCTAssertEqual(first.subagents.map(\.displayTitle), ["Search the repo"])
        // RFC 3339 带纳秒
        let start = try XCTUnwrap(first.start)
        XCTAssertEqual(start.timeIntervalSince1970, 1_793_409_123.123, accuracy: 0.01)
        XCTAssertEqual(SessionFormat.summary(first), "claude-sonnet-4-5 等 2 个模型 · 86 条消息 · 1.2 MB")

        // models 为 null、标题为空时用别名；还在统计
        let second = overview.sessions[1]
        XCTAssertEqual(second.displayTitle, "整理笔记")
        XCTAssertTrue(second.models.isEmpty)
        XCTAssertTrue(second.pending)
        XCTAssertEqual(SessionFormat.summary(second), "统计中 · 2 KB")

        // 只经过网关的会话：零值开始时间当作没有
        let gateway = overview.sessions[2]
        XCTAssertTrue(gateway.gateway)
        XCTAssertNil(gateway.start)
        XCTAssertNotNil(gateway.last)
        XCTAssertFalse(gateway.hasTranscript)
        XCTAssertEqual(gateway.unpriced, 1)
    }

    func testUnaskedReadsAreBlocked() throws {
        let overview = SessionsOverview(json: try WebFixture.json("sessions-manage-unasked.json"))
        XCTAssertTrue(overview.agents.isEmpty)
        XCTAssertFalse(overview.reads.asked)
        XCTAssertEqual(overview.reads.blocked.map(\.id), ["claude", "codex"])
        // 老版本没有 reads 字段：不当作被拦住
        XCTAssertTrue(SessionsOverview(json: ["agents": []]).reads.asked)
    }

    func testDecodesMissingAndWrongTypesDefensively() {
        let session = AgentSession(json: ["agent": "codex", "id": "abc", "size": .double(12.0), "messages": "x", "models": "oops",
                                          "via": [["model": "gpt-5"], ["model": "gpt-5"], ["provider": "p"]]])
        XCTAssertEqual(session.size, 12)
        XCTAssertEqual(session.messages, 0)
        XCTAssertEqual(session.modelNames, ["gpt-5"])
        XCTAssertEqual(session.displayTitle, "abc")
        XCTAssertNil(session.start)
        XCTAssertEqual(SessionsOverview(json: ["sessions": [["agent": "x"], ["agent": "x", "id": "1"]]]).sessions.count, 1)
    }

    func testLocalFilterAndSort() throws {
        let sessions = SessionsOverview(json: try WebFixture.json("sessions-manage-claude.json")).sessions
        XCTAssertEqual(sessions.filter { $0.matches("登录") }.count, 1)
        XCTAssertEqual(sessions.filter { $0.matches("NOTES") }.map(\.sessionID), ["11111111-aaaa-4bbb-8ccc-000000000002"])
        XCTAssertEqual(sessions.filter { $0.matches("sonnet demo") }.count, 1)
        XCTAssertEqual(sessions.filter { $0.matches("  ") }.count, 3)
        XCTAssertEqual(sessions.filter { $0.matches("smart") }.count, 1)
        XCTAssertEqual(SessionSort.size.sorted(sessions).first?.folderName, "demo-app")
        XCTAssertEqual(SessionSort.recent.sorted(sessions).last?.sessionID, "ses_gateway_EXAMPLE")
        XCTAssertEqual(SessionSort.cost.sorted(sessions).first?.cost ?? 0, 0.421, accuracy: 1e-9)
        XCTAssertEqual(SessionSort.messages.sorted(sessions).first?.messages, 86)
    }

    func testDecodesTranscript() throws {
        let transcript = SessionTranscript(json: try WebFixture.json("sessions-transcript.json"))
        XCTAssertTrue(transcript.cut)
        XCTAssertEqual(transcript.parts.count, 7)
        XCTAssertEqual(transcript.turns, 2)
        XCTAssertEqual(transcript.parts[0].label, "你")
        XCTAssertEqual(transcript.parts[1].label, "思考")
        XCTAssertEqual(transcript.parts[2].kind, .toolUse)
        XCTAssertEqual(transcript.parts[2].label, "调用工具 · Read")
        XCTAssertEqual(transcript.parts[3].cut, 1200)
        XCTAssertEqual(transcript.parts[4].label, "助手 · claude-sonnet-4-5")
        XCTAssertEqual(transcript.parts[6].kind, .context)
        XCTAssertEqual(transcript.visible(showTools: false).map(\.id), [0, 4, 5])
        XCTAssertEqual(transcript.visible(showTools: true).count, 7)
        let unknown = SessionTranscript(json: ["parts": [["role": "system", "kind": "audio", "text": "?"]]])
        XCTAssertEqual(unknown.parts[0].role, .other)
        XCTAssertEqual(unknown.parts[0].kind, .other)
    }

    func testDecodesSearchAndDelete() throws {
        let search = SessionSearchResult(json: try WebFixture.json("sessions-search.json"))
        XCTAssertEqual(search.hits.count, 1)
        XCTAssertEqual(search.hit(for: "11111111-aaaa-4bbb-8ccc-000000000001")?.snippet, "登录页的按钮在深色模式下看不清")
        XCTAssertEqual(search.total, 3)
        XCTAssertFalse(search.cut)
        XCTAssertFalse(SessionSearchResult.canSearch(" a "))
        XCTAssertTrue(SessionSearchResult.canSearch("按钮"))

        let deleted = SessionDeleteResult(json: try WebFixture.json("sessions-delete.json"))
        XCTAssertEqual(deleted.deleted, ["11111111-aaaa-4bbb-8ccc-000000000002"])
        XCTAssertEqual(deleted.refused.first?.active, true)
        XCTAssertEqual(deleted.failureMessage, "这个会话最近一分钟还在写入，Agent 可能正在使用它。稍后再删。")
        XCTAssertNil(SessionDeleteResult(json: ["deleted": ["a"], "refused": []]).failureMessage)
        let refusedAgent = SessionDeleteResult(json: ["deleted": [], "refused": [["id": "a", "error": "magpie can't delete this agent's sessions", "active": false]]])
        XCTAssertEqual(refusedAgent.failureMessage, "magpie 不能删除这个 Agent 的会话。")
    }

    func testMarkdownFilename() {
        XCTAssertEqual(SessionMarkdown.filename(contentDisposition: #"attachment; filename="magpie-session-claude-11111111-aaa.md""#, agent: "claude", id: "x"),
                       "magpie-session-claude-11111111-aaa.md")
        XCTAssertEqual(SessionMarkdown.filename(contentDisposition: nil, agent: "qoder-cn", id: "ses_ABCDEFGHIJKLMNOP"),
                       "magpie-session-qoder-cn-ses_ABCDEFGH.md")
        XCTAssertEqual(SessionMarkdown.filename(contentDisposition: #"attachment; filename="../../etc/passwd""#, agent: "a", id: "b"),
                       "magpie-session-a-b.md")
    }

    func testFormat() {
        XCTAssertEqual(SessionFormat.size(812), "812 B")
        XCTAssertEqual(SessionFormat.size(2048), "2 KB")
        XCTAssertEqual(SessionFormat.size(3_250_000), "3.1 MB")
        let zone = TimeZone(identifier: "Asia/Shanghai")!
        let now = QuotaTime.parse("2026-11-01T15:00:00+08:00")!
        XCTAssertEqual(SessionFormat.time(QuotaTime.parse("2026-11-01T09:05:00+08:00"), now: now, timeZone: zone), "09:05")
        XCTAssertEqual(SessionFormat.time(QuotaTime.parse("2026-10-31T23:30:00+08:00"), now: now, timeZone: zone), "昨天 23:30")
        XCTAssertEqual(SessionFormat.time(QuotaTime.parse("2026-03-02T10:00:00+08:00"), now: now, timeZone: zone), "03-02 10:00")
        XCTAssertEqual(SessionFormat.time(QuotaTime.parse("2025-03-02T10:00:00+08:00"), now: now, timeZone: zone), "2025-03-02")
        XCTAssertEqual(SessionFormat.time(nil), "—")
    }

    func testRequestBodies() throws {
        let delete = String(decoding: try WebRequests.sessionsDelete(agent: "claude", ids: ["a", "b"]).encoded(), as: UTF8.self)
        XCTAssertEqual(delete, #"{"agent":"claude","ids":["a","b"]}"#)
        let reads = String(decoding: try WebRequests.sessionReads(["codex": true]).encoded(), as: UTF8.self)
        XCTAssertEqual(reads, #"{"agents":{"codex":true}}"#)
    }
}

final class AgentSessionsClientTests: XCTestCase {
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

    private func query(_ request: URLRequest?) -> [String: String] {
        let items = request.flatMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
    }

    func testOverviewRequest() async throws {
        StubURLProtocol.handler = { _ in (200, ["Content-Type": "application/json"], try WebFixture.data("sessions-manage-claude.json")) }
        let overview = try await client.sessionsOverview(agent: "claude")
        XCTAssertEqual(overview.sessions.count, 3)
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.path, "/api/sessions/manage")
        XCTAssertEqual(query(request), ["agent": "claude"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "magpie_web_3430=web-key-EXAMPLE-0123")
        _ = try await client.sessionsOverview()
        XCTAssertNil(StubURLProtocol.lastRequest?.url?.query)
    }

    func testTranscriptAndSearchRequests() async throws {
        StubURLProtocol.handler = { _ in (200, ["Content-Type": "application/json"], try WebFixture.data("sessions-transcript.json")) }
        let transcript = try await client.sessionTranscript(agent: "claude", id: "id+1", sub: "agent-a1")
        XCTAssertEqual(transcript.parts.count, 7)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/sessions/transcript")
        XCTAssertEqual(query(StubURLProtocol.lastRequest), ["agent": "claude", "id": "id+1", "sub": "agent-a1"])

        StubURLProtocol.handler = { _ in (200, ["Content-Type": "application/json"], try WebFixture.data("sessions-search.json")) }
        let search = try await client.searchSessions(agent: "claude", query: "按钮")
        XCTAssertEqual(search.hits.count, 1)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/sessions/search")
        XCTAssertEqual(query(StubURLProtocol.lastRequest), ["agent": "claude", "q": "按钮"])
    }

    func testTranscriptErrorIsReadable() async throws {
        StubURLProtocol.handler = { _ in (400, ["Content-Type": "application/json"], Data(#"{"error":"no such session"}"#.utf8)) }
        do {
            _ = try await client.sessionTranscript(agent: "claude", id: "nope")
            XCTFail("应当失败")
        } catch let error as MagpieError {
            XCTAssertEqual(error, .webRejected(message: "no such session", code: nil))
        }
    }

    func testDeleteAndExportRequests() async throws {
        StubURLProtocol.handler = { _ in (200, ["Content-Type": "application/json"], try WebFixture.data("sessions-delete.json")) }
        let result = try await client.deleteSessions(agent: "claude", ids: ["11111111-aaaa-4bbb-8ccc-000000000002"])
        XCTAssertEqual(result.deleted.count, 1)
        var request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/sessions/delete")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        StubURLProtocol.handler = { _ in (200, ["Content-Type": "application/json"], Data(#"{"path":"~/Downloads/magpie-session-claude-1111.md"}"#.utf8)) }
        let path = try await client.exportSessionOnHost(agent: "claude", id: "1111")
        XCTAssertEqual(path, "~/Downloads/magpie-session-claude-1111.md")
        request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/sessions/export")
        XCTAssertEqual(query(request), ["agent": "claude", "id": "1111"])
    }

    func testMarkdownIsReadAsText() async throws {
        let body = "# 修复登录页\n\n- **Agent:** Claude Code\n"
        StubURLProtocol.handler = { _ in
            (200, ["Content-Type": "text/markdown; charset=utf-8", "Content-Disposition": #"attachment; filename="magpie-session-claude-1111.md""#], Data(body.utf8))
        }
        let markdown = try await client.sessionMarkdown(agent: "claude", id: "1111")
        XCTAssertEqual(markdown.text, body)
        XCTAssertEqual(markdown.filename, "magpie-session-claude-1111.md")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/sessions/markdown")

        StubURLProtocol.handler = { _ in (400, ["Content-Type": "application/json"], Data(#"{"error":"this agent's conversations can't be shown"}"#.utf8)) }
        do {
            _ = try await client.sessionMarkdown(agent: "opencode", id: "x")
            XCTFail("应当失败")
        } catch let error as MagpieError {
            XCTAssertEqual(error, .webRejected(message: "this agent's conversations can't be shown", code: nil))
        }
    }
}
