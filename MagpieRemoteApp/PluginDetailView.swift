import SwiftUI
import MagpieRemoteCore

// 插件详情：已安装插件的管理页（官方「已安装」一行能做的事）与市场卡片的详情（官方 detail 对话框：
// 简介、npm 与 GitHub 的信息、链接、README）。

// MARK: 已安装插件

struct PluginDetailView: View {
    let store: PluginStore
    let spec: String
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemove = false
    @State private var confirmOff = false
    @State private var pendingOption: PluginProviderOption?
    @State private var pendingMove: PluginMoveCandidate?
    @State private var web: PluginWebTarget?

    var body: some View {
        Group {
            if let plugin = store.plugin(spec) {
                form(plugin)
            } else {
                ContentUnavailableView("插件已移除", systemImage: "puzzlepiece.extension", description: Text(spec))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("plugin.gone")
            }
        }
        .navigationTitle(store.plugin(spec).map { store.shownName($0) } ?? "插件")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $web) { target in PluginWebSheet(service: store.service, target: target) }
    }

    private func form(_ plugin: WebPlugin) -> some View {
        let package = PluginSpec.name(plugin.spec)
        let card = store.card(for: plugin)
        let subs = store.market.subs(for: package)
        let working = store.busy[package] ?? store.busy[plugin.spec]
        return Form {
            Section {
                PluginHeader(store: store, listing: card, kind: plugin.logoKind, chips: plugin.kindChips)
            }
            .listRowBackground(Color.clear)

            Section {
                Toggle("启用", isOn: Binding(get: { !plugin.off }, set: { on in
                    if !on, !plugin.moved.isEmpty { confirmOff = true } else { Task { await store.setEnabled(plugin, on) } }
                }))
                .disabled(working != nil)
                .accessibilityIdentifier("plugin.toggle")
                if let working {
                    HStack { ProgressView(); Text(InstalledPluginRow.workingText(working)).foregroundStyle(.secondary) }
                }
                if let error = plugin.error {
                    Label("没有加载成功：\(error)", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.red)
                        .accessibilityIdentifier("plugin.error")
                }
            } footer: {
                Text("停用后插件不再运行，选项与登录保留。")
            }

            statusSection(plugin, subs: subs)
            updateSection(plugin)
            optionsSection(plugin)
            windowsSection(plugin)
            PluginFactsSection(store: store, listing: card, installed: plugin)
            PluginReadmeSection(store: store, name: card.package)

            Section {
                Button("移除插件", role: .destructive) { confirmRemove = true }
                    .disabled(store.isBusy)
                    .accessibilityIdentifier("plugin.remove")
            } footer: {
                Text("插件是他人的代码：由它登录并发出请求，或作为中间件看到请求。")
            }
        }
        .confirmationDialog("移除 \(store.shownName(plugin))？", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("移除", role: .destructive) {
                Task { if await store.remove(plugin) { dismiss() } }
            }
        } message: {
            Text(plugin.moved.isEmpty ? "移除插件及其安装的内容；它的登录会保留，直到你退出登录。"
                                      : "\(plugin.moved.joined(separator: "、")) 会停用，直到再次安装插件。它的账号会保留。")
        }
        .confirmationDialog("停用 \(store.shownName(plugin))？", isPresented: $confirmOff, titleVisibility: .visible) {
            Button("停用", role: .destructive) { Task { await store.setEnabled(plugin, false) } }
        } message: {
            Text("插件停用期间，\(plugin.moved.joined(separator: "、")) 也会停用。它的账号会保留。")
        }
        .confirmationDialog(pendingOption?.label ?? "", isPresented: present($pendingOption), titleVisibility: .visible, presenting: pendingOption) { option in
            Button("打开") { Task { await store.setProviderOption(option, on: true) } }
        } message: { option in
            Text(option.confirm)
        }
        .confirmationDialog("把 \(pendingMove?.name ?? "") 迁到这里？", isPresented: present($pendingMove), titleVisibility: .visible,
                            presenting: pendingMove) { candidate in
            Button("迁移") { Task { await store.move(candidate) } }
        } message: { candidate in
            Text("改由此插件运行 \(candidate.name)，账号不变；有账号无法使用时不做改动。")
        }
        .pluginAlerts(store: store, id: "plugin.detail")
    }

    /// 登录状态、两个插件冲突、中间件 / Hook / Agent / 工具 / 页面的说明，以及「登录」「迁移到这里」「用于 …」。
    @ViewBuilder
    private func statusSection(_ plugin: WebPlugin, subs: [PluginSub]) -> some View {
        let package = PluginSpec.name(plugin.spec)
        let here = (!plugin.off && plugin.error == nil && !subs.contains { $0.signedIn }) ? store.market.movable(for: package).first : nil
        let prefer = (plugin.off || plugin.error != nil) ? [] : plugin.clashes.filter { $0.by != plugin.spec }
        let out = (!plugin.off && plugin.error == nil) ? subs.first { !$0.signedIn } : nil
        let signedIn = subs.first { $0.signedIn }
        Section("状态") {
            PluginStatusLines(store: store, plugin: plugin)
            if let here {
                Button("把 \(here.name) 迁到这里") { pendingMove = here }
                    .disabled(store.isBusy)
            }
            ForEach(prefer, id: \.id) { clash in
                Button("用于 \(clash.name)") { Task { await store.prefer(plugin, clash: clash) } }
                    .disabled(store.isBusy)
                    .accessibilityHint("\(clash.name) 改由这个插件提供；两个插件都保留")
            }
            if let out {
                Button(signedIn == nil ? "登录" : "登录 \(out.name)") {
                    web = PluginWebTarget(view: "providers", title: "登录 \(out.name)")
                }
                .accessibilityIdentifier("plugin.signin")
            }
            if let signedIn {
                Button("在「供应商」中打开 \(signedIn.name)") {
                    web = PluginWebTarget(view: "providers", extra: [URLQueryItem(name: "edit", value: signedIn.id)], title: signedIn.name)
                }
            }
        }
    }

    @ViewBuilder
    private func updateSection(_ plugin: WebPlugin) -> some View {
        let check = store.versionCheck(for: plugin.spec)
        if plugin.updateOffered || check != nil || plugin.autoUpdated != nil {
            Section {
                if let check { Text(check.summary).font(.footnote).foregroundStyle(check.status == .unknown ? .orange : .secondary) }
                if let auto = plugin.autoUpdated, auto.to == plugin.version {
                    Text("magpie 已于 \(Self.day(auto.at)) 自动将它从 v\(auto.from) 更新到 v\(auto.to)").font(.footnote).foregroundStyle(.secondary)
                }
                if plugin.updateOffered {
                    Button(plugin.npmUpdate ? "更新到 v\(plugin.latest)" : "重新从 \(plugin.spec) 获取") { Task { await store.upgrade(plugin) } }
                        .disabled(store.isBusy || store.checking)
                        .accessibilityIdentifier("plugin.upgrade")
                }
            } header: {
                Text("更新")
            } footer: {
                if plugin.gitBehind {
                    Text("已安装 \(plugin.commit)，\(plugin.spec) 已到 \(plugin.head)")
                } else if plugin.npmUpdate, PluginSpec.name(plugin.spec).hasPrefix("@magpie-community/") {
                    Text("一小时内自动更新；点「更新」立即更新")
                }
            }
        }
    }

    @ViewBuilder
    private func optionsSection(_ plugin: WebPlugin) -> some View {
        let switches = store.providerOptions(for: plugin.spec)
        if plugin.hasOptionsEditor || !switches.isEmpty {
            Section {
                if plugin.hasOptionsEditor {
                    NavigationLink {
                        PluginOptionsEditor(store: store, spec: plugin.spec)
                    } label: {
                        LabeledContent("选项", value: plugin.options.isEmpty ? "未设置" : "\(plugin.options.count) 项")
                    }
                    .disabled(store.busy[PluginSpec.name(plugin.spec)] != nil)
                    .accessibilityIdentifier("plugin.options")
                }
                ForEach(switches) { option in
                    Toggle(isOn: Binding(get: { option.on }, set: { on in
                        if on, !option.confirm.isEmpty { pendingOption = option } else { Task { await store.setProviderOption(option, on: on) } }
                    })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label)
                            Text(option.detail.isEmpty ? option.providerName : "\(option.providerName) · \(option.detail)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("plugin.switch.\(option.key)")
                }
            } header: {
                Text("选项")
            } footer: {
                if plugin.hasOptionsEditor {
                    Text(plugin.options.isEmpty ? "它没有设置选项，包里有建议的选项。" : "它运行时用的选项，下一个请求起生效。")
                }
            }
        }
    }

    @ViewBuilder
    private func windowsSection(_ plugin: WebPlugin) -> some View {
        let pages = store.pages(for: plugin.spec)
        let panels = store.panels(for: plugin.spec)
        if !pages.isEmpty || !panels.isEmpty {
            Section {
                ForEach(pages) { page in
                    Button {
                        web = PluginWebTarget(view: page.key, title: page.title)
                    } label: {
                        Label(page.title, systemImage: "macwindow")
                    }
                    .accessibilityIdentifier("plugin.page.\(page.key)")
                }
                ForEach(panels) { panel in
                    Button {
                        web = PluginWebTarget(view: panel.slot, title: panel.title)
                    } label: {
                        LabeledContent { Text("在「\(panel.slot)」页") } label: { Label(panel.title, systemImage: "rectangle.on.rectangle") }
                    }
                }
            } header: {
                Text("页面与面板")
            } footer: {
                Text("插件的页面和面板在 magpie 网页里运行，会在 App 内打开主机上的 magpie 网页。")
            }
        }
    }

    static func day(_ text: String) -> String {
        PluginFormat.date(text).map { $0.formatted(.dateTime.month().day()) } ?? text
    }
}

// MARK: 详情页头（官方 pm-dhead）

struct PluginHeader: View {
    let store: PluginStore
    let listing: WebPluginListing
    let kind: PluginKind
    var chips: [(kind: PluginKind, title: String)] = []

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            PluginLogo(store: store, icon: listing.logo, kind: kind, big: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(listing.name).font(.title3.weight(.bold)).lineLimit(2)
                Text(by).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                if !chips.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in PluginKindChip(kind: chip.kind, title: chip.title) }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var by: String {
        if listing.community { return "magpie 社区 · " + listing.package }
        return [listing.npm?.publisher ?? "", listing.package].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: 信息与链接（官方 pm-facts / pm-links）

struct PluginFactsSection: View {
    let store: PluginStore
    let listing: WebPluginListing
    var installed: WebPlugin?

    var body: some View {
        let local = PluginSpec.isPath(listing.package) || PluginSpec.isGit(listing.package)
        let npm = listing.npm
        Section {
            if !listing.summary.isEmpty { Text(listing.summary).font(.callout) }
            if let installed, !installed.version.isEmpty {
                LabeledContent("版本", value: "v\(installed.version)")
            } else if let version = npm?.version, !version.isEmpty {
                LabeledContent("版本", value: "v\(version)")
            }
            if let installed, installed.source == .git, !installed.commit.isEmpty {
                LabeledContent("提交") { Text(installed.commit).font(.callout.monospaced()) }
            }
            if let weekly = npm?.weekly, weekly > 0 { LabeledContent("下载量", value: "\(PluginFormat.count(weekly))/周") }
            if let gh = listing.github { LabeledContent("Star", value: PluginFormat.count(gh.stars)) }
            if let license = npm?.license, !license.isEmpty { LabeledContent("许可证", value: license) }
            LabeledContent("更新于", value: updated)
            if !listing.providers.isEmpty { LabeledContent("登录", value: listing.providers.joined(separator: "、")) }
            if let installed {
                LabeledContent("来源", value: installed.source.title)
                LabeledContent("规格") {
                    Text(installed.spec).font(.callout.monospaced()).textSelection(.enabled).multilineTextAlignment(.trailing)
                }
            }
            if !local, let url = URL(string: "https://www.npmjs.com/package/" + listing.package) {
                Link(destination: url) { Label("npm", systemImage: "arrow.up.right.square") }
            }
            if let repo = npm?.repository, !repo.isEmpty, let url = URL(string: repo) {
                Link(destination: url) { Label(listing.github != nil ? "GitHub" : "源码", systemImage: "arrow.up.right.square") }
            }
            if let home = npm?.homepage, !home.isEmpty, home != npm?.repository, !home.hasPrefix((npm?.repository ?? "") + "#"), let url = URL(string: home) {
                Link(destination: url) { Label("主页", systemImage: "arrow.up.right.square") }
            }
            if let gh = listing.github {
                Label(PluginSpec.isGit(listing.package)
                      ? "非官方插件：\(gh.owner) 在 GitHub 上给它打了 \(store.taggedInfo?.topic ?? "magpie-plugin") 标签，magpie 没有审阅过。安装的是仓库当前的代码，它会用到你的登录信息或经手你的请求。"
                      : "非官方插件：\(gh.owner) 在 GitHub 上给它打了 \(store.taggedInfo?.topic ?? "magpie-plugin") 标签，magpie 没有审阅过。安装的是作者从这个仓库发布到 npm 的版本，它会用到你的登录信息或经手你的请求。",
                      systemImage: "checkmark.shield")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if !listing.replaces.isEmpty {
                Text("magpie 内置的此订阅登录已弃用：由此插件接替，内置里登录的账号会迁到插件。").font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("信息")
        }
    }

    private var updated: String {
        if let gh = listing.github, installed == nil, let date = PluginFormat.date(gh.pushed) {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        if let page = store.readmes[listing.package] {
            return page.updatedDate?.formatted(date: .abbreviated, time: .omitted) ?? "—"
        }
        return store.readmeErrors[listing.package] != nil ? "—" : "…"
    }
}

// MARK: README

struct PluginReadmeSection: View {
    let store: PluginStore
    let name: String

    var body: some View {
        Section("README") {
            if let page = store.readmes[name] {
                let blocks = PluginReadme.blocks(page.readme)
                if blocks.isEmpty {
                    Text("没有 README").foregroundStyle(.secondary)
                } else {
                    PluginReadmeView(blocks: blocks).padding(.vertical, 4)
                }
            } else if let error = store.readmeErrors[name] {
                Text(errorText(error)).font(.footnote).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) { ProgressView(); Text("正在读取 README…").foregroundStyle(.secondary) }
            }
        }
        .accessibilityIdentifier("plugin.readme")
        .task(id: name) { await store.loadReadme(name) }
    }

    private func errorText(_ error: String) -> String {
        if PluginSpec.isGit(name), store.market.entry(for: name) == nil { return "GitHub 没有响应：\(error)" }
        if PluginSpec.isPath(name) || PluginSpec.isGit(name) { return "无法读取该文件夹的 README：\(error)" }
        return "npm 没有响应：\(error)"
    }
}

// MARK: 市场卡片的详情（官方 detail）

struct PluginListingSheet: View {
    let store: PluginStore
    let listing: WebPluginListing
    let install: (WebPluginListing) -> Void
    let move: (PluginMoveCandidate) -> Void
    let signIn: (PluginSub) -> Void
    let openProvider: (PluginSub) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(alignment: .center) {
                        PluginHeader(store: store, listing: current, kind: current.pluginKind,
                                     chips: [(current.pluginKind, current.kind == "hooks" ? "请求 Hook" : current.pluginKind.title)])
                        Spacer(minLength: 8)
                        PluginActionButton(store: store, listing: current,
                                           onInstall: { l in dismiss(); install(l) },
                                           onMove: { c in dismiss(); move(c) },
                                           onSignIn: signIn, onOpen: openProvider)
                    }
                }
                .listRowBackground(Color.clear)
                if let entry = store.market.entry(for: listing.package) {
                    Section {
                        NavigationLink("管理已安装的插件") { PluginDetailView(store: store, spec: entry.spec) }
                            .accessibilityIdentifier("plugin.sheet.manage")
                    }
                }
                PluginFactsSection(store: store, listing: current)
                PluginReadmeSection(store: store, name: listing.package)
                Section {} footer: {
                    Text("插件是他人的代码：由它登录并发出请求，或作为中间件看到请求。")
                }
            }
            .navigationTitle(listing.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
            .pluginAlerts(store: store, id: "plugin.sheet")
        }
        .accessibilityIdentifier("plugin.sheet")
    }

    /// 卡片打开后 npm 才回答的，也跟着更新（官方 redrawAct）。
    private var current: WebPluginListing {
        if let npm = store.npm[listing.package], listing.github == nil { return listing.with(npm: npm) }
        return listing
    }
}

// MARK: 选项（官方 optionsEditor：JSON）

struct PluginOptionsEditor: View {
    let store: PluginStore
    let spec: String
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var loaded = false
    @State private var problem: String?
    @State private var confirmClear = false

    var body: some View {
        let plugin = store.plugin(spec)
        Form {
            Section {
                TextEditor(text: $text)
                    .font(.callout.monospaced())
                    .frame(minHeight: 180)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("plugin.options.text")
            } footer: {
                Text(plugin?.options.isEmpty == false ? "下一个请求起生效" : "未设置：这是包里给的示例")
            }
            if let problem {
                Section { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.footnote) }
            }
            if plugin?.options.isEmpty == false {
                Section {
                    Button("清空", role: .destructive) { confirmClear = true }
                        .accessibilityIdentifier("plugin.options.clear")
                } footer: {
                    Text("不带选项运行它")
                }
            }
        }
        .navigationTitle("选项")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { Task { await save() } }
                    .disabled(store.isBusy)
                    .accessibilityIdentifier("plugin.options.save")
            }
        }
        .onAppear {
            guard !loaded, let plugin else { return }
            loaded = true
            text = PluginOptionText.pretty(plugin.options.isEmpty ? plugin.optionsExample : plugin.options)
        }
        .confirmationDialog("清空", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                Task {
                    guard let plugin else { return }
                    if await store.saveOptions(plugin, nil) { dismiss() }
                }
            }
        } message: {
            Text("已保存的中间件选项将被移除。插件将不带选项运行。")
        }
        .pluginAlerts(store: store, id: "plugin.options")
    }

    private func save() async {
        guard let plugin = store.plugin(spec) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: WebJSON
        do {
            value = try WebJSON.decode(Data((trimmed.isEmpty ? "{}" : trimmed).utf8))
        } catch {
            problem = "不是 JSON：\(error.localizedDescription)"
            return
        }
        guard let options = value.object else {
            problem = "选项须是一个 JSON 对象"
            return
        }
        problem = nil
        if await store.saveOptions(plugin, options) { dismiss() }
    }
}
