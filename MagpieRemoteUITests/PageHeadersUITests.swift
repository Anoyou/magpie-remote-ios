import XCTest

/// 统一页头：底栏的每个页面、「更多」里的每一项，顶部都要有左对齐的大标题（导航栏里），
/// 有官方副标题的页面（用量、会话、网关密钥、资源库）还要有那行副标题。
/// 0.5.0 里「用量」「会话」「主页」没有大标题，这里逐页检查，防止再丢。
@MainActor
final class PageHeadersUITests: XCTestCase {
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

    /// 导航栏里有这个标题。`leading`：根页面（没有返回按钮）的大标题应当靠左，而不是居中的小标题。
    private func assertHeader(_ title: String, subtitle: String? = nil, leading: Bool = false, in app: XCUIApplication,
                              file: StaticString = #filePath, line: UInt = #line) {
        let bar = app.navigationBars.matching(identifier: title).firstMatch
        XCTAssertTrue(bar.appears(timeout: 10), "「\(title)」页没有导航栏标题", file: file, line: line)
        var text = bar.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
        if !text.appears(timeout: 3) {
            // 右上角有两个以上按钮时（例如「供应商」的「编辑」「添加」），iOS 26 的大标题画在导航栏里，
            // 却不挂在导航栏的无障碍子树下：改找画在导航栏范围里的那行标题文字（不会找到下面分页器里的同名按钮）。
            let barFrame = bar.frame
            let same = NSPredicate(format: "label == %@ AND elementType != %@", title, NSNumber(value: XCUIElement.ElementType.button.rawValue))
            let inBar = app.descendants(matching: .any).matching(same).allElementsBoundByIndex.first {
                let f = $0.frame
                return !f.isEmpty && f.midY >= barFrame.minY && f.midY <= barFrame.maxY
            }
            if let inBar { text = inBar }
        }
        XCTAssertTrue(text.appears(timeout: 5), "「\(title)」页的导航栏里没有标题文字：\(bar.debugDescription)", file: file, line: line)
        if leading {
            let barFrame = bar.frame
            XCTAssertLessThan(text.frame.minX - barFrame.minX, barFrame.width * 0.35,
                              "「\(title)」应当是靠左的大标题（不是居中的小标题）", file: file, line: line)
        }
        if let subtitle {
            let sub = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", subtitle)).firstMatch
            XCTAssertTrue(sub.appears(timeout: 5), "「\(title)」页没有副标题「\(subtitle)」", file: file, line: line)
        }
    }

    /// 默认底栏的 4 个页面和「更多」，以及「更多」里的各个页面。
    func testEveryDockTabAndMorePageHasHeader() {
        let app = launch()

        // 底栏（主页的大标题跟着分页走：Agent / 供应商 / 额度）
        app.openHome("Agent")
        assertHeader("Agent", leading: true, in: app)
        app.openHome("供应商")
        assertHeader("供应商", leading: true, in: app)
        app.openHome("额度")
        assertHeader("额度", leading: true, in: app)

        app.openDockTab("会话")
        assertHeader("会话", subtitle: "Agent 的历史对话", leading: true, in: app)
        app.openDockTab("路由")
        assertHeader("路由", leading: true, in: app)
        app.openDockTab("用量")
        assertHeader("用量", subtitle: "你的额度、花费及其去向", leading: true, in: app)
        app.openMore()
        assertHeader("更多", leading: true, in: app)

        // 「更多」里的页面（每次都点底栏「更多」回到根列表再进）
        let pages: [(id: String, title: String, subtitle: String?)] = [
            ("more.chat", "对话", nil),
            ("manage.keys", "网关密钥", "让每个网关密钥只用到"),
            ("manage.plugins", "插件", nil),
            ("more.library", "资源库", "指令、MCP 服务器、技能和 Hooks"),
            ("manage.hosts", "主机", nil),
            ("manage.about", "关于", nil),
            ("manage.guide", "配置引导", nil),
            ("more.customize", "自定义底栏", nil),
        ]
        for page in pages {
            app.openFromMore(page.id, title: page.title)
            assertHeader(page.title, subtitle: page.subtitle, in: app)
        }
    }

    /// 同一个页面放在底栏和放在「更多」里，页头一样：把「对话」换到底栏第 1 个，主页就去了「更多」。
    func testHeaderShowsBothInDockAndFromMore() {
        let app = launch()
        app.openFromMore("more.customize", title: "自定义底栏")
        let chat = app.descendants(matching: .any).matching(identifier: "dock.candidate.chat").firstMatch
        _ = chat.appears(timeout: 2)
        app.swipeUp(until: chat, max: 6)
        XCTAssertTrue(chat.appears(timeout: 10), "「在『更多』里」没有列出对话")
        chat.tap()
        let place = app.menuItem(id: "dock.place.0", label: "第 1 个位置（换下「主页」）")
        XCTAssertTrue(place.appears(timeout: 5), "没有出现「放进底栏」的位置选项")
        place.tap()
        XCTAssertTrue(app.tabBars.buttons["对话"].appears(timeout: 10), "底栏没有出现「对话」")

        app.openDockTab("对话")
        assertHeader("对话", leading: true, in: app)
        app.openFromMore("more.home", title: "Agent")
        assertHeader("Agent", in: app)
    }
}
