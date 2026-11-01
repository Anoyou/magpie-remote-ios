import Foundation
import Observation
import MagpieRemoteCore

/// 「管理 › 插件」的数据与操作。
@MainActor
@Observable
final class PluginStore {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case failed(MagpieError)
    }

    private(set) var phase: Phase = .idle
    private(set) var service: (any PluginServing)?
    private(set) var state: WebPlugins?
    private(set) var builtins: [WebBuiltinPlugin] = []
    private(set) var pages: [WebPluginPage] = []
    private(set) var panels: [WebPluginPanel] = []
    private(set) var providerOptions: [PluginProviderOption] = []
    private(set) var listings: [WebPluginListing] = []
    private(set) var agents: [String] = []
    private(set) var marketLoading = false
    private(set) var marketError: MagpieError?
    /// 最近一次「检查更新」的结果。
    private(set) var check: WebPluginCheck?
    private(set) var checking = false
    /// 正在进行的操作：spec → 说明（「正在安装…」等）。
    private(set) var working: [String: String] = [:]
    var actionError: MagpieError?
    /// 操作完成后的一句提示。
    var notice: String?
    /// 当前显示中的插件页面（最后一个负责弹窗）。
    var presenters: [String] = []

    var installed: [WebPlugin] { state?.plugins ?? [] }
    var busy: Bool { !working.isEmpty || checking }

    private var configuredFor: String?

    /// 跟随「管理」页的服务：主机或 Web 密钥变了才重新加载。
    func configure(manage: (any ManageServing)?) async {
        let next = makePluginService(for: manage)
        var signature = next == nil ? "none" : "fixture"
        if let live = next as? LivePluginService { signature = "live|\(live.web.baseURL.absoluteString)|\(live.web.key)" }
        guard signature != configuredFor else { return }
        configuredFor = signature
        service = next
        state = nil; builtins = []; pages = []; panels = []; providerOptions = []; listings = []; agents = []; check = nil
        guard next != nil else {
            phase = .idle
            return
        }
        await refresh()
    }

    func refresh() async {
        guard let service else { return }
        if phase != .ready { phase = .loading }
        async let plugins = service.plugins()
        async let builtins = service.builtins()
        async let pages = service.pages()
        async let panels = service.panels()
        async let options = service.providerOptions()
        do {
            state = try await plugins
            self.builtins = try await builtins.plugins
            phase = .ready
        } catch {
            phase = .failed(MagpieError.from(error))
        }
        // 页面、面板、供应商开关读不到时不影响列表。
        self.pages = (try? await pages) ?? self.pages
        self.panels = (try? await panels) ?? self.panels
        providerOptions = (try? await options) ?? providerOptions
        if listings.isEmpty { await loadMarket() }
    }

    /// 读市场（主机缓存的推荐列表）。失败只在「添加插件」里提示。
    func loadMarket() async {
        guard let service, !marketLoading else { return }
        marketLoading = true
        defer { marketLoading = false }
        do {
            listings = try await service.listings().listings
            agents = (try? await service.agents()) ?? []
            marketError = nil
        } catch {
            marketError = MagpieError.from(error)
        }
    }

    // MARK: 查询

    func plugin(_ spec: String) -> WebPlugin? { state?[spec] }
    func builtin(_ id: String) -> WebBuiltinPlugin? { builtins.first { $0.id == id } }
    func listing(for plugin: WebPlugin) -> WebPluginListing? { listings.first { $0.package == plugin.packageName } }
    func pages(for spec: String) -> [WebPluginPage] { pages.filter { $0.spec == spec } }
    func panels(for spec: String) -> [WebPluginPanel] { panels.filter { $0.spec == spec } }
    func providerOptions(for spec: String) -> [PluginProviderOption] { providerOptions.filter { $0.spec == spec } }
    func versionCheck(for spec: String) -> PluginVersionCheck? { check?.checks.first { $0.spec == spec } }

    func isInstalled(_ listing: WebPluginListing) -> Bool { installed.contains { $0.packageName == listing.package } }

    /// 简介：市场里的中文简介，否则插件提供的内容。
    func summary(for plugin: WebPlugin) -> String {
        if let text = listing(for: plugin)?.summary, !text.isEmpty { return text }
        return plugin.kinds.joined(separator: " · ")
    }

    /// 可更新到的版本：检查结果优先，否则主机已知的最新版本。
    func availableUpdate(for plugin: WebPlugin) -> String? {
        if let check = versionCheck(for: plugin.spec) {
            guard check.status == .update else { return nil }
            return check.latest.isEmpty ? (plugin.source == .git ? "最新提交" : "新版本") : check.latest
        }
        guard plugin.hasKnownUpdate else { return nil }
        return plugin.source == .git ? "最新提交" : plugin.latest
    }

    // MARK: 操作

    @discardableResult
    private func run(_ key: String, _ label: String, _ operation: (any PluginServing) async throws -> Void) async -> Bool {
        guard let service, working[key] == nil else { return false }
        working[key] = label
        notice = nil
        defer { working[key] = nil }
        do {
            try await operation(service)
            return true
        } catch {
            let error = MagpieError.from(error)
            if error != .cancelled { actionError = error }
            return false
        }
    }

    /// 插件增减、开关后，页面与供应商开关也会变。
    private func apply(_ next: WebPlugins) async {
        state = next
        guard let service else { return }
        pages = (try? await service.pages()) ?? pages
        panels = (try? await service.panels()) ?? panels
        providerOptions = (try? await service.providerOptions()) ?? providerOptions
    }

    @discardableResult
    func add(_ spec: String) async -> Bool {
        let label = state?.bun == false ? "正在下载 Bun 并安装…" : "正在安装…"
        let ok = await run(spec, label) { service in await self.apply(try await service.plugin(.add, PluginRequests.spec(spec))) }
        if ok { notice = "已安装 \(plugin(spec)?.displayName ?? spec)" }
        return ok
    }

    @discardableResult
    func remove(_ spec: String) async -> Bool {
        let name = plugin(spec)?.displayName ?? spec
        let ok = await run(spec, "正在移除…") { service in await self.apply(try await service.plugin(.remove, PluginRequests.spec(spec))) }
        if ok { notice = "已移除 \(name)" }
        return ok
    }

    func setEnabled(_ spec: String, _ enabled: Bool) async {
        await run(spec, enabled ? "正在启用…" : "正在停用…") { service in
            await self.apply(try await service.plugin(.off, PluginRequests.setEnabled(spec, enabled)))
        }
    }

    @discardableResult
    func saveOptions(_ spec: String, _ options: [String: WebJSON]) async -> Bool {
        await run(spec, "正在保存选项…") { service in
            await self.apply(try await service.plugin(.options, PluginRequests.options(spec, options)))
        }
    }

    func upgrade(_ spec: String) async {
        let ok = await run(spec, "正在更新…") { service in
            await self.apply(try await service.plugin(.upgrade, PluginRequests.spec(spec)))
        }
        if ok {
            check = nil
            let updated = plugin(spec)
            notice = "\(updated?.displayName ?? spec) 已更新" + (updated.map { $0.version.isEmpty ? "" : "到 v\($0.version)" } ?? "")
        }
    }

    func updateAll() async {
        let ok = await run("*", "正在更新全部插件…") { service in
            await self.apply(try await service.plugin(.update, [:]))
        }
        if ok {
            check = nil
            notice = "插件已全部更新"
        }
    }

    func checkUpdates() async {
        guard let service, !checking else { return }
        checking = true
        defer { checking = false }
        do {
            let result = try await service.checkUpdates()
            check = result
            if let next = result.state { state = next }
        } catch {
            let error = MagpieError.from(error)
            if error != .cancelled { actionError = error }
        }
    }

    func setBuiltin(_ id: String, on: Bool) async {
        await run("builtin:" + id, on ? "正在打开…" : "正在关闭…") { service in
            self.builtins = try await service.builtin(PluginRequests.builtin(id, on: on)).plugins
        }
    }

    @discardableResult
    func saveBuiltinConfig(_ id: String, _ config: [String: WebJSON]) async -> Bool {
        guard !config.isEmpty else { return true }
        return await run("builtin:" + id, "正在保存设置…") { service in
            self.builtins = try await service.builtin(PluginRequests.builtin(id, config: config)).plugins
        }
    }

    func setProviderOption(_ option: PluginProviderOption, on: Bool) async {
        await run("option:" + option.id, "正在保存…") { service in
            try await service.setProviderOption(provider: option.provider, key: option.key, on: on)
            self.providerOptions = (try? await service.providerOptions()) ?? self.providerOptions.map { item in
                var item = item
                if item.id == option.id { item.on = on }
                return item
            }
        }
    }
}
