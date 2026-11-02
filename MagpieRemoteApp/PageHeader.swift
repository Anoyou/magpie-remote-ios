import SwiftUI
import MagpieRemoteCore

/// 全 App 统一的页头。
///
/// - `pageHeader`：一个「页面」（底栏里的页面、「更多」里的每一项、固定名字的二级页）：
///   左对齐的大标题放在导航栏里（`.inlineLarge`），可选一行官方副标题（导航栏副标题）。
///   标题在导航栏里而不是跟着列表滚动，所以不管页面顶部有没有分页器、在底栏还是从「更多」推入，
///   大标题都一定在（0.5.0 里「用量」「会话」「主页」就是因为分页器 / `.inline` 把大标题弄没了）。
///   工具栏按钮一律放右上角，和标题同一行；深色 / 浅色跟系统导航栏一起变。
/// - `detailHeader`：名字不固定的详情页（某个供应商、某个会话、编辑页）和弹出的表单：普通的居中小标题。
///
/// 标题和副标题都用 magpie 网页上的官方中文（网页每页的标题 + 插件清单里的 Sub）。
/// 页面自己的状态行（例如「路由」的「● 实时 · 网关正在做的决定」）留在页面内容里，和网页一样。
extension View {
    func pageHeader(_ title: String, subtitle: String? = nil) -> some View {
        modifier(PageHeaderModifier(title: title, subtitle: subtitle, large: true))
    }

    func detailHeader(_ title: String, subtitle: String? = nil) -> some View {
        modifier(PageHeaderModifier(title: title, subtitle: subtitle, large: false))
    }
}

private struct PageHeaderModifier: ViewModifier {
    let title: String
    let subtitle: String?
    let large: Bool

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .modifier(PageSubtitle(subtitle: subtitle))
            .toolbarTitleDisplayMode(large ? .inlineLarge : .inline)
    }
}

private struct PageSubtitle: ViewModifier {
    let subtitle: String?

    func body(content: Content) -> some View {
        if let subtitle, !subtitle.isEmpty {
            content.navigationSubtitle(subtitle)
        } else {
            content
        }
    }
}

/// 各页面的官方副标题（magpie 网页插件清单 `Sub` 的官方简体中文译文，见 internal/gui/assets/i18n.js）。
/// 网页上没有副标题的页面（Agent、供应商、插件、设置…）这里也不写。
enum PageSubtitles {
    /// plugins/usage：Sub
    static let usage = "你的额度、花费及其去向、每个请求，以及上下文窗口里装了什么"
    /// plugins/sessions：Sub（官方原文「查看、搜索、继续和导出」；手机上不能继续会话，去掉「继续」）
    static let sessions = "Agent 的历史对话：查看、搜索和导出"
    /// plugins/budget（密钥限额）：Sub
    static let keys = "让每个网关密钥只用到你为它设的 Token 数或估算费用"
    /// plugins/library：Sub（给「资源库」页用）
    static let library = "指令、MCP 服务器、技能和 Hooks，统一管理，分发给每个 Agent"
}

extension AppPage {
    /// 页头的官方副标题；没有就不显示。
    var headerSubtitle: String? {
        switch self {
        case .usage: PageSubtitles.usage
        case .sessions: PageSubtitles.sessions
        case .keys: PageSubtitles.keys
        case .library: PageSubtitles.library
        default: nil
        }
    }
}
