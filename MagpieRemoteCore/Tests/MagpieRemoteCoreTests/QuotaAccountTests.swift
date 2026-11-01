import XCTest
@testable import MagpieRemoteCore

final class QuotaAccountTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_500_000)

    func testGroupsByAccountKeepingOrder() {
        let accounts = QuotaAccount.group(QuotaSamples.cards(now: now))
        XCTAssertEqual(accounts.count, 5)
        XCTAssertEqual(accounts.map(\.provider), ["claude", "claude", "codex", "zai", "deepseek"])
        XCTAssertEqual(Set(accounts.map(\.id)).count, 5)
        XCTAssertTrue(QuotaAccount.group([]).isEmpty)

        // 同一账号的两张卡片（例如主机重复返回）收在一起。
        var cards = QuotaSamples.cards(now: now)
        var copy = cards[0]
        copy.plan = "Max 20x"
        cards.append(copy)
        let merged = QuotaAccount.group(cards)
        XCTAssertEqual(merged.count, 5)
        XCTAssertEqual(merged[0].cards.count, 2)
    }

    func testSummaryAndStatus() {
        let accounts = QuotaAccount.group(QuotaSamples.cards(now: now))
        let work = accounts[0], personal = accounts[1], codex = accounts[2], zai = accounts[3], deepseek = accounts[4]

        XCTAssertEqual(work.title, "工作 Claude")
        XCTAssertEqual(work.subtitle, "Claude · Max 5x")
        XCTAssertEqual(work.monogram, "C")
        XCTAssertEqual(work.lowestRemaining, 38.5)
        XCTAssertEqual(work.status, .ok)
        XCTAssertEqual(work.summary(now: now), "最低剩余 38.5% · 2 小时 18 分钟后重置")

        XCTAssertEqual(personal.status, .critical)
        XCTAssertEqual(personal.summary(now: now), "最低剩余 8% · 47 分钟后重置")

        // resetSecs 从 readAt 起算：10 分钟前读取 + 90 分钟 = 80 分钟后。
        XCTAssertEqual(codex.status, .critical)
        XCTAssertEqual(codex.summary(now: now), "最低剩余 0% · 1 小时 20 分钟后重置")

        XCTAssertEqual(zai.status, .ok)
        XCTAssertTrue(zai.summary(now: now).hasPrefix("最低剩余 87.6%"))

        XCTAssertEqual(deepseek.status, .neutral)
        XCTAssertEqual(deepseek.title, "DeepSeek")
        XCTAssertEqual(deepseek.subtitle, "")
        XCTAssertEqual(deepseek.summary(now: now), "余额 ¥ 23.71")
        XCTAssertFalse(deepseek.hasMeteredWindows)
        XCTAssertTrue(work.canRefresh)
        XCTAssertEqual(work.historyKeys, [QuotaSamples.cards(now: now)[0].historyKey])
    }

    func testLowAndProblemStatus() {
        var card = QuotaSamples.cards(now: now)[0]
        card.windows = card.windows.map { var w = $0; w.used = 80; return w }
        XCTAssertEqual(QuotaAccount(id: card.id, cards: [card]).status, .low)

        card.error = "读取失败"
        let failing = QuotaAccount(id: card.id, cards: [card])
        XCTAssertEqual(failing.status, .problem)
        XCTAssertTrue(failing.summary(now: now).hasSuffix("有问题"))

        card.windows = []
        XCTAssertEqual(QuotaAccount(id: card.id, cards: [card]).summary(now: now), "读取失败")
    }

    func testPastResetStillShown() {
        var card = QuotaSamples.cards(now: now)[0]
        card.windows = card.windows.map { var w = $0; w.resetsAt = now.addingTimeInterval(-60); return w }
        XCTAssertTrue(QuotaAccount(id: card.id, cards: [card]).summary(now: now).hasSuffix("已到重置时间"))
    }

    func testExpansionDefaultsCollapsed() {
        var expansion = QuotaExpansion()
        XCTAssertFalse(expansion.isExpanded("a"))
        expansion.toggle("a")
        XCTAssertTrue(expansion.isExpanded("a"))
        expansion.toggle("a")
        XCTAssertFalse(expansion.isExpanded("a"))
        expansion.set("b", expanded: true)
        expansion.set("b", expanded: true)
        XCTAssertEqual(expansion.expanded, ["b"])
    }
}
