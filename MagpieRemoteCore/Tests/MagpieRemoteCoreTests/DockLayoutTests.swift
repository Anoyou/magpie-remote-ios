import XCTest
@testable import MagpieRemoteCore

final class DockLayoutTests: XCTestCase {
    func testDefaultIsHomeSessionsRoutesUsage() {
        XCTAssertEqual(DockLayout.default.pages, [.home, .sessions, .routes, .usage])
        XCTAssertTrue(DockLayout.default.isDefault)
        XCTAssertEqual(DockLayout.default.pages.map(\.title), ["主页", "会话", "路由", "用量"])
    }

    func testMorePagesExcludeDockPagesAndKeepEverythingElse() {
        let layout = DockLayout.default
        XCTAssertEqual(layout.morePages, [.chat, .keys, .plugins, .hostTools, .web, .hosts, .about])
        XCTAssertEqual(Set(layout.morePages + layout.pages), Set(AppPage.allCases))
    }

    func testStoredRoundTripAndMissingFallsBackToDefault() {
        XCTAssertEqual(DockLayout(stored: nil), .default)
        XCTAssertEqual(DockLayout(stored: []), .default)
        XCTAssertEqual(DockLayout(stored: ["nope", "管理"]), .default)
        let custom = DockLayout(pages: [.home, .usage, .chat, .routes])
        XCTAssertEqual(DockLayout(stored: custom.stored), custom)
    }

    /// 0.3 存下的 agents / providers / quota 都并入「主页」，重复的只留第一个，空位用默认页面补满。
    func testLegacyAgentsProvidersQuotaMigrateToHome() {
        XCTAssertEqual(AppPage(storedValue: "agents"), .home)
        XCTAssertEqual(AppPage(storedValue: "providers"), .home)
        XCTAssertEqual(AppPage(storedValue: "quota"), .home)
        XCTAssertEqual(AppPage(storedValue: "home"), .home)
        XCTAssertNil(AppPage(storedValue: "manage"))
        // 0.3 的默认底栏
        XCTAssertEqual(DockLayout(stored: ["agents", "sessions", "providers", "routes"]).pages, [.home, .sessions, .routes, .usage])
        // 三个都在底栏：只剩一个主页
        XCTAssertEqual(DockLayout(stored: ["quota", "agents", "providers", "chat"]).pages, [.home, .chat, .sessions, .routes])
        // 位置保留在第一个旧页面所在的位置
        XCTAssertEqual(DockLayout(stored: ["usage", "chat", "quota", "keys"]).pages, [.usage, .chat, .home, .keys])
        // 已经是新值的主页和旧值一起出现
        XCTAssertEqual(DockLayout(stored: ["home", "providers", "plugins", "about"]).pages, [.home, .plugins, .about, .sessions])
        XCTAssertEqual(DockLayout(stored: ["agents", "sessions", "providers", "routes"]).stored, ["home", "sessions", "routes", "usage"])
    }

    func testInvalidInputIsSanitizedToFourUniquePages() {
        // 重复、过多
        XCTAssertEqual(DockLayout(pages: [.chat, .chat, .usage, .keys, .plugins, .about]).pages, [.chat, .usage, .keys, .plugins])
        // 过少：用默认页面补满
        XCTAssertEqual(DockLayout(pages: [.chat]).pages, [.chat, .home, .sessions, .routes])
        XCTAssertEqual(DockLayout(stored: ["chat", "unknown", "chat"]).pages, [.chat, .home, .sessions, .routes])
        XCTAssertEqual(DockLayout(pages: [.home, .home]).pages, [.home, .sessions, .routes, .usage])
    }

    func testPlaceReplacesOrSwaps() {
        var layout = DockLayout.default
        layout.place(.chat, at: 0)
        XCTAssertEqual(layout.pages, [.chat, .sessions, .routes, .usage])
        XCTAssertTrue(layout.morePages.contains(.home))
        XCTAssertFalse(layout.morePages.contains(.chat))
        layout.place(.usage, at: 0)
        XCTAssertEqual(layout.pages, [.usage, .sessions, .routes, .chat])
        layout.place(.about, at: 9)
        XCTAssertEqual(layout.pages, [.usage, .sessions, .routes, .chat])
    }

    func testMoveMatchesOnMoveSemantics() {
        var layout = DockLayout.default
        layout.move(fromOffsets: IndexSet(integer: 0), toOffset: 4)
        XCTAssertEqual(layout.pages, [.sessions, .routes, .usage, .home])
        layout.move(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        XCTAssertEqual(layout.pages, [.home, .sessions, .routes, .usage])
        layout.move(fromOffsets: IndexSet(integer: 1), toOffset: 3)
        XCTAssertEqual(layout.pages, [.home, .routes, .sessions, .usage])
    }

    func testShiftAndReset() {
        var layout = DockLayout.default
        layout.shift(.home, by: -1)
        XCTAssertEqual(layout, .default)
        layout.shift(.home, by: 1)
        XCTAssertEqual(layout.pages, [.sessions, .home, .routes, .usage])
        XCTAssertFalse(layout.isDefault)
        layout.reset()
        XCTAssertTrue(layout.isDefault)
    }

    func testHomeSegmentStoredValue() {
        XCTAssertEqual(HomeSegment.allCases.map(\.title), ["Agent", "供应商", "额度"])
        XCTAssertEqual(HomeSegment(stored: nil), .agents)
        XCTAssertEqual(HomeSegment(stored: "nope"), .agents)
        XCTAssertEqual(HomeSegment(stored: "quota"), .quota)
        XCTAssertEqual(HomeSegment(stored: HomeSegment.providers.rawValue), .providers)
    }
}
