import XCTest
@testable import MagpieRemoteCore

/// 小组件：快照编解码、时间线、显示文字、App Group 候选与深链。全部是假数据。
final class WidgetTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_500_000) // 固定时间，避免依赖时钟
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!

    private func cards() -> [QuotaCard] {
        [
            QuotaCard(provider: "claude", name: "Claude", icon: "claude", plan: "Max 5x", user: "me@example.com", alias: "Work Claude",
                      windows: [QuotaWindow(name: "5 hours", used: 37, resetsAt: now.addingTimeInterval(2 * 3600 + 18 * 60)),
                                QuotaWindow(name: "Week", used: 61.5, resetsAt: now.addingTimeInterval(3 * 86400))],
                      readAt: now.addingTimeInterval(-120)),
            QuotaCard(provider: "codex", name: "Codex", icon: "codex-color", user: "dev@example.com",
                      windows: [QuotaWindow(name: "5h", remaining: 8, resetsAt: now.addingTimeInterval(47 * 60)),
                                QuotaWindow(name: "weekly", unlimited: true)],
                      readAt: now.addingTimeInterval(-60)),
            QuotaCard(provider: "deepseek", name: "DeepSeek", icon: "deepseek-color", kind: .balance, balance: "¥ 23.71"),
            QuotaCard(provider: "kimi", name: "Kimi", user: "13800000000", needsAccessKey: true),
        ]
    }

    private func snapshot(generatedAt: Date? = nil) -> WidgetSnapshot {
        var totals = UsageTotals()
        totals.calls = 120; totals.errors = 3; totals.input = 40_000; totals.output = 4_500; totals.cost = 1.234
        return WidgetSnapshot.make(hostName: "示例 Mac", quota: .cards(cards()), today: totals, concurrency: nil, now: generatedAt ?? now)
    }

    // MARK: 快照

    func testSnapshotMapsAccountsWindowsAndHasNoSecrets() throws {
        let snap = snapshot()
        let accounts = snap.quota.accounts
        XCTAssertEqual(accounts.map(\.title), ["Claude", "Codex", "DeepSeek", "Kimi"])
        XCTAssertEqual(accounts[0].account, "Work Claude")
        XCTAssertEqual(accounts[0].windows.map(\.name), ["5 小时", "每周"])
        XCTAssertEqual(accounts[0].windows[0].remaining, 63)
        XCTAssertEqual(accounts[0].windows[1].remaining, 38.5)
        // 不限量窗口没有百分比也没有文字：不进小组件。
        XCTAssertEqual(accounts[1].windows.map(\.name), ["5 小时"])
        XCTAssertEqual(accounts[1].lowestRemaining, 8)
        XCTAssertEqual(accounts[2].balance, "¥ 23.71")
        XCTAssertNotNil(accounts[3].problem)
        XCTAssertEqual(snap.today?.calls, 120)
        XCTAssertEqual(snap.today?.tokens, 44_500)
        XCTAssertNil(snap.concurrency)

        let json = String(decoding: try WidgetSnapshotCodec.encode(snap), as: UTF8.self)
        for forbidden in ["sk-", "apiKey", "gatewayKey", "webKey", "http://", "https://"] {
            XCTAssertFalse(json.contains(forbidden), "快照里不该出现 \(forbidden)")
        }
    }

    func testSnapshotRoundTripsAllQuotaStates() throws {
        let states: [WidgetQuotaState] = [.accounts(snapshot().quota.accounts), .accounts([]), .keyHeld, .noHost, .failed("连不上主机")]
        for state in states {
            let snap = WidgetSnapshot(generatedAt: now, hostName: "示例 Mac", quota: state,
                                      today: WidgetUsageToday(cost: 0.5, tokens: 10, calls: 2, errors: 1),
                                      concurrency: WidgetConcurrency(requests: 3, waiting: 1))
            let decoded = WidgetSnapshotCodec.decode(try WidgetSnapshotCodec.encode(snap))
            XCTAssertEqual(decoded, snap)
        }
    }

    func testDecodeRejectsGarbageAndNewerVersions() throws {
        XCTAssertNil(WidgetSnapshotCodec.decode(Data("not json".utf8)))
        var snap = snapshot()
        snap.version = WidgetSnapshot.currentVersion + 1
        XCTAssertNil(WidgetSnapshotCodec.decode(try WidgetSnapshotCodec.encode(snap)))
        snap.version = 0
        XCTAssertNil(WidgetSnapshotCodec.decode(try WidgetSnapshotCodec.encode(snap)))
    }

    func testMakeWithoutHostAndWithFailureAndKeyHeld() {
        XCTAssertEqual(WidgetSnapshot.make(hostName: nil, quota: .cards(cards()), today: nil, concurrency: nil, now: now).quota, .noHost)
        XCTAssertEqual(WidgetSnapshot.make(hostName: "示例 Mac", quota: nil, quotaError: "连不上主机", today: nil, concurrency: nil, now: now).quota,
                       .failed("连不上主机"))
        XCTAssertEqual(WidgetSnapshot.make(hostName: "示例 Mac", quota: .keyHeld(KeyLimit(limited: true)), today: nil, concurrency: nil, now: now).quota,
                       .keyHeld)
    }

    func testUpdatingQuotaKeepsUsage() {
        let later = now.addingTimeInterval(600)
        let updated = snapshot().updatingQuota(.cards(Array(cards().prefix(1))), now: later)
        XCTAssertEqual(updated.generatedAt, later)
        XCTAssertEqual(updated.quota.accounts.count, 1)
        XCTAssertEqual(updated.today?.calls, 120)
    }

    func testAccountsCappedAndSameAccountCardsMerged() {
        var many: [QuotaCard] = []
        for i in 0..<12 {
            many.append(QuotaCard(provider: "p\(i)", name: "P\(i)", windows: [QuotaWindow(name: "day", used: Double(i))]))
        }
        // 同一账号的第二张卡片并进同一个账号。
        many.insert(QuotaCard(provider: "p0", name: "P0", windows: [QuotaWindow(name: "month", used: 90)]), at: 1)
        let accounts = WidgetQuotaAccount.accounts(from: many)
        XCTAssertEqual(accounts.count, WidgetSnapshot.maxAccounts)
        XCTAssertEqual(accounts[0].windows.map(\.name), ["每天", "每月"])
        XCTAssertEqual(accounts[0].lowestRemaining, 10)
    }

    // MARK: 显示

    func testWindowDisplayCountdownAndPassedReset() {
        let window = WidgetQuotaWindow(name: "5 小时", remaining: 8, resetsAt: now.addingTimeInterval(2 * 3600 + 18 * 60))
        let d = WidgetDisplay.window(window, now: now)
        XCTAssertEqual(d.valueText, "8%")
        XCTAssertEqual(d.resetText, "2 小时 18 分后重置")
        XCTAssertEqual(d.level, .critical)
        XCTAssertFalse(d.resetPassed)

        let passed = WidgetDisplay.window(window, now: now.addingTimeInterval(3 * 3600))
        XCTAssertTrue(passed.resetPassed)
        XCTAssertEqual(passed.resetText, "已重置，待刷新")
        XCTAssertEqual(passed.level, .unknown)

        let text = WidgetDisplay.window(WidgetQuotaWindow(name: "点数", detail: "248 / 2000"), now: now)
        XCTAssertEqual(text.valueText, "248 / 2000")
        XCTAssertNil(text.resetText)
        XCTAssertEqual(WidgetQuotaLevel(remaining: 25), .low)
        XCTAssertEqual(WidgetQuotaLevel(remaining: 26), .normal)
    }

    func testPrimaryAccountIsTightestAndSkipsPassedResets() {
        let accounts = snapshot().quota.accounts
        XCTAssertEqual(WidgetDisplay.primaryAccount(accounts, now: now)?.title, "Codex")
        // Codex 的 5 小时窗口过了重置时间后，最紧张的变成 Claude。
        XCTAssertEqual(WidgetDisplay.primaryAccount(accounts, now: now.addingTimeInterval(3600))?.title, "Claude")
        // 没有百分比的账号：取第一个。
        let balanceOnly = Array(accounts.suffix(2))
        XCTAssertEqual(WidgetDisplay.primaryAccount(balanceOnly, now: now)?.title, "DeepSeek")
        XCTAssertNil(WidgetDisplay.primaryAccount([], now: now))
    }

    func testListedAccountsPutProblemsLast() {
        let accounts = snapshot().quota.accounts
        let kimiFirst = [accounts[3]] + accounts.prefix(3)
        XCTAssertEqual(WidgetDisplay.listedAccounts(kimiFirst, limit: 4).map(\.title), ["Claude", "Codex", "DeepSeek", "Kimi"])
        XCTAssertEqual(WidgetDisplay.listedAccounts(kimiFirst, limit: 2).map(\.title), ["Claude", "Codex"])
    }

    func testFormats() {
        XCTAssertEqual(WidgetFormat.countdown(to: now.addingTimeInterval(30), now: now), "1 分")
        XCTAssertEqual(WidgetFormat.countdown(to: now.addingTimeInterval(47 * 60), now: now), "47 分")
        XCTAssertEqual(WidgetFormat.countdown(to: now.addingTimeInterval(3600), now: now), "1 小时")
        XCTAssertEqual(WidgetFormat.countdown(to: now.addingTimeInterval(3 * 86400 + 4 * 3600), now: now), "3 天 4 小时")
        XCTAssertEqual(WidgetFormat.countdown(to: now.addingTimeInterval(-5), now: now), "0 分")
        XCTAssertEqual(WidgetFormat.cost(0), "$0")
        XCTAssertEqual(WidgetFormat.cost(0.004), "<$0.01")
        XCTAssertEqual(WidgetFormat.cost(1.234), "$1.23")
        XCTAssertEqual(WidgetFormat.cost(12.34), "$12.3")
        XCTAssertEqual(WidgetFormat.cost(1234.4), "$1,234")
        XCTAssertEqual(WidgetFormat.failureRate(nil), "—")
        XCTAssertEqual(WidgetFormat.failureRate(0), "0%")
        XCTAssertEqual(WidgetFormat.failureRate(3.0 / 120), "2.5%")
        XCTAssertEqual(WidgetFormat.failureRate(0.0005), "<0.1%")
        XCTAssertEqual(WidgetFormat.failureRate(0.5), "50%")
        XCTAssertEqual(WidgetUsageToday(cost: 0, tokens: 0, calls: 0, errors: 0).failureRate, nil)
        XCTAssertEqual(WidgetDisplay.updatedText(now.addingTimeInterval(-10), now: now), "刚刚更新")
        XCTAssertEqual(WidgetDisplay.updatedText(now.addingTimeInterval(-25 * 60), now: now), "25 分钟前更新")
        XCTAssertEqual(WidgetDisplay.updatedText(now.addingTimeInterval(-3 * 3600 - 5), now: now), "3 小时前更新")
        XCTAssertTrue(WidgetDisplay.updatedText(now.addingTimeInterval(-30 * 3600), now: now, timeZone: shanghai).hasSuffix(" 更新"))
    }

    func testFreshness() {
        XCTAssertEqual(WidgetFreshness(generatedAt: now, now: now.addingTimeInterval(29 * 60)), .fresh)
        XCTAssertEqual(WidgetFreshness(generatedAt: now, now: now.addingTimeInterval(30 * 60)), .aging)
        XCTAssertEqual(WidgetFreshness(generatedAt: now, now: now.addingTimeInterval(6 * 3600)), .stale)
    }

    // MARK: 时间线

    func testTimelineWithoutSnapshotIsSingleEntryAndRetriesIn30Minutes() {
        for content in [WidgetContent.noAppGroup, .noSnapshot] {
            XCTAssertEqual(WidgetTimelinePlan.entryDates(for: content, now: now), [now])
            XCTAssertEqual(WidgetTimelinePlan.reloadDate(for: content, now: now), now.addingTimeInterval(1800))
        }
    }

    func testTimelineIncludesQuarterHoursResetsAndFreshnessThresholds() {
        let content = WidgetContent.snapshot(snapshot())
        let dates = WidgetTimelinePlan.entryDates(for: content, now: now)
        XCTAssertEqual(dates.first, now)
        XCTAssertEqual(dates, dates.sorted())
        XCTAssertEqual(Set(dates).count, dates.count)
        XCTAssertLessThanOrEqual(dates.count, WidgetTimelinePlan.maxEntries)
        XCTAssertTrue(dates.allSatisfy { $0 >= now && $0 <= now.addingTimeInterval(WidgetTimelinePlan.horizon) })
        // Codex 5 小时窗口（47 分钟后）与 Claude 5 小时窗口（2 小时 18 分后）的重置时刻；3 天后的每周重置不在范围内。
        XCTAssertTrue(dates.contains(now.addingTimeInterval(47 * 60)))
        XCTAssertTrue(dates.contains(now.addingTimeInterval(2 * 3600 + 18 * 60)))
        XCTAssertFalse(dates.contains(now.addingTimeInterval(3 * 86400)))
        // 30 分钟后快照变「旧」。
        XCTAssertTrue(dates.contains(now.addingTimeInterval(WidgetFreshness.agingAfter)))
        // 其余点对齐整刻钟。
        let quarter = dates.dropFirst().filter { $0.timeIntervalSince1970.truncatingRemainder(dividingBy: 900) == 0 }
        XCTAssertGreaterThanOrEqual(quarter.count, 23)
        XCTAssertEqual(WidgetTimelinePlan.reloadDate(for: content, now: now), dates.last)
    }

    func testTimelineForOldSnapshotSkipsPastThresholds() {
        let old = snapshot(generatedAt: now.addingTimeInterval(-7 * 3600))
        let dates = WidgetTimelinePlan.entryDates(for: .snapshot(old), now: now)
        XCTAssertFalse(dates.contains(old.generatedAt.addingTimeInterval(WidgetFreshness.agingAfter)))
        XCTAssertTrue(dates.allSatisfy { $0 >= now })
    }

    // MARK: App Group

    func testCandidatesOrderAndDedup() {
        let profile = ProvisioningProfileInfo(teamID: "ABCDE12345", appGroups: ["group.com.magpieremote.personal.ABCDE12345", "group.*"])
        let info: [String: Any] = [
            "ALTAppGroups": ["group.com.magpieremote.personal.ABCDE12345", "group.alt.extra"],
            "MagpieAppGroup": "group.com.magpieremote.personal",
        ]
        let ids = WidgetAppGroup.candidates(info: info, bundleID: "com.magpieremote.personal.ABCDE12345.widgets", profile: profile)
        XCTAssertEqual(ids, [
            "group.com.magpieremote.personal.ABCDE12345",
            "group.alt.extra",
            "group.com.magpieremote.personal",
        ])
    }

    func testCandidatesWithoutProfileFallBackToBaseAndBundle() {
        let ids = WidgetAppGroup.candidates(info: ["MagpieAppGroup": "$(MAGPIE_APP_GROUP)"], bundleID: "com.example.renamed.widgets", profile: nil)
        XCTAssertEqual(ids, ["group.com.magpieremote.personal", "group.com.example.renamed"])
        let team = WidgetAppGroup.candidates(info: [:], bundleID: "com.example.renamed", profile: ProvisioningProfileInfo(teamID: "TEAM000001", appGroups: []))
        XCTAssertEqual(team, ["group.com.magpieremote.personal", "group.com.magpieremote.personal.TEAM000001",
                              "group.com.example.renamed", "group.com.example.renamed.TEAM000001"])
    }

    func testProvisioningProfileParse() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>TeamIdentifier</key><array><string>ABCDE12345</string></array>
        <key>Entitlements</key><dict>
        <key>com.apple.security.application-groups</key><array><string>group.com.magpieremote.personal.ABCDE12345</string><string>group.*</string></array>
        </dict></dict></plist>
        """
        var data = Data([0x30, 0x82, 0x01, 0x00, 0xFF]) // 假装的 CMS 头
        data.append(Data(xml.utf8))
        data.append(Data([0x00, 0xA0, 0x82]))
        let info = ProvisioningProfileInfo.parse(data)
        XCTAssertEqual(info?.teamID, "ABCDE12345")
        XCTAssertEqual(info?.appGroups, ["group.com.magpieremote.personal.ABCDE12345"])
        XCTAssertNil(ProvisioningProfileInfo.parse(Data("no plist here".utf8)))
    }

    func testStoreResolveWriteReadAndDegrade() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("widget-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        let resolved = WidgetSnapshotStore.resolve(candidates: ["group.a", "group.none", "group.b"]) { id in
            switch id {
            case "group.a": a
            case "group.b": b
            default: nil
            }
        }
        XCTAssertEqual(resolved.groups, ["group.a", "group.b"])
        let store = resolved.store
        XCTAssertEqual(store.content(), .noSnapshot)
        XCTAssertEqual(store.write(snapshot()), 2)
        XCTAssertEqual(store.content(), .snapshot(snapshot()))

        // 另一个进程只看到其中一个组、且那里有更新的快照：取最新的。
        let newer = snapshot(generatedAt: now.addingTimeInterval(60))
        XCTAssertEqual(WidgetSnapshotStore(directories: [store.directories[1]]).write(newer), 1)
        XCTAssertEqual(store.read()?.generatedAt, newer.generatedAt)

        store.clear()
        XCTAssertEqual(store.content(), .noSnapshot)
        XCTAssertEqual(WidgetSnapshotStore(directories: []).content(), .noAppGroup)
        XCTAssertEqual(WidgetSnapshotStore(directories: []).write(snapshot()), 0)
    }

    // MARK: 深链

    func testLinksRoundTripAndRoute() {
        for link in WidgetLink.allCases {
            XCTAssertEqual(WidgetLink(url: link.url), link)
        }
        XCTAssertEqual(WidgetLink.quota.url.absoluteString, "magpieremote://widget/quota")
        XCTAssertEqual(WidgetLink(url: URL(string: "magpieremote://usage")!), .usage)
        XCTAssertEqual(WidgetLink(url: URL(string: "MagpieRemote://widget/QUOTA")!), .quota)
        XCTAssertNil(WidgetLink(url: URL(string: "magpieremote://widget/nope")!))
        XCTAssertNil(WidgetLink(url: URL(string: "https://example.com/widget/quota")!))
        XCTAssertEqual(WidgetLink.quota.homeSegment, .quota)
        XCTAssertNil(WidgetLink.usage.homeSegment)

        XCTAssertEqual(WidgetLink.quota.route(dock: .default), .tab(.home))
        XCTAssertEqual(WidgetLink.usage.route(dock: .default), .tab(.usage))
        let custom = DockLayout(pages: [.sessions, .routes, .chat, .keys])
        XCTAssertEqual(WidgetLink.quota.route(dock: custom), .more(.home))
        XCTAssertEqual(WidgetLink.usage.route(dock: custom), .more(.usage))
    }
}
