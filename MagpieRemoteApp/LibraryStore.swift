import Foundation
import Observation
import MagpieRemoteCore

/// 「资源库」页的数据与操作（照官方 plugins/library/client.js 的 load / change / chipsChange / report）。
@MainActor
@Observable
final class LibraryStore {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(MagpieError)
    }

    let service: any LibraryServing
    private(set) var phase: Phase = .loading
    private(set) var page: LibrarySnapshot?
    /// magpie 里把资源库关掉了（官方此时导航里没有资源库，只有「启用资源库」）。
    private(set) var turnedOff = false
    /// 正在跑的改动（按钮变灰，和官方 change() 期间禁用按钮一样）。
    private(set) var busy = false
    /// 底部状态栏的一句话（官方 status）。
    var status: String?
    var statusIsWarning = false
    /// 失败的原因（弹窗显示）。
    var failure: String?
    /// 在 Agent 页隐藏的 Agent（官方 isHidden）：这里也不列出，已有的东西留着。
    var hidden: [String] = []
    /// 有资格弹出失败弹窗的页面（最上面的那个弹，见 libraryAlerts）。
    var presenters: [String] = []

    var tab: LibraryTab {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: LibraryTab.defaultsKey) }
    }

    // MARK: MCP 服务器的检测结果（每个会话检测一次，改过再检测）
    private(set) var health: [String: LibraryServerHealth] = [:]
    private(set) var checking: Set<String> = []
    private var checkedKeys: [String: String] = [:]

    // MARK: RTK
    private(set) var rtk: LibraryRTK?
    private(set) var rtkBusy: Set<String> = []
    private(set) var rtkStep: LibraryRTKStep?
    private(set) var rtkError: String?

    /// 一行 Agent 的改动：点击马上显示，同一行一次只写一份，期间的点击合并成最后一次（官方 chipsChange）。
    private var pendingAgents: [String: [String]] = [:]
    private var writingAgents: Set<String> = []

    /// 技能的「检查更新」「重新分组」正在进行。
    private(set) var checkingSkills = false
    private(set) var regrouping = false
    private(set) var updatingAll = false
    private var autoChecked = false

    init(service: any LibraryServing) {
        self.service = service
        tab = LibraryTab(stored: UserDefaults.standard.string(forKey: LibraryTab.defaultsKey))
    }

    /// 「启用资源库」。
    func enable() async {
        guard !busy else { return }
        busy = true
        do {
            try await service.enableLibrary()
            busy = false
            say("资源库已启用")
            await load()
        } catch {
            busy = false
            failure = MagpieError.from(error).message
        }
    }

    func say(_ text: String, warn: Bool = false) {
        statusIsWarning = warn
        status = text
    }

    func name(of id: String) -> String { page?.name(of: id) ?? id }

    // MARK: 读取

    /// 先读「一瞥」马上显示，再读整页（官方 load：glance 后 full）。
    func load() async {
        turnedOff = await service.libraryEnabled() == false
        if turnedOff { phase = .ready; return }
        if page == nil {
            phase = .loading
            if let glance = try? await service.page(glance: true) { take(glance) }
        }
        await refresh()
    }

    func refresh() async {
        do {
            take(try await service.page(glance: false))
            phase = .ready
            if page?.checkDue == true, !autoChecked, page?.skills.contains(where: { $0.kind == "github" || $0.kind == "git" }) == true {
                // 官方：很久没检查过时，打开技能就自己检查一次（#1449）
                autoChecked = true
                Task { await checkSkills(quiet: true) }
            }
        } catch {
            let error = MagpieError.from(error)
            if page == nil { phase = .failed(error) } else { say(error.message, warn: true) }
        }
    }

    private func take(_ next: LibrarySnapshot) {
        var next = next
        // 还在写的行保持最后一次点击的样子
        for (key, want) in pendingAgents { apply(want, key: key, to: &next) }
        page = next
        if phase != .ready, !next.partial { phase = .ready }
        if next.partial, phase == .loading { phase = .ready }
    }

    // MARK: 改动

    /// 资源库的一个改动；成功后说 `done`（或按结果说），失败弹窗。返回是否成功。
    @discardableResult
    func run(_ action: LibraryAction, _ body: WebJSON, done: String? = nil, given: [String]? = nil) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            let next = try await service.change(action, body, current: page)
            take(next)
            if let said = LibraryWords.report(next.result, done: done, given: given, name: name(of:)) { say(said.text, warn: said.warn) }
            return true
        } catch {
            failure = MagpieError.from(error).message
            return false
        }
    }

    // MARK: 一行的 Agent

    private func key(_ action: LibraryAction, _ name: String) -> String { action.rawValue + "\n" + name }

    /// 行上显示的 Agent：在写的那次点击，或主机给的。
    func agents(_ action: LibraryAction, _ name: String, current: [String]) -> [String] {
        pendingAgents[key(action, name)] ?? current
    }

    private func apply(_ want: [String], key: String, to page: inout LibrarySnapshot) {
        let parts = key.split(separator: "\n", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let name = parts[1]
        switch parts[0] {
        case LibraryAction.serversAgents.rawValue:
            if let i = page.servers.firstIndex(where: { $0.name == name }) { page.servers[i].agents = want }
        case LibraryAction.skillsAgents.rawValue:
            if let i = page.skills.firstIndex(where: { $0.name == name }) { page.skills[i].agents = want }
        case LibraryAction.hooksAgents.rawValue:
            if let i = page.hooks.firstIndex(where: { $0.name == name }) { page.hooks[i].agents = want }
        case LibraryAction.subagentsAgents.rawValue:
            if let i = page.subagents.firstIndex(where: { $0.name == name }) { page.subagents[i].agents = want }
        default: break
        }
    }

    /// 一行的 Agent 改成 `want`。`allChip` = 点的是「全部」（成功后说全部启用 / 移除）。
    func setAgents(_ action: LibraryAction, name: String, to want: [String], allChip: Bool = false) {
        let k = key(action, name)
        pendingAgents[k] = want
        if var p = page { apply(want, key: k, to: &p); page = p }
        guard !writingAgents.contains(k) else { return }
        writingAgents.insert(k)
        Task {
            var sent: [String]?
            var failed = false
            while let wanted = pendingAgents[k], sent.map({ Set($0) != Set(wanted) }) ?? true {
                sent = wanted
                do {
                    let next = try await service.change(action, LibraryRequests.agents(name, wanted), current: page)
                    let same = pendingAgents[k].map { Set($0) == Set(wanted) } ?? true
                    if same { pendingAgents[k] = nil }
                    take(next)
                    if same {
                        if allChip, next.result?.problems.isEmpty ?? true {
                            say(LibraryWords.allSaid(name, on: wanted.count))
                        } else if let said = LibraryWords.report(next.result, done: nil, given: wanted, name: self.name(of:)) {
                            say(said.text, warn: said.warn)
                        }
                    }
                } catch {
                    failed = true
                    pendingAgents[k] = nil
                    say(MagpieError.from(error).message, warn: true)
                    break
                }
            }
            writingAgents.remove(k)
            if failed { await refresh() }
        }
    }

    // MARK: MCP 服务器

    private func healthKey(_ s: LibraryServer) -> String {
        [s.transport, s.command, s.args.joined(separator: " "), s.url, s.env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","),
         s.headers.keys.sorted().joined(separator: ","), String(s.signedIn), s.agents.sorted().joined(separator: ",")].joined(separator: "|")
    }

    /// 检测有 Agent 用着、还没检测过（或改过）的服务器（官方 inUse + checkHealth）。
    func checkServersInUse() {
        guard let page else { return }
        let due = page.servers.filter { s in
            let inUse = !s.agents.isEmpty || page.projects.contains { $0.servers[s.name] != nil }
            return (inUse || health[s.name] != nil) && checkedKeys[s.name] != healthKey(s) && !checking.contains(s.name)
        }
        guard !due.isEmpty else { return }
        Task { await check(due.map(\.name), fresh: false) }
    }

    func check(_ names: [String], fresh: Bool) async {
        guard let page else { return }
        let names = names.filter { !checking.contains($0) }
        guard !names.isEmpty else { return }
        checking.formUnion(names)
        defer { checking.subtract(names) }
        do {
            let got = try await service.checkServers(names, fresh: fresh)
            for (name, h) in got { health[name] = h }
            for s in page.servers where names.contains(s.name) { checkedKeys[s.name] = healthKey(s) }
        } catch {
            say(MagpieError.from(error).message, warn: true)
        }
    }

    func signOut(_ name: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            take(try await service.signOut(name))
            health[name] = nil
            checkedKeys[name] = nil
            say("已退出 \(name) 的登录")
        } catch {
            failure = MagpieError.from(error).message
        }
    }

    func serversConfig(agent: String, names: [String]) async -> (file: String, text: String, skipped: [String])? {
        do { return try await service.serversConfig(agent: agent, names: names) } catch {
            failure = MagpieError.from(error).message
            return nil
        }
    }

    // MARK: 技能

    func checkSkills(quiet: Bool = false) async {
        guard !checkingSkills else { return }
        checkingSkills = true
        defer { checkingSkills = false }
        do {
            let next = try await service.checkSkills()
            take(next)
            if !quiet || !next.skillsWithUpdates.isEmpty { say(LibraryWords.checked(next)) }
        } catch {
            if !quiet { failure = MagpieError.from(error).message }
        }
    }

    func regroupSkills() async {
        guard !regrouping else { return }
        regrouping = true
        defer { regrouping = false }
        do {
            let next = try await service.regroupSkills()
            take(next)
            say(next.regrouped.map { $0 > 0 ? "已重新分组：\($0) 个技能归入分组" : "分组没有变化" } ?? "已重新分组")
        } catch {
            failure = MagpieError.from(error).message
        }
    }

    func updateAllSkills() async {
        guard !updatingAll, !busy else { return }
        updatingAll = true
        busy = true
        defer { updatingAll = false; busy = false }
        do {
            let next = try await service.change(.skillsUpdateAll, [:], current: page)
            take(next)
            let said = LibraryWords.updatedAll(next)
            say(said.text, warn: said.warn)
        } catch {
            failure = MagpieError.from(error).message
        }
    }

    func skillText(_ name: String) async throws -> String { try await service.skillText(name) }
    func probe(_ source: String) async throws -> LibraryProbe { try await service.probe(source: source) }
    func marketServers(_ query: String) async throws -> LibraryMarket<LibraryMarketServer> { try await service.marketServers(query) }
    func marketSkills(_ query: String) async throws -> LibraryMarket<LibraryMarketSkill> { try await service.marketSkills(query) }

    // MARK: RTK

    func loadRTK(force: Bool = false) async {
        if rtk != nil && !force { return }
        do {
            rtk = try await service.rtk()
            rtkError = nil
        } catch {
            rtkError = MagpieError.from(error).message
        }
    }

    func setRTK(_ agent: LibraryRTK.Agent, on: Bool) async {
        guard !rtkBusy.contains(agent.id) else { return }
        rtkBusy.insert(agent.id)
        defer { rtkBusy.remove(agent.id) }
        do {
            rtk = try await service.setRTK(agent: agent.id, on: on)
            say(on ? "已为 \(agent.name) 打开 RTK，重启后生效" : "已为 \(agent.name) 关闭 RTK，重启后生效")
        } catch {
            failure = MagpieError.from(error).message
            await loadRTK(force: true)
        }
    }

    func rtk(_ step: LibraryRTKStep) async {
        guard rtkStep == nil else { return }
        rtkStep = step
        defer { rtkStep = nil }
        do {
            let next = try await service.rtk(step)
            rtk = next
            switch step {
            case .upgrade: say(next.behind ? "RTK 升级失败，原因见 RTK 卡片" : "RTK 已升级到 \(next.version)", warn: next.behind)
            case .install: say(next.installed ? "RTK 已安装 — 在下方为你的 agent 打开" : "安装失败", warn: !next.installed)
            case .path: say(next.offPath ? "仍不在 PATH 中" : "RTK 已加到 PATH", warn: next.offPath)
            }
        } catch {
            switch step {
            case .upgrade: failure = "升级失败：" + MagpieError.from(error).message
            case .install: failure = "安装失败：" + MagpieError.from(error).message
            case .path: failure = MagpieError.from(error).message
            }
        }
    }
}
