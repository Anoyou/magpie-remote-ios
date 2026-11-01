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
    private(set) var keys: [WebCallerKey] = []
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
        await refresh()
    }

    private func reset(_ phase: Phase) {
        service = nil
        configuredFor = nil
        settings = nil; incompatible = nil
        providers = []; groups = nil; agents = []; keys = []; issued = []
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
            agents = try await state.agents
            self.keys = try await keys.keys
            self.issued = (try? await issued) ?? []
            phase = .ready
            speeds = (try? await service.modelSpeeds()) ?? speeds
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
            self.agents = state.agents
            if let notice = state.notice { self.notice = notice }
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
