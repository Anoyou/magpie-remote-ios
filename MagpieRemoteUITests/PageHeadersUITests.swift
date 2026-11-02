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

    /// 导航栏里有这个标题，返回标题文字的高度（系统大标题约 41 pt，收起后的小标题约 20 pt）。
    /// `leading`：根页面（没有返回按钮）的大标题应当靠左，而不是居中的小标题。
    @discardableResult
    private func assertHeader(_ title: String, subtitle: String? = nil, leading: Bool = false, in app: XCUIApplication,
                              file: StaticString = #filePath, line: UInt = #line) -> CGFloat {
        let bar = app.navigationBars.matching(identifier: title).firstMatch
        XCTAssertTrue(bar.appears(timeout: 10), "「\(title)」页没有导航栏标题", file: file, line: line)
        // 导航栏范围里、朗读文字就是标题的文字（不算按钮：主页分页器里也有同名的「Agent」「供应商」）。
        // 大标题模式下导航栏里还藏着一份收起后用的小标题：取最高的那一个。
        let same = NSPredicate(format: "label == %@ AND elementType == %@", title, NSNumber(value: XCUIElement.ElementType.staticText.rawValue))
        var texts: [XCUIElement] = []
        let found = waitUntil(5) {
            let barFrame = bar.frame
            texts = app.descendants(matching: .any).matching(same).allElementsBoundByIndex.filter {
                let f = $0.frame
                return !f.isEmpty && f.midY >= barFrame.minY && f.midY <= barFrame.maxY
            }
            return !texts.isEmpty
        }
        XCTAssertTrue(found, "「\(title)」页的导航栏里没有标题文字：\(bar.debugDescription)", file: file, line: line)
        guard let text = texts.max(by: { $0.frame.height < $1.frame.height }) else { return 0 }
        if leading {
            let barFrame = bar.frame
            XCTAssertLessThan(text.frame.minX - barFrame.minX, barFrame.width * 0.35,
                              "「\(title)」应当是靠左的大标题（不是居中的小标题）", file: file, line: line)
        }
        if let subtitle {
            let sub = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", subtitle)).firstMatch
            XCTAssertTrue(sub.appears(timeout: 5), "「\(title)」页没有副标题「\(subtitle)」", file: file, line: line)
        }
        return text.frame.height
    }

    /// 所有页面的大标题一样高（同一个系统大标题字号），而且是大标题（不是收起后的小标题）。
    private func assertSameSize(_ heights: [(String, CGFloat)], file: StaticString = #filePath, line: UInt = #line) {
        let all = heights.map { "\($0.0) \(Int($0.1.rounded()))pt" }.joined(separator: "、")
        guard let tallest = heights.map(\.1).max(), let shortest = heights.map(\.1).min() else { return }
        XCTAssertGreaterThanOrEqual(shortest, 30, "有页面的标题不是系统大标题（太小）：\(all)", file: file, line: line)
        XCTAssertLessThanOrEqual(tallest - shortest, 1.5, "各页面的大标题高度不一致：\(all)", file: file, line: line)
    }

    /// 默认底栏的 4 个页面和「更多」，以及「更多」里的各个页面。
    func testEveryDockTabAndMorePageHasHeader() {
        let app = launch()
        var heights: [(String, CGFloat)] = []

        // 底栏（主页的大标题跟着分页走：Agent / 供应商 / 额度）
        app.openHome("Agent")
        heights.append(("Agent", assertHeader("Agent", leading: true, in: app)))
        app.openHome("供应商")
        heights.append(("供应商", assertHeader("供应商", leading: true, in: app)))
        app.openHome("额度")
        heights.append(("额度", assertHeader("额度", leading: true, in: app)))

        app.openDockTab("会话")
        heights.append(("会话", assertHeader("会话", subtitle: "Agent 的历史对话", leading: true, in: app)))
        app.openDockTab("路由")
        heights.append(("路由", assertHeader("路由", leading: true, in: app)))
        app.openDockTab("用量")
        heights.append(("用量", assertHeader("用量", subtitle: "你的额度、花费及其去向", leading: true, in: app)))
        app.openMore()
        heights.append(("更多", assertHeader("更多", leading: true, in: app)))

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
            heights.append((page.title, assertHeader(page.title, subtitle: page.subtitle, leading: true, in: app)))
        }
        assertSameSize(heights)
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
