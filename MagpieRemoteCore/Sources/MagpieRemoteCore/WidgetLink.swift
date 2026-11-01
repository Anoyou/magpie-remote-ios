import Foundation

/// 点小组件打开 App 时用的链接：`magpieremote://widget/quota`、`magpieremote://widget/usage`。
/// URL scheme 写在 App 的 Info.plist（CFBundleURLTypes）里。
public enum WidgetLink: String, CaseIterable, Hashable, Sendable {
    /// 额度：主页的「额度」分页。
    case quota
    /// 用量页。
    case usage

    public static let scheme = "magpieremote"
    public static let host = "widget"

    public var url: URL { URL(string: "\(Self.scheme)://\(Self.host)/\(rawValue)")! }

    /// 解析链接；不是本 App 的小组件链接返回 nil。也接受 `magpieremote://quota` 这种省略 host 的写法。
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        let host = url.host?.lowercased() ?? ""
        let path = url.pathComponents.filter { $0 != "/" }.map { $0.lowercased() }
        let name: String?
        if host == Self.host { name = path.first } else { name = host.isEmpty ? path.first : host }
        guard let name, let link = WidgetLink(rawValue: name) else { return nil }
        self = link
    }

    /// 要打开的页面。
    public var page: AppPage {
        switch self {
        case .quota: .home
        case .usage: .usage
        }
    }

    /// 打开主页时选哪个分页。
    public var homeSegment: HomeSegment? { self == .quota ? .quota : nil }

    /// 在当前底栏下怎么打开：页面在底栏里就切到那个标签；不在（用户把它移进了「更多」）就切到「更多」再推入。
    public func route(dock: DockLayout) -> WidgetRoute {
        dock.pages.contains(page) ? .tab(page) : .more(page)
    }
}

public enum WidgetRoute: Hashable, Sendable {
    case tab(AppPage)
    case more(AppPage)
}
