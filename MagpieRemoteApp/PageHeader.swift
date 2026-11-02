import SwiftUI
import MagpieRemoteCore

/// 全 App 统一的页头：只用系统导航栏自己的标题，不自己画字、不换字体、不放 `.principal` 标题。
///
/// - `pageHeader`：一个「页面」（底栏里的页面、「更多」里的每一项、固定名字的二级页）：
///   系统标准大标题（`.navigationBarTitleDisplayMode(.large)`，和「设置」「信息」等系统 App 一样），
///   可选一行官方副标题（系统的导航栏副标题 `navigationSubtitle`）。往上滚时由系统收成居中小标题。
///   0.6.0 用的是 `.inlineLarge`（导航栏里的「中号」标题），字号和系统大标题不同，
///   不同页面（有没有副标题、右上角几个按钮）看起来还不一样大；0.6.1 起所有页面统一成系统大标题。
///   工具栏按钮一律放右上角；深色 / 浅色跟系统导航栏一起变。
/// - `detailHeader`：名字不固定的详情页（某个供应商、某个会话、编辑页）和弹出的表单：系统的居中小标题。
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

extension View {
    /// 搜索的统一规则（DESIGN.md「搜索」）：一律用系统的 `.searchable`，放在系统默认位置（和「会话」页一样，
    /// 由系统决定放在导航栏里跟着大标题展开 / 收起，或收成工具栏里的放大镜），不用 `.navigationBarDrawer(displayMode: .always)` 钉住。
    /// 页面主体就是那张可搜索的列表时（会话、插件、发现、选模型的表单）显示完整的搜索栏；
    /// 页面上还有分页器 / 筛选 / 图表、搜索只是其中一个工具时（用量 › 请求、用量 › 会话、Agent 的模型列表），
    /// 再加上这个修饰符，把搜索收成工具栏里的放大镜按钮，点开才展开。
    func minimizedSearch() -> some View {
        searchToolbarBehavior(.minimize)
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
            .navigationBarTitleDisplayMode(large ? .large : .inline)
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
    // 0.6.2：原来的官方原文太长，393 pt 宽的 iPhone 上一行放不下、被截断（收起成小标题时更挤）。
    // 现在每条压到一行能放下的长度（约 12 个字以内），意思仍取自官方原文。
    /// plugins/usage：Sub「你的额度、花费及其去向、每个请求，以及上下文窗口里装了什么」（额度已在「主页」）
    static let usage = "花费、请求和上下文窗口"
    /// plugins/sessions：Sub「Agent 的历史对话：查看、搜索、继续和导出」（手机上不能继续会话）
    static let sessions = "查看、搜索和导出历史对话"
    /// plugins/budget（密钥限额）：Sub「让每个网关密钥只用到你为它设的 Token 数或估算费用」
    static let keys = "给每个网关密钥设用量上限"
    /// plugins/library：Sub「指令、MCP 服务器、技能和 Hooks，统一管理，分发给每个 Agent」
    static let library = "统一管理，分发给每个 Agent"
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
