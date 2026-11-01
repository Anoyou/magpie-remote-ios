import XCTest

/// 新底栏的导航：前 4 个是可自定义的页面（默认主页、会话、路由、用量），第 5 个固定是「更多」。
/// 「主页」顶部分页器里是 Agent、供应商、额度；不在底栏里的页面（对话、网关密钥、插件、主机工具、关于…）都从「更多」进入。
@MainActor
extension XCUIApplication {
    /// 等底栏出现（以固定的「更多」为准）。
    func waitForDock(timeout: TimeInterval) -> Bool {
        tabBars.buttons["更多"].appears(timeout: timeout)
    }

    /// 点底栏的一个页面，等它的导航栏标题出现。
    func openDockTab(_ title: String, navigationTitle: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let tab = tabBars.buttons[title]
        XCTAssertTrue(tab.appears(timeout: 15), "底栏里没有「\(title)」", file: file, line: line)
        tab.tap()
        let expected = navigationTitle ?? title
        XCTAssertTrue(navigationBars[expected].appears(timeout: 10), "没有打开「\(expected)」", file: file, line: line)
    }

    /// 打开「主页」并切到分页器里的一页（Agent / 供应商 / 额度），等这一页的导航栏标题出现。
    func openHome(_ segment: String, file: StaticString = #filePath, line: UInt = #line) {
        let tab = tabBars.buttons["主页"]
        XCTAssertTrue(tab.appears(timeout: 15), "底栏里没有「主页」", file: file, line: line)
        tab.tap()
        let control = homeSegments
        XCTAssertTrue(control.appears(timeout: 10), "主页顶部没有分页器", file: file, line: line)
        let button = control.buttons[segment]
        XCTAssertTrue(button.appears(timeout: 5), "分页器里没有「\(segment)」", file: file, line: line)
        if !button.isSelected { button.tap() }
        XCTAssertTrue(navigationBars[segment].appears(timeout: 10), "没有切到「\(segment)」", file: file, line: line)
    }

    /// 「主页」顶部的分页器。
    var homeSegments: XCUIElement {
        let byID = segmentedControls["home.segment"]
        return byID.exists ? byID : segmentedControls.firstMatch
    }

    /// 打开底栏「更多」的根列表。
    func openMore(file: StaticString = #filePath, line: UInt = #line) {
        openDockTab("更多", file: file, line: line)
    }

    /// 从「更多」打开一个页面（按行的 identifier，列表懒加载，必要时往下滑）。
    func openFromMore(_ identifier: String, title: String, file: StaticString = #filePath, line: UInt = #line) {
        openMore(file: file, line: line)
        let link = descendants(matching: .any).matching(identifier: identifier).firstMatch
        // 懒加载的列表里靠下的行一开始不在无障碍树里：短等一下，没有就往下滑（找到即停）。
        _ = link.appears(timeout: 2)
        swipeUp(until: link, max: 8)
        XCTAssertTrue(link.appears(timeout: 10), "「更多」里没有入口 \(identifier)", file: file, line: line)
        link.tap()
        XCTAssertTrue(navigationBars[title].appears(timeout: 10), "没有打开「\(title)」", file: file, line: line)
    }

    /// 弹出菜单里的一项。放在 Menu 的 Section 里的按钮，iOS 不会把 SwiftUI 的 accessibilityIdentifier
    /// 带到菜单项上（只剩标题），所以按 identifier 或按标题找，哪个先出现用哪个。
    func menuItem(id identifier: String, label: String) -> XCUIElement {
        buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", identifier, label)).firstMatch
    }
}
