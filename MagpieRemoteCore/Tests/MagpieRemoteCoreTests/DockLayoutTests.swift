import XCTest
@testable import MagpieRemoteCore

final class DockLayoutTests: XCTestCase {
    func testDefaultIsAgentSessionsProvidersRoutes() {
        XCTAssertEqual(DockLayout.default.pages, [.agents, .sessions, .providers, .routes])
        XCTAssertTrue(DockLayout.default.isDefault)
        XCTAssertEqual(DockLayout.default.pages.map(\.title), ["Agent", "会话", "供应商", "路由"])
    }

    func testMorePagesExcludeDockPagesAndKeepEverythingElse() {
        let layout = DockLayout.default
        XCTAssertEqual(layout.morePages, [.quota, .usage, .chat, .keys, .plugins, .hostTools, .web, .hosts, .about])
        XCTAssertEqual(Set(layout.morePages + layout.pages), Set(AppPage.allCases))
    }

    func testStoredRoundTripAndMissingFallsBackToDefault() {
        XCTAssertEqual(DockLayout(stored: nil), .default)
        XCTAssertEqual(DockLayout(stored: []), .default)
        XCTAssertEqual(DockLayout(stored: ["nope", "管理"]), .default)
        let custom = DockLayout(pages: [.quota, .usage, .chat, .routes])
        XCTAssertEqual(DockLayout(stored: custom.stored), custom)
    }

    func testInvalidInputIsSanitizedToFourUniquePages() {
        // 重复、过多
        XCTAssertEqual(DockLayout(pages: [.quota, .quota, .usage, .chat, .keys, .about]).pages, [.quota, .usage, .chat, .keys])
        // 过少：用默认页面补满
        XCTAssertEqual(DockLayout(pages: [.quota]).pages, [.quota, .agents, .sessions, .providers])
        XCTAssertEqual(DockLayout(stored: ["chat", "unknown", "chat"]).pages, [.chat, .agents, .sessions, .providers])
        XCTAssertEqual(DockLayout(pages: [.agents, .agents]).pages, [.agents, .sessions, .providers, .routes])
    }

    func testPlaceReplacesOrSwaps() {
        var layout = DockLayout.default
        layout.place(.quota, at: 0)
        XCTAssertEqual(layout.pages, [.quota, .sessions, .providers, .routes])
        XCTAssertTrue(layout.morePages.contains(.agents))
        XCTAssertFalse(layout.morePages.contains(.quota))
        layout.place(.routes, at: 0)
        XCTAssertEqual(layout.pages, [.routes, .sessions, .providers, .quota])
        layout.place(.about, at: 9)
        XCTAssertEqual(layout.pages, [.routes, .sessions, .providers, .quota])
    }

    func testMoveMatchesOnMoveSemantics() {
        var layout = DockLayout.default
        layout.move(fromOffsets: IndexSet(integer: 0), toOffset: 4)
        XCTAssertEqual(layout.pages, [.sessions, .providers, .routes, .agents])
        layout.move(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        XCTAssertEqual(layout.pages, [.agents, .sessions, .providers, .routes])
        layout.move(fromOffsets: IndexSet(integer: 1), toOffset: 3)
        XCTAssertEqual(layout.pages, [.agents, .providers, .sessions, .routes])
    }

    func testShiftAndReset() {
        var layout = DockLayout.default
        layout.shift(.agents, by: -1)
        XCTAssertEqual(layout, .default)
        layout.shift(.agents, by: 1)
        XCTAssertEqual(layout.pages, [.sessions, .agents, .providers, .routes])
        XCTAssertFalse(layout.isDefault)
        layout.reset()
        XCTAssertTrue(layout.isDefault)
    }
}
