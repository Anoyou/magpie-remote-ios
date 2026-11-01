import SwiftUI

@main
struct MagpieRemoteApp: App {
    @State private var model = AppModel(environment: .current)
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MainTabs()
                .environment(model)
                .task { await model.start() }
                // 点小组件打开（magpieremote://widget/…）：切到额度 / 用量。
                .onOpenURL { model.open($0) }
                // 回到前台时顺便更新小组件快照（2 分钟内不重复请求主机）。
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.refreshWidgets() } }
                }
                .preferredColorScheme(Self.testScheme)
        }
    }

    /// UI 测试截深色图用（`--ui-dark`）：CI 模拟器上 XCUIDevice.appearance 不一定生效。
    private static let testScheme: ColorScheme? = ProcessInfo.processInfo.arguments.contains("--ui-dark") ? .dark : nil
}
