import Foundation

/// App 里能放进底栏或「更多」的页面。`rawValue` 会存进 UserDefaults，改名前要考虑旧值（见 `init(storedValue:)`）。
public enum AppPage: String, CaseIterable, Identifiable, Hashable, Sendable {
    /// 「主页」：Agent、供应商、额度三页合在一起，顶部分页器切换（0.4.0 起）。
    case home
    case sessions, routes
    case usage, chat
    case keys, plugins, hostTools, web, hosts, about

    public var id: String { rawValue }

    /// 从保存的字符串恢复，兼容旧版本存下的值：0.3 的 Agent / 供应商 / 额度（agents / providers / quota）都并入「主页」。
    public init?(storedValue: String) {
        switch storedValue {
        case "agents", "providers", "quota": self = .home
        default: self.init(rawValue: storedValue)
        }
    }

    /// 底栏与「更多」里显示的名称（尽量短，底栏放得下）。
    public var title: String {
        switch self {
        case .home: "主页"
        case .sessions: "会话"
        case .routes: "路由"
        case .usage: "用量"
        case .chat: "对话"
        case .keys: "网关密钥"
        case .plugins: "插件"
        case .hostTools: "主机工具"
        case .web: "网页功能"
        case .hosts: "主机"
        case .about: "关于"
        }
    }

    /// 「自定义底栏」里的说明。
    public var detail: String {
        switch self {
        case .home: "Agent、供应商与额度"
        case .sessions: "Agent 会话记录"
        case .routes: "实时路由与路由组"
        case .usage: "花费、请求数与请求记录"
        case .chat: "经由网关和模型对话"
        case .keys: "网关密钥与临时密钥"
        case .plugins: "已安装与内置插件"
        case .hostTools: "主机更新、自动调优、隐私模型"
        case .web: "账号登录、备份与同步、脱敏"
        case .hosts: "切换、添加、编辑主机"
        case .about: "版本与更新日志"
        }
    }

    public var symbol: String {
        switch self {
        case .home: "house"
        case .sessions: "bubble.left.and.text.bubble.right"
        case .routes: "arrow.triangle.branch"
        case .usage: "chart.bar.xaxis"
        case .chat: "bubble.left.and.bubble.right"
        case .keys: "key"
        case .plugins: "puzzlepiece.extension"
        case .hostTools: "wrench.and.screwdriver"
        case .web: "safari"
        case .hosts: "desktopcomputer"
        case .about: "info.circle"
        }
    }
}

/// 「主页」顶部分页器的三页。`rawValue` 存进 UserDefaults（记住上次选的）。
public enum HomeSegment: String, CaseIterable, Identifiable, Hashable, Sendable {
    case agents, providers, quota

    public static let defaultsKey = "home.segment"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .agents: "Agent"
        case .providers: "供应商"
        case .quota: "额度"
        }
    }

    /// 读保存的值；没有或无法识别时是 Agent。
    public init(stored: String?) {
        self = stored.flatMap(HomeSegment.init(rawValue:)) ?? .agents
    }
}

/// 底栏前 4 个位置放哪些页面（第 5 个固定是「更多」）。纯数据，便于测试；保存由 App 负责。
public struct DockLayout: Equatable, Sendable {
    public static let slotCount = 4
    public static let defaultPages: [AppPage] = [.home, .sessions, .routes, .usage]
    public static let `default` = DockLayout(pages: defaultPages)

    /// 恰好 `slotCount` 个、互不重复的页面。
    public private(set) var pages: [AppPage]

    /// 不合法的输入（数量不对、重复、未知）会被整理：去掉重复与未知的，再用默认页面补满。
    public init(pages: [AppPage]) {
        var result: [AppPage] = []
        for page in pages where !result.contains(page) && result.count < Self.slotCount {
            result.append(page)
        }
        for page in Self.defaultPages + AppPage.allCases where result.count < Self.slotCount && !result.contains(page) {
            result.append(page)
        }
        self.pages = result
    }

    /// 从保存的字符串恢复；没有保存过或内容无法识别时用默认布局。
    /// 旧版本的 agents / providers / quota 会换成「主页」，重复的只留第一个，空位用默认页面补满。
    public init(stored: [String]?) {
        guard let stored else { self = .default; return }
        let pages = stored.compactMap(AppPage.init(storedValue:))
        self = pages.isEmpty ? .default : DockLayout(pages: pages)
    }

    public var stored: [String] { pages.map(\.rawValue) }
    public var isDefault: Bool { pages == Self.defaultPages }

    /// 不在底栏、出现在「更多」里的页面（按固定顺序）。
    public var morePages: [AppPage] { AppPage.allCases.filter { !pages.contains($0) } }

    public func contains(_ page: AppPage) -> Bool { pages.contains(page) }

    /// 拖动排序（参数与 SwiftUI `onMove` 一致）。
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().filter { pages.indices.contains($0) }.map { pages[$0] }
        guard !moving.isEmpty else { return }
        var rest = pages
        for index in source.sorted(by: >) where rest.indices.contains(index) { rest.remove(at: index) }
        let before = source.filter { $0 < destination }.count
        let insertAt = min(max(destination - before, 0), rest.count)
        rest.insert(contentsOf: moving, at: insertAt)
        pages = rest
    }

    /// 把第 `index` 个位置换成 `page`。`page` 已在底栏时两者交换位置。
    public mutating func place(_ page: AppPage, at index: Int) {
        guard pages.indices.contains(index) else { return }
        if let current = pages.firstIndex(of: page) {
            pages.swapAt(current, index)
        } else {
            pages[index] = page
        }
    }

    /// 上移 / 下移一格。
    public mutating func shift(_ page: AppPage, by offset: Int) {
        guard let index = pages.firstIndex(of: page) else { return }
        let target = index + offset
        guard pages.indices.contains(target) else { return }
        pages.swapAt(index, target)
    }

    public mutating func reset() { pages = Self.defaultPages }
}
