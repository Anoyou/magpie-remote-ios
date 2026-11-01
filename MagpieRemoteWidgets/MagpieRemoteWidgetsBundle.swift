import SwiftUI
import WidgetKit

/// 小组件扩展入口：「额度」（主屏小 / 中 / 大与锁屏三种）与「今日用量」。
/// 两个小组件都只读 App 写进 App Group 的快照（见 Core 的 `WidgetSnapshot`），自己不联网、不读钥匙串。
@main
struct MagpieRemoteWidgetsBundle: WidgetBundle {
    var body: some Widget {
        QuotaWidget()
        UsageWidget()
    }
}
