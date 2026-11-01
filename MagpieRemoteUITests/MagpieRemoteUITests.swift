import XCTest

/// 全部在 fixture 模式下运行（`--ui-testing`），不需要真实主机。
@MainActor
final class MagpieRemoteUITests: XCTestCase {
    /// 首屏等待时间：CI 预热时用 `MAGPIE_REMOTE_WARMUP_TIMEOUT` 放宽（新启动的模拟器第一次冷启动很慢）。
    private var launchTimeout: TimeInterval {
        ProcessInfo.processInfo.environment["MAGPIE_REMOTE_WARMUP_TIMEOUT"].flatMap { TimeInterval($0) } ?? 45
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] + extra
        app.launch()
        XCTAssertTrue(app.waitForDock(timeout: launchTimeout), "首屏没有出现底栏「更多」")
        return app
    }

    /// 不依赖元素类型：SwiftUI 合并后的无障碍元素可能是按钮或其它类型，只按文字查找。
    private func element(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// 按 identifier 查找，不限元素类型（SwiftUI 可能把按钮暴露成其它类型）。
    private func element(id identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// 默认底栏：主页、会话、路由、用量、更多；主页顶部分页器里是 Agent、供应商、额度；对话从「更多」进入。
    func testDefaultDockTabs() {
        let app = launch()
        for title in ["主页", "会话", "路由", "用量", "更多"] {
            XCTAssertTrue(app.tabBars.buttons[title].exists, "缺少标签：\(title)")
        }
        XCTAssertFalse(app.tabBars.buttons["管理"].exists, "旧的「管理」标签应当已经去掉")
        XCTAssertTrue(app.navigationBars["Agent"].waitForExistence(timeout: 10), "首屏应当是主页的「Agent」分页")
        for title in ["Agent", "供应商", "额度"] {
            XCTAssertTrue(app.homeSegments.buttons[title].exists, "主页分页器缺少「\(title)」")
        }
        XCTAssertFalse(app.tabBars.buttons["Agent"].exists, "Agent 已并入主页，不应再单独在底栏")
        app.openMore()
        for id in ["more.chat", "manage.keys"] {
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: id).firstMatch.waitForExistence(timeout: 10), "「更多」里缺少 \(id)")
        }
        for id in ["more.home", "more.usage", "manage.groups"] {
            XCTAssertFalse(app.descendants(matching: .any).matching(identifier: id).firstMatch.exists, "在底栏里的页面不应再出现在「更多」里：\(id)")
        }
    }

    func testFixtureHostConnectsAndShowsQuota() {
        let app = launch()
        app.openHome("额度")
        XCTAssertTrue(element(containing: "工作 Claude", in: app).waitForExistence(timeout: 15))
    }

    func testHostSheetOpensAndAddForm() {
        let app = launch()
        let open = app.buttons["hosts.open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        XCTAssertTrue(app.navigationBars["主机"].waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "示例 Mac", in: app).exists)
        app.buttons["hosts.add"].tap()
        XCTAssertTrue(app.navigationBars["添加主机"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["host.address"].exists)
        XCTAssertTrue(app.secureTextFields["host.secret.gateway-key"].exists)
        // 地址为空时不能保存
        XCTAssertFalse(app.buttons["host.save"].isEnabled)
    }

    func testSetupGuideOpensFromEmptyState() {
        let app = launch(["--fixture-empty"])
        XCTAssertTrue(element(containing: "还没有添加主机", in: app).waitForExistence(timeout: 10), "空状态没有出现「还没有添加主机」")
        let guide = element(id: "guide.open", in: app)
        XCTAssertTrue(guide.waitForExistence(timeout: 10), "空状态里没有「配置引导」按钮（guide.open）")
        guide.tap()
        XCTAssertTrue(app.navigationBars["配置引导"].waitForExistence(timeout: 10), "没有打开「配置引导」页")
        XCTAssertTrue(element(containing: "在局域网共享", in: app).waitForExistence(timeout: 5), "配置引导里缺少「在局域网共享」步骤")
        XCTAssertTrue(element(containing: "magpie daemon web on --lan", in: app).waitForExistence(timeout: 5), "配置引导里缺少 magpie daemon web on --lan 命令")
    }

    func testOfflineHostShowsChineseError() {
        let app = launch(["--fixture-offline"])
        app.openHome("额度")
        XCTAssertTrue(element(containing: "连不上主机", in: app).waitForExistence(timeout: 15), "没有出现中文错误标题「连不上主机」")
        XCTAssertTrue(element(containing: "主机都没有回应", in: app).waitForExistence(timeout: 5), "没有出现超时的中文说明")
        XCTAssertTrue(element(id: "state.retry", in: app).waitForExistence(timeout: 5), "错误页里没有「重试」按钮（state.retry）")
    }

    func testAboutShowsVersionAndChangelog() {
        let app = launch()
        // 「关于」在「更多」最下面，列表懒加载：openFromMore 会先滑到它
        app.openFromMore("manage.about", title: "关于")
        app.buttons["about.changelog"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["更新日志"].waitForExistence(timeout: 10))
        // 0.1.0 是最早的段落，在最下面（0.3.0、0.4.0 的条目很长，List 懒加载），需要往下滚很多屏。
        let release = element(containing: "0.1.0", in: app)
        var found = release.waitForExistence(timeout: 5)
        for _ in 0..<30 where !found {
            app.swipeUp(velocity: .fast)
            found = release.waitForExistence(timeout: 1)
        }
        XCTAssertTrue(found, "更新日志里没有 0.1.0")
    }

    // MARK: 用量

    /// 分段控件里的一段（先按控件 id 找，避免点到别的页面上同名的段）。
    private func segment(_ title: String, of identifier: String, in app: XCUIApplication) -> XCUIElement {
        let control = element(id: identifier, in: app)
        XCTAssertTrue(control.waitForExistence(timeout: 10), "没有分段控件 \(identifier)")
        return control.buttons[title].firstMatch
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return condition()
    }

    private func openUsage(_ app: XCUIApplication) {
        app.openDockTab("用量")
        XCTAssertTrue(element(id: "usage.totalCost", in: app).waitForExistence(timeout: 15), "用量页没有出现总花费（usage.totalCost）")
    }

    private func openRequests(_ app: XCUIApplication) {
        // 概览里合计、图表变多了，「请求记录」入口在下面（列表懒加载）：滑到它出现
        let open = element(id: "usage.requests.open", in: app)
        _ = open.waitForExistence(timeout: 5)
        app.swipeUpUntilHittable(open)
        XCTAssertTrue(open.waitForExistence(timeout: 10), "没有「请求记录」入口（usage.requests.open）")
        open.tap()
        XCTAssertTrue(app.navigationBars["请求记录"].waitForExistence(timeout: 10), "没有打开「请求记录」")
        // 「今天」在刚过零点时可能还没有示例请求，固定看 30 天。
        segment("30 天", of: "usage.requests.period", in: app).tap()
        XCTAssertTrue(element(id: "usage.requests.total", in: app).waitForExistence(timeout: 10), "请求记录没有显示总条数")
    }

    func testUsagePeriodSwitch() {
        let app = launch()
        openUsage(app)
        XCTAssertTrue(element(containing: "总花费", in: app).exists)
        let before = element(id: "usage.counts", in: app).label
        segment("7 天", of: "usage.period", in: app).tap()
        XCTAssertTrue(element(containing: "近 7 天", in: app).waitForExistence(timeout: 10), "切换到 7 天后标题没有变成「近 7 天」")
        segment("30 天", of: "usage.period", in: app).tap()
        XCTAssertTrue(element(containing: "近 30 天", in: app).waitForExistence(timeout: 10), "切换到 30 天后标题没有变成「近 30 天」")
        let counts = element(id: "usage.counts", in: app)
        XCTAssertTrue(waitUntil(10) { counts.exists && counts.label != before }, "切换时间段后请求数没有变化：\(before)")
        XCTAssertTrue(element(id: "usage.concurrency", in: app).exists || app.swipeUpAndFind(id: "usage.concurrency"), "没有显示当前并发")
    }

    func testUsageFilterToFailed() {
        let app = launch()
        openUsage(app)
        openRequests(app)
        let total = element(id: "usage.requests.total", in: app)
        let before = total.label
        element(id: "usage.filter.failed", in: app).tap()
        XCTAssertTrue(waitUntil(10) { total.exists && total.label != before }, "只看失败后总条数没有变化：\(before)")
        let first = element(id: "usage.request.0", in: app)
        _ = first.waitForExistence(timeout: 3)
        app.swipeUpUntilHittable(first)
        XCTAssertTrue(first.waitForExistence(timeout: 10), "筛选后没有请求")
        XCTAssertTrue(first.label.contains("失败"), "只看失败后第一条不是失败的请求：\(first.label)")
    }

    func testUsageOpenRequestDetail() {
        let app = launch()
        openUsage(app)
        openRequests(app)
        let first = element(id: "usage.request.0", in: app)
        _ = first.waitForExistence(timeout: 3)
        app.swipeUpUntilHittable(first)
        XCTAssertTrue(first.waitForExistence(timeout: 10), "请求记录是空的")
        first.tap()
        XCTAssertTrue(app.navigationBars["请求详情"].waitForExistence(timeout: 10), "没有打开「请求详情」")
        XCTAssertTrue(element(containing: "耗时", in: app).exists)
        XCTAssertTrue(element(containing: "实际模型", in: app).exists)
        element(id: "usage.detail.done", in: app).tap()
        XCTAssertTrue(app.navigationBars["请求记录"].waitForExistence(timeout: 10))
    }

    func testUsageHeldKeyShowsOwnRequestsOnly() {
        let app = launch(["--fixture-held-key"])
        app.openDockTab("用量")
        XCTAssertTrue(element(id: "usage.heldNote", in: app).waitForExistence(timeout: 15), "受限密钥没有显示说明")
        XCTAssertFalse(element(id: "usage.totalCost", in: app).exists, "受限密钥不应显示总花费")
        openRequests(app)
        let first = element(id: "usage.request.0", in: app)
        _ = first.waitForExistence(timeout: 3)
        app.swipeUpUntilHittable(first)
        XCTAssertTrue(first.waitForExistence(timeout: 10), "受限密钥看不到自己的请求记录")
    }

    // MARK: 对话（fixture：假模型目录 + 假的流式回答）

    private func openChatAndSend(_ text: String, in app: XCUIApplication) {
        app.openFromMore("more.chat", title: "对话")
        let composer = app.descendants(matching: .any)["chat.composer"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 15), "没有出现输入框")
        // 模型目录加载后自动选中第一个路由组。
        XCTAssertTrue(element(containing: "示例路由组", in: app).waitForExistence(timeout: 15), "没有自动选中模型")
        composer.tap()
        composer.typeText(text)
        let send = app.buttons["chat.send"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
    }

    func testChatSendsMessageAndStreamsReply() {
        let app = launch()
        openChatAndSend("hello", in: app)
        XCTAssertTrue(element(containing: "流式回复", in: app).waitForExistence(timeout: 15), "没有出现流式回答")
        XCTAssertTrue(element(containing: "已收到「hello」", in: app).waitForExistence(timeout: 15), "回答没有完整显示")
        XCTAssertTrue(element(containing: "由 example/example-model-1 回答", in: app).waitForExistence(timeout: 10), "没有显示实际回答的模型")
        XCTAssertTrue(app.buttons["chat.send"].waitForExistence(timeout: 10), "回答结束后应恢复发送按钮")
    }

    func testChatCreateAndDeleteSession() {
        let app = launch()
        openChatAndSend("first chat", in: app)
        XCTAssertTrue(element(containing: "由 example/example-model-1 回答", in: app).waitForExistence(timeout: 15))

        app.buttons["chat.new"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.empty"].firstMatch.waitForExistence(timeout: 10), "新对话应为空")

        app.buttons["chat.sessions.open"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["对话列表"].waitForExistence(timeout: 10))
        XCTAssertTrue(element(containing: "first chat", in: app).waitForExistence(timeout: 10), "对话列表里没有刚才的对话")

        let menu = app.buttons["chat.session.menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let delete = app.buttons["chat.session.delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let confirm = app.buttons["chat.session.confirmDelete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "删除前应要求确认")
        confirm.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chat.sessions.empty"].firstMatch.waitForExistence(timeout: 10), "删除后列表应为空")
    }
}

private extension XCUIApplication {
    /// 向上滑直到元素出现并可点（合计、图表下面的列表行，懒加载）。
    func swipeUpUntilHittable(_ element: XCUIElement, max: Int = 10) {
        for _ in 0..<max where !(element.exists && element.isHittable) { swipeUp() }
    }

    /// 向上滑几次直到找到元素（列表里靠下的内容）。
    func swipeUpAndFind(id: String) -> Bool {
        for _ in 0..<4 {
            if descendants(matching: .any).matching(identifier: id).firstMatch.exists { return true }
            swipeUp()
        }
        return descendants(matching: .any).matching(identifier: id).firstMatch.exists
    }
}
