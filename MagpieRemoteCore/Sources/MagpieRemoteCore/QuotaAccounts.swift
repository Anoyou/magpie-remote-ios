import Foundation

/// 额度页上「一个来源账号」：主机按 `from|provider|小写 user` 区分账号（即 `QuotaCard.id`），
/// 同一个账号的卡片收在一起，默认折叠成一行摘要，点开再看明细。
public struct QuotaAccount: Hashable, Identifiable, Sendable {
    public var id: String
    public var cards: [QuotaCard]

    public init(id: String, cards: [QuotaCard]) {
        self.id = id
        self.cards = cards
    }

    /// 保持主机返回的顺序：账号按首次出现排序，账号内按原顺序。
    public static func group(_ cards: [QuotaCard]) -> [QuotaAccount] {
        var order: [String] = []
        var map: [String: [QuotaCard]] = [:]
        for card in cards {
            if map[card.id] == nil { order.append(card.id) }
            map[card.id, default: []].append(card)
        }
        return order.map { QuotaAccount(id: $0, cards: map[$0] ?? []) }
    }

    private var primary: QuotaCard? { cards.first }

    public var provider: String { primary?.provider ?? "" }
    /// 供应商显示名（「Claude」「DeepSeek」）。
    public var providerName: String { primary?.name ?? provider }
    /// 主机给的图标名（claude / codex / …），没有时用供应商 id。
    public var icon: String { primary?.icon ?? provider }
    /// 折叠行左侧的字母标记：供应商显示名的第一个字母或汉字。
    public var monogram: String {
        let source = providerName.trimmingCharacters(in: .whitespaces)
        return source.first.map { String($0).uppercased() } ?? "?"
    }
    /// 账号名：别名 > 账号 > 套餐名 > 供应商名。
    public var title: String { primary?.accountLabel ?? providerName }

    /// 折叠行的第二行开头：供应商名与套餐（和账号名重复的部分不再显示）。
    public var subtitle: String {
        var parts: [String] = []
        if providerName != title { parts.append(providerName) }
        if let plan = primary?.plan, plan != title, !parts.contains(plan) { parts.append(plan) }
        return parts.joined(separator: " · ")
    }

    /// 所有卡片里最紧张的窗口剩余百分比。
    public var lowestRemaining: Double? { cards.compactMap(\.lowestRemaining).min() }
    public var balanceText: String? { cards.lazy.compactMap(\.balanceText).first }
    public var problem: String? { cards.lazy.compactMap(\.problem).first }
    public var hasMeteredWindows: Bool { cards.contains { !$0.meteredWindows.isEmpty } }
    public var isUnlimited: Bool { !cards.isEmpty && cards.allSatisfy { !$0.windows.isEmpty && $0.windows.allSatisfy(\.unlimited) } }
    /// 能否让这台主机重新读取（别的 magpie 转来的账号不行）。
    public var canRefresh: Bool { cards.contains(where: \.canRefresh) }
    /// 拿来重新读取的那张卡片（provider + user 定位账号）。
    public var refreshCard: QuotaCard? { cards.first(where: \.canRefresh) }
    /// 这个账号的历史曲线匹配键。
    public var historyKeys: Set<String> { Set(cards.map(\.historyKey)) }

    /// 最近一次重置时间（只看还没到的；都到了就取最晚那个，界面会显示「等待主机更新」）。
    public func nearestReset(now: Date = Date()) -> Date? {
        let dates = cards.flatMap { card in card.windows.compactMap { $0.resetDate(readAt: card.readAt) } }
        if let upcoming = dates.filter({ $0 > now }).min() { return upcoming }
        return dates.max()
    }

    public enum Status: String, Hashable, Sendable {
        /// 额度充足。
        case ok
        /// 剩余不多（≤ 25%）。
        case low
        /// 快用完或已用完（≤ 10%）。
        case critical
        /// 读不到 / 需要补填访问密钥。
        case problem
        /// 只有余额或不限量，没有百分比可比。
        case neutral
    }

    public var status: Status {
        if let lowest = lowestRemaining {
            if lowest <= 10 { return .critical }
            if problem != nil { return .problem }
            if lowest <= 25 { return .low }
            return .ok
        }
        if problem != nil { return .problem }
        return .neutral
    }

    /// 折叠行的一行摘要：「剩余 8% · 47 分钟后重置」「余额 ¥ 23.71」「读取失败：…」。
    public func summary(now: Date = Date()) -> String {
        var parts: [String] = []
        if let lowest = lowestRemaining {
            parts.append("最低剩余 \(QuotaFormat.percent(lowest))")
        } else if let balance = balanceText {
            parts.append("余额 \(balance)")
        } else if isUnlimited {
            parts.append("不限量")
        }
        if let reset = nearestReset(now: now) {
            if let relative = QuotaFormat.relative(to: reset, now: now) {
                parts.append("\(relative)重置")
            } else {
                parts.append("已到重置时间")
            }
        }
        if parts.isEmpty, let problem { return problem }
        if problem != nil { parts.append("有问题") }
        return parts.isEmpty ? "暂无额度数据" : parts.joined(separator: " · ")
    }
}

/// 额度页里哪些账号是展开的。只在本次运行中记住（切换标签、刷新后保持），重新打开 App 时全部折叠。
public struct QuotaExpansion: Hashable, Sendable {
    public private(set) var expanded: Set<String> = []

    public init() {}

    public func isExpanded(_ id: String) -> Bool { expanded.contains(id) }

    public mutating func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    public mutating func set(_ id: String, expanded value: Bool) {
        if value { expanded.insert(id) } else { expanded.remove(id) }
    }
}
