import XCTest
@testable import MagpieRemoteCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 按 UTC 分量构造时间，不经过解析器。
private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Double = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let whole = calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: Int(s)))!
    return whole.addingTimeInterval(s - Double(Int(s)))
}

/// 拼出 RFC 3339 字符串。
private func rfc(_ date: String, _ time: String, _ zone: String) -> String {
    date + "T" + time + zone
}

/// fixture 里的时间带秒和小数，这里只比较到分钟。
private func assertNear(_ actual: Date?, _ expected: Date, file: StaticString = #filePath, line: UInt = #line) {
    guard let actual else { return XCTFail("时间为 nil", file: file, line: line) }
    XCTAssertEqual(actual.timeIntervalSince(expected), 0, accuracy: 60, file: file, line: line)
}

private func decodeList<T: Decodable>(_ type: T.Type, _ json: String) throws -> [T] {
    try JSONDecoder().decode(QuotaList<T>.self, from: Data(json.utf8)).data
}

final class QuotaTimeTests: XCTestCase {
    func testRFC3339WithNanoseconds() throws {
        let date = try XCTUnwrap(QuotaTime.parse(rfc("2026-11-01", "02:40:57.127852063", "+08:00")))
        XCTAssertEqual(date.timeIntervalSince1970, at(2026, 10, 31, 18, 40, 57).timeIntervalSince1970 + 0.127852063, accuracy: 1e-6)
        XCTAssertEqual(QuotaTime.parse(rfc("2026-11-01", "02:40:57", "Z")), at(2026, 11, 1, 2, 40, 57))
        XCTAssertEqual(QuotaTime.parse(rfc("2026-11-01", "02:40:57.5", "-0700")), at(2026, 11, 1, 9, 40, 57.5))
        XCTAssertEqual(QuotaTime.parse(rfc("2026-11-01", "02:40:57", "+00:00")), at(2026, 11, 1, 2, 40, 57))
        let json = #"{"provider":"p","readAt":"\#(rfc("2026-11-01", "02:40:57.1", "Z"))"}"#
        let card = try JSONDecoder().decode(QuotaCard.self, from: Data(json.utf8))
        XCTAssertEqual(card.readAt!.timeIntervalSince1970, at(2026, 11, 1, 2, 40, 57).timeIntervalSince1970 + 0.1, accuracy: 1e-6)
    }

    func testHumanFormatIsAlsoAccepted() {
        XCTAssertEqual(QuotaTime.parse("Sun 2026-11-01 2:40 AM CST (UTC+08:00)"), at(2026, 10, 31, 18, 40))
        XCTAssertEqual(QuotaTime.parse("Sun 2026-11-01 12:00 AM CST (UTC+08:00)"), at(2026, 10, 31, 16, 0))
        XCTAssertEqual(QuotaTime.parse("Sun 2026-11-01 12:30 PM CST (UTC+08:00)"), at(2026, 11, 1, 4, 30))
        XCTAssertEqual(QuotaTime.parse("Wed 2026-11-04 9:00 PM EST (UTC-05:00)"), at(2026, 11, 5, 2, 0))
        XCTAssertEqual(QuotaTime.parse("Sun 2026-11-01 2:40:15 AM UTC (UTC)"), at(2026, 11, 1, 2, 40, 15))
    }

    func testUnparseableIsNilAndNumbersAreEpoch() {
        XCTAssertNil(QuotaTime.parse(""))
        XCTAssertNil(QuotaTime.parse("soon"))
        XCTAssertEqual(QuotaTime.parse("1700000000"), Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(QuotaTime.fromNumber(1_700_000_000_000), Date(timeIntervalSince1970: 1_700_000_000))
    }
}

final class QuotaDecodingTests: XCTestCase {
    func testGatewayCardsFixture() throws {
        let cards = try decodeList(QuotaCard.self, QuotaFixtures.gatewayCards)
        XCTAssertEqual(cards.map(\.provider), ["claude", "workbuddy", "deepseek"])

        let claude = cards[0]
        XCTAssertEqual(claude.kind, .subscription)
        XCTAssertEqual(claude.accountLabel, "Work Claude")
        XCTAssertEqual(claude.accountDetail, "me@example.com · Max 5x")
        XCTAssertEqual(claude.windows.count, 2)
        XCTAssertEqual(claude.windows[0].remainingPercent, 63)
        XCTAssertEqual(claude.windows[1].remainingPercent, 38.5)
        assertNear(claude.windows[0].resetsAt, at(2026, 10, 31, 21, 0))
        assertNear(claude.readAt, at(2026, 10, 31, 18, 41))
        XCTAssertEqual(claude.lowestRemaining, 38.5)
        XCTAssertEqual(claude.id, "|claude|me@example.com")
        XCTAssertTrue(claude.canRefresh)

        let buddy = cards[1]
        XCTAssertEqual(buddy.windows[0].amount, 250)
        XCTAssertEqual(buddy.windows[0].limit, 1000)
        XCTAssertEqual(buddy.windows[0].remainingPercent, 75)
        XCTAssertNotNil(buddy.windows[0].runsOutAt)
        XCTAssertNil(buddy.readAt)

        let deepseek = cards[2]
        XCTAssertEqual(deepseek.kind, .balance)
        XCTAssertEqual(deepseek.balanceText, "¥ 23.71")
        XCTAssertTrue(deepseek.windows.isEmpty)
        XCTAssertNil(deepseek.lowestRemaining)
    }

    func testRefreshFixtureHasCardShape() throws {
        let refreshed = try decodeList(QuotaCard.self, QuotaFixtures.gatewayRefresh)
        let cards = try decodeList(QuotaCard.self, QuotaFixtures.gatewayCards)
        XCTAssertEqual(refreshed, cards)
        // 同样的 readAt：主机 30 秒内返回的缓存。
        XCTAssertEqual(QuotaRefreshOutcome.compare(before: cards, after: refreshed), .cached)
    }

    func testGatewayQuotasFixture() throws {
        let quotas = try decodeList(QuotaCard.self, QuotaFixtures.gatewayQuotas)
        XCTAssertEqual(quotas.count, 4)
        let codex = try XCTUnwrap(quotas.first { $0.provider == "codex" })
        XCTAssertEqual(codex.windows[0].remainingPercent, 0)
        XCTAssertEqual(codex.problem, "couldn't read the allowance: 429 Too Many Requests")
        XCTAssertNotNil(codex.asOf)
        let zai = try XCTUnwrap(quotas.first { $0.provider == "zai" })
        XCTAssertEqual(zai.kind, .plan)
        XCTAssertEqual(zai.windows[0].display, "248 / 2000")
        XCTAssertEqual(zai.renew, "auto")
        XCTAssertNotNil(zai.until)
        let deepseek = try XCTUnwrap(quotas.first { $0.provider == "deepseek" })
        XCTAssertEqual(deepseek.balanceSplit.map(\.text), ["¥ 10.00", "¥ 13.71"])
    }

    func testBalanceSplitOnlyIsJoined() {
        let card = QuotaCard(provider: "x", name: "X", kind: .balance,
                             balanceSplit: [.init(label: "赠送", text: "¥ 1.00"), .init(text: "¥ 2.00")])
        XCTAssertEqual(card.balanceText, "赠送 ¥ 1.00 · ¥ 2.00")
    }

    func testLiveEmptyListsAndNulls() throws {
        XCTAssertEqual(try decodeList(QuotaCard.self, QuotaFixtures.gatewayCardsEmpty), [])
        XCTAssertEqual(try decodeList(QuotaCard.self, QuotaFixtures.liveCards), [])
        XCTAssertEqual(try decodeList(QuotaCard.self, QuotaFixtures.liveQuotas), [])
        XCTAssertEqual(try decodeList(QuotaCard.self, QuotaFixtures.liveQuotasKept), [])
        XCTAssertEqual(try decodeList(QuotaHistorySeries.self, QuotaFixtures.liveHistory7), [])
        XCTAssertEqual(try decodeList(QuotaCard.self, #"{"object":"list","data":null}"#), [])
        // 卡片里的 windows 为 null、类型不对的字段都不该让整张卡片失败。
        let cards = try decodeList(QuotaCard.self, #"{"data":[{"provider":"p","name":"P","windows":null,"used":"x","readAt":"?"}]}"#)
        XCTAssertEqual(cards.count, 1)
        XCTAssertTrue(cards[0].windows.isEmpty)
        XCTAssertNil(cards[0].readAt)
        XCTAssertEqual(cards[0].kind, .unknown)
        XCTAssertTrue(QuotaGroup.group([]).isEmpty)
        // 不是列表形状的响应要报错。
        XCTAssertThrowsError(try decodeList(QuotaCard.self, #"{"error":"x"}"#))
    }

    func testWindowWithoutBar() throws {
        let read = rfc("2026-11-01", "00:00:00", "Z")
        let cards = try decodeList(QuotaCard.self, #"{"data":[{"provider":"p","name":"P","windows":[{"name":"a","text":"无限"},{"name":"b","unlimited":true},{"name":"c","used":10,"balance":3.5},{"name":"d","used":130},{"name":"e","resetSecs":60,"used":5}],"readAt":"\#(read)"}]}"#)
        let windows = cards[0].windows
        XCTAssertNil(windows[0].remainingPercent)
        XCTAssertNil(windows[1].remainingPercent)
        XCTAssertNil(windows[2].remainingPercent)
        XCTAssertEqual(windows[3].remainingPercent, 0)
        XCTAssertEqual(windows[4].resetDate(readAt: cards[0].readAt), at(2026, 11, 1, 0, 1))
        XCTAssertEqual(cards[0].meteredWindows.map(\.name), ["d", "e"])
    }

    func testHistoryFixture() throws {
        let history = try decodeList(QuotaHistorySeries.self, QuotaFixtures.gatewayHistory)
        XCTAssertEqual(history.count, 1)
        let series = history[0]
        XCTAssertEqual(series.id, "claude|me@example.com")
        XCTAssertEqual(series.lines.map(\.name), ["5 hours", "Week"])
        XCTAssertEqual(series.lines[0].points.map(\.left), [100, 81, 63])
        assertNear(series.lines[0].points[0].at, at(2026, 10, 31, 16, 5))
        assertNear(series.lines[0].points[0].start, at(2026, 10, 31, 16, 0))
        XCTAssertEqual(series.lines[1].points.last?.left, 38.5)
        XCTAssertEqual(series.pointCount, 5)

        let cards = try decodeList(QuotaCard.self, QuotaFixtures.gatewayCards)
        XCTAssertEqual(cards[0].historyKey, series.id)
    }

    func testHistoryDropsBadPoints() throws {
        let a = rfc("2026-11-01", "02:00:00", "Z"), b = rfc("2026-11-01", "01:00:00", "Z")
        let history = try decodeList(QuotaHistorySeries.self, #"{"data":[{"provider":"p","user":null,"lines":[{"name":"w","points":[{"at":"\#(a)","left":150},{"left":3},{"at":"\#(b)","left":-2}]}]}]}"#)
        XCTAssertEqual(history[0].lines[0].points.map(\.left), [0, 100])
        XCTAssertEqual(history[0].id, "p|")
    }

    func testKeyLimitFixtures() throws {
        let decoder = JSONDecoder()
        let unlimited = try decoder.decode(KeyLimit.self, from: Data(QuotaFixtures.gatewayLimitUnlimited.utf8))
        XCTAssertFalse(unlimited.limited)
        XCTAssertEqual(unlimited.key, "iPhone")
        XCTAssertTrue(unlimited.allBudgets.isEmpty)
        XCTAssertFalse(try decoder.decode(KeyLimit.self, from: Data(QuotaFixtures.liveLimit.utf8)).limited)

        let limited = try decoder.decode(KeyLimit.self, from: Data(QuotaFixtures.gatewayLimitLimited.utf8))
        XCTAssertTrue(limited.limited)
        XCTAssertEqual(limited.limits.count, 2)
        let day = limited.limits[0]
        XCTAssertEqual(day.periodText, "每天")
        XCTAssertEqual(day.tokenLimit, 200_000)
        XCTAssertEqual(day.costLimit, 5)
        XCTAssertEqual(day.usedFraction!, 44532.0 / 200_000, accuracy: 1e-9)
        assertNear(day.reset, at(2026, 11, 1, 16, 0))
        let hours = try XCTUnwrap(limited.limit)
        XCTAssertEqual(hours.periodText, "每 5 小时")
        XCTAssertNil(hours.costLimit, "costLimit 缺省 = 不限金额")
        XCTAssertEqual(hours.usageText, "已用 4.45 万 / 5 万 词元 · $0.52 · 17 次调用")

        let issued = try decoder.decode(KeyLimit.self, from: Data(QuotaFixtures.gatewayLimitIssued.utf8))
        XCTAssertEqual(issued.key, "ios-temp")
        XCTAssertNotNil(issued.expires)
        XCTAssertEqual(issued.allBudgets.map(\.periodText), ["每 30 天", "每天"])

        let live = try decoder.decode(KeyLimit.self, from: Data(QuotaFixtures.liveHeldLimit.utf8))
        XCTAssertTrue(live.limited)
        XCTAssertNotNil(live.expires)
        XCTAssertNotNil(live.limit?.reset)
        XCTAssertEqual(live.limit?.periodText, "每 1 小时")
        XCTAssertEqual(live.limit?.tokenLimit, 10000)
        XCTAssertEqual(live.limit?.remainingPercent ?? -1, 100, accuracy: 1e-9)
        XCTAssertEqual(live.allBudgets.count, 1)
    }

    func testSpentBudgetIsFull() {
        XCTAssertEqual(KeyBudget(period: "day", tokens: 1, tokenLimit: 100, spent: true).usedFraction, 1)
        XCTAssertNil(KeyBudget(period: "day", tokens: 5).usedFraction)
    }

    func testAccessErrorsFromFixtures() {
        XCTAssertEqual(QuotaAccessError.from(status: 403, body: Data(QuotaFixtures.liveHeldQuotas.utf8)), .keyHeld)
        XCTAssertEqual(QuotaAccessError.from(status: 403, body: Data(QuotaFixtures.liveReadOnly.utf8)), .readOnly)
        XCTAssertEqual(QuotaAccessError.from(status: 400, body: Data(QuotaFixtures.gatewayRefreshRemoteCard.utf8)), .remoteCard)
        XCTAssertNil(QuotaAccessError.from(status: 403, body: Data(QuotaFixtures.gatewayQuotasNotShared.utf8)))
        XCTAssertNil(QuotaAccessError.from(status: 403, body: Data("magpie is not shared".utf8)))
        if case .lanSharingOff = MagpieError.from(status: 403, body: Data(QuotaFixtures.gatewayQuotasNotShared.utf8)) {} else {
            XCTFail("未共享的 403 应提示开启局域网共享")
        }
    }
}

final class QuotaLogicTests: XCTestCase {
    func testRefreshOutcome() {
        let t0 = at(2026, 11, 1, 0, 0)
        let a = QuotaCard(provider: "claude", name: "Claude", user: "Me@example.com", readAt: t0)
        var a2 = a
        a2.readAt = t0.addingTimeInterval(45)
        XCTAssertEqual(QuotaRefreshOutcome.compare(before: [a], after: [a]), .cached)
        XCTAssertEqual(QuotaRefreshOutcome.compare(before: [a], after: [a2]), .refreshed)
        let b = QuotaCard(provider: "codex", name: "Codex", readAt: t0)
        XCTAssertEqual(QuotaRefreshOutcome.compare(before: [a], after: [a, b]), .refreshed, "新出现的卡片算刷新")
        let noRead = QuotaCard(provider: "x", name: "X")
        XCTAssertEqual(QuotaRefreshOutcome.compare(before: [noRead], after: [noRead]), .unknown)
        XCTAssertEqual(QuotaRefreshOutcome.compare(before: [], after: []), .unknown)
    }

    func testThrottle() {
        let t0 = at(2026, 11, 1, 0, 0)
        var throttle = QuotaRefreshThrottle()
        XCTAssertNil(throttle.wait(now: t0))
        throttle.record(now: t0)
        XCTAssertEqual(throttle.wait(now: t0.addingTimeInterval(10)), 20)
        XCTAssertEqual(throttle.wait(for: "|claude|me@example.com", now: t0.addingTimeInterval(10)), 20, "全部刷新也覆盖单张卡片")
        XCTAssertNil(throttle.wait(now: t0.addingTimeInterval(30)))
        throttle.record("|codex|", now: t0.addingTimeInterval(40))
        XCTAssertNil(throttle.wait(now: t0.addingTimeInterval(41)), "单张卡片刷新不挡全部刷新")
        XCTAssertNotNil(throttle.wait(for: "|codex|", now: t0.addingTimeInterval(41)))
        XCTAssertNil(throttle.wait(for: "|claude|", now: t0.addingTimeInterval(41)))
    }

    func testMergeAndGroup() throws {
        let cards = try decodeList(QuotaCard.self, QuotaFixtures.gatewayCards)
        let quotas = try decodeList(QuotaCard.self, QuotaFixtures.gatewayQuotas)
        let merged = QuotaMerge.merge(cards: cards, readings: quotas)
        XCTAssertEqual(merged.prefix(3).map(\.provider), ["claude", "workbuddy", "deepseek"])
        XCTAssertTrue(merged.contains { $0.provider == "codex" })
        XCTAssertEqual(merged.filter { $0.provider == "deepseek" }.count, 1)
        XCTAssertEqual(Set(merged.map(\.id)).count, merged.count)

        var updated = cards[0]
        updated.readAt = nil
        XCTAssertNil(QuotaMerge.replacing(cards, with: [updated])[0].readAt)

        let groups = QuotaGroup.group(QuotaSamples.cards())
        XCTAssertEqual(groups.map(\.provider), ["claude", "codex", "zai", "deepseek"])
        XCTAssertEqual(groups[0].cards.count, 2)
        XCTAssertEqual(groups[0].title, "Claude")
    }

    func testSamples() throws {
        let now = at(2026, 11, 1, 3, 0, 0.25)
        let cards = QuotaSamples.cards(now: now)
        XCTAssertEqual(cards.count, 5)
        XCTAssertEqual(cards[0].windows[0].resetsAt!.timeIntervalSince(now), 2 * 3600 + 18 * 60, accuracy: 0.001)
        XCTAssertEqual(cards[2].windows[0].resetDate(readAt: cards[2].readAt), cards[2].readAt!.addingTimeInterval(5400))
        XCTAssertEqual(cards[4].balanceText, "¥ 23.71")
        XCTAssertTrue(cards.allSatisfy { $0.user.map { $0.hasSuffix("@example.com") } ?? true })

        let refreshed = QuotaSamples.refreshedCards(now: now.addingTimeInterval(60))
        XCTAssertEqual(QuotaRefreshOutcome.compare(before: cards, after: refreshed), .refreshed)

        let week = QuotaSamples.history(days: 7, now: now)
        let month = QuotaSamples.history(days: 30, now: now)
        XCTAssertEqual(week.count, 4)
        XCTAssertNotEqual(week[0].lines[0].points.first?.at, month[0].lines[0].points.first?.at)
        XCTAssertEqual(week[0].id, cards[0].historyKey)
        XCTAssertEqual(week[0].lines[0].points.last?.left, 63)

        let held = QuotaSamples.heldKeyLimit(now: now)
        XCTAssertTrue(held.limited)
        XCTAssertEqual(held.allBudgets.count, 2)
        XCTAssertEqual(held.limit?.tokensLeft, 3770)
    }
}

final class QuotaFormatTests: XCTestCase {
    private let zone = TimeZone(secondsFromGMT: 8 * 3600)!
    /// 2026-11-01 02:40 +08:00
    private let now = at(2026, 10, 31, 18, 40)

    private func local(_ mo: Int, _ d: Int, _ h: Int, _ mi: Int, year: Int = 2026) -> Date {
        at(year, mo, d, h, mi).addingTimeInterval(-8 * 3600)
    }

    func testRelative() {
        XCTAssertEqual(QuotaFormat.relative(to: now.addingTimeInterval(20), now: now), "1 分钟后")
        XCTAssertEqual(QuotaFormat.relative(to: now.addingTimeInterval(45 * 60), now: now), "45 分钟后")
        XCTAssertEqual(QuotaFormat.relative(to: now.addingTimeInterval(2 * 3600 + 18 * 60), now: now), "2 小时 18 分钟后")
        XCTAssertEqual(QuotaFormat.relative(to: now.addingTimeInterval(3 * 3600), now: now), "3 小时后")
        XCTAssertEqual(QuotaFormat.relative(to: now.addingTimeInterval(3 * 86400 + 6 * 3600 + 120), now: now), "3 天 6 小时后")
        XCTAssertNil(QuotaFormat.relative(to: now.addingTimeInterval(-1), now: now))
    }

    func testAbsoluteAndReset() {
        XCTAssertEqual(QuotaFormat.absolute(local(11, 1, 5, 0), now: now, timeZone: zone), "今天 05:00")
        XCTAssertEqual(QuotaFormat.absolute(local(11, 2, 9, 0), now: now, timeZone: zone), "明天 09:00")
        XCTAssertEqual(QuotaFormat.absolute(local(11, 4, 9, 0), now: now, timeZone: zone), "11月4日 周三 09:00")
        XCTAssertEqual(QuotaFormat.absolute(local(1, 3, 21, 5, year: 2027), now: now, timeZone: zone), "2027年1月3日 21:05")
        XCTAssertEqual(QuotaFormat.reset(local(11, 1, 5, 0), now: now, timeZone: zone), "2 小时 20 分钟后重置（今天 05:00）")
        XCTAssertEqual(QuotaFormat.reset(local(11, 1, 2, 0), now: now, timeZone: zone), "已到重置时间（今天 02:00），等待主机更新")
        XCTAssertEqual(QuotaFormat.readAgo(now.addingTimeInterval(-30), now: now), "刚刚读取")
        XCTAssertEqual(QuotaFormat.readAgo(now.addingTimeInterval(-300), now: now), "5 分钟前读取")
    }

    func testNumbers() {
        XCTAssertEqual(QuotaFormat.percent(63), "63%")
        XCTAssertEqual(QuotaFormat.percent(38.5), "38.5%")
        XCTAssertEqual(QuotaFormat.percent(0.2), "<1%")
        XCTAssertEqual(QuotaFormat.percent(120), "100%")
        XCTAssertEqual(QuotaFormat.tokens(9981), "9,981")
        XCTAssertEqual(QuotaFormat.tokens(44532), "4.45 万")
        XCTAssertEqual(QuotaFormat.tokens(200_000), "20 万")
        XCTAssertEqual(QuotaFormat.tokens(120_000_000), "1.2 亿")
        XCTAssertEqual(QuotaFormat.usd(0.5172), "$0.52")
        XCTAssertEqual(QuotaFormat.usd(5), "$5.00")
        XCTAssertEqual(QuotaFormat.windowName("5 hours"), "5 小时")
        XCTAssertEqual(QuotaFormat.windowName("Week"), "每周")
        XCTAssertEqual(QuotaFormat.windowName("Opus week"), "Opus week")
    }
}

final class QuotaClientTests: XCTestCase {
    private var session: URLSession!
    private let base = URL(string: "http://100.64.0.1:3425")!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
        StubURLProtocol.handler = nil
        StubURLProtocol.lastRequest = nil
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    private var client: GatewayClient { GatewayClient(baseURL: base, key: "sk-magpie-key-EXAMPLE", session: session) }

    func testSnapshotMergesCardsAndKeptReadings() async throws {
        StubURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == QuotaEndpoint.cards { return (200, [:], Data(QuotaFixtures.gatewayCards.utf8)) }
            if path == QuotaEndpoint.quotas, request.url?.query == "kept=1" { return (200, [:], Data(QuotaFixtures.gatewayQuotas.utf8)) }
            return (404, [:], Data())
        }
        let snapshot = try await client.quotaSnapshot()
        guard case .cards(let cards) = snapshot else { return XCTFail("应返回卡片") }
        XCTAssertEqual(cards.first?.accountLabel, "Work Claude")
        XCTAssertTrue(cards.contains { $0.provider == "codex" })
    }

    func testSnapshotStillWorksWhenReadingsFail() async throws {
        StubURLProtocol.handler = { request in
            if request.url?.path == QuotaEndpoint.cards { return (200, [:], Data(QuotaFixtures.liveCards.utf8)) }
            return (500, [:], Data("boom".utf8))
        }
        let snapshot = try await client.quotaSnapshot()
        XCTAssertEqual(snapshot, .cards([]))
    }

    func testHeldKeyFallsBackToOwnLimit() async throws {
        StubURLProtocol.handler = { request in
            switch request.url?.path {
            case QuotaEndpoint.cards, QuotaEndpoint.quotas: return (403, ["Content-Type": "application/json"], Data(QuotaFixtures.liveHeldQuotas.utf8))
            case QuotaEndpoint.limit: return (200, [:], Data(QuotaFixtures.liveHeldLimit.utf8))
            default: return (404, [:], Data())
            }
        }
        let snapshot = try await client.quotaSnapshot()
        guard case .keyHeld(let limit) = snapshot else { return XCTFail("受限密钥应显示自己的限额") }
        XCTAssertTrue(limit.limited)
        XCTAssertEqual(limit.limit?.tokenLimit, 10000)
    }

    func testNotSharedIsAPlainError() async {
        StubURLProtocol.handler = { _ in (403, [:], Data(QuotaFixtures.gatewayQuotasNotShared.utf8)) }
        do {
            _ = try await client.quotaSnapshot()
            XCTFail("应报错")
        } catch let error as MagpieError {
            if case .lanSharingOff = error {} else { XCTFail("\(error)") }
        } catch {
            XCTFail("\(error)")
        }
    }

    func testRefreshIsPostWithScope() async throws {
        StubURLProtocol.handler = { _ in (200, [:], Data(QuotaFixtures.gatewayRefresh.utf8)) }
        let cards = try await client.refreshQuotaCards(provider: "claude", user: "me@example.com")
        XCTAssertEqual(cards.count, 3)
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, QuotaEndpoint.refresh)
        XCTAssertEqual(request.url?.query, "provider=claude&user=me@example.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-magpie-key-EXAMPLE")
    }

    func testRefreshReadOnlyAndRemoteCard() async {
        StubURLProtocol.handler = { _ in (403, [:], Data(QuotaFixtures.liveReadOnly.utf8)) }
        do { _ = try await client.refreshQuotaCards(); XCTFail("应报错") } catch { XCTAssertEqual(error as? QuotaAccessError, .readOnly) }
        StubURLProtocol.handler = { _ in (400, [:], Data(QuotaFixtures.gatewayRefreshRemoteCard.utf8)) }
        do { _ = try await client.refreshQuotaCards(provider: "x"); XCTFail("应报错") } catch { XCTAssertEqual(error as? QuotaAccessError, .remoteCard) }
    }

    func testHistoryQuery() async throws {
        StubURLProtocol.handler = { _ in (200, [:], Data(QuotaFixtures.gatewayHistory.utf8)) }
        let history = try await client.quotaHistory(days: 30)
        XCTAssertEqual(history.first?.lines.count, 2)
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.query, "days=30")
    }
}
