import XCTest
@testable import MagpieRemoteCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 「用量」的 请求 / 会话 / 上下文 三个标签。网关的请求记录用真实抓到的 live fixture；网页接口的 fixture 按
/// magpie 源码（internal/usage/heatmap.go、internal/gui/usage.go、internal/sessions/stats.go、internal/gui/context.go、
/// internal/gateway/prompt.go）的 json 标签整理，数据是假的。
final class UsageLedgerTests: XCTestCase {
    private func livePage(_ name: String = "gw-usage-requests.json") throws -> UsageRequestPage {
        try JSONDecoder().decode(UsageRequestPage.self, from: LiveFixture.data(name))
    }

    func testLedgerDecodesSeriesAndRankings() throws {
        let page = try livePage()
        XCTAssertEqual(page.bucket, "day")
        XCTAssertFalse(page.series.isEmpty)
        let point = try XCTUnwrap(page.series.first)
        XCTAssertEqual(point.by["agent"]?["magpie"]?.calls, 8)
        XCTAssertEqual(point.by["agent"]?["curl"]?.tokens, 38)
        XCTAssertEqual(page.by["agent"]?.map(\.id), ["magpie", "curl"])
        XCTAssertEqual(page.by["agent"]?.first?.totals.decodeN, 5)
        XCTAssertEqual(page.totals.decodeN, 6)
        XCTAssertEqual(page.through.calls + page.direct.calls + page.reported.calls >= page.totals.calls, true)
        XCTAssertNotNil(page.successRate)
    }

    func testTrendSumsToTotalsWithOther() throws {
        let data = UsageFixtureData(now: Date(timeIntervalSince1970: 1_793_500_000), timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        let page = data.requests(UsageRequestQuery(period: .month))
        XCTAssertEqual(page.by["model"]?.count, 4)
        let trend = UsageTrend(page: page, metric: .tokens, split: .agent)
        XCTAssertEqual(trend.labels.count, page.series.count)
        for i in trend.totals.indices {
            let stacked = trend.layers.reduce(0) { $0 + $1.values[i] }
            XCTAssertEqual(stacked, trend.totals[i], accuracy: 0.5)
        }
        XCTAssertFalse(trend.layers.contains(where: \.isOther), "只有 3 个 Agent，不应有「其它」")
        let calls = UsageTrend(page: page, metric: .calls, split: .modelAt)
        XCTAssertEqual(calls.totals.reduce(0, +), Double(page.totals.calls), accuracy: 0.5)
        let speed = UsageTrend(page: page, metric: .speed, split: .provider)
        XCTAssertTrue(speed.layers.allSatisfy { !$0.isOther })
        XCTAssertFalse(speed.isEmpty)
        // 按花费排名：第一名花费最高
        let ranked = page.ranking(.provider, metric: .cost)
        XCTAssertEqual(ranked.first?.totals.cost, ranked.map(\.totals.cost).max())
    }

    func testTrendFoldsTheRestIntoOther() throws {
        var page = try livePage()
        var by: [String: UsageLedgerPart] = [:]
        var shares: [UsageShare] = []
        var totals = UsageTotals()
        for i in 0..<9 {
            by["m\(i)"] = UsageLedgerPart(calls: 1, tokens: 100 - i)
            var t = UsageTotals(); t.calls = 1; t.input = 100 - i
            shares.append(UsageShare(id: "m\(i)", name: "m\(i)", totals: t))
            totals = totals + t
        }
        page.series = [UsageLedgerPoint(label: "x", time: nil, totals: totals, by: ["model": by])]
        page.by = ["model": shares]
        let trend = UsageTrend(page: page, metric: .tokens, split: .model)
        XCTAssertEqual(trend.layers.count, UsageTrend.shown + 1)
        XCTAssertEqual(trend.layers.last?.name, "其它")
        XCTAssertEqual(trend.layers.last?.values.first ?? 0, Double(93 + 92), accuracy: 0.01)
    }

    func testSpeedPicksTheLargerSample() {
        var t = UsageTotals()
        t.decodeMs = 2_000; t.decodeOut = 200; t.decodeN = 3
        XCTAssertEqual(UsageSpeed(t)?.value ?? 0, 100, accuracy: 0.01)
        XCTAssertEqual(UsageSpeed(t)?.text, "100 词元/秒")
        t.floorMs = 10_000; t.floorOut = 500; t.floorN = 9
        let s = UsageSpeed(t)
        XCTAssertEqual(s?.isFloor, true)
        XCTAssertEqual(s?.text, "≥50 词元/秒")
        XCTAssertEqual(s?.otherValue ?? 0, 100, accuracy: 0.01)
        XCTAssertNil(UsageSpeed(UsageTotals()))
    }

    func testCacheHitRateLeavesOutUnknown() {
        var t = UsageTotals()
        t.input = 100; t.cacheRead = 300
        XCTAssertEqual(t.cacheHitRate ?? 0, 0.75, accuracy: 1e-9)
        t.cacheUnknown = 100
        XCTAssertEqual(t.cacheHitRate ?? 0, 1, accuracy: 1e-9)
        XCTAssertNil(UsageTotals().cacheHitRate)
    }

    func testRowDetailsSpeedProtocolAndTiming() throws {
        let json = #"""
        {"t":"2026-11-01T09:00:00.000+08:00","agent":"claude","provider":"anthropic","model":"claude-sonnet-4-6","in":10,"out":500,
         "cache_read":0,"cache_write":0,"ms":3000,"ttft_ms":1000,"sent_ms":400,"own_ms":120,"masking_ms":20,"retried_ms":100,"queued_ms":50,
         "status":200,"ep":"/v1/chat/completions → /v1/messages","rid":"req_EXAMPLE","kind":"title","session":"s-1","native_session":"n-1",
         "upstream":"Example Cloud","pricing_model":"claude-sonnet-4-6","source":"","cost":0.01,"priced":true}
        """#
        let row = try JSONDecoder().decode(UsageRequestRow.self, from: Data(json.utf8))
        XCTAssertEqual(row.outputSpeed ?? 0, 250, accuracy: 0.01)
        XCTAssertEqual(row.protocolText, "Chat → Anthropic")
        XCTAssertEqual(row.requestID, "req_EXAMPLE")
        XCTAssertEqual(row.kind, "title")
        XCTAssertEqual(row.upstream, "Example Cloud")
        let timing = row.timingBreakdown
        XCTAssertEqual(timing.map(\.title), ["脱敏", "在 magpie 里", "先失败的尝试", "排队等名额", "连接与发送", "供应商首字"])
        XCTAssertEqual(timing.map(\.ms), [20, 100, 100, 50, 130, 600])
        let q = Dictionary(uniqueKeysWithValues: (row.contentQuery ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["agent"], "claude")
        XCTAssertEqual(q["session"], "n-1")
        XCTAssertTrue(q["from"]?.hasPrefix("2026-11-01T00:59:55") == true, q["from"] ?? "")
        XCTAssertTrue(q["at"]?.hasPrefix("2026-11-01T01:00:03") == true, q["at"] ?? "")

        // 会话文件里读到的：没有协议，失败的没有速度
        var log = row
        log.source = "log"
        XCTAssertNil(log.protocolText)
        log.status = 500
        XCTAssertNil(log.outputSpeed)
    }

    func testQueryCarriesNewFilters() {
        var q = UsageRequestQuery(period: .week, purpose: "title", computer: "this", via: "log", day: "2026-10-30")
        XCTAssertTrue(q.isFiltered)
        let items = Dictionary(uniqueKeysWithValues: q.queryItems.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["purpose"], "title")
        XCTAssertEqual(items["computer"], "this")
        XCTAssertEqual(items["via"], "log")
        XCTAssertEqual(items["day"], "2026-10-30")
        q.search = "gpt"
        XCTAssertEqual(Set(q.heatmapItems.map(\.name)), ["purpose", "computer", "via", "q"])
    }

    func testHeatmapAndContent() throws {
        let heat = UsageHeatmap(json: try WebFixture.json("usage-heatmap.json"))
        XCTAssertEqual(heat.days.count, 3)
        XCTAssertEqual(heat.days.last?.calls, 40)
        XCTAssertEqual(heat.days[1].unpriced, 1)
        XCTAssertFalse(heat.isEmpty)
        let weeks = heat.weeks()
        XCTAssertEqual(weeks.count, 53)
        XCTAssertTrue(weeks.allSatisfy { $0.count == 7 })
        XCTAssertEqual(weeks.flatMap { $0 }.compactMap { $0 }.first?.date, "2025-11-03")
        XCTAssertEqual(weeks.flatMap { $0 }.compactMap { $0 }.last?.date, "2026-11-01")
        let level = UsageHeatmap.levels([0, 10, 20, 40])
        XCTAssertEqual([0, 10, 20, 40].map { level(Double($0)) }, [0, 1, 2, 4])

        let content = UsageRequestContent(json: try WebFixture.json("usage-request-content.json"))
        XCTAssertTrue(content.found)
        XCTAssertEqual(content.input.count, 2)
        XCTAssertEqual(content.input[1].cut, 120)
        XCTAssertEqual(content.output.map(\.kind), [.thinking, .toolUse, .text])
        XCTAssertTrue(content.cut)
        let missing = UsageRequestContent(json: try WebFixture.json("usage-request-content-missing.json"))
        XCTAssertFalse(missing.found)
        XCTAssertTrue(missing.whyText.contains("Codex"))
    }
}

final class SessionStatsTests: XCTestCase {
    private var stats: SessionStats { get throws { SessionStats(json: try WebFixture.json("sessions-stats.json")) } }
    private var overview: SessionStatsOverview { get throws { SessionStatsOverview(json: try WebFixture.json("sessions-overview.json")) } }

    func testDecodesStatsAndOverview() throws {
        let st = try stats
        XCTAssertEqual(st.from, "2026-10-26")
        XCTAssertEqual(st.dates.count, 7)
        XCTAssertEqual(st.usage.count, 4)
        XCTAssertEqual(st.active.first?.hours.count, 24)
        XCTAssertEqual(st.keys?.count, 3)
        XCTAssertEqual(st.agents["codex"], "Codex")

        let ov = try overview
        XCTAssertEqual(ov.count, 3)
        XCTAssertEqual(ov.median, 10_100)
        XCTAssertEqual(ov.days.count, 7)
        XCTAssertEqual(ov.top["tokens"]?.first?.title, "修复登录页的样式问题")
        XCTAssertEqual(ov.top["tokens"]?.first?.inOut, 15_400)
        XCTAssertEqual(ov.shape["messages"]?.labels(), ["1–5", "6–15", "16–30", "31–60", "61–120", "121+"])
        XCTAssertEqual(ov.shape["autonomy"]?.labels().first, "0")
        XCTAssertEqual(ov.tools.map(\.name), ["Read", "Bash", "Edit"])
        XCTAssertEqual(ov.toolCategories.first?.name, "Read")
        XCTAssertEqual(ov.skills.first?.agents["claude"], 3)
        XCTAssertEqual(ov.skillCount, 2)
    }

    func testReportSumsUnderFilters() throws {
        let st = try stats, ov = try overview
        let all = SessionUsageReport(stats: st, overview: ov, filter: SessionFilter())
        XCTAssertEqual(all.tokens, 12_000 + 3_400 + 8_000 + 2_100 + 500 + 200 + 3_000 + 900)
        XCTAssertEqual(all.unpricedModels, ["local-model"])
        XCTAssertEqual(all.activeSeconds, 3_600 + 900 + 420)
        XCTAssertEqual(all.activeDays, 3)
        XCTAssertEqual(all.folders.first?.name, "demo-app")
        XCTAssertEqual(all.models.first?.id, "claude-sonnet-4-6")
        XCTAssertEqual(all.agents.map(\.id), ["claude", "codex"])
        XCTAssertEqual(all.days.count, 7)
        XCTAssertEqual(all.days.first?.sessions, 1)
        XCTAssertEqual(all.days.first?.messages, 42)
        XCTAssertEqual(all.busiestHour?.hour, 10)
        XCTAssertNotNil(all.cacheHitRate)

        let codex = SessionUsageReport(stats: st, overview: nil, filter: SessionFilter(agent: "codex"))
        XCTAssertEqual(codex.tokens, 10_100)
        XCTAssertEqual(codex.folders.map(\.name), ["server"])
        let byModel = SessionUsageReport(stats: st, overview: nil, filter: SessionFilter(model: "gpt-5"))
        XCTAssertNil(byModel.activeSeconds, "按模型筛选时 magpie 不分模型记活跃时长")
        XCTAssertNil(byModel.hours)
    }

    func testListKeepsTheSessionsAtWorkInRange() throws {
        let list = UsageSessionList(json: try WebFixture.json("sessions-list.json"))
        XCTAssertEqual(list.sessions.count, 4)
        XCTAssertEqual(list.dirs.count, 2)
        XCTAssertEqual(list.sessions.first?.agentName, "Claude Code")
        XCTAssertTrue(list.sessions.first?.resume.contains("--resume") == true)
        let st = try stats
        let shown = SessionUsageReport.sessions(list.sessions, stats: st, range: .week, filter: SessionFilter())
        XCTAssertEqual(shown.map(\.session.sessionID), ["fixture-claude-2", "fixture-codex-1", "fixture-claude-1"])
        let searched = SessionUsageReport.sessions(list.sessions, stats: st, range: .week, filter: SessionFilter(search: "单元"))
        XCTAssertEqual(searched.map(\.session.sessionID), ["fixture-codex-1"])
        let folder = SessionUsageReport.sessions(list.sessions, stats: st, range: .week, filter: SessionFilter(folder: "~/code/demo-app"))
        XCTAssertEqual(folder.map(\.session.sessionID), ["fixture-claude-1"])
    }

    func testRangesAndDurations() {
        XCTAssertEqual(SessionRange.allCases.map(\.days), [1, 7, 30, 90, 0])
        XCTAssertEqual(SessionFilter(agent: "claude").overviewQuery(.month).map { "\($0.name)=\($0.value ?? "")" },
                       ["days=30", "agent=claude", "model=", "cwd="])
        XCTAssertEqual(sessionDuration(0), "0")
        XCTAssertEqual(sessionDuration(20), "<1 分")
        XCTAssertEqual(sessionDuration(600), "10 分")
        XCTAssertEqual(sessionDuration(3_720), "1 小时 2 分")
    }
}

final class ContextReportTests: XCTestCase {
    func testDecodesAgentsAndSessions() throws {
        let report = ContextReport(json: try WebFixture.json("context.json"))
        XCTAssertEqual(report.days, 7)
        XCTAssertEqual(report.agents.map(\.agent), ["claude", "scripts"])
        let claude = report.agents[0]
        XCTAssertEqual(claude.score, 78)
        XCTAssertEqual(claude.grade, .good)
        XCTAssertEqual(claude.scores.map(\.title), ["缓存", "起步轻", "增长慢", "可靠"])
        XCTAssertEqual(claude.scores[0].ratio, 0.95, accuracy: 1e-9)
        XCTAssertEqual(claude.tags.map(\.title), ["缓存友好", "MCP 偏重", "会压缩"])
        XCTAssertEqual(claude.tags[0].detail, "86% 的提示是从供应商缓存读的")
        XCTAssertEqual(claude.tags[1].detail, "MCP 服务的工具定义每次请求占 9K")
        XCTAssertTrue(claude.showsCache)
        XCTAssertEqual(claude.visibleShares.map(\.kind), [.system, .tools, .memory, .results, .chat], "低于 1% 的文件不显示")
        XCTAssertNotNil(claude.latestTime)
        XCTAssertEqual(report.agents[1].clients, ["curl", "python-httpx"])
        XCTAssertFalse(report.agents[1].showsCache)

        XCTAssertEqual(report.sessions.count, 2)
        let s = report.sessions[0]
        XCTAssertEqual(s.peakFill ?? 0, 0.305, accuracy: 1e-9)
        XCTAssertEqual(ContextHealth(fill: s.peakFill ?? 0), .ok)
        XCTAssertEqual(ContextHealth(fill: 0.95), .bad)
        let prompt = try XCTUnwrap(s.latest)
        XCTAssertEqual(prompt.parts.map(\.kind), ["system", "tools", "memory", "results", "chat"], "按 magpie 的顺序")
        XCTAssertEqual(prompt.fill ?? 0, 0.305, accuracy: 1e-9)
        XCTAssertEqual(prompt.parts[1].items.map(\.title), ["Bash", "github", "另外 6 项"])
        XCTAssertEqual(prompt.parts[1].items[1].tagTitle, "MCP")
        XCTAssertEqual(prompt.parts[4].items.map(\.title), ["第 14 轮", "更早的 13 轮"])
        XCTAssertEqual(s.latestCacheShare ?? 0, 55.0 / 61.0, accuracy: 1e-9)
        let untitled = report.sessions[1]
        XCTAssertEqual(untitled.displayTitle, "9a8b7c6d")
        XCTAssertNil(untitled.latest)
        XCTAssertNil(untitled.latestCacheShare)
        XCTAssertEqual(report.sessionAgents, ["claude"])
    }

    func testFormat() {
        XCTAssertEqual(ContextFormat.tokens(999), "999")
        XCTAssertEqual(ContextFormat.tokens(1_200), "1.2K")
        XCTAssertEqual(ContextFormat.tokens(61_000), "61K")
        XCTAssertEqual(ContextFormat.tokens(120_400), "120K")
        XCTAssertEqual(ContextFormat.tokens(1_250_000), "1.25M")
        XCTAssertEqual(ContextFormat.tokens(12_340_000), "12.3M")
        XCTAssertEqual(ContextGrade(90), .great)
        XCTAssertEqual(ContextGrade(40).title, "需要留意")
    }
}

/// fixture 模式的示例数据要能按真实接口的解码器读出来。
final class UsageTabsFixtureDataTests: XCTestCase {
    func testFixtureDataDecodes() {
        let data = UsageTabsFixtureData()
        let heat = UsageHeatmap(json: data.heatmap())
        XCTAssertFalse(heat.isEmpty)
        XCTAssertEqual(heat.weeks().count, 53)
        XCTAssertTrue(UsageRequestContent(json: data.requestContent(agent: "claude")).found)
        XCTAssertFalse(UsageRequestContent(json: data.requestContent(agent: "codex")).found)

        let list = UsageSessionList(json: data.sessionList())
        XCTAssertEqual(list.sessions.count, 5)
        for range in SessionRange.allCases {
            let st = SessionStats(json: data.sessionStats(range))
            let ov = SessionStatsOverview(json: data.sessionOverview(range, filter: SessionFilter()))
            XCTAssertEqual(ov.days.count, st.dates.count, range.rawValue)
            let report = SessionUsageReport(stats: st, overview: ov, filter: SessionFilter())
            XCTAssertTrue(report.hasUsage, range.rawValue)
            XCTAssertEqual(SessionUsageReport.sessions(list.sessions, stats: st, range: range, filter: SessionFilter()).count, ov.count, range.rawValue)
        }
        let codex = SessionStatsOverview(json: data.sessionOverview(.all, filter: SessionFilter(agent: "codex")))
        XCTAssertEqual(codex.count, 2)

        let context = ContextReport(json: data.context(days: 7))
        XCTAssertEqual(context.agents.count, 2)
        XCTAssertEqual(context.sessions.count, 2)
        XCTAssertNotNil(context.sessions.first?.latest)
    }
}

final class UsageTabsClientTests: XCTestCase {
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

    private func serve(_ name: String) {
        StubURLProtocol.handler = { _ in (200, ["Content-Type": "application/json"], try WebFixture.data(name)) }
    }

    func testRequests() async throws {
        serve("usage-heatmap.json")
        _ = try await client.usageHeatmap(UsageRequestQuery(period: .week, failedOnly: true, agent: "claude"))
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/usage/heatmap")
        XCTAssertEqual(query(StubURLProtocol.lastRequest), ["failed": "1", "agent": "claude"])
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Cookie"), "magpie_web_3430=web-key-EXAMPLE-0123")

        serve("usage-request-content.json")
        let content = try await client.usageRequestContent([URLQueryItem(name: "agent", value: "claude")])
        XCTAssertTrue(content.found)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/usage/requests/content")

        serve("sessions-stats.json")
        _ = try await client.sessionStats(.quarter)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/sessions/stats")
        XCTAssertEqual(query(StubURLProtocol.lastRequest), ["days": "90"])

        serve("sessions-overview.json")
        _ = try await client.sessionStatsOverview(.all, filter: SessionFilter(folder: "~/code/demo-app"))
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/sessions/overview")
        XCTAssertEqual(query(StubURLProtocol.lastRequest), ["days": "0", "agent": "", "model": "", "cwd": "~/code/demo-app"])

        serve("sessions-list.json")
        let list = try await client.usageSessions()
        XCTAssertEqual(list.sessions.count, 4)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/sessions")

        serve("context.json")
        _ = try await client.contextReport(days: 99)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/api/context")
        XCTAssertEqual(query(StubURLProtocol.lastRequest), ["days": "30"])
    }
}
