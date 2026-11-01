import XCTest

/// 底栏「路由」：fixture 模式下的实时路由舞台（RoutesFixture.trace 每 6 秒一个示例请求）与路由组卡片。
@MainActor
final class RoutesUITests: XCTestCase {
    private var launchTimeout: TimeInterval {
        ProcessInfo.processInfo.environment["MAGPIE_REMOTE_WARMUP_TIMEOUT"].flatMap { TimeInterval($0) } ?? 45
    }

    private func launchRoutes(_ extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] + extra
        app.launch()
        XCTAssertTrue(app.waitForDock(timeout: launchTimeout), "没有出现底栏「更多」")
        // 默认底栏第 4 个就是「路由」。
        app.openDockTab("路由")
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
        XCTAssertTrue(stage.appears(timeout: 10), "没有出现实时路由舞台")
        // 示例请求走路由组「聪明组」：标题、两个 Key 的行、底部的计数
        XCTAssertTrue(element(containing: "聪明组", in: app).appears(timeout: 10))
        XCTAssertTrue(element(id: "routes.row.relay-example#k1", in: app).appears(timeout: 10), "没有出现第一个 Key 的行")
        XCTAssertTrue(element(id: "routes.row.deepseek#k1", in: app).exists)
        XCTAssertTrue(element(id: "routes.stats", in: app).exists)
        XCTAssertTrue(element(id: "routes.caption", in: app).exists)
        // 点一个历史请求，舞台改画它，出现「回到实时」
        let request = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'routes.request.'")).element(boundBy: 1)
        scrollTo(request, in: app)
        XCTAssertTrue(request.appears(timeout: 10), "没有出现最近的请求")
        request.tap()
        XCTAssertTrue(element(id: "routes.live", in: app).appears(timeout: 5), "点选请求后应当出现「回到实时」")
    }

    /// 喜鹊真的画出来了：`--routes-fliers` 让 UI 测试里也飞，每只画出来的喜鹊有一个 routes.flier 元素
    /// （fixture 每 6 秒一个请求：先飞到 magpie 等路由，再飞到 Key，回答由另一只衔回来）。
    func testMagpieFliesWithTheRequest() {
        let app = launchRoutes(["--routes-fliers"])
        XCTAssertTrue(element(id: "routes.stage", in: app).appears(timeout: 10), "没有出现实时路由舞台")
        XCTAssertTrue(element(id: "routes.flier", in: app).appears(timeout: 20), "舞台上没有画出喜鹊")
        // Agent 卡片的位置都量到了（以前外层把它们盖掉，Agent → magpie 的线和这段路上的喜鹊都画不出来）
        let wires = element(id: "routes.wires", in: app)
        XCTAssertTrue(wires.appears(timeout: 5), "没有线的测量元素")
        let measured = NSPredicate(format: "value BEGINSWITH 'agents=all rows=' AND NOT (value ENDSWITH 'rows=0')")
        XCTAssertTrue(waitUntil(10) { measured.evaluate(with: wires) }, "Agent 卡片的位置没量到（只见：\(String(describing: wires.value))）")
        // 正常成功的一次：喜鹊从 Agent 沿它的线飞向 magpie
        let fromAgent = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'routes.flier' AND value == 'toHub'")).firstMatch
        XCTAssertTrue(fromAgent.appears(timeout: 20), "没有喜鹊沿 Agent → magpie 的线飞（只见：\(String(describing: wires.value))）")
    }

    /// 「账号打码」：账号（这里是备用订阅账号的邮箱）换成模糊的替身字母，再点一次恢复。
    func testMaskHidesAccounts() {
        let app = launchRoutes()
        let row = element(id: "routes.row.codex#demo", in: app)
        XCTAssertTrue(row.appears(timeout: 10), "没有出现备用账号的行")
        XCTAssertTrue(row.label.contains("demo.user@example.com"), "打码前应当显示账号：\(row.label)")
        let mask = element(id: "routes.mask", in: app)
        XCTAssertTrue(mask.exists, "舞台上没有「账号打码」")
        mask.tap()
        let masked = element(id: "routes.row.codex#demo", in: app)
        XCTAssertTrue(waitUntil(5) { masked.exists && !masked.label.contains("demo.user@example.com") }, "打码后仍显示账号")
        XCTAssertTrue(element(containing: "账号已打码", in: app).exists)
        element(id: "routes.mask", in: app).tap()
        XCTAssertTrue(element(id: "routes.row.codex#demo", in: app).hasLabel(containing: "demo.user@example.com", within: 5), "取消打码后没有恢复账号")
    }

    /// 「最近的请求」默认只列 10 个，点「显示全部」展开。
    func testRequestListFoldsToTen() {
        let app = launchRoutes()
        let more = element(id: "routes.requests.more", in: app)
        scrollTo(more, in: app)
        XCTAssertTrue(more.appears(timeout: 10), "请求超过 10 个时应当有「显示全部」")
        let requests = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'routes.request.'"))
        XCTAssertTrue(requests.count > 0 && requests.count <= 10, "默认只列 10 个：\(requests.count)")
        more.tap()
        XCTAssertTrue(waitUntil(5) { requests.count > 10 }, "点「显示全部」后请求没有超过 10 个：\(requests.count)")
        XCTAssertTrue(element(id: "routes.requests.more", in: app).label.contains("收起"))
    }

    /// 「重放」：卡片下「最近一个请求是怎么路由的」旁的重放按钮，放的时候舞台上方出现重放条（速度、停止），停止后回到实时。
    func testReplayTheLastRequest() {
        let app = launchRoutes()
        XCTAssertTrue(element(id: "routes.stage", in: app).waitForExistence(timeout: 10), "没有出现实时路由舞台")
        let replay = element(id: "routes.replay.one", in: app)
        scrollTo(replay, in: app, attempts: 3)
        XCTAssertTrue(replay.waitForExistence(timeout: 20), "最近一个请求结束后应当有「重放」")
        replay.tap()
        XCTAssertTrue(element(id: "routes.replay", in: app).waitForExistence(timeout: 5), "没有出现重放条")
        let speed = element(id: "routes.replay.speed", in: app)
        XCTAssertTrue(speed.exists)
        speed.tap()
        XCTAssertTrue(speed.label.contains("2×"), "点一下速度变成 2×：\(speed.label)")
        element(id: "routes.replay.stop", in: app).tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: element(id: "routes.replay", in: app))
        waitForExpectations(timeout: 5)
    }

    /// 请求是舞台下面单独的一张卡片：标题旁有「全部重放」，下面「按请求 / 按会话」。
    func testRequestsCardHasReplayAllAndGrouping() {
        let app = launchRoutes()
        let card = element(id: "routes.requests", in: app)
        scrollTo(card, in: app, attempts: 3)
        XCTAssertTrue(card.waitForExistence(timeout: 10), "没有请求卡片")
        XCTAssertTrue(element(id: "routes.replay.all", in: app).waitForExistence(timeout: 10), "没有「全部重放」")
        XCTAssertTrue(element(id: "routes.bySession", in: app).exists, "没有「按请求 / 按会话」")
        XCTAssertTrue(element(id: "routes.steps", in: app).exists, "没有「是怎么路由的」那几步")
        XCTAssertTrue(element(id: "routes.gogroups", in: app).exists, "标题旁没有跳到路由组的按钮")
    }

    func testChangeRoutingFromGroupCard() {
        let app = launchRoutes()
        let tag = element(id: "group.routing.smart", in: app)
        scrollTo(tag, in: app)
        XCTAssertTrue(tag.appears(timeout: 10), "路由组卡片上没有路由方式标签")
        XCTAssertTrue(tag.label.contains("按顺序"), "示例路由组应当按顺序路由：\(tag.label)")
        tag.tap()
        let rotate = app.buttons["轮流"].firstMatch
        XCTAssertTrue(rotate.appears(timeout: 5), "路由方式菜单里没有「轮流」")
        rotate.tap()
        XCTAssertTrue(element(id: "group.routing.smart", in: app).hasLabel(containing: "轮流", within: 10), "路由方式没有换成「轮流」")
    }

    func testEditorShowsMemberSpeedsAndRouting() {
        let app = launchRoutes()
        let open = element(id: "group.open.fast-first", in: app)
        scrollTo(open, in: app)
        XCTAssertTrue(open.appears(timeout: 10))
        open.tap()
        XCTAssertTrue(app.navigationBars["最快优先"].appears(timeout: 10), "没有打开路由组编辑页")
        // 成员旁显示近 7 天速度；速度优先时标出最快的
        XCTAssertTrue(element(containing: "首字", in: app).appears(timeout: 10), "成员旁没有显示速度")
        XCTAssertTrue(element(containing: "最快", in: app).exists)
        let choice = element(id: "group.routing.choice.fast", in: app)
        scrollTo(choice, in: app)
        XCTAssertTrue(choice.exists, "没有路由方式的选项")
        XCTAssertTrue(element(id: "group.save", in: app).exists)
    }
}
