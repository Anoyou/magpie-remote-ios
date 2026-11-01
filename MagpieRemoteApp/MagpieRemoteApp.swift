import SwiftUI

@main
struct MagpieRemoteApp: App {
    @State private var model = AppModel(environment: .current)

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
