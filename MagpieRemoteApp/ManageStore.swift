import Foundation
import Observation
import MagpieRemoteCore

/// 刚拿到、只显示这一次的明文密钥。
struct RevealedSecret: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var secret: String
}

/// 「管理」页的数据与操作。各子页面共用一个实例。
@MainActor
@Observable
final class ManageStore {
    enum Phase: Equatable {
        case noHost
        /// 这台主机还没有填 Web 密钥。
        case noWebKey
        case loading
        case ready
        case failed(MagpieError)
    }

    private(set) var phase: Phase = .noHost
    private(set) var service: (any ManageServing)?
    private(set) var settings: WebSettings?
    /// 主机版本过旧（仍然显示数据，但顶部给出提示）。
    private(set) var incompatible: MagpieError?
    private(set) var providers: [WebProvider] = []
    private(set) var presets: [WebPreset] = []
    private(set) var groups: WebGroups?
    /// 各模型近 7 天的速度（路由组成员旁显示）。
    private(set) var speeds = ModelSpeeds()
    private(set) var agents: [WebAgent] = []
    /// 各 Agent 命令行程序的版本（`GET /api/agents/cli`，读完 Agent 之后再补上，不挡列表）。
    private(set) var clis: [String: AgentCLI] = [:]
    /// 正在更新命令行程序的 Agent。
    private(set) var cliBusy: Set<String> = []
    /// 「全部更新」：点过之后一直显示，直到重新读取 Agent。
    private(set) var updateRun: AgentUpdateRun?
    /// 保存的方案。
    private(set) var profiles: [WebProfile] = []
    /// 操作完成后的一句话（官方网页底部状态栏），几秒后自动消失。
    var status: String?

    /// 弹窗里保存后的一句话：等弹窗收起（约 0.45 秒）再显示在页面底部，否则 4 秒里有一段被弹窗挡着。
    func sayAfterSheet(_ text: String) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            status = text
        }
    }
    private(set) var keys: [WebCallerKey] = []
    /// 网关密钥能限定的账号 id → 显示名。
    private(set) var keyAccountNames: [String: String] = [:]
    private(set) var issued: [IssuedKey] = []
    /// 主机返回的提示（例如切换模型后需要重启 Agent）。
    var notice: String?
    /// 最近一次操作失败的原因（弹窗显示）。
    var actionError: MagpieError?
    /// 新建 / 轮换 / 复制得到的明文。
    var revealed: RevealedSecret?
    private(set) var busy = false
    /// 当前显示中的管理页面（最后一个负责弹窗）。
    var presenters: [String] = []
    private var configuredFor: String?

    var canIssue: Bool { service?.canIssue ?? false }
    /// 当前连接的标识（主机或密钥变了就会变）：依赖服务的子页面用它重建自己的状态。
    var configurationKey: String { configuredFor ?? "none" }

    /// 根据当前主机与密钥选择服务；主机或密钥变了才重新加载。
    func configure(model: AppModel) async {
        guard let host = model.activeHost else {
            reset(.noHost)
            return
        }
        let webKey = model.manageSecret(.webKey)
        let issuer = model.manageSecret(.issuerKey)
        let signature = [host.id.uuidString, host.webURL.absoluteString, host.gatewayURL.absoluteString,
                         webKey ?? "", issuer ?? ""].joined(separator: "|")
        guard signature != configuredFor else { return }
        configuredFor = signature
        if model.isFixture {
            service = FixtureManageService.shared
        } else if let webKey, !webKey.isEmpty {
            service = LiveManageService(host: host, webKey: webKey, issuerKey: issuer)
        } else {
            reset(.noWebKey)
            return
        }
        providers = []; groups = nil; agents = []; keys = []; issued = []
        clis = [:]; cliBusy = []; updateRun = nil; profiles = []
        await refresh()
    }

    private func reset(_ phase: Phase) {
        service = nil
        configuredFor = nil
        settings = nil; incompatible = nil
        providers = []; groups = nil; agents = []; keys = []; issued = []
        clis = [:]; cliBusy = []; updateRun = nil; profiles = []
        self.phase = phase
    }

    /// 重新读取全部数据。先读版本：连不上或密钥不对时整页显示错误。
    func refresh() async {
        guard let service else { return }
        if phase != .ready { phase = .loading }
        do {
            let settings = try await service.settings()
            self.settings = settings
            incompatible = MagpieCompatibility.check(hostVersion: settings.version)
        } catch {
            phase = .failed(MagpieError.from(error))
            return
        }
        async let providers = service.providers()
        async let groups = service.groups()
        async let state = service.state()
        async let keys = service.callerKeys()
        async let issued = service.issuedKeys()
        do {
            apply(try await providers)
            self.groups = try await groups
            let agentState = try await state
            agents = agentState.agents
            profiles = agentState.profiles
            if updateRun?.running != true { updateRun = nil } // 官方：重新读取 Agent 后那一行只留还有的更新
            let keyList = try await keys
            self.keys = keyList.keys
            keyAccountNames = keyList.accountNames
            self.issued = (try? await issued) ?? []
            phase = .ready
            speeds = (try? await service.modelSpeeds()) ?? speeds
            Task { await self.loadCLIs() }
        } catch {
            phase = .failed(MagpieError.from(error))
        }
    }

    private func apply(_ list: WebProviders) {
        providers = list.providers
        if !list.presets.isEmpty { presets = list.presets.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    }

    /// 执行一个写操作：期间 busy，失败时弹出错误。返回是否成功。
    @discardableResult
    private func run(_ operation: (any ManageServing) async throws -> Void) async -> Bool {
        guard let service else { return false }
        busy = true
        defer { busy = false }
        do {
            try await operation(service)
            return true
        } catch {
            let error = MagpieError.from(error)
            if error != .cancelled { actionError = error }
            return false
        }
    }

    func provider(_ id: String) -> WebProvider? { providers.first { $0.id == id } }

    // MARK: 供应商

    @discardableResult
    func saveProvider(_ provider: WebProvider, edits: WebRequests.ProviderEdits) async -> Bool {
        await run { service in
            self.apply(try await service.provider(.save, WebRequests.providerSave(provider, edits: edits)))
        }
    }

    func setModel(_ model: String, on: Bool, in provider: WebProvider) async {
        await saveProvider(provider, edits: .init(enabledModels: WebRequests.toggledModels(provider, model: model, on: on)))
    }

    @discardableResult
    func addProvider(name: String, chat: String, key: String, preset: String?) async -> Bool {
        await run { service in
            self.apply(try await service.provider(.save, WebRequests.providerAdd(name: name, chat: chat, key: key, preset: preset)))
        }
    }

    @discardableResult
    func deleteProvider(_ id: String) async -> Bool {
        await run { service in self.apply(try await service.provider(.delete, WebRequests.providerID(id))) }
    }

    func setProvider(_ id: String, enabled: Bool) async {
        await run { service in self.apply(try await service.provider(enabled ? .on : .off, WebRequests.providerID(id))) }
    }

    /// 供应商「测试」：不经过 busy（其它操作照常），失败时弹出错误并返回 nil。
    func testProvider(_ id: String) async -> [ProviderTestResult]? {
        guard let service else { return nil }
        do {
            return try await service.testProvider(id)
        } catch {
            let error = MagpieError.from(error)
            if error != .cancelled { actionError = error }
            return nil
        }
    }

    func refetchModels(_ id: String) async {
        await run { service in self.apply(try await service.provider(.models, WebRequests.providerID(id))) }
    }

    // MARK: 供应商的 Key

    /// 一把 Key 的操作（添加、批量添加、设为首选、改名、换值、启用 / 停用、删除）。成功后列表换成主机返回的，
    /// 并把它交给调用方（批量添加要读 added / had）；失败弹出错误、返回 nil。
    @discardableResult
    func providerKeys(_ action: ProviderKeyAction, _ body: WebJSON) async -> WebProviders? {
        var result: WebProviders?
        await run { service in
            let list = try await service.providerKeys(action, body)
            self.apply(list)
            result = list
        }
        return result
    }

    /// 按需取一把 Key 的明文（显示 / 复制用）。不经过 busy，不缓存；失败时弹出错误并返回 nil。
    func providerKeySecret(_ provider: String, key: String?) async -> String? {
        guard let service else { return nil }
        do {
            return try await service.providerKeySecret(provider, account: key)
        } catch {
            let error = MagpieError.from(error)
            if error != .cancelled { actionError = error }
            return nil
        }
    }

    /// 列表拖动排序：先在本地挪动，再提交；失败时恢复主机的顺序。
    func moveProviders(from source: IndexSet, to destination: Int) async {
        var order = providers
        order.move(fromOffsets: source, toOffset: destination)
        providers = order
        let ok = await run { service in self.apply(try await service.arrangeProviders(order.map(\.id))) }
        if !ok { await refresh() }
    }

    // MARK: 路由组

    @discardableResult
    func saveGroup(_ group: WebGroup?, id: String, name: String, members: [String]) async -> Bool {
        await run { service in
            self.groups = try await service.group(.save, WebRequests.groupSave(group, id: id, name: name, members: members))
        }
    }

    @discardableResult
    func deleteGroup(_ id: String) async -> Bool {
        await run { service in self.groups = try await service.group(.delete, WebRequests.groupDelete(id)) }
    }

    func setGroup(_ id: String, on: Bool) async {
        await run { service in self.groups = try await service.group(.switch, WebRequests.groupSwitch(id, on: on)) }
    }

    /// 整组保存，只改 `edits` 里给出的设置。
    @discardableResult
    func saveGroup(_ group: WebGroup?, edits: GroupEdits) async -> Bool {
        await run { service in
            self.groups = try await service.group(.save, WebRequests.groupSave(group, edits: edits))
        }
    }

    func pickGroupMember(_ id: String, member: String) async {
        await run { service in self.groups = try await service.group(.pick, WebRequests.groupPick(id, member: member)) }
    }

    func copyGroup(_ group: WebGroup) async {
        await run { service in self.groups = try await service.group(.copy, WebRequests.groupCopy(group.id, name: group.name + " 副本")) }
    }

    func setFoundGroups(_ on: Bool) async {
        await run { service in self.groups = try await service.group(.found, WebRequests.groupFound(on)) }
    }

    /// 拖动调整路由组顺序：先在本地挪动，再提交；失败时恢复主机的顺序。
    func moveGroups(from source: IndexSet, to destination: Int) async {
        guard let groups else { return }
        let order = groups.order(moving: source, to: destination)
        var local = groups
        local.groups = order.compactMap { id in groups.groups.first { $0.id == id } }
        self.groups = local
        let ok = await run { service in self.groups = try await service.group(.arrange, WebRequests.groupArrange(order)) }
        if !ok { await refresh() }
    }

    /// 多账号 / 多 Key 供应商自己的路由设置；改完重新读路由组（pools 在里面）。
    func setPool(_ provider: String, routing: GroupRouting? = nil, affinity: GroupAffinity? = nil, sink: Bool? = nil) async {
        await run { service in
            if let routing { self.apply(try await service.provider(.route, WebRequests.providerRouting(provider, routing: routing))) }
            if let affinity { self.apply(try await service.provider(.affinity, WebRequests.providerAffinity(provider, affinity: affinity))) }
            if let sink { self.apply(try await service.provider(.sink, WebRequests.providerSink(provider, sink: sink))) }
            self.groups = try await service.groups()
        }
    }

    func refreshSpeeds() async {
        guard let service else { return }
        if let speeds = try? await service.modelSpeeds() { self.speeds = speeds }
    }

    // MARK: Agent

    func setAgent(_ agent: String, field: String, value: String) async {
        await run { service in
            let state = try await service.setAgent(agent, field: field, value: value)
            self.apply(state)
            if let notice = state.notice { self.notice = notice }
        }
    }

    private func apply(_ state: WebState) {
        agents = state.agents
        profiles = state.profiles
    }

    private func agentName(_ id: String) -> String { agents.first { $0.id == id }?.name ?? id }

    /// 读各 Agent 命令行程序的版本；主机说还有在问的（pending），过 4 秒再读，最多 3 次（官方 loadCLIs）。
    func loadCLIs(again: Int = 0) async {
        guard let service, let result = try? await service.agentCLIs() else { return }
        clis = result.agents
        if result.pending && again < 3 {
            try? await Task.sleep(for: .seconds(4))
            await loadCLIs(again: again + 1)
        }
    }

    /// 能更新的（有新版本、没在更新）。
    var updatable: [WebAgent] { agents.filter { clis[$0.id]?.update == true && !cliBusy.contains($0.id) } }

    /// 更新一个 Agent 的命令行程序。`quiet`（全部更新时）不弹提示，返回失败原因；成功返回 nil。
    @discardableResult
    func updateCLI(_ id: String, quiet: Bool = false) async -> String? {
        let name = agentName(id)
        guard let service else { return nil }
        if cliBusy.contains(id) { return "\(name) 正在更新" }
        let from = clis[id]?.version
        cliBusy.insert(id)
        defer { cliBusy.remove(id) }
        do {
            let cli = try await service.updateAgentCLI(id)
            clis[id] = cli
            if quiet { updateRun?.changed.append(AgentCLIText.change(agent: name, from: from, to: cli.version)) }
            else { status = AgentCLIText.updated(agent: name, from: from, to: cli.version) }
            return nil
        } catch {
            let error = MagpieError.from(error)
            if !quiet, error != .cancelled { actionError = error }
            cliBusy.remove(id)
            await loadCLIs() // 现在是什么版本
            return error.message
        }
    }

    /// 「全部更新」：一个接一个（两个全局 npm 安装同时跑会互相踩到目录）。
    func updateAllCLIs() async {
        if updateRun?.running == true { return }
        let list = updatable
        guard !list.isEmpty else { return }
        updateRun = AgentUpdateRun(names: list.map(\.name))
        for agent in list {
            updateRun?.now = agent.name
            if let message = await updateCLI(agent.id, quiet: true) {
                updateRun?.failed.append(.init(name: agent.name, message: message))
            }
            updateRun?.done += 1
        }
        guard let run = updateRun else { return }
        if run.failed.isEmpty { status = run.summary } else { actionError = .webRejected(message: run.failed.map(\.message).joined(separator: " · "), code: nil) }
    }

    /// 重新查找这台电脑上的 Agent（官方右上角的刷新），再读版本。
    func rescanAgents() async {
        let ok = await run { service in self.apply(try await service.rescanAgents()) }
        guard ok else { return }
        updateRun = nil
        status = "已重新检测 Agent"
        await loadCLIs()
    }

    /// 打开「接入 magpie」开关。
    func connectAgent(_ id: String) async {
        await run { service in
            let state = try await service.agentAction(.connect, id)
            self.apply(state)
            let agent = state.agents.first { $0.id == id }
            self.status = agent?.connectedSaid(how: state.connectedHow) ?? "\(self.agentName(id)) 已接入 magpie"
        }
    }

    /// 断开并还原接入前的设置（调用方先确认）。
    func disconnectAgent(_ id: String) async {
        let name = agentName(id)
        await run { service in
            self.apply(try await service.agentAction(.disconnect, id))
            self.status = "\(name) 已不再经过 magpie，原来的设置已还原"
        }
    }

    /// 把 magpie 设的值重新写回去（「重新应用」）。
    func reapplyAgent(_ id: String) async {
        let name = agentName(id)
        await run { service in
            let state = try await service.agentAction(.reapply, id)
            self.apply(state)
            self.status = "\(name) 已重新经过 magpie"
            if let notice = state.notice { self.notice = notice }
        }
    }

    /// 「保留当前设置」：接受在 magpie 之外换掉的模型。
    func keepAgent(_ id: String) async {
        await run { service in self.apply(try await service.agentAction(.keep, id)) }
    }

    func disconnectPreview(_ id: String) async throws -> AgentDisconnectPreview {
        guard let service else { throw MagpieError.cancelled }
        return try await service.agentDisconnectPreview(id)
    }

    /// 方案：保存当前（`update` = 覆盖已有的）、应用、删除。
    func profile(_ action: ProfileAction, name: String, update: Bool = false) async {
        await run { service in
            let state = try await service.profile(action, name: name)
            self.apply(state)
            switch action {
            case .use: self.status = WebProfile.appliedSaid(name: name, changed: state.changed ?? 0)
            case .save: self.status = update ? "已用当前配置更新 \(name)" : "已保存 \(name)"
            case .delete: self.status = "已删除 \(name)"
            }
        }
    }

    // MARK: Agent 排序 / 隐藏、模型列表（对齐官方第二轮）

    private var arrangement: AgentArrangement {
        AgentArrangement(agents: agents, order: settings?.agentOrder ?? [], hidden: settings?.agentsHidden ?? [])
    }

    /// 先在本地改，再提交；失败时恢复（官方 saveArrangement）。
    @discardableResult
    private func saveArrangement(order: [String], hidden: [String]) async -> Bool {
        let previous = settings
        settings?.agentOrder = order
        settings?.agentsHidden = hidden
        let ok = await run { service in
            self.settings = try await service.arrangeAgents(order: order, hidden: hidden, shown: [])
        }
        if !ok { settings = previous }
        return ok
    }

    /// 上移 / 下移：在上面那组里挪到第 `to` 个（官方 moveAgent）。
    func moveAgent(_ id: String, to: Int) async {
        guard let order = arrangement.moving(id, to: to) else { return }
        await saveArrangement(order: order, hidden: settings?.agentsHidden ?? [])
    }

    /// 隐藏 / 显示（官方 setAgentHidden）。
    func setAgentHidden(_ agent: WebAgent, hide: Bool) async {
        let next = AgentArrange.hiding(agent, hide: hide, all: agents, order: settings?.agentOrder ?? [], hidden: settings?.agentsHidden ?? [])
        guard await saveArrangement(order: next.order, hidden: next.hidden) else { return }
        let stillFolded = !hide && !arrangement.shown.contains { $0.id == agent.id }
        status = AgentArrange.said(agent, hide: hide, stillFolded: stillFolded)
    }

    /// 读一个 Agent 的模型列表。失败弹出错误并返回 nil。
    func agentModels(_ id: String) async -> AgentModelList? {
        guard let service else { return nil }
        do {
            return try await service.agentModels(id)
        } catch {
            let error = MagpieError.from(error)
            if error != .cancelled { actionError = error }
            return nil
        }
    }

    /// 改一个 Agent 的模型列表（不经过 busy，一个接一个地发）；成功后重读 Agent（数量、选择器里的模型会变）。
    @discardableResult
    func setAgentModels(_ id: String, _ body: WebJSON) async -> WebJSON? {
        guard let service else { return nil }
        do {
            let answer = try await service.setAgentModels(id, body)
            if let state = try? await service.state() { apply(state) }
            return answer
        } catch {
            let error = MagpieError.from(error)
            if error != .cancelled { actionError = error }
            return nil
        }
    }

    // MARK: 停用的模型

    @discardableResult
    func setDisabledModels(_ models: [String]) async -> Bool {
        await run { service in self.settings = try await service.setDisabledModels(models) }
    }

    // MARK: 测试模型

    /// 「测试模型」：不经过 busy；失败（含「停止」）返回 nil，停止不弹错误。
    func testProviderModels(_ id: String, models: [String], run: String) async -> [ProviderTestResult]? {
        guard let service else { return nil }
        do {
            return try await service.testProviderModels(id, models: models, run: run)
        } catch {
            let error = MagpieError.from(error)
            if error != .cancelled { actionError = error }
            return nil
        }
    }

    func stopProviderTest(run: String) async {
        try? await service?.stopProviderTest(run: run)
    }

    /// 网关密钥能限定的模型与账号。失败弹出错误并返回 nil。
    func callerKeyModels() async -> CallerKeyModels? {
        guard let service else { return nil }
        do {
            return try await service.callerKeyModels()
        } catch {
            let error = MagpieError.from(error)
            if error != .cancelled { actionError = error }
            return nil
        }
    }

    // MARK: 网关密钥

    /// 网关密钥操作。`reveal` 为 false 时不弹出明文，而是作为返回值交给调用方（新建密钥的表单自己显示）。
    @discardableResult
    func callerKey(_ action: CallerKeyAction, _ body: WebJSON, title: String = "", reveal: Bool = true) async -> (ok: Bool, secret: RevealedSecret?) {
        var revealed: RevealedSecret?
        let ok = await run { service in
            let result = try await service.callerKey(action, body)
            self.keys = result.keys
            if !result.accountNames.isEmpty { self.keyAccountNames = result.accountNames }
            if let secret = result.secret { revealed = RevealedSecret(title: title, secret: secret) }
        }
        if reveal, let revealed { self.revealed = revealed }
        return (ok, reveal ? nil : revealed)
    }

    func issueKey(name: String, ttl: String) async -> RevealedSecret? {
        var revealed: RevealedSecret?
        await run { service in
            let key = try await service.issueKey(name: name, ttl: ttl)
            revealed = RevealedSecret(title: "临时密钥「\(key.name)」", secret: key.key)
            self.issued = (try? await service.issuedKeys()) ?? self.issued
        }
        return revealed
    }

    func revokeIssued(_ id: String) async {
        await run { service in
            try await service.revokeIssuedKey(id)
            self.issued = (try? await service.issuedKeys()) ?? self.issued.filter { $0.id != id }
        }
    }
}
