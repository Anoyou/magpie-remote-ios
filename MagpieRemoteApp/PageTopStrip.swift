import SwiftUI

/// 页面顶部的「条」（分页器、读取失败的提示…）：放进列表当第一行，跟着内容一起滚，不钉在导航栏下面。
///
/// 0.6.1 之前「主页」「用量」的分页器放在导航栏下方的 `safeAreaBar` 里（钉住不动），
/// 管理页读取失败的提示放在 `safeAreaInset(edge: .top)` 里。系统大标题在顶部展开 / 收起时，
/// 钉住的那一条和大标题互相抢位置，滚到最上面附近时页头会来回抖。系统 App（设置、信息…）的做法是
/// 让这类内容就是列表的第一行，这里也一样：
///
/// - 外层（`HomeView`、`UsageView`、`ManageGate`）用 `.pageTopStrip { … }` 把条交给里面的页面；
/// - 页面的根列表第一行写 `PageTopStripSection()`（`ScrollView` 页写 `PageTopStripView()`）；
/// - 还没有列表的状态（读取中、出错、没有主机）用 `PageTopStripStack` 把条放在最上面（这些状态不能滚，不会抖）。
///
/// 推入的详情页、弹出的表单不显示外层的条（`.pageTopStrip(nil)` 清掉）。
/// 只在主线程上的 SwiftUI 环境里传递（AnyView 本身不是 Sendable）。
struct PageTopStrip: @unchecked Sendable {
    let view: AnyView
}

extension EnvironmentValues {
    @Entry var pageTopStrip: PageTopStrip? = nil
}

extension View {
    /// 把一条内容交给里面的页面，作为它列表的第一行。
    func pageTopStrip<Strip: View>(@ViewBuilder _ strip: () -> Strip) -> some View {
        environment(\.pageTopStrip, PageTopStrip(view: AnyView(strip())))
    }

    /// 里面的视图不再显示外层的条（推入的详情页、已经自己放好条的页面内容）。
    func pageTopStrip(_ none: PageTopStrip?) -> some View {
        environment(\.pageTopStrip, none)
    }
}

/// 列表的第一节：外层交来的条（没有就什么都不显示）。
struct PageTopStripSection: View {
    @Environment(\.pageTopStrip) private var strip

    var body: some View {
        if let strip {
            Section {
                strip.view
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowSeparator(.hidden)
            }
        }
    }
}

/// `ScrollView` 页面里的条（放在滚动内容的最上面）。
struct PageTopStripView: View {
    @Environment(\.pageTopStrip) private var strip

    var body: some View {
        if let strip {
            strip.view
        }
    }
}

/// 不能滚的状态（读取中、出错、没有主机）：条在最上面，下面是状态本身。
struct PageTopStripStack<Content: View>: View {
    @Environment(\.pageTopStrip) private var strip
    @ViewBuilder var content: Content

    var body: some View {
        if let strip {
            VStack(spacing: 0) {
                strip.view
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                content
                    .frame(maxHeight: .infinity)
                    .pageTopStrip(nil)
            }
        } else {
            content
        }
    }
}
