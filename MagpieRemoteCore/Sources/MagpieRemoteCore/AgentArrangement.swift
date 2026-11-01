import Foundation

// 与 magpie 官方网页版 Agent 列表一致（internal/gui/assets/app.js：onMagpie、agentUsed、connectable、arrangeAgents）：
// 「在用」的 Agent 排在上面；什么都没设置的（未设置）和手动隐藏的（已隐藏）收进下面默认折叠的一组。

extension WebAgent {
    /// 有设置文件、但找不到它的命令行程序（可能已卸载）。
    public var cliMissing: Bool { raw["cliMissing"]?.bool ?? false }
    /// 用自己的链接添加 magpie 的 App（例如 Cindy）已经加上了 magpie。
    public var added: Bool { raw["added"]?.bool ?? false }
    /// 曾接入 magpie、但它的配置后来被改掉了。
    public var drifted: Bool { raw["drift"]?.object != nil }
    /// 只靠启动命令接入的 Agent（例如 agy）给的命令。
    public var launch: String { raw["launch"]?.string ?? "" }
    /// 用自己的链接添加 magpie 的 App 的链接。
    public var importLink: String { raw["import"]?.string ?? "" }

    /// 在 magpie 上：已接入、已添加，或接入后被改掉（要修好）。官方 `onMagpie`。
    public var onMagpie: Bool { wired || added || drifted }

    /// magpie 能给它模型（有带 ref 或值为 magpie 的选项，或者它的列表里有 magpie 的模型）。官方 `connectable`。
    public var connectable: Bool {
        guard importLink.isEmpty else { return false }
        let fields = raw["fields"]?.array ?? []
        let hasConnectField = fields.contains { field in
            (field["options"]?.array ?? []).contains { option in
                !(option["ref"]?.string ?? "").isEmpty || option["value"]?.string == "magpie"
            }
        }
        return hasConnectField || (raw["models"]?["listed"]?.int ?? 0) > 0
    }

    /// 「在用」：设置过点什么。官方 `agentUsed`。
    public var isUsed: Bool {
        if cliMissing { return onMagpie }
        if onMagpie { return true }
        if !connectable && fields.contains(where: { !$0.value.isEmpty && !Self.isTweak($0.key) }) { return true }
        return !launch.isEmpty && fields.isEmpty && importLink.isEmpty
    }

    /// 只是调 Agent 自己怎么跑（ultracode、思考强度），不算「设置了模型」。官方 `tweak`。
    static func isTweak(_ key: String) -> Bool {
        key == "ultracode" || key == "effort" || key.hasSuffix("_effort")
    }
}

/// Agent 列表的分组：在用的在上面，其余（未设置、已隐藏）默认折叠。
public struct AgentArrangement: Equatable, Sendable {
    /// 在用的（一个都没在用时是全部未隐藏的）。
    public var shown: [WebAgent]
    /// 什么都没设置的。
    public var notSetUp: [WebAgent]
    /// 在网页版里手动隐藏的。
    public var hidden: [WebAgent]

    /// 折叠起来的数量。
    public var foldedCount: Int { notSetUp.count + hidden.count }

    public init(agents: [WebAgent], order: [String] = [], hidden hiddenIDs: [String] = []) {
        let hiddenSet = Set(hiddenIDs)
        func rank(_ agent: WebAgent) -> Int { order.firstIndex(of: agent.id) ?? order.count }
        let all = agents.enumerated()
            .sorted { lhs, rhs in
                let (a, b) = (rank(lhs.element), rank(rhs.element))
                return a != b ? a < b : lhs.offset < rhs.offset
            }
            .map(\.element)
        // 有能接入的 Agent 时，要有一个在 magpie 上才开始折叠；否则只要有一个设置过就折叠（一台新 magpie 什么都不折叠）。
        let counts: (WebAgent) -> Bool = all.contains(where: \.connectable) ? { $0.onMagpie } : { $0.isUsed }
        let anyUsed = all.contains { !hiddenSet.contains($0.id) && counts($0) }
        func inView(_ agent: WebAgent) -> Bool { !hiddenSet.contains(agent.id) && (!anyUsed || agent.isUsed) }
        shown = all.filter(inView)
        let folded = all.filter { !inView($0) }
        notSetUp = folded.filter { !hiddenSet.contains($0.id) }
        hidden = folded.filter { hiddenSet.contains($0.id) }
    }
}
