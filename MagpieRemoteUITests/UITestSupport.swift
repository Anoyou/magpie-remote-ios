import XCTest

/// 所有 UI 测试共用的等待工具。
///
/// XCTest 自带的 `waitForExistence(timeout:)` 与 `expectation(for:evaluatedWith:)` 每隔 1 秒才检查一次，
/// 而且第一次检查也要等满 1 秒——元素早就在屏幕上也白等 1 秒。CI 日志里全部用例加起来约 450 次、近 8 分钟。
/// 这里改成：先立刻查一次，之后每 0.25 秒查一次，超时时间不变（只会更早通过，不会更早判失败）。
@MainActor
extension XCUIElement {
    /// 等元素出现（替代 `waitForExistence(timeout:)`，语义相同）。
    func appears(timeout: TimeInterval) -> Bool {
        UITestWait.until(timeout) { self.exists }
    }

    /// 等元素消失（替代 `waitForNonExistence(timeout:)` 与 `exists == false` 的 expectation）。
    func disappears(timeout: TimeInterval) -> Bool {
        UITestWait.until(timeout) { !self.exists }
    }

    /// 等元素出现且朗读文字包含某段文字（元素不在时不读 label，免得直接判失败）。
    func hasLabel(containing text: String, within timeout: TimeInterval) -> Bool {
        UITestWait.until(timeout) { self.exists && self.label.contains(text) }
    }
}

@MainActor
enum UITestWait {
    /// 先立刻检查一次，之后每 0.25 秒检查一次，直到条件成立或超时；超时前最后再查一次。
    static func until(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        if condition() { return true }
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            if condition() { return true }
        }
        return condition()
    }
}

@MainActor
extension XCTestCase {
    /// 等条件成立（替代 `expectation(for:evaluatedWith:)` + `waitForExpectations`）。
    func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        UITestWait.until(timeout, condition)
    }
}

@MainActor
extension XCUIApplication {
    /// 向上滑直到元素出现并可点，最多滑 `max` 次；已经可点就不滑（找到即停，不再反复查询）。
    func swipeUp(until element: XCUIElement, max: Int) {
        for _ in 0..<max {
            if element.exists && element.isHittable { return }
            swipeUp()
        }
    }

    /// 向下滑直到元素出现并可点，最多滑 `max` 次。
    func swipeDown(until element: XCUIElement, max: Int) {
        for _ in 0..<max {
            if element.exists && element.isHittable { return }
            swipeDown()
        }
    }
}

@MainActor
extension XCUIApplication {
    /// 页面的系统搜索栏（`.searchable`）。iOS 26 会按地方大小把它显示成完整的搜索栏，
    /// 或收成工具栏里的放大镜按钮（`.minimizedSearch()` 的页面总是按钮）：是按钮就先点开。
    func revealSearchField(timeout: TimeInterval = 10) -> XCUIElement {
        let field = searchFields.firstMatch
        if field.appears(timeout: 3) { return field }
        let button = buttons.matching(NSPredicate(format: "label == %@ OR label == %@ OR identifier == %@ OR identifier == %@",
                                                  "搜索", "Search", "Search", "search")).firstMatch
        if button.appears(timeout: timeout) { button.tap() }
        _ = field.appears(timeout: timeout)
        return field
    }
}
