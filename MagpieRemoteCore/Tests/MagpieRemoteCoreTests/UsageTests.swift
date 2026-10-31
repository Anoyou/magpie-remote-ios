import XCTest
@testable import MagpieRemoteCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

final class UsageDecodingTests: XCTestCase {
    // MARK: 时间

    func testParsesMagpieHumanTime() throws {
        let date = try XCTUnwrap(UsageTimestamp.parse("Sun 2026-11-01 2:40 AM CST (UTC+08:00)"))
        XCTAssertEqual(date, try XCTUnwrap(UsageTimestamp.parse("2026-10-31T18:40:00Z")))
        XCTAssertEqual(UsageTimestamp.parse("Sat 2026-10-31 12:00 PM CST (UTC+08:00)"), UsageTimestamp.parse("2026-10-31T04:00:00Z"))
        XCTAssertEqual(UsageTimestamp.parse("Sun 2026-11-01 12:00 AM CST (UTC+08:00)"), UsageTimestamp.parse("2026-10-31T16:00:00Z"))
        XCTAssertEqual(UsageTimestamp.parse("Mon 2026-03-09 9:05 PM PDT (UTC-07:00)"), UsageTimestamp.parse("2026-03-10T04:05:00Z"))
    }

    func testParsesRFC3339WithNanoseconds() throws {
        let date = try XCTUnwrap(UsageTimestamp.parse("2026-11-01T02:40:12.123456789+08:00"))
        let base = try XCTUnwrap(UsageTimestamp.parse("2026-10-31T18:40:12Z"))
        XCTAssertEqual(date.timeIntervalSince(base), 0.123456789, accuracy: 0.0001)
        XCTAssertNil(UsageTimestamp.parse("yesterday"))
        XCTAssertEqual(UsageTimestamp(raw: "garbage").raw, "garbage")
        XCTAssertNil(UsageTimestamp(raw: "garbage").date)
    }

    func testFormatRoundTrips() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let date = try XCTUnwrap(UsageTimestamp.parse("2026-10-31T18:40:00Z"))
        let text = UsageTimestamp.format(date, timeZone: zone)
        XCTAssertTrue(text.hasPrefix("Sun 2026-11-01 2:40 AM"), text)
        XCTAssertTrue(text.hasSuffix("(UTC+08:00)"), text)
        XCTAssertEqual(UsageTimestamp.parse(text), date)
    }

    // MARK: 汇总

    func testDecodesSummaryFixture() throws {
        let summary = try decode(UsageSummary.self, UsageFixtures.usageSummary)
        XCTAssertEqual(summary.period, "today")
        XCTAssertEqual(summary.totals.calls, 57)
        XCTAssertEqual(summary.totals.errors, 2)
        XCTAssertEqual(summary.totals.retried, 1)
        XCTAssertEqual(summary.totals.cost, 3.4172, accuracy: 1e-9)
        XCTAssertEqual(summary.totals.cacheRead, 1_630_400)
        XCTAssertEqual(summary.totals.tokens, 184_220 + 40_312 + 1_630_400 + 92_110)
        XCTAssertEqual(summary.totals.meanTTFTms, 71_830 / 55)
        XCTAssertNotNil(summary.since?.date)
        XCTAssertEqual(summary.bucket, "hour")
        XCTAssertEqual(summary.series.count, 3)
        XCTAssertEqual(summary.series[1].totals.calls, 12)
        XCTAssertEqual(summary.agents.map(\.displayName), ["Claude Code", "MagpieRemote"])
        XCTAssertEqual(summary.models.first?.sub, "Anthropic")
        XCTAssertEqual(summary.callerKeys.last?.displayName, "未用网关密钥（本机）")
        XCTAssertEqual(summary.sessionCount, 1)
    }

    func testDecodesLiveSummaries() throws {
        let today = try decode(UsageSummary.self, UsageFixtures.liveUsageToday)
        XCTAssertEqual(today.period, "today")
        XCTAssertEqual(today.totals.calls, 10)
        XCTAssertEqual(today.totals.unpriced, 10)
        XCTAssertEqual(today.totals.cost, 0)
        XCTAssertEqual(today.models.map(\.id), ["mock/mock-gpt-1", "mock/mock-gpt-mini"])
        XCTAssertEqual(today.agents.map(\.id), ["magpie", "curl"])
        XCTAssertEqual(today.callerKeys.first?.displayName, "Contract client")
        XCTAssertEqual(today.since?.date, UsageTimestamp.parse("2026-10-31T00:00:00Z"))
        XCTAssertNotNil(today.series.first?.time?.date)
        XCTAssertEqual(try decode(UsageSummary.self, UsageFixtures.liveUsage7d).period, "7d")
        // 不认识的 period（week）主机按 30d 处理，回复里如实写 30d。
        XCTAssertEqual(try decode(UsageSummary.self, UsageFixtures.liveUsageWeek).period, "30d")
    }

    func testBreakdownsSortAndShare() throws {
        let summary = try decode(UsageSummary.self, UsageFixtures.usageSummary)
        let models = summary.breakdown(.model)
        XCTAssertEqual(models.first?.id, "anthropic/claude-sonnet-4-6")
        XCTAssertEqual(models.reduce(0) { $0 + $1.share }, 1, accuracy: 1e-9)
        let providers = summary.breakdown(.provider)
        XCTAssertEqual(providers.map(\.id), ["anthropic", "deepseek"])
        XCTAssertEqual(providers.map(\.title), ["Anthropic", "DeepSeek"])
        XCTAssertEqual(summary.breakdown(.account).first?.title, "Work Claude")
        XCTAssertEqual(summary.breakdown(.account).first?.subtitle, "Anthropic · me@example.com")
        XCTAssertEqual(summary.breakdown(.callerKey).map(\.title), ["未用网关密钥（本机）", "iPhone"])
        XCTAssertEqual(summary.breakdown(.agent).count, 2)
    }

    func testBreakdownSharesByCallsWhenUnpriced() throws {
        let live = try decode(UsageSummary.self, UsageFixtures.liveUsageToday)
        let models = live.breakdown(.model)
        XCTAssertEqual(models.first?.id, "mock/mock-gpt-1")
        XCTAssertEqual(models.first?.share ?? 0, 0.8, accuracy: 1e-9)
        XCTAssertEqual(live.breakdown(.provider).map(\.title), ["Mock"])
        XCTAssertTrue(live.breakdown(.account).isEmpty)
    }

    // MARK: 请求记录

    func testDecodesRequestPageFixture() throws {
        let page = try decode(UsageRequestPage.self, UsageFixtures.usageRequests)
        XCTAssertEqual(page.total, 2)
        XCTAssertEqual(page.offset, 0)
        XCTAssertEqual(page.rows.count, 2)
        let ok = page.rows[0]
        XCTAssertEqual(ok.id, "r1793472032742")
        XCTAssertEqual(ok.model, "claude-sonnet-4-6")
        XCTAssertEqual(ok.requestedIfDifferent, "group/coding")
        XCTAssertEqual(ok.input, 288)
        XCTAssertEqual(ok.reasoning, 21)
        XCTAssertEqual(ok.ttftMs, 912)
        XCTAssertEqual(ok.cost, 0.0012942, accuracy: 1e-12)
        XCTAssertFalse(ok.failed)
        XCTAssertEqual(ok.access, "subscription")
        XCTAssertEqual(ok.providerAccount, "me@example.com")
        XCTAssertNotNil(ok.time.date)
        let bad = page.rows[1]
        XCTAssertTrue(bad.failed)
        XCTAssertTrue(bad.retried)
        XCTAssertEqual(bad.errorType, "timeout")
        XCTAssertNil(bad.requestedIfDifferent)
        XCTAssertEqual(UsageFormat.status(bad), "上游出错（502）")
        XCTAssertEqual(page.models.map(\.id), ["claude-sonnet-4-6", "deepseek-chat"])
        XCTAssertEqual(page.agents.map(\.id), ["MagpieRemote"])
        XCTAssertEqual(page.callerKeys.first?.name, "iPhone")
        XCTAssertEqual(page.accounts.first?.name, "Work Claude")
        XCTAssertEqual(page.totals.errors, 1)
    }

    func testDecodesLiveRequestPages() throws {
        let page = try decode(UsageRequestPage.self, UsageFixtures.liveRequests)
        XCTAssertEqual(page.total, 11)
        XCTAssertEqual(page.rows.count, 11)
        XCTAssertEqual(Set(page.rows.map(\.id)).count, 11)
        XCTAssertNil(page.rows[0].requestedIfDifferent, "mock/mock-gpt-1 与 mock-gpt-1 是同一个模型")
        XCTAssertEqual(page.rows[1].requestedIfDifferent, "group/fast")
        XCTAssertEqual(page.rows[1].session, "contract")
        let rejected = page.rows[4]
        XCTAssertNil(rejected.routeId)
        XCTAssertTrue(rejected.rejected)
        XCTAssertTrue(rejected.failed)
        XCTAssertNil(rejected.providerTitle)
        XCTAssertEqual(rejected.callerKeyTitle, "contract-temp")
        XCTAssertEqual(UsageFormat.status(rejected), "被拒绝（403）")
        XCTAssertEqual(page.models.map(\.id), ["mock-gpt-1", "mock-gpt-mini"])
        XCTAssertEqual(page.agents.map(\.id), ["curl", "magpie"])
        XCTAssertEqual(page.callerKeys.first?.name, "Contract client")

        let one = try decode(UsageRequestPage.self, UsageFixtures.liveRequestsLimit1)
        XCTAssertEqual(one.rows.count, 1)
        XCTAssertEqual(one.total, 11)

        let heldEmpty = try decode(UsageRequestPage.self, UsageFixtures.liveHeldRequests)
        XCTAssertEqual(heldEmpty.total, 0)
        XCTAssertTrue(heldEmpty.rows.isEmpty)

        let held = try decode(UsageRequestPage.self, UsageFixtures.heldRequestsWithRejected)
        XCTAssertEqual(held.rows.count, 2)
        XCTAssertTrue(held.rows[0].rejected)
        XCTAssertEqual(held.callerKeys.map(\.name), ["ios-temp"])
    }

    func testDuplicateRowIdsAreMadeUnique() throws {
        let json = #"{"rows":[{"t":"Sun 2026-11-01 2:41 AM CST (UTC+08:00)","model":"m","status":403},{"t":"Sun 2026-11-01 2:41 AM CST (UTC+08:00)","model":"m","status":403}],"offset":0,"total":2}"#
        let page = try decode(UsageRequestPage.self, json)
        XCTAssertEqual(Set(page.rows.map(\.id)).count, 2)
    }

    // MARK: 并发

    func testDecodesConcurrency() throws {
        let snapshot = try decode(ConcurrencySnapshot.self, UsageFixtures.concurrency)
        XCTAssertEqual(snapshot.requests, 4)
        XCTAssertEqual(snapshot.waiting, 1)
        XCTAssertEqual(snapshot.lanes.map(\.id), ["claude", "deepseek#9bf109433b"])
        XCTAssertEqual(snapshot.lanes[1].provider, "deepseek")
        XCTAssertEqual(snapshot.lanes[1].keyId, "9bf109433b")
        XCTAssertNil(snapshot.lanes[0].keyId)
        XCTAssertEqual(snapshot.active.count, 4)
        XCTAssertEqual(snapshot.active[1].phaseTitle, "排队等并发名额")
        XCTAssertEqual(snapshot.active[3].phaseTitle, "处理中")
        XCTAssertFalse(snapshot.isIdle)
        let idle = try decode(ConcurrencySnapshot.self, UsageFixtures.liveConcurrency)
        XCTAssertTrue(idle.isIdle)
        XCTAssertTrue(idle.lanes.isEmpty)
    }

    func testDetectsHeldKey() {
        XCTAssertTrue(UsageEndpoint.isKeyHeld(status: 403, body: Data(UsageFixtures.liveHeldUsage.utf8)))
        XCTAssertTrue(UsageEndpoint.isKeyHeld(status: 403, body: Data(UsageFixtures.liveHeldConcurrency.utf8)))
        XCTAssertFalse(UsageEndpoint.isKeyHeld(status: 403, body: Data("magpie isn't shared on the local network".utf8)))
        XCTAssertFalse(UsageEndpoint.isKeyHeld(status: 401, body: Data(UsageFixtures.liveHeldUsage.utf8)))
    }
}

final class UsageQueryTests: XCTestCase {
    private func dict(_ q: UsageRequestQuery) -> [String: String] {
        Dictionary(uniqueKeysWithValues: q.queryItems.map { ($0.name, $0.value ?? "") })
    }

    func testDefaultQuery() {
        XCTAssertEqual(dict(UsageRequestQuery()), ["period": "today", "offset": "0", "limit": "100"])
        XCTAssertFalse(UsageRequestQuery().isFiltered)
    }

    func testFiltersAndClamping() {
        let q = UsageRequestQuery(period: .week, offset: -3, limit: 9_999, failedOnly: true, retriedOnly: true,
                                  model: "deepseek-chat", agent: "MagpieRemote", callerKey: "none", search: "  sonnet ")
        XCTAssertEqual(dict(q), ["period": "7d", "offset": "0", "limit": "500", "failed": "1", "retried": "1",
                                 "model": "deepseek-chat", "agent": "MagpieRemote", "callerKey": "none", "q": "sonnet"])
        XCTAssertTrue(q.isFiltered)
        XCTAssertTrue(UsageRequestQuery(search: "x").isFiltered)
        XCTAssertFalse(UsageRequestQuery(search: "   ").isFiltered)
        XCTAssertEqual(UsagePeriod.allCases.map(\.rawValue), ["today", "7d", "30d", "all"])
    }

    func testPagerWalksOffsetsUntilTotal() throws {
        let data = UsageFixtureData(now: Date(timeIntervalSince1970: 1_793_472_000), timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai")))
        var pager = UsageRequestPager(query: UsageRequestQuery(period: .month, offset: 40, limit: 100))
        XCTAssertEqual(pager.nextQuery?.offset, 0)
        var pages = 0
        while let next = pager.nextQuery, pages < 50 {
            XCTAssertTrue(pager.apply(data.requests(next), requestedOffset: next.offset))
            pages += 1
        }
        XCTAssertGreaterThan(pager.total, 100)
        XCTAssertEqual(pager.rows.count, pager.total)
        XCTAssertEqual(pages, (pager.total + 99) / 100)
        XCTAssertEqual(Set(pager.rows.map(\.id)).count, pager.rows.count)
        XCTAssertFalse(pager.hasMore)
    }

    func testPagerIgnoresStaleOffsetsAndEmptyPages() throws {
        let page = try decode(UsageRequestPage.self, UsageFixtures.usageRequests)
        var pager = UsageRequestPager(query: UsageRequestQuery())
        XCTAssertFalse(pager.apply(page, requestedOffset: 100))
        XCTAssertTrue(pager.apply(page, requestedOffset: 0))
        XCTAssertFalse(pager.hasMore)
        var claimsMore = page
        claimsMore.total = 10
        var p2 = UsageRequestPager(query: UsageRequestQuery())
        p2.apply(claimsMore, requestedOffset: 0)
        XCTAssertEqual(p2.nextQuery?.offset, 2)
        var empty = claimsMore
        empty.rows = []
        p2.apply(empty, requestedOffset: 2)
        XCTAssertNil(p2.nextQuery, "空页时停止翻页")
    }
}

final class UsageFixtureDataTests: XCTestCase {
    private func data() throws -> UsageFixtureData {
        UsageFixtureData(now: Date(timeIntervalSince1970: 1_793_472_000), timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai")))
    }

    func testPeriodsGrow() throws {
        let data = try data()
        let calls = UsagePeriod.allCases.map { data.summary($0).totals.calls }
        XCTAssertGreaterThan(calls[0], 0)
        XCTAssertEqual(calls, calls.sorted())
        XCTAssertLessThan(calls[0], calls[2])
        XCTAssertNotEqual(data.summary(.today).totals.cost, data.summary(.week).totals.cost)
        XCTAssertEqual(data.summary(.today).bucket, "hour")
        XCTAssertEqual(data.summary(.week).bucket, "day")
        XCTAssertFalse(data.summary(.week).series.isEmpty)
    }

    func testSummaryMatchesRequestTotals() throws {
        let data = try data()
        let summary = data.summary(.week)
        let page = data.requests(UsageRequestQuery(period: .week, limit: 1))
        XCTAssertEqual(page.total, summary.totals.calls)
        XCTAssertEqual(page.totals.cost, summary.totals.cost, accuracy: 1e-9)
        XCTAssertEqual(summary.breakdown(.model).reduce(0) { $0 + $1.totals.calls }, summary.totals.calls)
        XCTAssertEqual(summary.breakdown(.provider).reduce(0) { $0 + $1.totals.calls }, summary.totals.calls)
        XCTAssertEqual(summary.breakdown(.callerKey).reduce(0) { $0 + $1.totals.calls }, summary.totals.calls)
        XCTAssertFalse(summary.breakdown(.account).isEmpty)
    }

    func testFiltersApply() throws {
        let data = try data()
        let failed = data.requests(UsageRequestQuery(period: .month, failedOnly: true))
        XCTAssertGreaterThan(failed.total, 0)
        XCTAssertTrue(failed.rows.allSatisfy(\.failed))
        let retried = data.requests(UsageRequestQuery(period: .month, retriedOnly: true))
        XCTAssertGreaterThan(retried.total, 0)
        XCTAssertTrue(retried.rows.allSatisfy { $0.retried })
        let model = data.requests(UsageRequestQuery(period: .month, model: "gpt-5"))
        XCTAssertTrue(model.rows.allSatisfy { $0.model == "gpt-5" })
        let local = data.requests(UsageRequestQuery(period: .month, callerKey: "none"))
        XCTAssertTrue(local.rows.allSatisfy { $0.callerKeyId == nil })
        let search = data.requests(UsageRequestQuery(period: .month, search: "GROUP/coding"))
        XCTAssertGreaterThan(search.total, 0)
        XCTAssertTrue(search.rows.allSatisfy { $0.requested == "group/coding" })
        let held = data.requests(UsageRequestQuery(period: .month), heldKey: true)
        XCTAssertTrue(held.rows.allSatisfy { $0.callerKeyName == "iPhone" })
        XCTAssertEqual(held.callerKeys.map(\.name), ["iPhone"])
    }

    func testFixtureTimesParse() throws {
        let row = try data().requests(UsageRequestQuery(period: .today, limit: 1)).rows[0]
        let parsed = try XCTUnwrap(UsageTimestamp.parse(row.time.raw))
        let original = try XCTUnwrap(row.time.date)
        XCTAssertLessThan(abs(parsed.timeIntervalSince(original)), 60)
    }
}

final class UsageFormatTests: XCTestCase {
    func testNumbers() {
        XCTAssertEqual(UsageFormat.cost(0), "$0.00")
        XCTAssertEqual(UsageFormat.cost(3.4172), "$3.42")
        XCTAssertEqual(UsageFormat.cost(0.0012942), "$0.0013")
        XCTAssertEqual(UsageFormat.cost(12_345.6), "$12,346")
        XCTAssertEqual(UsageFormat.tokens(8_211), "8211")
        XCTAssertEqual(UsageFormat.tokens(184_220), "18.4 万")
        XCTAssertEqual(UsageFormat.tokens(30_000), "3 万")
        XCTAssertEqual(UsageFormat.tokens(160_000_000), "1.6 亿")
        XCTAssertEqual(UsageFormat.count(1_234_567), "1,234,567")
        XCTAssertEqual(UsageFormat.duration(ms: 912), "912 毫秒")
        XCTAssertEqual(UsageFormat.duration(ms: 2_871), "2.9 秒")
        XCTAssertEqual(UsageFormat.duration(ms: 90_000), "1 分 30 秒")
        XCTAssertEqual(UsageFormat.percent(0.004), "<1%")
        XCTAssertEqual(UsageFormat.percent(0.42), "42%")
    }

    func testTimes() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let now = try XCTUnwrap(UsageTimestamp.parse("2026-11-01T10:00:00+08:00"))
        XCTAssertEqual(UsageFormat.time(UsageTimestamp(raw: "Sun 2026-11-01 2:40 AM CST (UTC+08:00)"), now: now, timeZone: zone), "02:40")
        XCTAssertEqual(UsageFormat.time(UsageTimestamp(raw: "Sat 2026-10-31 11:05 PM CST (UTC+08:00)"), now: now, timeZone: zone), "10-31 23:05")
        XCTAssertEqual(UsageFormat.time(UsageTimestamp(raw: "2025-12-31T23:59:00+08:00"), now: now, timeZone: zone), "2025-12-31 23:59")
        XCTAssertEqual(UsageFormat.time(UsageTimestamp(raw: "?"), now: now, timeZone: zone), "?")
        XCTAssertEqual(UsageFormat.fullTime(UsageTimestamp(raw: "Sun 2026-11-01 2:40 AM CST (UTC+08:00)"), timeZone: zone), "2026-11-01 02:40:00")
    }
}

final class UsageClientTests: XCTestCase {
    private var session: URLSession!
    private let base = URL(string: "http://100.64.0.1:3425")!
    private var client: GatewayClient { GatewayClient(baseURL: base, key: "sk-magpie-key-EXAMPLE", session: session) }

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
        StubURLProtocol.handler = nil
        StubURLProtocol.lastRequest = nil
    }

    func testSummaryRequestAndDecode() async throws {
        StubURLProtocol.handler = { _ in (200, ["Content-Type": "application/json"], Data(UsageFixtures.usageSummary.utf8)) }
        let result = try await client.usageSummary(period: .week)
        XCTAssertEqual(result.value?.totals.calls, 57)
        let url = try XCTUnwrap(StubURLProtocol.lastRequest?.url)
        XCTAssertEqual(url.path, "/v1/magpie/usage")
        XCTAssertEqual(url.query, "period=7d")
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-magpie-key-EXAMPLE")
    }

    func testHeldKeyIsNotAnError() async throws {
        StubURLProtocol.handler = { _ in (403, ["Content-Type": "application/json"], Data(UsageFixtures.liveHeldUsage.utf8)) }
        let summary = try await client.usageSummary(period: .today)
        XCTAssertTrue(summary.isHeld)
        if case .held(let message) = summary { XCTAssertTrue(message.contains("/v1/magpie/usage/requests")) }
        StubURLProtocol.handler = { _ in (403, ["Content-Type": "application/json"], Data(UsageFixtures.liveHeldConcurrency.utf8)) }
        let concurrency = try await client.concurrency()
        XCTAssertTrue(concurrency.isHeld)
    }

    func testNotSharedPlainText403IsAnError() async {
        StubURLProtocol.handler = { _ in (403, ["Content-Type": "text/plain"], Data("magpie isn't shared on the local network".utf8)) }
        do {
            _ = try await client.usageSummary(period: .today)
            XCTFail("应当失败")
        } catch {
            guard case .lanSharingOff = error as? MagpieError else { return XCTFail("\(error)") }
        }
    }

    func testRequestsQueryAndDecode() async throws {
        StubURLProtocol.handler = { _ in (200, [:], Data(UsageFixtures.usageRequests.utf8)) }
        let page = try await client.usageRequests(UsageRequestQuery(period: .month, offset: 100, failedOnly: true, agent: "MagpieRemote"))
        XCTAssertEqual(page.rows.count, 2)
        let components = try XCTUnwrap(StubURLProtocol.lastRequest?.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        XCTAssertEqual(components.path, "/v1/magpie/usage/requests")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items, ["period": "30d", "offset": "100", "limit": "100", "failed": "1", "agent": "MagpieRemote"])
    }

    func testConcurrencyDecode() async throws {
        StubURLProtocol.handler = { _ in (200, [:], Data(UsageFixtures.concurrency.utf8)) }
        let result = try await client.concurrency()
        XCTAssertEqual(result.value?.requests, 4)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/v1/magpie/concurrency")
    }

    func testMissingKeyFailsFast() async {
        let keyless = GatewayClient(baseURL: base, key: nil, session: session)
        do {
            _ = try await keyless.usageRequests(UsageRequestQuery())
            XCTFail("应当失败")
        } catch {
            XCTAssertEqual(error as? MagpieError, .missingKey(.gatewayKey))
        }
    }
}
