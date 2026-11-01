import UIKit
import XCTest

/// 「路由」舞台的逐帧截图：和官方 magpie 网页路由页逐帧对比喜鹊的样子与时间（网页那边用 Playwright 的假时钟截）。
///
/// `--routes-snapshot=<秒>` 让舞台用停住的时钟（RoutesClock）：fixture 的示例请求（RoutesFixture.trace）从 <秒> 开始，
/// 每点一下「路由」分区标题里的「下一帧」（routes.snapshot.step）走 0.1 秒，等它的 label 显示这一刻已经画好再截。每帧既作为附件放进 .xcresult，
/// 也写到仓库的 build/results/routes-frames/（CI 会把 build/results 整个上传成 artifact）。
/// 场景：6.0–10.6 秒是第 13 个请求（先飞到 magpie 等路由，再到第一个 Key，回答衔回来）；
/// 18.0–22.6 秒是第 15 个请求（第一个 Key 限流 429，红圈飞回 magpie，改道到第二个 Key）。
@MainActor
final class RoutesSnapshotUITests: XCTestCase {
    private var launchTimeout: TimeInterval {
        ProcessInfo.processInfo.environment["MAGPIE_REMOTE_WARMUP_TIMEOUT"].flatMap { TimeInterval($0) } ?? 45
    }

    /// build/results/routes-frames（从这个源文件的路径往上两级就是仓库根）。
    private var outputDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/results/routes-frames", isDirectory: true)
    }

    private func frames(_ scene: String, from start: Double, to end: Double, every: Int = 1, dark: Bool = false) {
        continueAfterFailure = false
        XCUIDevice.shared.appearance = dark ? .dark : .light
        defer { XCUIDevice.shared.appearance = .light }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--routes-fliers", "--routes-snapshot=\(start)",
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] + (dark ? ["--ui-dark"] : [])
        app.launch()
        XCTAssertTrue(app.waitForDock(timeout: launchTimeout), "没有出现底栏「更多」")
        app.openDockTab("路由")
        let stage = app.descendants(matching: .any).matching(identifier: "routes.stage").firstMatch
        XCTAssertTrue(stage.appears(timeout: 15), "没有出现实时路由舞台")
        let step = app.buttons["routes.snapshot.step"].firstMatch
        let clock = step
        let directory = outputDirectory.appendingPathComponent(scene, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var ms = Int((start * 1000).rounded())
        let last = Int((end * 1000).rounded())
        var index = 0
        while ms <= last {
            wait(for: clock, toShow: ms)
            if index % every == 0 {
                let shot = visibleShot(of: stage, in: app)
                let name = String(format: "ios-%06d", ms)
                let attachment = XCTAttachment(image: shot)
                attachment.name = "\(scene)/\(name)"
                attachment.lifetime = .keepAlways
                add(attachment)
                try? shot.pngData()?.write(to: directory.appendingPathComponent(name + ".png"))
            }
            index += 1
            ms += 100
            if ms <= last { step.tap() }
        }
    }

    /// 舞台卡片在屏幕上看得见的那一块。卡片下面加了「是怎么路由的」之后比屏幕还高，
    /// `XCUIElement.screenshot()` 对超出屏幕的元素会失败（Rendering screen failed），所以截整屏再裁。
    private func visibleShot(of element: XCUIElement, in app: XCUIApplication) -> UIImage {
        let screen = XCUIScreen.main.screenshot().image
        let bounds = app.windows.firstMatch.frame
        let rect = element.frame.intersection(bounds)
        guard let cg = screen.cgImage, !rect.isNull, rect.width > 0, rect.height > 0 else { return screen }
        let scale = CGFloat(cg.width) / bounds.width
        let pixels = CGRect(x: (rect.minX - bounds.minX) * scale, y: (rect.minY - bounds.minY) * scale,
                            width: rect.width * scale, height: rect.height * scale).integral
        guard let cropped = cg.cropping(to: pixels) else { return screen }
        return UIImage(cgImage: cropped, scale: screen.scale, orientation: .up)
    }

    /// 等「下一帧」的 label 显示这一刻（毫秒）已经画好。直接读 label，比 expectation 的轮询快、失败时也能说出停在哪。
    private func wait(for clock: XCUIElement, toShow ms: Int) {
        let want = "下一帧 \(ms)"
        let deadline = Date().addingTimeInterval(30)
        var seen = "-"
        while Date() < deadline {
            if clock.exists {
                seen = clock.label
                if seen == want { return }
            }
            usleep(100_000)
        }
        XCTFail("「下一帧」没走到 \(ms)：exists=\(clock.exists)，label=\(seen)")
    }

    func testRoutesFramesSuccess() {
        frames("success-light", from: 6.0, to: 10.6)
    }

    func testRoutesFramesReroute() {
        frames("reroute-light", from: 18.0, to: 22.6)
    }

    func testRoutesFramesDark() {
        frames("success-dark", from: 6.0, to: 10.6, every: 3, dark: true)
    }
}
