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
