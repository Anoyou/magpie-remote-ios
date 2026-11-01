import SwiftUI
import UIKit

@main
struct MagpieRemoteApp: App {
    @State private var model = AppModel(environment: .current)

    init() {
        // UI 测试（--ui-testing）关掉 UIKit 过场动画：页面推入、弹出表单、菜单直接到位，
        // XCUITest 每次点按后不用再等动画播完才算界面静止。只影响测试，真机与演示不受影响。
        if RT.uiTesting { UIView.setAnimationsEnabled(false) }
    }

    var body: some Scene {
        WindowGroup {
            MainTabs()
                .environment(model)
                .task { await model.start() }
                .preferredColorScheme(Self.testScheme)
        }
    }

    /// UI 测试截深色图用（`--ui-dark`）：CI 模拟器上 XCUIDevice.appearance 不一定生效。
    private static let testScheme: ColorScheme? = ProcessInfo.processInfo.arguments.contains("--ui-dark") ? .dark : nil
}
