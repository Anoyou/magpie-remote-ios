import Foundation
import MagpieRemoteCore

/// 运行环境：真实主机，或 fixture 模式（UI 测试与演示用，不需要任何主机）。
///
/// 开启 fixture 模式：启动参数 `--ui-testing`，或环境变量 `MAGPIE_REMOTE_FIXTURE=1`。
/// fixture 下另有：
/// - `--fixture-empty`：没有任何主机（测试空状态与添加流程）；
/// - `--fixture-offline`：主机连不上（测试错误提示）。
struct AppEnvironment: Sendable {
    var isFixture: Bool
    var fixtureEmpty: Bool
    var fixtureOffline: Bool

    static var current: AppEnvironment {
        let info = ProcessInfo.processInfo
        let fixture = info.arguments.contains("--ui-testing") || info.environment["MAGPIE_REMOTE_FIXTURE"] == "1"
        return AppEnvironment(isFixture: fixture,
                              fixtureEmpty: info.arguments.contains("--fixture-empty"),
                              fixtureOffline: info.arguments.contains("--fixture-offline"))
    }

    static let live = AppEnvironment(isFixture: false, fixtureEmpty: false, fixtureOffline: false)
}
