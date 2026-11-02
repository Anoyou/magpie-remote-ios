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

/// 顶部条的间距规则（0.6.3，DESIGN.md「顶部分页器」）：所有页面一样。
/// - 分页器离导航栏标题固定 `top`；
/// - 两个分页器（「用量」的页面分页 + 范围）放在同一条里，中间 `between`；
/// - 条和下面第一块内容之间固定 `below`，不叠加列表的分组间距、也不随「卡片间距」变。
enum PageTopStripMetrics {
    static let top: CGFloat = 8
    static let between: CGFloat = 8
    static let below: CGFloat = 12
}

/// 列表的第一节：外层交来的条 + 这一页自己的分页器（`inner`，例如「用量 › 概览」的「今天 / 7 天…」），
/// 两个都没有就什么都不显示。整节是一行（透明底、无分隔线、无内边距），上下间距按 `PageTopStripMetrics`：
/// 这一节自己写了分组间距（`listSectionSpacing(.custom(below))`），所以它和下一节之间就是 `below`，
/// 不管列表整体用「紧凑」还是「宽松」（分节上写的间距优先于列表整体的）。
struct PageTopStripSection<Inner: View>: View {
    @Environment(\.pageTopStrip) private var strip
    private let showsOuter: Bool
    private let inner: Inner
    private let hasInner: Bool

    init(showsOuter: Bool = true, @ViewBuilder inner: () -> Inner) {
        self.showsOuter = showsOuter
        self.inner = inner()
        hasInner = Inner.self != EmptyView.self
    }

    var body: some View {
        let outer = showsOuter ? strip : nil
        if outer != nil || hasInner {
            Section {
                VStack(spacing: PageTopStripMetrics.between) {
                    if let outer { outer.view }
                    if hasInner { inner }
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            }
            .environment(\.defaultMinListRowHeight, 0)
            .listSectionSpacing(.custom(PageTopStripMetrics.below))
            .listSectionMargins(.top, PageTopStripMetrics.top)
        }
    }
}

extension PageTopStripSection where Inner == EmptyView {
    init(showsOuter: Bool = true) {
        self.init(showsOuter: showsOuter) { EmptyView() }
    }
}

/// `ScrollView` 页面里的条（放在滚动内容的最上面；外面那层 `VStack` 用 `PageTopStripMetrics` 的间距）。
struct PageTopStripView: View {
    @Environment(\.pageTopStrip) private var strip

    var body: some View {
        if let strip {
            strip.view
                .padding(.top, PageTopStripMetrics.top)
                .padding(.bottom, PageTopStripMetrics.below)
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
                    .padding(.top, PageTopStripMetrics.top)
                    .padding(.bottom, PageTopStripMetrics.below)
                content
                    .frame(maxHeight: .infinity)
                    .pageTopStrip(nil)
            }
        } else {
            content
        }
    }
}

// MARK: 卡片间距

/// 「更多 › App › 卡片间距」（0.6.3）：全 App 列表分组（卡片）之间的距离。紧凑是默认。
enum CardSpacing: String, CaseIterable, Identifiable {
    case compact, roomy

    static let defaultsKey = "app.cardSpacing"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .compact: "紧凑"
        case .roomy: "宽松"
        }
    }

    var listSpacing: ListSectionSpacing {
        switch self {
        case .compact: .compact
        case .roomy: .default
        }
    }
}

private struct CardSpacingModifier: ViewModifier {
    @AppStorage(CardSpacing.defaultsKey) private var raw = CardSpacing.compact.rawValue

    func body(content: Content) -> some View {
        content.listSectionSpacing((CardSpacing(rawValue: raw) ?? .compact).listSpacing)
    }
}

extension View {
    /// 每个 `List` 都挂这一个（DESIGN.md「卡片间距」）：分组间距跟着「更多 › 卡片间距」走。
    /// 页面顶部的条（`PageTopStripSection`）自己写了间距，不受它影响。
    func cardSpacing() -> some View {
        modifier(CardSpacingModifier())
    }
}
