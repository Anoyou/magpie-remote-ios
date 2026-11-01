import Foundation
import Observation
import MagpieRemoteCore

/// 「插件」页的数据与操作，照 magpie 网页 plugins.js：已安装、推荐列表、GitHub 上的非官方插件、npm 的回答
/// 各自读、各自画，谁先到先显示（npm 和 git 提交在后面补上）。
@MainActor
@Observable
final class PluginStore {
    enum Tab: String, CaseIterable, Identifiable {
        case builtin, discover, installed
        var id: String { rawValue }
    }

    /// 页面顶部的一句提示（官方的状态栏）。
    struct Notice: Equatable {
        enum Kind { case ok, warn, error }
        var text: String
        var kind: Kind
    }

    /// npm 搜索。
    enum Hits: Equatable {
        case none
        case loading(String)
        case list(String, [WebPluginListing])
        case failed(String, String)
    }

    private(set) var service: (any PluginServing)?

    // 已安装（GET /api/plugins）
    private(set) var state: WebPlugins?
    private(set) var stateError: MagpieError?
    // 推荐（GET /api/plugins/listings）
    private(set) var listings: [WebPluginListing]?
    private(set) var listingsError: MagpieError?
    private(set) var agents: [String] = []
    // GitHub（GET /api/plugins/github）
    private(set) var tagged: [WebPluginListing]?
    private(set) var taggedInfo: WebTaggedRepos?
    private(set) var taggedLoading = false
    // npm 与 git 提交
    private(set) var npm: [String: WebPluginNPM] = [:]
    private(set) var heads: [String: String] = [:]
    // 内置插件
    private(set) var builtins: [WebBuiltinPlugin]?
    private(set) var builtinsError: MagpieError?
    // 插件的供应商与开关、页面、面板
    private(set) var providers = WebPluginProviders()
    private(set) var pages: [WebPluginPage] = []
    private(set) var panels: [WebPluginPanel] = []
    // README 与图标
    private(set) var readmes: [String: WebPluginReadme] = [:]
    private(set) var readmeErrors: [String: String] = [:]
    private var readmeOrder: [String] = []
    private(set) var icons: [String: Data] = [:]
    private var iconAsked: Set<String> = []

    /// 最近一次「检查更新」：spec → 结果。
    private(set) var check: WebPluginCheck?
    private(set) var checkedAt: Date?
    private(set) var checking = false
    /// 正在进行的操作：包名或 spec → add / remove / upgrade / off / options / move / prefer；`*` = 全部更新，`+` = 手动安装。
    private(set) var busy: [String: String] = [:]
    private(set) var mirrorSaving = false
    private(set) var registrySaving = false

    var hits: Hits = .none
    var notice: Notice?
    var actionError: MagpieError?
    /// 当前显示中的页面（最后一个负责弹窗）。
    var presenters: [String] = []

    private var configuredFor: String?
    private var npmTries = 0

    var market: PluginMarket {
        PluginMarket(state: state, listings: listings, tagged: tagged, npm: npm, heads: heads, subs: providers.subs)
    }
    var installed: [WebPlugin] { market.installed }
    var isBusy: Bool { !busy.isEmpty }
    var loaded: Bool { state != nil || listings != nil || builtins != nil }

    /// 跟随「管理」页的服务：主机或 Web 密钥变了才重新加载。
    func configure(manage: (any ManageServing)?) async {
        let next = makePluginService(for: manage)
        var signature = next == nil ? "none" : "fixture"
        if let live = next as? LivePluginService { signature = "live|\(live.web.baseURL.absoluteString)|\(live.web.key)" }
        guard signature != configuredFor else { return }
        configuredFor = signature
        service = next
        state = nil; stateError = nil; listings = nil; listingsError = nil; tagged = nil; taggedInfo = nil
        npm = [:]; heads = [:]; builtins = nil; builtinsError = nil; providers = WebPluginProviders(); pages = []; panels = []
        readmes = [:]; readmeErrors = [:]; readmeOrder = []; icons = [:]; iconAsked = []; check = nil; hits = .none; notice = nil
        guard next != nil else { return }
        await load()
    }

    /// 官方 load：各部分同时读，到了就显示；之后问 npm 与 git。
    func load() async {
        guard service != nil else { return }
        async let mine: Void = loadMine()
        async let list: Void = loadListings()
        async let gh: Void = loadTagged(again: false)
        async let built: Void = loadBuiltins()
        async let subs: Void = loadProviders()
        async let windows: Void = loadWindows()
        _ = await (mine, list, gh, built, subs, windows)
        await askNPM(onlyMissing: false)
        await askGit()
    }

    private func loadMine() async {
        guard let service else { return }
        do {
            state = try await service.plugins()
            stateError = nil
        } catch {
            let error = MagpieError.from(error)
            if error != .cancelled { stateError = error }
        }
    }

    private func loadListings() async {
        guard let service else { return }
        do {
            listings = try await service.listings().listings
            listingsError = nil
            agents = (try? await service.agents()) ?? agents
        } catch {
            let error = MagpieError.from(error)
            if error != .cancelled { listingsError = error }
        }
    }

    /// GitHub 的回答：问不到时保留之前的列表，并说明原因（官方 loadTagged）。
    func loadTagged(again: Bool) async {
        guard let service, !taggedLoading else { return }
        taggedLoading = true
        defer { taggedLoading = false }
        if again { taggedInfo = nil }
        do {
            let r = try await service.tagged(again: again)
            let got = r.repos.map(WebPluginListing.github)
            if !(!r.error.isEmpty && got.isEmpty && !(tagged ?? []).isEmpty) { tagged = got }
            taggedInfo = r
        } catch {
            let error = MagpieError.from(error)
            guard error != .cancelled else { return }
            taggedInfo = WebTaggedRepos(json: ["error": .string(error.message)])
            tagged = tagged ?? []
        }
    }

    private func loadBuiltins() async {
        guard let service else { return }
        do {
            builtins = try await service.builtins().plugins
            builtinsError = nil
        } catch {
            let error = MagpieError.from(error)
            if error != .cancelled { builtinsError = error }
        }
    }

    private func loadProviders() async {
        guard let service else { return }
        providers = (try? await service.pluginProviders()) ?? providers
    }

    private func loadWindows() async {
        guard let service else { return }
        pages = (try? await service.pages()) ?? pages
        panels = (try? await service.panels()) ?? panels
    }

    /// 问 npm 推荐的与已安装的包；npm 没说的标成「未知」（仍可安装），过 15 秒再问，最多 4 次（官方 askNPM）。
    func askNPM(onlyMissing: Bool) async {
        guard let service else { return }
        var names = (listings ?? []).map(\.package) + (state?.plugins ?? []).filter { PluginSpec.onNPM($0.spec) }.map { PluginSpec.name($0.spec) }
        names = Array(Set(names)).sorted()
        if onlyMissing { names = names.filter { npm[$0] == nil || npm[$0]?.unknown == true } }
        guard !names.isEmpty else { return }
        if let answer = try? await service.npm(names: names) {
            for (name, info) in answer { npm[name] = info }
        }
        var unknown = false
        for l in listings ?? [] where npm[l.package] == nil || npm[l.package]?.unknown == true {
            npm[l.package] = .unknownAnswer
            unknown = true
        }
        if unknown, npmTries < 4 {
            npmTries += 1
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                await self?.askNPM(onlyMissing: true)
            }
        }
    }

    func askGit() async {
        guard let service, (state?.plugins ?? []).contains(where: { $0.source == .git }) else { return }
        if let got = try? await service.gitHeads() { heads.merge(got.filter { !$0.value.isEmpty }) { _, new in new } }
    }

    /// 下拉刷新：重新读全部。
    func refresh() async {
        npmTries = 0
        await load()
    }

    /// 操作之后：已安装、供应商、页面重读，再补问 npm 与 git（官方 refresh）。
    private func refreshAfterChange() async {
        guard let service else { return }
        async let mine = try? service.plugins()
        async let subs = try? service.pluginProviders()
        async let p = try? service.pages()
        async let n = try? service.panels()
        if let next = await mine { state = next }
        providers = await subs ?? providers
        pages = await p ?? pages
        panels = await n ?? panels
        agents = (try? await service.agents()) ?? agents
        await askNPM(onlyMissing: true)
        await askGit()
    }

    // MARK: 查询

    func plugin(_ spec: String) -> WebPlugin? { installed.first { $0.spec == spec } }
    func builtin(_ id: String) -> WebBuiltinPlugin? { builtins?.first { $0.id == id } }
    func shownName(_ plugin: WebPlugin) -> String { market.shownName(plugin) }
    func listing(for plugin: WebPlugin) -> WebPluginListing? { market.listing(for: plugin) }
    func pages(for spec: String) -> [WebPluginPage] { pages.filter { $0.spec == spec } }
    func panels(for spec: String) -> [WebPluginPanel] { panels.filter { $0.spec == spec } }
    func providerOptions(for spec: String) -> [PluginProviderOption] { providers.options.filter { $0.spec == spec } }
    func versionCheck(for spec: String) -> PluginVersionCheck? { check?.checks.first { $0.spec == spec } }
    func action(for listing: WebPluginListing) -> PluginCardAction {
        market.action(for: listing.package, listing: listing, busy: busy)
    }

    /// 已安装插件对应的卡片（详情页用）：市场里有用市场的，否则凑一张。
    func card(for plugin: WebPlugin) -> WebPluginListing {
        if let l = listing(for: plugin) { return l }
        if let g = tagged?.first(where: { market.entry(for: $0.package)?.spec == plugin.spec }) { return g }
        var card = WebPluginListing.installed(plugin, name: shownName(plugin))
        if PluginSpec.onNPM(plugin.spec), let info = npm[PluginSpec.name(plugin.spec)] { card = card.with(npm: info) }
        return card
    }

    func isInstalled(_ listing: WebPluginListing) -> Bool { market.entry(for: listing.package) != nil }

    // MARK: 操作

    @discardableResult
    private func run(_ key: String, _ op: String, _ operation: (any PluginServing) async throws -> Void) async -> Bool {
        guard let service, busy[key] == nil else { return false }
        busy[key] = op
        notice = nil
        defer { busy[key] = nil }
        do {
            try await operation(service)
            return true
        } catch {
            let error = MagpieError.from(error)
            if error != .cancelled { actionError = error }
            return false
        }
    }

    /// 安装（官方 install / manual）。`name` 是卡片上的名字。
    @discardableResult
    func install(_ spec: String, name: String, key: String? = nil) async -> Bool {
        let package = key ?? PluginSpec.name(spec)
        let ok = await run(package, "add") { service in
            self.state = try await service.plugin(.add, PluginRequests.spec(spec))
        }
        guard ok else { return false }
        await refreshAfterChange()
        let signIn = !market.subs(for: PluginSpec.name(spec)).filter { !$0.signedIn }.isEmpty
        notice = Notice(text: signIn ? "\(name) 已安装，登录后即可使用" : "\(name) 已安装", kind: .ok)
        return true
    }

    @discardableResult
    func remove(_ plugin: WebPlugin) async -> Bool {
        let name = shownName(plugin)
        let ok = await run(PluginSpec.name(plugin.spec), "remove") { service in
            self.state = try await service.plugin(.remove, PluginRequests.spec(plugin.spec))
        }
        guard ok else { return false }
        await refreshAfterChange()
        notice = Notice(text: "已移除 \(name)", kind: .ok)
        return true
    }

    func setEnabled(_ plugin: WebPlugin, _ enabled: Bool) async {
        let ok = await run(PluginSpec.name(plugin.spec), "off") { service in
            self.state = try await service.plugin(.off, PluginRequests.setEnabled(plugin.spec, enabled))
        }
        if ok { await refreshAfterChange() }
    }

    @discardableResult
    func saveOptions(_ plugin: WebPlugin, _ options: [String: WebJSON]?) async -> Bool {
        let name = shownName(plugin)
        let body = options.map { PluginRequests.options(plugin.spec, $0) } ?? PluginRequests.clearOptions(plugin.spec)
        let ok = await run(PluginSpec.name(plugin.spec), "options") { service in
            self.state = try await service.plugin(.options, body)
        }
        if ok { notice = Notice(text: options == nil ? "\(name) 的选项已清空" : "\(name) 的选项已保存", kind: .ok) }
        return ok
    }

    /// 两个插件都登录同一个供应商时，改由这个提供（官方「用于 …」）。
    func prefer(_ plugin: WebPlugin, clash: PluginClash) async {
        let ok = await run(PluginSpec.name(plugin.spec), "prefer") { service in
            self.state = try await service.plugin(.prefer, PluginRequests.prefer(plugin.spec, provider: clash.id))
        }
        if ok {
            await refreshAfterChange()
            notice = Notice(text: "\(clash.name) 现在由 \(shownName(plugin)) 提供", kind: .ok)
        }
    }

    func upgrade(_ plugin: WebPlugin) async {
        let npmUpdate = plugin.npmUpdate
        let target = plugin.latest
        let ok = await run(PluginSpec.name(plugin.spec), "upgrade") { service in
            self.state = try await service.plugin(.upgrade, PluginRequests.spec(plugin.spec))
        }
        guard ok else { return }
        check = nil
        await refreshAfterChange()
        let name = self.plugin(plugin.spec).map(shownName) ?? shownName(plugin)
        notice = Notice(text: npmUpdate ? "\(name) 已更新到 v\(target)" : "\(name) 已是最新", kind: .ok)
    }

    func updateAll() async {
        let ok = await run("*", "update") { service in
            self.state = try await service.plugin(.update, [:])
        }
        guard ok else { return }
        check = nil
        await refreshAfterChange()
        notice = Notice(text: "插件已更新", kind: .ok)
    }

    /// 内置订阅的账号迁到插件上（官方 move）。
    func move(_ candidate: PluginMoveCandidate) async {
        let ok = await run(candidate.package, "move") { service in try await service.move(candidate.id) }
        if ok {
            await refreshAfterChange()
            let accounts = candidate.accounts
            notice = Notice(text: "\(candidate.name) 已改由插件运行：\(accounts) 个账号。在「供应商」中编辑它即可改回。", kind: .ok)
        } else if let error = actionError {
            actionError = nil
            notice = Notice(text: "仍使用内置：\(error.message)", kind: .error)
        }
    }

    /// 立刻问 npm / 仓库每个插件的最新版本，不安装（官方 checkUpdates）。
    func checkUpdates() async {
        guard let service, !checking, busy.isEmpty else { return }
        checking = true
        defer { checking = false }
        do {
            let r = try await service.checkUpdates()
            if let next = r.state { state = next }
            for c in r.checks {
                if !c.latest.isEmpty {
                    var raw = npm[c.package]?.raw ?? ["weekly": 0]
                    raw["version"] = .string(c.latest)
                    npm[c.package] = WebPluginNPM(raw: raw)
                }
                if !c.head.isEmpty { heads[c.spec] = c.head }
            }
            check = r
            checkedAt = Date()
            let asked = r.checks.filter { [.update, .current, .unknown].contains($0.status) }
            let unknown = asked.filter { $0.status == .unknown }
            notice = Notice(text: r.summary, kind: !asked.isEmpty && unknown.count == asked.count ? .error : (unknown.isEmpty ? .ok : .warn))
        } catch {
            let error = MagpieError.from(error)
            if error != .cancelled { notice = Notice(text: "无法检查更新：\(error.message)", kind: .error) }
        }
    }

    func setMirror(_ on: Bool) async {
        guard let service, !mirrorSaving, state != nil else { return }
        mirrorSaving = true
        defer { mirrorSaving = false }
        let was = state?.raw["mirror"]
        state?.raw["mirror"] = .bool(on)
        do {
            let now = try await service.setMirror(on)
            state?.raw["mirror"] = .bool(now)
            if now {
                // 列表与 npm 的回答改从镜像读
                await loadListings()
                await askNPM(onlyMissing: false)
            }
        } catch {
            state?.raw["mirror"] = was ?? .bool(!on)
            let error = MagpieError.from(error)
            if error != .cancelled { actionError = error }
        }
    }

    @discardableResult
    func setRegistry(_ url: String) async -> Bool {
        guard let service, !registrySaving else { return false }
        registrySaving = true
        defer { registrySaving = false }
        do {
            let r = try await service.setRegistry(url)
            state?.raw["registry"] = r.json
            await askNPM(onlyMissing: false)
            return true
        } catch {
            let error = MagpieError.from(error)
            if error != .cancelled { actionError = error }
            return false
        }
    }

    func setBuiltin(_ id: String, on: Bool) async {
        await run("builtin:" + id, on ? "on" : "off") { service in
            self.builtins = try await service.builtin(PluginRequests.builtin(id, on: on)).plugins
        }
    }

    /// 内置插件的一项设置，改了就存（官方 ui.form 的 onChange）。
    @discardableResult
    func saveBuiltinSetting(_ id: String, key: String, value: WebJSON) async -> Bool {
        let ok = await run("builtin:" + id, "config") { service in
            self.builtins = try await service.builtin(PluginRequests.builtin(id, config: [key: value])).plugins
        }
        if ok { notice = Notice(text: "已保存", kind: .ok) }
        return ok
    }

    func setProviderOption(_ option: PluginProviderOption, on: Bool) async {
        await run("option:" + option.id, "option") { service in
            try await service.setProviderOption(provider: option.provider, key: option.key, on: on)
            self.providers = (try? await service.pluginProviders()) ?? self.providers
        }
    }

    // MARK: 搜索、README、图标

    /// npm 搜索（两个字符以上；官方 350 毫秒后才问）。
    func search(_ query: String) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2, let service else {
            hits = .none
            return
        }
        hits = .loading(q)
        do {
            try await Task.sleep(for: .milliseconds(350))
            let list = try await service.search(q)
            if case .loading(let asked) = hits, asked == q { hits = .list(q, list) }
        } catch is CancellationError {
            return
        } catch {
            let error = MagpieError.from(error)
            if error == .cancelled { return }
            if case .loading(let asked) = hits, asked == q { hits = .failed(q, error.message) }
        }
    }

    /// README：读过的直接显示，再悄悄重读；最多留 20 个（官方 pages Map）。
    func loadReadme(_ name: String) async {
        guard let service else { return }
        do {
            let page = try await service.readme(name)
            readmes[name] = page
            readmeErrors[name] = nil
            readmeOrder.removeAll { $0 == name }
            readmeOrder.append(name)
            if readmeOrder.count > 20 { readmes[readmeOrder.removeFirst()] = nil }
        } catch {
            let error = MagpieError.from(error)
            if error != .cancelled, readmes[name] == nil { readmeErrors[name] = error.message }
        }
    }

    /// 主机保存的图标（`file:`），问一次。
    func loadIcon(_ name: String) async {
        guard let service, name.hasPrefix("file:"), !iconAsked.contains(name) else { return }
        iconAsked.insert(name)
        if let data = try? await service.icon(name) { icons[name] = data }
    }
}
