import XCTest

/// 0.6.2：页面顶部的分页器（主页、用量）不再钉在导航栏下面，而是列表的第一行，跟着内容一起滚。
/// 钉住时它和系统大标题的展开 / 收起互相抢位置，真机上滚到顶部附近页头会来回抖。
/// 抖动本身在 UI 测试里不好量，这里检查它的成因被去掉了：分页器在列表里面，往上拖时跟着列表走。
@MainActor
final class PageTopStripUITests: XCTestCase {
    private var launchTimeout: TimeInterval {
        ProcessInfo.processInfo.environment["MAGPIE_REMOTE_WARMUP_TIMEOUT"].flatMap { TimeInterval($0) } ?? 45
    }

    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.waitForDock(timeout: launchTimeout), "没有出现底栏「更多」")
        return app
    }

    /// 分页器是页面滚动区域（列表 / ScrollView）里的一个子元素，而不是导航栏下面单独的一条。
    private func assertInsideScrollingContent(_ identifier: String, in app: XCUIApplication,
                                              file: StaticString = #filePath, line: UInt = #line) {
        let inList = app.collectionViews.descendants(matching: .segmentedControl).matching(identifier: identifier).firstMatch
        let inScroll = app.scrollViews.descendants(matching: .segmentedControl).matching(identifier: identifier).firstMatch
        XCTAssertTrue(inList.appears(timeout: 10) || inScroll.exists, "「\(identifier)」应当在页面的列表里（跟着内容滚）", file: file, line: line)
    }

    /// 慢慢往上拖（没有惯性）：列表里的分页器跟着走很远；钉在导航栏下面的只会随大标题收起挪动几十 pt。
    private func assertScrollsAway(_ control: XCUIElement, in app: XCUIApplication,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(control.appears(timeout: 10), "没有分页器", file: file, line: line)
        let before = control.frame
        let bar = app.navigationBars.firstMatch.frame
        XCTAssertGreaterThanOrEqual(before.minY, bar.maxY - 2, "分页器应当在导航栏下面的内容里：\(before) / 导航栏 \(bar)", file: file, line: line)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.32))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        let moved = waitUntil(3) {
            !control.exists || !control.isHittable || control.frame.minY < before.minY - 150
        }
        XCTAssertTrue(moved, "往上拖时分页器没有跟着列表走（还钉在导航栏下面）：之前 \(before)，之后 \(control.frame)", file: file, line: line)
        // 拖回去：分页器回到原位，还能点
        end.press(forDuration: 0.1, thenDragTo: start, withVelocity: .slow, thenHoldForDuration: 0.3)
        app.swipeDown(until: control, max: 4)
        XCTAssertTrue(control.appears(timeout: 5) && control.isHittable, "滚回顶部后分页器不见了", file: file, line: line)
    }

    func testUsageTabsScrollWithTheList() {
        let app = launch()
        app.openDockTab("用量")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "usage.totalCost").firstMatch.appears(timeout: 15), "概览没有出现总花费")
        assertInsideScrollingContent("usage.tab", in: app)
        assertScrollsAway(app.segmentedControls["usage.tab"], in: app)
        // 切到「请求」：分段同样是这一页列表的第一行
        app.segmentedControls["usage.tab"].buttons["请求"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "usage.requests.period").firstMatch.appears(timeout: 10))
        assertInsideScrollingContent("usage.tab", in: app)
    }

    func testHomeSegmentsAreInsideTheList() {
        let app = launch()
        app.openHome("Agent")
        assertInsideScrollingContent("home.segment", in: app)
        app.openHome("额度")
        assertInsideScrollingContent("home.segment", in: app)
        app.openHome("供应商")
        assertInsideScrollingContent("home.segment", in: app)
    }

    /// 搜索统一用导航栏标题下面的系统搜索栏（`pageSearchable`）：从「更多」推入的插件页也要有搜索栏，
    /// 而且它跟着大标题一起收起（不是 `.always` 钉在标题下面——钉住的搜索栏往上滚时还留在原处、还能点）。
    func testPluginsSearchIsNotPinnedUnderTheTitle() {
        let app = launch()
        app.openFromMore("manage.plugins", title: "插件")
        let search = app.revealSearchField()
        XCTAssertTrue(search.exists && search.isHittable, "插件页没有搜索栏：\(app.navigationBars.firstMatch.debugDescription)")
        let before = search.frame
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)
        let collapsed = waitUntil(3) { !search.exists || !search.isHittable || search.frame.height < 10 }
        XCTAssertTrue(collapsed, "往上滚时搜索栏没有跟着大标题收起（还钉在标题下面）：之前 \(before)，之后 \(search.frame)")
        // 往下拉又出来
        XCTAssertTrue(app.revealSearchField().isHittable, "往下拉后搜索栏没有重新出来")
    }

    /// 「更多」照 iOS「设置」的样式：分组标题，读到 magpie 版本时有「magpie 版本」一行。
    func testMoreLooksLikeSettings() {
        let app = launch()
        app.openMore()
        XCTAssertTrue(app.staticTexts["主机"].appears(timeout: 10) || app.staticTexts["主机".uppercased()].exists, "「更多」没有「主机」分组")
        let version = app.descendants(matching: .any).matching(identifier: "more.magpieVersion").firstMatch
        XCTAssertTrue(version.appears(timeout: 15), "「更多 › 主机」里没有「magpie 版本」")
        XCTAssertTrue(version.label.contains("magpie 版本"), "版本行的文字不对：\(version.label)")
        let pages = app.staticTexts["页面"]
        app.swipeUp(until: pages, max: 3)
        XCTAssertTrue(pages.exists, "「更多」没有「页面」分组")
    }
}
