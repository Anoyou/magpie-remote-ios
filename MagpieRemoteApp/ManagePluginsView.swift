import SwiftUI
import MagpieRemoteCore

/// 「插件」页，照 magpie 网页的插件页（internal/gui/assets/plugins.js、registry.js）：
/// 顶部三个分页「内置 / 发现 / 已安装」与搜索；「发现」是 magpie 社区按种类分区的卡片、GitHub 上的非官方插件、
/// npm 搜索、「已有想装的？」与 npm 源；「已安装」每行一个插件，有更新提示、检查更新、开关、移除；
/// 「内置」是 magpie 自带部分的开关与设置。
struct ManagePluginsView: View {
    let manage: ManageStore
    @State private var store = PluginStore()
    @AppStorage("magpie.pluginTab") private var tabRaw = PluginStore.Tab.discover.rawValue
    @AppStorage("magpie.pluginSort") private var sortRaw = PluginSort.nameAscending.rawValue
    @State private var query = ""
    @State private var showAdd = false
    @State private var detail: WebPluginListing?
    @State private var web: PluginWebTarget?
    @State private var pendingInstall: PendingInstall?
    @State private var pendingMove: PluginMoveCandidate?
    @State private var pendingRemove: WebPlugin?
    @State private var pendingOff: WebPlugin?
    @State private var ghFilter = PluginGitHubFilter()

    /// 安装前的确认：先问替换同名插件（官方 replaceOK），再提醒只装信任的插件。
    struct PendingInstall: Identifiable {
        var spec: String
        var name: String
        var replacement: PluginReplacement?
        var key: String?
        var id: String { spec }
    }

    private var tab: PluginStore.Tab {
        get { PluginStore.Tab(rawValue: tabRaw) ?? .discover }
        nonmutating set { tabRaw = newValue.rawValue }
    }

    var body: some View {
        List {
            Section {
                tabPicker
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

            if let notice = store.notice {
                Section { PluginNoticeRow(notice: notice) }
            }
            if store.service == nil, manage.service == nil {
                Section { Text("先在「管理」页连接主机并填写 Web 密钥。").foregroundStyle(.secondary) }
            }

            switch tab {
            case .builtin: builtinTab
            case .discover: discoverTab
            case .installed: installedTab
            }
        }
        .navigationTitle("插件")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索插件和 npm…")
        .onChange(of: query) { _, new in
            if !new.isEmpty, tab != .discover { tab = .discover }
        }
        .task(id: query) { await store.search(query) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAdd = true
                } label: {
                    Label("添加插件", systemImage: "plus")
                }
                .disabled(store.service == nil)
                .accessibilityIdentifier("plugins.add")
            }
            ToolbarItem(placement: .secondaryAction) {
                Toggle(isOn: Binding(get: { store.state?.mirror ?? false }, set: { on in Task { await store.setMirror(on) } })) {
                    Label("国内镜像", systemImage: "globe.asia.australia")
                }
                .disabled(store.state == nil || store.mirrorSaving)
                .accessibilityIdentifier("plugins.mirror")
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    web = PluginWebTarget(view: "plugins", title: "插件（网页）")
                } label: {
                    Label("在网页中打开插件页", systemImage: "safari")
                }
                .accessibilityIdentifier("plugins.web")
            }
        }
        .refreshable { await store.refresh() }
        .task(id: manage.service.map { String(describing: type(of: $0)) } ?? "none") { await store.configure(manage: manage.service) }
        .onAppear { Task { await store.configure(manage: manage.service) } }
        .sheet(isPresented: $showAdd) {
            AddPluginSheet(store: store) { tab = .installed }
        }
        .sheet(item: $detail) { listing in
            PluginListingSheet(store: store, listing: listing, install: { l in later { ask(install: l.package, name: l.name) } },
                               move: { c in later { pendingMove = c } }, signIn: { signIn($0) }, openProvider: { openProvider($0) })
        }
        .sheet(item: $web) { target in PluginWebSheet(service: store.service, target: target) }
        .confirmationDialog(pendingInstall.map { installTitle($0) } ?? "", isPresented: present($pendingInstall),
                            titleVisibility: .visible, presenting: pendingInstall) { item in
            Button(item.replacement == nil ? "安装" : "替换") {
                Task {
                    if await store.install(item.spec, name: item.name, key: item.key), item.key == "+" { tab = .installed }
                }
            }
        } message: { item in
            Text(item.replacement?.message ?? "插件是他人的代码，会拿到你的登录或看到你的请求：只安装你信任的。将从 \(item.spec) 安装。")
        }
        .confirmationDialog("迁移 \(pendingMove?.name ?? "")？", isPresented: present($pendingMove), titleVisibility: .visible,
                            presenting: pendingMove) { candidate in
            Button("迁移") { Task { await store.move(candidate) } }
        } message: { candidate in
            Text("改由此插件运行 \(candidate.name)，账号不变（\(candidate.accounts) 个）；有账号无法使用时不做改动。")
        }
        .confirmationDialog(pendingRemove.map { "移除 \(store.shownName($0))？" } ?? "", isPresented: present($pendingRemove),
                            titleVisibility: .visible, presenting: pendingRemove) { plugin in
            Button("移除", role: .destructive) { Task { await store.remove(plugin) } }
        } message: { plugin in
            Text(removeMessage(plugin))
        }
        .confirmationDialog(pendingOff.map { "停用 \(store.shownName($0))？" } ?? "", isPresented: present($pendingOff),
                            titleVisibility: .visible, presenting: pendingOff) { plugin in
            Button("停用", role: .destructive) { Task { await store.setEnabled(plugin, false) } }
        } message: { plugin in
            Text("插件停用期间，\(movedNames(plugin)) 也会停用。它的账号会保留。")
        }
        .pluginAlerts(store: store, id: "plugins")
    }

    // MARK: 分页

    private var tabPicker: some View {
        let count = store.installed.count
        return Picker("插件", selection: Binding(get: { tab }, set: { tab = $0 })) {
            Text("内置").tag(PluginStore.Tab.builtin)
            Text("发现").tag(PluginStore.Tab.discover)
            Text(count > 0 ? "已安装 · \(count)" : "已安装").tag(PluginStore.Tab.installed)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("plugins.tabs")
    }

    // MARK: 内置（官方 drawBuiltin / renderBuiltins）

    @ViewBuilder
    private var builtinTab: some View {
        Section {
            Text("不是人人都需要的部分。关掉后，它会从侧边栏、各页面和设置中隐去；magpie 的工作方式不变。")
                .font(.footnote).foregroundStyle(.secondary)
            if let broken = store.builtins?.first(where: { $0.broken != nil })?.broken {
                Label("plugins.yml 读不了，所以每个内置插件都保持原样：\(broken)", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
        if let error = store.builtinsError, store.builtins == nil {
            Section { failure(error) { await store.refresh() } }
        } else if let builtins = store.builtins {
            ForEach(builtins) { builtin in
                BuiltinPluginSection(store: store, builtin: builtin)
            }
        } else {
            Section { loadingRow("正在读取内置插件…") }
        }
    }

    // MARK: 发现（官方 drawBody）

    @ViewBuilder
    private var discoverTab: some View {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = store.listingsError, store.listings == nil {
            Section { failure(error, prefix: "无法加载插件") { await store.refresh() } }
        } else if store.listings == nil {
            Section { introCard }
                .listRowBackground(Color.clear)
            Section { loadingRow("正在读取插件…") }
        } else if q.isEmpty {
            Section { introCard }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            ForEach(store.market.discoverSections()) { section in
                cardSection(section.title, hint: section.hint, cards: section.cards, id: "plugins.section.\(section.id.rawValue)")
            }
            githubSection(query: "")
            manualSection
            registrySection
        } else {
            let suggested = store.market.suggested(matching: q)
            if !suggested.isEmpty { cardSection("推荐", hint: "", cards: suggested, id: "plugins.section.suggested") }
            githubSection(query: q)
            npmSection(q)
        }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("插件扩展 magpie").font(.title3.weight(.bold))
            Text("插件负责登录编程套餐并发出请求，其模型可像其他供应商的一样用于所有 agent。插件为 OpenCode 的供应商插件或 pi 扩展包，运行在 Bun 上。")
                .font(.subheadline)
            Text("插件还可以在 magpie 网关里处理 Agent 发出和收到的内容、决定路由该用哪个账号、给每个 Agent 提供工具、接入一个 Agent，或加一个自己的页面。")
                .font(.subheadline).foregroundStyle(.secondary)
            Link(destination: URL(string: "https://usemagpie.ai/docs/zh/plugins")!) {
                Label("编写插件", systemImage: "arrow.up.right.square")
            }
            .font(.subheadline.weight(.semibold))
            Label("插件是他人的代码，会拿到你的登录或看到你的请求：只安装你信任的。", systemImage: "checkmark.shield")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plugins.intro")
    }

    private func cardSection(_ title: String, hint: String, cards: [WebPluginListing], id: String) -> some View {
        Section {
            ForEach(cards, id: \.package) { card($0) }
        } header: {
            Text(title)
        } footer: {
            if !hint.isEmpty { Text(hint) }
        }
        .accessibilityIdentifier(id)
    }

    private func card(_ listing: WebPluginListing) -> some View {
        PluginCard(store: store, listing: listing, open: { detail = $0 },
                   onInstall: { ask(install: $0.package, name: $0.name) },
                   onMove: { pendingMove = $0 }, onSignIn: { signIn($0) }, onOpen: { openProvider($0) })
    }

    /// GitHub 上的非官方插件（官方 ghSection / ghWaiting / ghFailed / ghNote / drawGh）。
    @ViewBuilder
    private func githubSection(query: String) -> some View {
        let all = store.market.githubCards(matching: query)
        let info = store.taggedInfo
        let failed = !(info?.error.isEmpty ?? true)
        Section {
            if store.tagged == nil || (store.taggedLoading && all.isEmpty) {
                HStack(spacing: 8) { ProgressView(); Text("正在 GitHub 上查找").foregroundStyle(.secondary) }
                    .accessibilityIdentifier("plugins.github.loading")
            } else if all.isEmpty, failed, let info {
                Text(info.reason(kept: false)).font(.footnote).foregroundStyle(.secondary)
                Button("重试") { Task { await store.loadTagged(again: true) } }
            } else {
                if failed, let info {
                    HStack {
                        Label(info.reason(kept: true), systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                        Spacer()
                        Button("重试") { Task { await store.loadTagged(again: true) } }.buttonStyle(.borderless).disabled(store.taggedLoading)
                    }
                }
                if PluginGitHubFilter.shows(for: store.tagged ?? []) { githubFilterBar(all) }
                let shown = PluginGitHubFilter.shows(for: store.tagged ?? []) ? ghFilter.apply(all, isInstalled: { store.isInstalled($0) }) : all
                if shown.isEmpty, !all.isEmpty {
                    HStack {
                        Text("GitHub 上没有符合的插件").foregroundStyle(.secondary)
                        Spacer()
                        Button("全部显示") { ghFilter = PluginGitHubFilter() }.buttonStyle(.borderless)
                    }
                }
                ForEach(shown, id: \.package) { card($0) }
            }
        } header: {
            Text("非官方插件 · GitHub")
        } footer: {
            Text("作者自己打了 \(info?.topic ?? "magpie-plugin") 标签的仓库，未经审阅，安装前请先看代码")
        }
        .accessibilityIdentifier("plugins.section.github")
    }

    private func githubFilterBar(_ all: [WebPluginListing]) -> some View {
        let kinds = PluginGitHubFilter.kinds(in: all)
        let have = all.contains { store.isInstalled($0) } && all.contains { !store.isInstalled($0) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                if kinds.count > 1 {
                    Picker("插件类型", selection: $ghFilter.kind) {
                        Text("全部 · \(ghFilter.count(all, kind: nil, installed: ghFilter.installed, isInstalled: { store.isInstalled($0) }))").tag(PluginKind?.none)
                        ForEach(kinds, id: \.self) { k in
                            Text("\(k.title) · \(ghFilter.count(all, kind: k, installed: ghFilter.installed, isInstalled: { store.isInstalled($0) }))").tag(PluginKind?.some(k))
                        }
                    }
                    .pickerStyle(.menu)
                }
                if have {
                    Picker("是否已安装", selection: $ghFilter.installed) {
                        Text("全部").tag(Bool?.none)
                        Text("已安装 · \(ghFilter.count(all, kind: ghFilter.kind, installed: true, isInstalled: { store.isInstalled($0) }))").tag(Bool?.some(true))
                        Text("未安装 · \(ghFilter.count(all, kind: ghFilter.kind, installed: false, isInstalled: { store.isInstalled($0) }))").tag(Bool?.some(false))
                    }
                    .pickerStyle(.menu)
                }
            }
            TextField("按名称、作者或简介筛选", text: $ghFilter.query)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
        }
    }

    /// npm 搜索（官方「npm 上的插件」）。
    private func npmSection(_ q: String) -> some View {
        Section {
            switch store.hits {
            case .none:
                Text("输入两个及以上字符以搜索 npm").foregroundStyle(.secondary)
            case .loading:
                loadingRow("正在搜索 npm…")
            case .failed(_, let message):
                Text(message).font(.footnote).foregroundStyle(.red)
            case .list(_, let hits):
                let list = store.market.npmCards(hits)
                if list.isEmpty {
                    Text(store.market.suggested(matching: q).isEmpty ? "没有叫「\(q)」的插件" : "npm 上没有更多了").foregroundStyle(.secondary)
                }
                ForEach(list, id: \.package) { card($0) }
            }
        } header: {
            Text("npm 上的插件")
        } footer: {
            Text("任何人都可发布的 OpenCode 插件和 pi 包，安装前请先了解它做什么")
        }
        .accessibilityIdentifier("plugins.section.npm")
    }

    /// 「已有想装的？」（官方 manual）。
    private var manualSection: some View {
        ManualInstallSection(store: store) { spec in ask(install: spec, name: spec, typed: true, key: "+") }
    }

    @ViewBuilder
    private var registrySection: some View {
        if let registry = store.state?.registry {
            RegistrySection(store: store, registry: registry)
        }
    }

    // MARK: 已安装（官方 drawInstalled）

    @ViewBuilder
    private var installedTab: some View {
        if let error = store.stateError, store.state == nil {
            Section { failure(error, prefix: "无法加载插件") { await store.refresh() } }
        } else if store.state == nil {
            Section { loadingRow("正在读取插件…") }
        } else if store.installed.isEmpty {
            Section {
                ContentUnavailableView {
                    Label("还没有插件", systemImage: "puzzlepiece.extension")
                } description: {
                    Text("在「发现」中安装订阅或中间件；订阅在这里登录。")
                } actions: {
                    Button("发现插件") { tab = .discover }.buttonStyle(.glassProminent)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("plugins.empty")
            }
        } else {
            let outdated = store.market.outdated
            if !outdated.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(outdated.count == 1 ? "\(store.shownName(outdated[0])) 有新版本"
                                                  : "\(outdated.count) 个插件有新版本：\(outdated.map { store.shownName($0) }.joined(separator: "、"))",
                              systemImage: "circle.fill")
                            .labelStyle(DotLabelStyle())
                            .font(.callout)
                        Button(store.busy["*"] != nil ? "更新中…" : "全部更新（\(outdated.count)）") { Task { await store.updateAll() } }
                            .buttonStyle(.glassProminent)
                            .tint(.blue)
                            .disabled(store.isBusy || store.checking)
                            .accessibilityIdentifier("plugins.updateAll")
                    }
                }
            }
            Section {
                ForEach(store.market.sorted(PluginSort(rawValue: sortRaw) ?? .nameAscending), id: \.spec) { plugin in
                    NavigationLink {
                        PluginDetailView(store: store, spec: plugin.spec)
                    } label: {
                        InstalledPluginRow(store: store, plugin: plugin)
                    }
                    .accessibilityIdentifier("plugins.row.\(plugin.spec)")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("移除", role: .destructive) { pendingRemove = plugin }
                            .disabled(store.isBusy)
                        Button(plugin.off ? "启用" : "停用") { toggle(plugin) }
                            .tint(plugin.off ? .green : .gray)
                    }
                    .swipeActions(edge: .leading) {
                        if plugin.updateOffered {
                            Button("更新") { Task { await store.upgrade(plugin) } }.tint(.blue)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("已安装")
                    Spacer()
                    if store.installed.count > 1 {
                        Menu {
                            Picker("排序", selection: $sortRaw) {
                                ForEach(PluginSort.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                            }
                        } label: {
                            Label("排序", systemImage: "arrow.up.arrow.down").labelStyle(.iconOnly)
                        }
                        .accessibilityIdentifier("plugins.sort")
                    }
                }
            } footer: {
                if let state = store.state {
                    Text(state.bun ? "插件运行在 Bun \(state.bunVersion) 上" : "这台 Mac 上还没有 Bun：添加第一个插件时 magpie 会先下载它，需要多等一会儿。")
                }
            }

            if store.market.canCheck {
                Section {
                    Button {
                        Task { await store.checkUpdates() }
                    } label: {
                        HStack {
                            Label(store.checking ? "检查中…" : "检查更新", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if store.checking { ProgressView() }
                        }
                    }
                    .disabled(store.checking || store.isBusy)
                    .accessibilityIdentifier("plugins.check")
                } footer: {
                    Text("立刻问 npm 每个插件的最新版本，不会安装。" + (store.checkedAt.map { "上次检查：\($0.formatted(date: .omitted, time: .shortened))" } ?? ""))
                }
            }

            if !store.pages.isEmpty {
                Section {
                    ForEach(store.pages) { page in
                        Button {
                            web = PluginWebTarget(view: page.key, title: page.title)
                        } label: {
                            Label(page.title, systemImage: "macwindow")
                        }
                        .accessibilityIdentifier("plugins.page.\(page.key)")
                    }
                } header: {
                    Text("插件页面")
                } footer: {
                    Text("插件自带的页面需要 magpie 的网页环境，会在 App 内打开主机上的 magpie 网页。")
                }
            }
        }
    }

    // MARK: 操作

    private func toggle(_ plugin: WebPlugin) {
        if !plugin.off, !plugin.moved.isEmpty { pendingOff = plugin } else { Task { await store.setEnabled(plugin, plugin.off) } }
    }

    /// 表单收起后再弹确认。
    private func later(_ action: @escaping @MainActor () -> Void) {
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            action()
        }
    }

    private func ask(install spec: String, name: String, typed: Bool = false, key: String? = nil) {
        pendingInstall = PendingInstall(spec: spec, name: name, replacement: store.market.namesake(of: spec, typed: typed), key: key)
    }

    private func installTitle(_ item: PendingInstall) -> String { item.replacement?.title ?? "安装「\(item.name)」？" }

    private func signIn(_ sub: PluginSub) {
        openWeb(PluginWebTarget(view: "providers", title: "登录 \(sub.name)"))
    }

    private func openProvider(_ sub: PluginSub) {
        openWeb(PluginWebTarget(view: "providers", extra: [URLQueryItem(name: "edit", value: sub.id)], title: sub.name))
    }

    /// 从详情表单里打开网页：先收起表单，再弹出网页。
    private func openWeb(_ target: PluginWebTarget) {
        guard detail != nil else {
            web = target
            return
        }
        detail = nil
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            web = target
        }
    }

    private func movedNames(_ plugin: WebPlugin) -> String { plugin.moved.joined(separator: "、") }

    private func removeMessage(_ plugin: WebPlugin) -> String {
        plugin.moved.isEmpty ? "移除插件及其安装的内容；它的登录会保留，直到你退出登录。"
                             : "\(movedNames(plugin)) 会停用，直到再次安装插件。它的账号会保留。"
    }

    private func loadingRow(_ text: String) -> some View {
        HStack(spacing: 8) { ProgressView(); Text(text).foregroundStyle(.secondary) }
    }

    private func failure(_ error: MagpieError, prefix: String? = nil, retry: @escaping @MainActor () async -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(prefix.map { "\($0)：\(error.message)" } ?? error.title, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            if prefix == nil { Text(error.message).font(.footnote) }
            if let hint = error.hint { Text(hint).font(.footnote).foregroundStyle(.secondary) }
            Button("重试") { Task { await retry() } }.buttonStyle(.borderless)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("plugins.error")
    }
}

/// 一个小圆点在前的标签（官方 pm-dot）。
private struct DotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.font(.system(size: 7)).foregroundStyle(.blue)
            configuration.title
        }
    }
}

// MARK: 已安装的一行（官方 installedRow）

struct InstalledPluginRow: View {
    let store: PluginStore
    let plugin: WebPlugin

    var body: some View {
        let listing = store.listing(for: plugin)
        let subs = store.market.subs(for: PluginSpec.name(plugin.spec))
        HStack(alignment: .top, spacing: 12) {
            PluginLogo(store: store, icon: listing?.logo.isEmpty == false ? listing!.logo : (!plugin.icon.isEmpty ? plugin.icon : (subs.first?.icon ?? plugin.agent?.icon ?? "")),
                       kind: plugin.logoKind)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(store.shownName(plugin)).font(.body.weight(.medium)).foregroundStyle(plugin.off ? .secondary : .primary).lineLimit(1)
                    if !plugin.version.isEmpty { Text("v\(plugin.version)").font(.caption).foregroundStyle(.secondary) }
                    if plugin.source == .git, !plugin.commit.isEmpty { Text(plugin.commit).font(.caption.monospaced()).foregroundStyle(.secondary) }
                }
                chips
                PluginStatusLines(store: store, plugin: plugin, compact: true)
                if let working = store.busy[PluginSpec.name(plugin.spec)] ?? store.busy[plugin.spec] {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(Self.workingText(working)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var chips: some View {
        let check = store.versionCheck(for: plugin.spec)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                if plugin.gitBehind {
                    PluginChip(text: "有新提交", tone: .accent)
                } else if plugin.npmUpdate {
                    PluginChip(text: "v\(plugin.latest) 可用", tone: .accent)
                } else if check?.status == .unknown {
                    PluginChip(text: "无法检查", symbol: "exclamationmark.circle", tone: .warn)
                } else if let auto = plugin.autoUpdated, auto.to == plugin.version {
                    PluginChip(text: "已自动更新", tone: .soft)
                } else if (check?.status == .current || check?.status == .update), !plugin.version.isEmpty {
                    PluginChip(text: "已是最新", tone: .soft)
                }
                let moved = plugin.moved
                if !(moved + plugin.serves).isEmpty, !plugin.off {
                    PluginChip(text: "承载 \((moved + plugin.serves).joined(separator: "、"))", tone: .good)
                }
                ForEach(Array(plugin.kindChips.enumerated()), id: \.offset) { _, chip in
                    PluginKindChip(kind: chip.kind, title: chip.title)
                }
            }
        }
    }

    static func workingText(_ op: String) -> String {
        switch op {
        case "add": "安装中…"
        case "remove": "移除中…"
        case "upgrade": "更新中…"
        case "off": "正在切换…"
        case "options": "正在保存选项…"
        case "move": "正在迁移…"
        case "prefer": "正在切换…"
        default: "处理中…"
        }
    }
}

/// 一个插件的状态说明（官方行的 sub、clashLine、mwLine、gatewayLine、agentLine、toolsLine、pageLine、panelsLine、actionsLine）。
struct PluginStatusLines: View {
    let store: PluginStore
    let plugin: WebPlugin
    var compact = false

    var body: some View {
        let subs = store.market.subs(for: PluginSpec.name(plugin.spec))
        let movable = plugin.off ? [] : store.market.movable(for: PluginSpec.name(plugin.spec))
        VStack(alignment: .leading, spacing: 3) {
            if let error = plugin.off ? nil : plugin.error {
                line("没有加载成功：\(error)", tone: .red)
            } else if plugin.off {
                line("关闭", tone: .secondary)
            } else if !subs.isEmpty {
                ForEach(subs) { sub in
                    let builtin = !sub.signedIn && movable.contains { $0.id == sub.pid }
                    HStack(spacing: 5) {
                        Circle().fill(sub.signedIn ? Color.green : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                        Text(sub.signedIn ? "\(sub.name)：已登录" : builtin ? "\(sub.name)：使用 magpie 内置" : "\(sub.name)：未登录")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            } else if let text = signsInText {
                line(text, tone: .secondary)
            }
            if !plugin.off, plugin.error == nil {
                ForEach(Array(PluginFormat.clashLines(plugin, ownName: store.shownName(plugin), nameOf: { nameOf($0) }).enumerated()), id: \.offset) { _, c in
                    line(c.text, tone: c.here ? .secondary : .orange)
                }
            }
            if !plugin.off {
                if let mw = plugin.middleware {
                    let l = PluginFormat.middlewareLine(mw)
                    line(l.text + (l.failures.isEmpty ? "" : " · " + l.failures.joined(separator: " · ")), tone: l.isError ? .red : .secondary)
                }
                if let gw = plugin.gateway { line(PluginFormat.gatewayLine(gw), tone: .secondary) }
                if let agent = plugin.agent {
                    let l = PluginFormat.agentLine(agent)
                    line(l.text, tone: l.isError ? .red : .secondary)
                }
                if !plugin.tools.isEmpty { line(PluginFormat.toolsLine(plugin.tools), tone: .secondary) }
            }
            if let page = plugin.page { line(PluginFormat.pageLine(page), tone: .secondary) }
            if !plugin.panels.isEmpty { line(PluginFormat.panelsLine(plugin.panels, reads: plugin.panelReads), tone: .secondary) }
            if !plugin.actions.isEmpty { line(PluginFormat.actionsLine(plugin.actions), tone: .secondary) }
        }
    }

    /// 官方行的 sub：只有中间件、请求 Hook、Agent、工具、页面或面板的插件，由下面各自的一行说明。
    private var signsInText: String? {
        let toolsOnly = !plugin.tools.isEmpty && plugin.providers.isEmpty
        let ownLine = plugin.middleware != nil || plugin.agent != nil || plugin.gateway != nil || plugin.isGateway || toolsOnly
            || ((plugin.page != nil || !plugin.panels.isEmpty) && plugin.inMagpieOnly)
        if ownLine && plugin.providers.isEmpty { return nil }
        if !plugin.clashes.isEmpty && plugin.providers.isEmpty { return nil }
        if !plugin.providers.isEmpty { return "可登录 \(plugin.providers.joined(separator: "、"))" }
        return plugin.named ? "没有 magpie 能用的登录" : nil
    }

    private func nameOf(_ spec: String) -> String { store.plugin(spec).map { store.shownName($0) } ?? PluginSpec.label(spec) }

    private func line(_ text: String, tone: Color) -> some View {
        Text(text).font(.caption).foregroundStyle(tone).lineLimit(compact ? 2 : nil)
    }
}

// MARK: 内置插件（官方 renderBuiltins + kernel.js 的 ui.form）

struct BuiltinPluginSection: View {
    let store: PluginStore
    let builtin: WebBuiltinPlugin
    @State private var drafts: [String: String] = [:]
    @State private var problem: [String: String] = [:]

    var body: some View {
        let broken = store.builtins?.first(where: { $0.broken != nil }) != nil
        Section {
            Toggle(isOn: Binding(get: { builtin.on }, set: { on in Task { await store.setBuiltin(builtin.id, on: on) } })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(builtin.title)
                    if !builtin.detail.isEmpty { Text(builtin.detail).font(.caption).foregroundStyle(.secondary) }
                    if builtin.inUse > 0 {
                        Text("正在使用，因此保持开启" + (builtin.use.map { "（\($0)）" } ?? "")).font(.caption).foregroundStyle(.orange)
                    }
                    if let why = builtin.why { Text(why).font(.caption).foregroundStyle(.orange) }
                }
            }
            .disabled(builtin.inUse > 0 || broken || store.busy["builtin:" + builtin.id] != nil)
            .accessibilityIdentifier("plugins.builtin.\(builtin.id)")

            if builtin.on, !broken {
                ForEach(builtin.settings) { setting in
                    settingRow(setting)
                }
            }
        }
    }

    @ViewBuilder
    private func settingRow(_ setting: PluginSetting) -> some View {
        let value = setting.value(in: builtin.config)
        VStack(alignment: .leading, spacing: 4) {
            switch setting.kind {
            case .boolean:
                Toggle(setting.title, isOn: Binding(get: { value.bool ?? false }, set: { on in save(setting, .bool(on)) }))
            case _ where !setting.choices.isEmpty:
                Picker(setting.title, selection: Binding(get: { value }, set: { save(setting, $0) })) {
                    ForEach(setting.choices, id: \.self) { choice in
                        Text(choice.string ?? PluginOptionText.text(choice)).tag(choice)
                    }
                }
                .pickerStyle(.menu)
            default:
                LabeledContent(setting.title) {
                    TextField(setting.title, text: Binding(get: { drafts[setting.key] ?? (value.isNull ? "" : PluginOptionText.text(value)) },
                                                           set: { drafts[setting.key] = $0 }))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(setting.kind == .string ? .default : .decimalPad)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { commit(setting) }
                }
                if drafts[setting.key] != nil {
                    HStack {
                        Spacer()
                        Button("取消") { drafts[setting.key] = nil; problem[setting.key] = nil }.buttonStyle(.borderless)
                        Button("保存") { commit(setting) }.buttonStyle(.borderless).fontWeight(.semibold)
                    }
                    .font(.footnote)
                }
            }
            if let problem = problem[setting.key] { Text(problem).font(.caption).foregroundStyle(.red) }
            if !setting.detail.isEmpty { Text(setting.detail).font(.caption).foregroundStyle(.secondary) }
        }
        .disabled(store.busy["builtin:" + builtin.id] != nil)
        .accessibilityIdentifier("builtin.setting.\(setting.key)")
    }

    private func commit(_ setting: PluginSetting) {
        guard let text = drafts[setting.key] else { return }
        guard let value = setting.parse(text) else {
            problem[setting.key] = "「\(setting.title)」的值不对" + rangeHint(setting)
            return
        }
        problem[setting.key] = nil
        drafts[setting.key] = nil
        if value != setting.value(in: builtin.config) { save(setting, value) }
    }

    private func rangeHint(_ setting: PluginSetting) -> String {
        switch (setting.minimum, setting.maximum) {
        case let (min?, max?): "（\(PluginOptionText.number(min)) 到 \(PluginOptionText.number(max))）"
        case let (min?, nil): "（不小于 \(PluginOptionText.number(min))）"
        case let (nil, max?): "（不大于 \(PluginOptionText.number(max))）"
        default: setting.kind == .integer ? "（整数）" : ""
        }
    }

    private func save(_ setting: PluginSetting, _ value: WebJSON) {
        Task { await store.saveBuiltinSetting(builtin.id, key: setting.key, value: value) }
    }
}

/// 选项值与文字之间的转换。
enum PluginOptionText {
    static func text(_ value: WebJSON) -> String {
        switch value {
        case .string(let text): return text
        case .null: return "null"
        default:
            guard let data = try? value.encoded() else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
    }

    static func number(_ value: Double) -> String {
        value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
    }

    /// 选项 JSON（官方编辑器用两格缩进）。
    static func pretty(_ options: [String: WebJSON]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(WebJSON.object(options)) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: 已有想装的？（官方 manual）

struct ManualInstallSection: View {
    let store: PluginStore
    let install: (String) -> Void
    @State private var text = ""

    var body: some View {
        Section {
            HStack {
                TextField("npm 包名、GitHub 仓库（github:owner/repo）或本机文件夹", text: $text)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit { go() }
                    .disabled(store.busy["+"] != nil)
                    .accessibilityIdentifier("plugins.manual.spec")
                Button(store.busy["+"] != nil ? "安装中…" : "安装") { go() }
                    .buttonStyle(.glassProminent)
                    .disabled(PluginRequests.normalizedSpec(text) == nil || store.isBusy)
                    .accessibilityIdentifier("plugins.manual.install")
            }
        } header: {
            Text("已有想装的？")
        } footer: {
            Text("例如 @scope/name、name@版本号、github:owner/repo，或这台 Mac 上的文件夹路径。")
        }
    }

    private func go() {
        guard let spec = PluginRequests.normalizedSpec(text), !store.isBusy else { return }
        install(spec)
    }
}

// MARK: npm 源（官方 registry.js）

struct RegistrySection: View {
    let store: PluginStore
    let registry: PluginRegistry
    @State private var editing = false
    @State private var draft = ""
    @State private var problem: String?

    var body: some View {
        Section {
            if editing {
                TextField("https://registry.npmmirror.com", text: $draft)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.done)
                    .onSubmit { save() }
                    .accessibilityIdentifier("plugins.registry.field")
                HStack {
                    Button("取消") { editing = false; draft = ""; problem = nil }.buttonStyle(.borderless)
                    Spacer()
                    Button("保存") { save() }
                        .buttonStyle(.borderless).fontWeight(.semibold)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || store.registrySaving)
                }
                if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text(registry.url).font(.callout.monospaced()).textSelection(.enabled)
                    Text(registry.fromText).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("plugins.registry")
                Button("修改") { editing = true; draft = registry.setHere ? registry.url : "" }
                if registry.setHere {
                    Button("使用默认") { Task { await store.setRegistry("") } }
                        .disabled(store.registrySaving)
                }
            }
        } header: {
            Text("npm 源")
        } footer: {
            Text(registry.setHere ? "在这里设置的源优先；「使用默认」改用 .npmrc、.bunfig.toml 或终端环境中设置的源，都没有则用 npm 官方源。"
                                  : "插件从这个源安装，版本也从这里查。在这里设置的源比 .npmrc、bunfig 与终端环境的都优先。")
        }
    }

    private func save() {
        let url = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        Task {
            if await store.setRegistry(url) {
                editing = false
                draft = ""
                problem = nil
            } else {
                problem = store.actionError?.message
                store.actionError = nil
            }
        }
    }
}

// MARK: 添加插件（工具栏「+」）

struct AddPluginSheet: View {
    let store: PluginStore
    let installed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var pending: String?

    private var normalized: String? { PluginRequests.normalizedSpec(text) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("npm 包名、GitHub 仓库或 Git 地址", text: $text)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .onSubmit { pending = normalized }
                        .accessibilityIdentifier("plugin.add.spec")
                    Button("添加") { pending = normalized }
                        .disabled(normalized == nil || store.isBusy)
                        .accessibilityIdentifier("plugin.add.submit")
                } header: {
                    Text("已有想装的？")
                } footer: {
                    Text("例如 @scope/name、name@版本号、github:owner/repo 或 https://github.com/owner/repo。也可以在「发现」里浏览 magpie 社区的插件。")
                }
            }
            .navigationTitle("添加插件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
            .confirmationDialog(title, isPresented: present($pending), titleVisibility: .visible, presenting: pending) { spec in
                Button(replacement(spec) == nil ? "安装" : "替换") {
                    dismiss()
                    installed()
                    Task { await store.install(spec, name: spec, key: "+") }
                }
            } message: { spec in
                Text(replacement(spec)?.message ?? "插件是他人的代码，会拿到你的登录或看到你的请求：只安装你信任的。将从 \(spec) 安装。")
            }
        }
    }

    private var title: String {
        guard let spec = pending else { return "" }
        return replacement(spec)?.title ?? "安装「\(spec)」？"
    }

    private func replacement(_ spec: String) -> PluginReplacement? { store.market.namesake(of: spec, typed: true) }
}
