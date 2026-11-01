import Foundation

// 主屏 / 锁屏小组件的数据快照。
//
// 数据流（见 docs/widgets.md）：App 在前台读到额度、今日用量、并发后，把**不含任何密钥**的快照
// 写进 App Group 共享目录，再让 WidgetKit 重载时间线；小组件只读这份快照，自己不联网、不碰钥匙串。
// 自签（Sideloadly / AltStore）时 App Group 可能被改名或没开通，小组件读不到快照就显示「打开 App 刷新」。

/// 写进 App Group 的整份快照（JSON）。只放显示用的文字和数字，不放密钥、主机地址或请求内容。
public struct WidgetSnapshot: Codable, Hashable, Sendable {
    /// 快照格式版本。小组件遇到比自己新的版本就当作没有快照（提示打开 App 刷新），不去猜字段。
    public static let currentVersion = 1

    public var version: Int
    /// App 生成这份快照的时间。
    public var generatedAt: Date
    /// 当前主机的名字（用户自己起的，例如「书房 Mac」）；没添加主机时为 nil。
    public var hostName: String?
    public var quota: WidgetQuotaState
    /// 今日用量；读不到（密钥受限、主机没连上）时为 nil。
    public var today: WidgetUsageToday?
    /// 当前并发；读不到时为 nil。
    public var concurrency: WidgetConcurrency?

    public init(version: Int = WidgetSnapshot.currentVersion, generatedAt: Date, hostName: String?,
                quota: WidgetQuotaState, today: WidgetUsageToday? = nil, concurrency: WidgetConcurrency? = nil) {
        self.version = version
        self.generatedAt = generatedAt
        self.hostName = hostName
        self.quota = quota
        self.today = today
        self.concurrency = concurrency
    }

    /// 额度卡片里最多存几个账号（大号小组件最多显示 4 个，多存几个给排序留余地）。
    public static let maxAccounts = 8
    /// 每个账号最多存几个窗口（5 小时、每周、Opus 每周…）。
    public static let maxWindows = 3
}

/// 额度部分的状态。
public enum WidgetQuotaState: Codable, Hashable, Sendable {
    /// 正常读到的账号（可能为空：主机上没有订阅账号）。
    case accounts([WidgetQuotaAccount])
    /// 这把网关密钥受限，主机不给它看账号额度。
    case keyHeld
    /// 没添加主机。
    case noHost
    /// 读取失败（主机连不上等），附中文说明。
    case failed(String)

    public var accounts: [WidgetQuotaAccount] {
        if case .accounts(let list) = self { return list }
        return []
    }

    private enum CodingKeys: String, CodingKey { case state, accounts, message }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .state) {
        case "accounts": self = .accounts(try c.decodeIfPresent([WidgetQuotaAccount].self, forKey: .accounts) ?? [])
        case "keyHeld": self = .keyHeld
        case "noHost": self = .noHost
        default: self = .failed(try c.decodeIfPresent(String.self, forKey: .message) ?? "读取失败")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .accounts(let list):
            try c.encode("accounts", forKey: .state)
            try c.encode(list, forKey: .accounts)
        case .keyHeld: try c.encode("keyHeld", forKey: .state)
        case .noHost: try c.encode("noHost", forKey: .state)
        case .failed(let message):
            try c.encode("failed", forKey: .state)
            try c.encode(message, forKey: .message)
        }
    }
}

/// 一个账号（一张额度卡片）在小组件里显示的内容。
public struct WidgetQuotaAccount: Codable, Hashable, Sendable, Identifiable {
    /// 与 `QuotaAccount.id`（即 `QuotaCard.id`）相同。
    public var id: String
    /// 供应商名，例如「Claude」。
    public var title: String
    /// 账号名：别名 > 账号 > 套餐名。
    public var account: String
    /// 官方标志名（`OfficialIcon.mark` 用）。
    public var icon: String?
    public var windows: [WidgetQuotaWindow]
    /// 余额卡片的显示文字（例如「¥ 23.71」）。
    public var balance: String?
    /// 要提示的问题（读不到、需要补访问密钥）。
    public var problem: String?
    /// 主机读取这个账号的时间（几张卡片里最早的那次）。
    public var readAt: Date?

    public init(id: String, title: String, account: String, icon: String? = nil, windows: [WidgetQuotaWindow] = [],
                balance: String? = nil, problem: String? = nil, readAt: Date? = nil) {
        self.id = id
        self.title = title
        self.account = account
        self.icon = icon
        self.windows = windows
        self.balance = balance
        self.problem = problem
        self.readAt = readAt
    }

    /// 最紧张的窗口剩余百分比（没有可画进度条的窗口时为 nil）。
    public var lowestRemaining: Double? { windows.compactMap(\.remaining).min() }

    /// 最紧张的那个窗口。
    public var tightestWindow: WidgetQuotaWindow? {
        windows.filter { $0.remaining != nil }.min { ($0.remaining ?? 101) < ($1.remaining ?? 101) }
    }

    /// 从额度页的账号转换（同一账号的几张卡片合在一起）：窗口名翻成中文，只留能画进度条或有文字的窗口。
    public init(account: QuotaAccount) {
        var windows: [WidgetQuotaWindow] = []
        var readAt: Date?
        outer: for card in account.cards {
            let cardRead = card.readAt ?? card.asOf
            if let cardRead, readAt.map({ cardRead < $0 }) ?? true { readAt = cardRead }
            for window in card.windows {
                let remaining = window.remainingPercent
                guard remaining != nil || window.display != nil || window.text != nil else { continue }
                windows.append(WidgetQuotaWindow(name: QuotaFormat.windowName(window.name), remaining: remaining,
                                                 resetsAt: window.resetDate(readAt: cardRead), detail: window.display ?? window.text))
                if windows.count == WidgetSnapshot.maxWindows { break outer }
            }
        }
        self.init(id: account.id, title: account.providerName, account: account.title, icon: account.icon, windows: windows,
                  balance: account.balanceText, problem: account.problem, readAt: readAt)
    }

    /// 额度卡片 → 账号（保持主机顺序，最多 `maxAccounts` 个）。
    public static func accounts(from cards: [QuotaCard]) -> [WidgetQuotaAccount] {
        QuotaAccount.group(cards).prefix(WidgetSnapshot.maxAccounts).map(WidgetQuotaAccount.init(account:))
    }
}

/// 一个额度窗口。
public struct WidgetQuotaWindow: Codable, Hashable, Sendable {
    /// 中文窗口名（「5 小时」「每周」）。
    public var name: String
    /// 剩余百分比 0–100；无限 / 只有文字时为 nil。
    public var remaining: Double?
    public var resetsAt: Date?
    /// 供应商自己的计数或文字（「248 / 2000」）。
    public var detail: String?

    public init(name: String, remaining: Double? = nil, resetsAt: Date? = nil, detail: String? = nil) {
        self.name = name
        self.remaining = remaining.map { min(max($0, 0), 100) }
        self.resetsAt = resetsAt
        self.detail = detail
    }
}

/// 今日用量。
public struct WidgetUsageToday: Codable, Hashable, Sendable {
    /// 美元。
    public var cost: Double
    public var tokens: Int
    public var calls: Int
    public var errors: Int
    /// 有调用没有价格（花费可能偏低）。
    public var unpriced: Int

    public init(cost: Double, tokens: Int, calls: Int, errors: Int, unpriced: Int = 0) {
        self.cost = cost
        self.tokens = tokens
        self.calls = calls
        self.errors = errors
        self.unpriced = unpriced
    }

    public init(totals: UsageTotals) {
        self.init(cost: totals.cost, tokens: totals.tokens, calls: totals.calls, errors: totals.errors, unpriced: totals.unpriced)
    }

    /// 失败率 0–1；没有调用时为 nil。
    public var failureRate: Double? { calls > 0 ? Double(errors) / Double(calls) : nil }
}

/// 当前并发。
public struct WidgetConcurrency: Codable, Hashable, Sendable {
    public var requests: Int
    public var waiting: Int

    public init(requests: Int, waiting: Int) {
        self.requests = requests
        self.waiting = waiting
    }

    public init(snapshot: ConcurrencySnapshot) {
        self.init(requests: snapshot.requests, waiting: snapshot.waiting)
    }
}

// MARK: 生成

extension WidgetSnapshot {
    /// 用 App 读到的数据生成快照。账号按主机返回的顺序，最多 `maxAccounts` 个。
    public static func make(hostName: String?, quota: QuotaSnapshot?, quotaError: String? = nil,
                            today: UsageTotals?, concurrency: ConcurrencySnapshot?, now: Date) -> WidgetSnapshot {
        let state: WidgetQuotaState
        if hostName == nil {
            state = .noHost
        } else {
            switch quota {
            case .cards(let cards)?: state = .accounts(WidgetQuotaAccount.accounts(from: cards))
            case .keyHeld?: state = .keyHeld
            case nil: state = .failed(quotaError ?? "读取失败")
            }
        }
        return WidgetSnapshot(generatedAt: now, hostName: hostName, quota: state,
                              today: today.map(WidgetUsageToday.init(totals:)),
                              concurrency: concurrency.map(WidgetConcurrency.init(snapshot:)))
    }

    /// 只更新额度部分（额度页刷新后调用），其余沿用上一份快照。
    public func updatingQuota(_ quota: QuotaSnapshot, now: Date) -> WidgetSnapshot {
        var copy = self
        copy.generatedAt = now
        switch quota {
        case .cards(let cards): copy.quota = .accounts(WidgetQuotaAccount.accounts(from: cards))
        case .keyHeld: copy.quota = .keyHeld
        }
        return copy
    }
}

// MARK: 编解码

public enum WidgetSnapshotCodec {
    /// 共享目录里的文件名。
    public static let fileName = "widget-snapshot.json"

    public static func encode(_ snapshot: WidgetSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }

    /// 解码；损坏、或是更新版本 App 写的快照返回 nil（小组件显示「打开 App 刷新」）。
    public static func decode(_ data: Data) -> WidgetSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data),
              snapshot.version >= 1, snapshot.version <= WidgetSnapshot.currentVersion else { return nil }
        return snapshot
    }
}
