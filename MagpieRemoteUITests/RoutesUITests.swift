import XCTest

/// 「管理 › 路由」：fixture 模式下的实时路由舞台（RoutesFixture.trace 每 6 秒一个示例请求）与路由组卡片。
@MainActor
final class RoutesUITests: XCTestCase {
    private var launchTimeout: TimeInterval {
        ProcessInfo.processInfo.environment["MAGPIE_REMOTE_WARMUP_TIMEOUT"].flatMap { TimeInterval($0) } ?? 45
    }

    private func launchRoutes() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let tab = app.tabBars.buttons["管理"]
        XCTAssertTrue(tab.waitForExistence(timeout: launchTimeout), "没有出现「管理」标签")
        tab.tap()
        let link = element(id: "manage.groups", in: app)
        XCTAssertTrue(link.waitForExistence(timeout: 15), "没有出现「路由组」入口")
        link.tap()
        XCTAssertTrue(app.navigationBars["路由"].waitForExistence(timeout: 10), "没有打开「路由」页")
        return app
    }

    private func element(id identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func element(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 8) {
        var tries = 0
        while (!element.exists || !element.isHittable) && tries < attempts {
            app.swipeUp()
            tries += 1
        }
    }

    func testLiveStageShowsRouteThroughGroup() {
        let app = launchRoutes()
        let stage = element(id: "routes.stage", in: app)
        XCTAssertTrue(stage.waitForExistence(timeout: 10), "没有出现实时路由舞台")
        // 示例请求走路由组「聪明组」：标题、两个 Key 的行、底部的计数
        XCTAssertTrue(element(containing: "聪明组", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(element(id: "routes.row.relay-example#k1", in: app).waitForExistence(timeout: 10), "没有出现第一个 Key 的行")
        XCTAssertTrue(element(id: "routes.row.deepseek#k1", in: app).exists)
        XCTAssertTrue(element(id: "routes.stats", in: app).exists)
        XCTAssertTrue(element(id: "routes.caption", in: app).exists)
        // 点一个历史请求，舞台改画它，出现「回到实时」
        let request = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'routes.request.'")).element(boundBy: 1)
        scrollTo(request, in: app)
        XCTAssertTrue(request.waitForExistence(timeout: 10), "没有出现最近的请求")
        request.tap()
        XCTAssertTrue(element(id: "routes.live", in: app).waitForExistence(timeout: 5), "点选请求后应当出现「回到实时」")
    }

    func testChangeRoutingFromGroupCard() {
        let app = launchRoutes()
        let tag = element(id: "group.routing.smart", in: app)
        scrollTo(tag, in: app)
        XCTAssertTrue(tag.waitForExistence(timeout: 10), "路由组卡片上没有路由方式标签")
        XCTAssertTrue(tag.label.contains("按顺序"), "示例路由组应当按顺序路由：\(tag.label)")
        tag.tap()
        let rotate = app.buttons["轮流"].firstMatch
        XCTAssertTrue(rotate.waitForExistence(timeout: 5), "路由方式菜单里没有「轮流」")
        rotate.tap()
        let changed = NSPredicate(format: "label CONTAINS '轮流'")
        expectation(for: changed, evaluatedWith: element(id: "group.routing.smart", in: app))
        waitForExpectations(timeout: 10)
    }

    func testEditorShowsMemberSpeedsAndRouting() {
        let app = launchRoutes()
        let open = element(id: "group.open.fast-first", in: app)
        scrollTo(open, in: app)
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        XCTAssertTrue(app.navigationBars["最快优先"].waitForExistence(timeout: 10), "没有打开路由组编辑页")
        // 成员旁显示近 7 天速度；速度优先时标出最快的
        XCTAssertTrue(element(containing: "首字", in: app).waitForExistence(timeout: 10), "成员旁没有显示速度")
        XCTAssertTrue(element(containing: "最快", in: app).exists)
        let choice = element(id: "group.routing.choice.fast", in: app)
        scrollTo(choice, in: app)
        XCTAssertTrue(choice.exists, "没有路由方式的选项")
        XCTAssertTrue(element(id: "group.save", in: app).exists)
    }
}
