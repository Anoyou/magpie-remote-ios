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
        // 和网页一样按钮文字不变（「账号打码」），打开时值为「开」
        XCTAssertEqual(element(id: "routes.mask", in: app).value as? String, "开", "打码后「账号打码」应当是打开的")
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
        // 先等最近一个请求结束（「重放」出现），再滑到能点；不要先滑：还没出现时连滑几下会把舞台滑出屏幕（懒加载）。
        // 「重放」只在最近一个请求已结束时出现；fixture 每 6 秒来一个新请求，按钮会一隐一现。
        // 所以看到它就按坐标点（元素刚好消失也不会让点击本身失败），没进重放就等下一次再点。
        let replay = element(id: "routes.replay.one", in: app)
        let bar = element(id: "routes.replay", in: app)
        XCTAssertTrue(replay.appears(timeout: 20), "最近一个请求结束后应当有「重放」")
        app.swipeUp(until: replay, max: 2)
        var started = false
        let window = app.windows.firstMatch.frame
        for _ in 0..<6 where !started {
            // snapshot() 在元素刚好消失时只是抛错（不算测试失败）；拿到框后按整个 App 的坐标点，不再去找元素。
            guard replay.appears(timeout: 15), let snap = try? replay.snapshot() else { continue }
            let f = snap.frame
            guard !f.isEmpty, window.contains(CGPoint(x: f.midX, y: f.midY)) else {
                if f.midY > window.midY { app.swipeUp() } else { app.swipeDown() }
                continue
            }
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: f.midX, dy: f.midY)).tap()
            started = bar.appears(timeout: 2)
        }
        XCTAssertTrue(started, "没有出现重放条")
        // 只重放一个请求一两秒就放完了；换速度、停止用「全部重放」（十几个请求，够长）。
        let all = element(id: "routes.replay.all", in: app)
        XCTAssertTrue(all.appears(timeout: 15), "没有「全部重放」")
        scrollTo(all, in: app, attempts: 4)
        all.tap()
        let speed = element(id: "routes.replay.speed", in: app)
        app.swipeDown(until: speed, max: 4)
        XCTAssertTrue(speed.appears(timeout: 5), "全部重放时没有出现重放条的速度按钮")
        speed.tap()
        XCTAssertTrue(speed.hasLabel(containing: "2×", within: 3), "点一下速度变成 2×")
        element(id: "routes.replay.stop", in: app).tap()
        XCTAssertTrue(element(id: "routes.replay", in: app).disappears(timeout: 5), "停止后重放条应当消失")
    }

    /// 请求是舞台下面单独的一张卡片：标题旁有「全部重放」，下面「按请求 / 按会话」。
    func testRequestsCardHasReplayAllAndGrouping() {
        let app = launchRoutes()
        // 列表是懒加载的：标题（在最上面）和舞台下的「是怎么路由的」要在往下滑到请求卡片之前看，滑走的行不在无障碍树里。
        XCTAssertTrue(element(id: "routes.gogroups", in: app).appears(timeout: 10), "标题旁没有跳到路由组的按钮")
        let steps = element(id: "routes.steps", in: app)
        _ = steps.appears(timeout: 10)
        scrollTo(steps, in: app, attempts: 3)
        XCTAssertTrue(steps.appears(timeout: 10), "没有「是怎么路由的」那几步")
        let card = element(id: "routes.requests", in: app)
        scrollTo(card, in: app, attempts: 3)
        XCTAssertTrue(card.appears(timeout: 10), "没有请求卡片")
        XCTAssertTrue(element(id: "routes.replay.all", in: app).appears(timeout: 10), "没有「全部重放」")
        XCTAssertTrue(element(id: "routes.bySession", in: app).exists, "没有「按请求 / 按会话」")
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
