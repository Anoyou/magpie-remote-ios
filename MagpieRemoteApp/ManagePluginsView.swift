import SwiftUI
import MagpieRemoteCore

/// 「管理 › 插件」：主机上 magpie 已安装的插件与内置插件。可开关、检查更新、从 npm / GitHub / 市场添加、
/// 移除（先确认）、编辑选项；插件自带的页面在 App 内用 magpie 网页打开。
struct ManagePluginsView: View {
    let manage: ManageStore
    @State private var store = PluginStore()
    @State private var showAdd = false
    @State private var pendingRemove: WebPlugin?

    var body: some View {
        List {
            statusSection

            if store.phase == .ready || store.state != nil {
                installedSection
                updateSection
                if !store.pages.isEmpty { pagesSection }
                builtinSection
                webSection
            }
        }
        .navigationTitle("插件")
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
        }
        .refreshable { await store.refresh() }
        .task(id: manage.service.map { String(describing: type(of: $0)) } ?? "none") { await store.configure(manage: manage.service) }
        .onAppear { Task { await store.configure(manage: manage.service) } }
        .sheet(isPresented: $showAdd) { AddPluginSheet(store: store) }
        .confirmationDialog("移除插件「\(pendingRemove?.displayName ?? "")」？", isPresented: present($pendingRemove),
                            titleVisibility: .visible, presenting: pendingRemove) { plugin in
            Button("移除插件", role: .destructive) { Task { await store.remove(plugin.spec) } }
        } message: { _ in
            Text("会从 Mac 上的 magpie 卸载它；它提供的供应商、页面和工具随之消失。")
        }
        .pluginAlerts(store: store, id: "plugins")
    }

    @ViewBuilder
    private var statusSection: some View {
        switch store.phase {
        case .idle:
            if manage.service == nil {
                Section { Text("先在「管理」页连接主机并填写 Web 密钥。").foregroundStyle(.secondary) }
            }
        case .loading:
            Section {
                HStack { ProgressView(); Text("正在读取插件…").foregroundStyle(.secondary) }
            }
        case .failed(let error):
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label(error.title, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(error.message).font(.footnote)
                    if let hint = error.hint { Text(hint).font(.footnote).foregroundStyle(.secondary) }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("plugins.error")
                Button("重试") { Task { await store.refresh() } }
            }
        case .ready:
            if let notice = store.notice {
                Section {
                    Label(notice, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("plugins.notice")
                }
            }
            if let error = store.state?.error {
                Section {
                    Label("有插件没能读取：\(error)", systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                }
            }
        }
    }

    private var installedSection: some View {
        Section {
            if store.installed.isEmpty {
                Text("还没有安装插件。点右上角「+」从市场或 npm 添加。")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("plugins.empty")
            }
            ForEach(store.installed) { plugin in
                NavigationLink {
                    PluginDetailView(store: store, spec: plugin.spec)
                } label: {
                    PluginRow(store: store, plugin: plugin)
                }
                .accessibilityIdentifier("plugins.row.\(plugin.spec)")
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("移除", role: .destructive) { pendingRemove = plugin }
                }
            }
        } header: {
            Text("已安装")
        } footer: {
            if let state = store.state, !state.bun {
                Text("这台 Mac 上还没有 Bun：添加第一个插件时 magpie 会先下载它，需要多等一会儿。")
            }
        }
    }

    private var updateSection: some View {
        Section {
            Button {
                Task { await store.checkUpdates() }
            } label: {
                HStack {
                    Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if store.checking { ProgressView() }
                }
            }
            .disabled(store.busy || store.installed.isEmpty)
            .accessibilityIdentifier("plugins.check")
            if let check = store.check {
                Text(check.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("plugins.check.result")
                if !check.updates.isEmpty {
                    Button("全部更新（\(check.updates.count) 个）") { Task { await store.updateAll() } }
                        .disabled(store.busy)
                        .accessibilityIdentifier("plugins.updateAll")
                }
            }
            if let label = store.working["*"] {
                HStack { ProgressView(); Text(label).foregroundStyle(.secondary) }
            }
        } footer: {
            Text("检查只问 npm 和代码仓库有没有新版本，不会安装；官方社区插件 magpie 也会自己更新。")
        }
    }

    private var pagesSection: some View {
        Section {
            ForEach(store.pages) { page in
                NavigationLink {
                    PluginWebPageView(service: store.service, view: page.key, title: page.title)
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

    private var builtinSection: some View {
        Section {
            ForEach(store.builtins) { builtin in
                NavigationLink {
                    BuiltinPluginDetailView(store: store, id: builtin.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(builtin.title).foregroundStyle(builtin.on ? .primary : .secondary)
                            if !builtin.detail.isEmpty {
                                Text(builtin.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer()
                        Text(builtin.on ? "已开启" : "已关闭").font(.caption).foregroundStyle(builtin.on ? .green : .secondary)
                    }
                }
                .accessibilityIdentifier("plugins.builtin.\(builtin.id)")
            }
        } header: {
            Text("内置插件")
        } footer: {
            Text("magpie 自带的功能。关掉的插件，它的页面和设置会从 magpie 里隐藏；正在使用的不能关。")
        }
    }

    private var webSection: some View {
        Section {
            NavigationLink {
                PluginWebPageView(service: store.service, view: "plugins", title: "插件（网页）")
            } label: {
                Label("在网页中打开插件页", systemImage: "safari")
            }
            .accessibilityIdentifier("plugins.web")
        } footer: {
            Text("登录插件的供应商、处理插件冲突、国内镜像与 npm 源等设置，在 magpie 网页里完成。")
        }
    }
}

/// 列表里的一行插件。
private struct PluginRow: View {
    let store: PluginStore
    let plugin: WebPlugin

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "puzzlepiece.extension")
                .foregroundStyle(plugin.enabled ? Color.accentColor : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(plugin.displayName).foregroundStyle(plugin.enabled ? .primary : .secondary)
                    if !plugin.version.isEmpty {
                        Text("v\(plugin.version)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                let summary = store.summary(for: plugin)
                if !summary.isEmpty {
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 8) {
                    if !plugin.enabled { badge("已停用", .secondary) }
                    if plugin.error != nil { badge("加载失败", .red) }
                    if let update = store.availableUpdate(for: plugin) { badge(update.first?.isNumber == true ? "可更新到 v\(update)" : "有更新", .blue) }
                    if let working = store.working[plugin.spec] {
                        ProgressView().controlSize(.mini)
                        Text(working).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(color)
    }
}

// MARK: 插件详情

struct PluginDetailView: View {
    let store: PluginStore
    let spec: String
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemove = false
    @State private var pendingOption: PluginProviderOption?

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
        .navigationTitle(store.plugin(spec)?.displayName ?? "插件")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func form(_ plugin: WebPlugin) -> some View {
        Form {
            Section {
                Toggle("启用", isOn: Binding(get: { plugin.enabled }, set: { on in
                    Task { await store.setEnabled(plugin.spec, on) }
                }))
                .disabled(store.working[plugin.spec] != nil)
                .accessibilityIdentifier("plugin.toggle")
                if let working = store.working[plugin.spec] {
                    HStack { ProgressView(); Text(working).foregroundStyle(.secondary) }
                }
                if let error = plugin.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.red)
                        .accessibilityIdentifier("plugin.error")
                }
            } footer: {
                Text("停用后插件不再运行，设置与选项保留。")
            }

            Section("信息") {
                let summary = store.summary(for: plugin)
                if !summary.isEmpty { Text(summary).font(.callout) }
                LabeledContent("版本", value: plugin.version.isEmpty ? "未知" : "v\(plugin.version)")
                if plugin.source == .git, !plugin.commit.isEmpty { LabeledContent("提交", value: plugin.commit) }
                LabeledContent("来源", value: plugin.source.title)
                LabeledContent("规格") {
                    Text(plugin.spec).font(.callout.monospaced()).textSelection(.enabled).multilineTextAlignment(.trailing)
                }
                if !plugin.kinds.isEmpty { LabeledContent("提供", value: plugin.kinds.joined(separator: "、")) }
            }

            updateSection(plugin)

            let switches = store.providerOptions(for: plugin.spec)
            Section {
                NavigationLink {
                    PluginOptionsEditor(store: store, plugin: plugin)
                } label: {
                    LabeledContent("插件选项", value: plugin.options.isEmpty ? "未设置" : "\(plugin.options.count) 项")
                }
                .accessibilityIdentifier("plugin.options")
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
                Text("插件选项会原样交给插件，改动后插件会重新启动。")
            }

            let pages = store.pages(for: plugin.spec)
            let panels = store.panels(for: plugin.spec)
            if !pages.isEmpty || !panels.isEmpty {
                Section {
                    ForEach(pages) { page in
                        NavigationLink {
                            PluginWebPageView(service: store.service, view: page.key, title: page.title)
                        } label: {
                            Label(page.title, systemImage: "macwindow")
                        }
                        .accessibilityIdentifier("plugin.page.\(page.key)")
                    }
                    ForEach(panels) { panel in
                        NavigationLink {
                            PluginWebPageView(service: store.service, view: panel.slot, title: panel.title)
                        } label: {
                            LabeledContent { Text("在「\(panel.slot)」页") } label: { Label(panel.title, systemImage: "rectangle.on.rectangle") }
                        }
                    }
                } header: {
                    Text("页面与面板")
                } footer: {
                    Text("会在 App 内打开主机上的 magpie 网页。")
                }
            }

            Section {
                Button("移除插件", role: .destructive) { confirmRemove = true }
                    .disabled(store.working[plugin.spec] != nil)
                    .accessibilityIdentifier("plugin.remove")
            }
        }
        .confirmationDialog("移除插件「\(plugin.displayName)」？", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("移除插件", role: .destructive) {
                Task {
                    if await store.remove(plugin.spec) { dismiss() }
                }
            }
        } message: {
            Text("会从 Mac 上的 magpie 卸载它；它提供的供应商、页面和工具随之消失。")
        }
        .confirmationDialog(pendingOption?.label ?? "", isPresented: present($pendingOption), titleVisibility: .visible, presenting: pendingOption) { option in
            Button("打开") { Task { await store.setProviderOption(option, on: true) } }
        } message: { option in
            Text(option.confirm)
        }
        .pluginAlerts(store: store, id: "plugin.detail")
    }

    @ViewBuilder
    private func updateSection(_ plugin: WebPlugin) -> some View {
        let update = store.availableUpdate(for: plugin)
        let check = store.versionCheck(for: plugin.spec)
        if update != nil || check != nil {
            Section("更新") {
                if let check { Text(check.summary).font(.footnote).foregroundStyle(.secondary) }
                if let update {
                    Button(update.first?.isNumber == true ? "更新到 v\(update)" : "更新") { Task { await store.upgrade(plugin.spec) } }
                        .disabled(store.busy)
                        .accessibilityIdentifier("plugin.upgrade")
                }
            }
        }
    }
}

// MARK: 插件选项

/// 插件选项（`plugins.json` 的 options）：保存时整份替换。布尔、数字、文字直接编辑，数组与对象按 JSON 编辑。
struct PluginOptionsEditor: View {
    let store: PluginStore
    let plugin: WebPlugin
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [OptionRow]
    @State private var newKey = ""
    @State private var newValue = ""
    @State private var problem: String?

    struct OptionRow: Identifiable, Equatable {
        var id = UUID()
        var key: String
        var value: WebJSON
        var text: String
    }

    init(store: PluginStore, plugin: WebPlugin) {
        self.store = store
        self.plugin = plugin
        _rows = State(initialValue: Self.rows(plugin.options))
    }

    static func rows(_ options: [String: WebJSON]) -> [OptionRow] {
        options.keys.sorted().map { key in
            OptionRow(key: key, value: options[key] ?? .null, text: PluginOptionText.text(options[key] ?? .null))
        }
    }

    var body: some View {
        Form {
            if rows.isEmpty {
                Section {
                    Text("还没有选项。").foregroundStyle(.secondary)
                    if !plugin.optionsExample.isEmpty {
                        Button("从插件建议的选项开始") { rows = Self.rows(plugin.optionsExample) }
                            .accessibilityIdentifier("plugin.options.example")
                    }
                }
            }
            Section {
                ForEach($rows) { $row in
                    if row.value.bool != nil {
                        Toggle(row.key, isOn: Binding(get: { row.value.bool ?? false }, set: { row.value = .bool($0); row.text = $0 ? "true" : "false" }))
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.key).font(.caption).foregroundStyle(.secondary)
                            TextField("值", text: $row.text, axis: .vertical)
                                .font(row.value.string == nil ? .callout.monospaced() : .body)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                    }
                }
                .onDelete { rows.remove(atOffsets: $0) }
            } footer: {
                if !rows.isEmpty { Text("左滑删除一项。数组和对象按 JSON 填写。") }
            }

            Section("添加一项") {
                TextField("名称", text: $newKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("plugin.options.newKey")
                TextField("值（true、数字、文字或 JSON）", text: $newValue)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("添加") {
                    let key = newKey.trimmingCharacters(in: .whitespaces)
                    let value = PluginOptionText.parse(newValue, like: nil)
                    rows.removeAll { $0.key == key }
                    rows.append(OptionRow(key: key, value: value, text: PluginOptionText.text(value)))
                    newKey = ""; newValue = ""
                }
                .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let problem {
                Section { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.footnote) }
            }
        }
        .navigationTitle("插件选项")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { Task { await save() } }
                    .disabled(store.working[plugin.spec] != nil)
                    .accessibilityIdentifier("plugin.options.save")
            }
        }
        .pluginAlerts(store: store, id: "plugin.options")
    }

    private func save() async {
        var options: [String: WebJSON] = [:]
        for row in rows {
            guard !row.key.isEmpty else { continue }
            if row.value.bool != nil {
                options[row.key] = row.value
                continue
            }
            let value = PluginOptionText.parse(row.text, like: row.value)
            if (row.value.array != nil || row.value.object != nil), value.string != nil {
                problem = "「\(row.key)」不是有效的 JSON。"
                return
            }
            options[row.key] = value
        }
        problem = nil
        if await store.saveOptions(plugin.spec, options) { dismiss() }
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

    /// 原来是文字的继续当文字；其余先按 JSON 解析，不是 JSON 时当文字。
    static func parse(_ text: String, like original: WebJSON?) -> WebJSON {
        if case .string = original { return .string(text) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let json = try? WebJSON.decode(Data(trimmed.utf8)) { return json }
        return .string(text)
    }
}

// MARK: 内置插件

struct BuiltinPluginDetailView: View {
    let store: PluginStore
    let id: String
    @State private var drafts: [String: String] = [:]
    @State private var problem: String?

    var body: some View {
        Group {
            if let builtin = store.builtin(id) {
                form(builtin)
            } else {
                ContentUnavailableView("没有这个内置插件", systemImage: "puzzlepiece")
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("builtin.gone")
            }
        }
        .navigationTitle(store.builtin(id)?.title ?? "内置插件")
        .navigationBarTitleDisplayMode(.inline)
        .pluginAlerts(store: store, id: "builtin")
    }

    private func form(_ builtin: WebBuiltinPlugin) -> some View {
        Form {
            Section {
                Toggle("启用", isOn: Binding(get: { builtin.chosen }, set: { on in
                    Task { await store.setBuiltin(builtin.id, on: on) }
                }))
                .disabled(!builtin.canToggle || store.working["builtin:" + builtin.id] != nil)
                .accessibilityIdentifier("builtin.toggle")
                LabeledContent("状态", value: builtin.stateText)
                if let why = builtin.why { Text(why).font(.footnote).foregroundStyle(.orange) }
            } header: {
                if !builtin.detail.isEmpty { Text(builtin.detail).textCase(nil) }
            } footer: {
                if let broken = builtin.broken {
                    Text("magpie 的 plugins.yml 读不了，暂时不能修改：\(broken)")
                } else if builtin.inUse > 0 {
                    Text("正在使用，不能关闭" + (builtin.use.map { "（\($0)）" } ?? "") + "。")
                }
            }

            let settings = builtin.settings
            if !settings.isEmpty {
                Section {
                    ForEach(settings) { setting in
                        settingRow(setting, builtin: builtin)
                    }
                } header: {
                    Text("设置")
                } footer: {
                    if let problem { Text(problem).foregroundStyle(.red) }
                }
                Section {
                    Button("保存设置") { Task { await save(builtin) } }
                        .disabled(drafts.isEmpty || store.working["builtin:" + builtin.id] != nil)
                        .accessibilityIdentifier("builtin.save")
                }
            }
        }
    }

    private func current(_ setting: PluginSetting, _ builtin: WebBuiltinPlugin) -> String {
        if let draft = drafts[setting.key] { return draft }
        let value = setting.value(in: builtin.config)
        return value.isNull ? "" : PluginOptionText.text(value)
    }

    @ViewBuilder
    private func settingRow(_ setting: PluginSetting, builtin: WebBuiltinPlugin) -> some View {
        let binding = Binding<String>(get: { current(setting, builtin) }, set: { drafts[setting.key] = $0 })
        VStack(alignment: .leading, spacing: 4) {
            switch setting.kind {
            case .boolean:
                Toggle(setting.title, isOn: Binding(get: { binding.wrappedValue == "true" }, set: { binding.wrappedValue = $0 ? "true" : "false" }))
            case .string where !setting.choices.isEmpty:
                Picker(setting.title, selection: binding) {
                    ForEach(setting.choices.compactMap(\.string), id: \.self) { Text($0).tag($0) }
                }
            default:
                Text(setting.title).font(.caption).foregroundStyle(.secondary)
                TextField(setting.title, text: binding)
                    .keyboardType(setting.kind == .string ? .default : .decimalPad)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            if !setting.detail.isEmpty { Text(setting.detail).font(.caption).foregroundStyle(.secondary) }
        }
        .accessibilityIdentifier("builtin.setting.\(setting.key)")
    }

    private func save(_ builtin: WebBuiltinPlugin) async {
        var config: [String: WebJSON] = [:]
        for setting in builtin.settings {
            guard let text = drafts[setting.key] else { continue }
            guard let value = setting.parse(text) else {
                problem = "「\(setting.title)」的值不对。"
                return
            }
            if value != setting.value(in: builtin.config) { config[setting.key] = value }
        }
        problem = nil
        if await store.saveBuiltinConfig(builtin.id, config) { drafts = [:] }
    }
}

// MARK: 添加插件

struct AddPluginSheet: View {
    let store: PluginStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var pending: Pending?
    @State private var installing: String?

    struct Pending: Identifiable {
        var spec: String
        var name: String
        var id: String { spec }
    }

    private var normalized: String? { PluginRequests.normalizedSpec(text) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("npm 包名、GitHub 仓库或 Git 地址", text: $text)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .onSubmit { if let spec = normalized { pending = Pending(spec: spec, name: spec) } }
                        .accessibilityIdentifier("plugin.add.spec")
                    Button("添加") { if let spec = normalized { pending = Pending(spec: spec, name: spec) } }
                        .disabled(normalized == nil || installing != nil)
                        .accessibilityIdentifier("plugin.add.submit")
                } header: {
                    Text("从地址添加")
                } footer: {
                    Text("例如 @scope/name、name@版本号、github:owner/repo 或 https://github.com/owner/repo。")
                }

                if let installing {
                    Section {
                        HStack {
                            ProgressView()
                            VStack(alignment: .leading) {
                                Text(store.working[installing] ?? "正在安装…")
                                Text("可能要几分钟，请不要离开这个页面。").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("plugin.add.progress")
                    }
                }

                marketSection
            }
            .navigationTitle("添加插件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }.disabled(installing != nil)
                }
            }
            .task { if store.listings.isEmpty { await store.loadMarket() } }
            .confirmationDialog("安装「\(pending?.name ?? "")」？", isPresented: present($pending), titleVisibility: .visible, presenting: pending) { item in
                Button("安装") { Task { await install(item.spec) } }
            } message: { item in
                Text("将从 \(item.spec) 下载插件，并在 Mac 上的 magpie 里运行它的代码。只安装你信任的插件。")
            }
            .pluginAlerts(store: store, id: "plugin.add")
        }
        .interactiveDismissDisabled(installing != nil)
    }

    @ViewBuilder
    private var marketSection: some View {
        Section {
            if store.marketLoading && store.listings.isEmpty {
                HStack { ProgressView(); Text("正在读取市场…").foregroundStyle(.secondary) }
            } else if let error = store.marketError, store.listings.isEmpty {
                Text("读不到插件市场：\(error.message)").font(.footnote).foregroundStyle(.secondary)
                Button("重试") { Task { await store.loadMarket() } }
            }
            ForEach(store.listings) { listing in
                let installed = store.isInstalled(listing)
                Button {
                    pending = Pending(spec: listing.package, name: listing.name)
                } label: {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(listing.name).foregroundStyle(.primary)
                                Text(listing.kindTitle).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                if listing.community { Text("社区").font(.caption2.weight(.semibold)).foregroundStyle(.blue) }
                            }
                            if !listing.summary.isEmpty {
                                Text(listing.summary).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                            Text(listing.package + (listing.latest.isEmpty ? "" : " · v\(listing.latest)"))
                                .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if installed {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("已安装")
                        }
                    }
                }
                .disabled(installed || installing != nil)
                .accessibilityIdentifier("plugin.market.\(listing.package)")
            }
        } header: {
            Text("插件市场")
        } footer: {
            if !store.agents.isEmpty {
                Text("还可以添加的 Agent：\(store.agents.joined(separator: "、"))。")
            } else {
                Text("magpie 推荐的插件，来自社区维护的列表。")
            }
        }
    }

    private func install(_ spec: String) async {
        installing = spec
        let ok = await store.add(spec)
        installing = nil
        if ok { dismiss() }
    }
}

// MARK: 插件页面（网页兜底）

/// 插件自带的页面要在 magpie 网页框架里运行：在 App 内打开 `/?view=<页面键>`，Cookie 带 Web 密钥。
struct PluginWebPageView: View {
    let service: (any PluginServing)?
    let view: String
    let title: String

    var body: some View {
        Group {
            if let target = service?.webPage(view: view) {
                MagpieWebView(url: target.url, cookieName: target.cookieName, key: target.key)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                ContentUnavailableView {
                    Label(title, systemImage: "macwindow")
                } description: {
                    Text(service == nil ? "先为这台主机填写 Web 密钥。" : "示例模式下不会打开网页。连接真实主机后，这里显示 magpie 网页里的「\(title)」。")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("plugins.web.placeholder")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: 弹窗

extension View {
    /// 插件页的操作失败提示。导航栈与弹出的表单里可能同时有好几个插件页面，只由最上面的那个负责弹出（`id` 区分）。
    func pluginAlerts(store: PluginStore, id: String) -> some View {
        modifier(PluginAlerts(store: store, id: id))
    }
}

private struct PluginAlerts: ViewModifier {
    let store: PluginStore
    let id: String

    private var active: Bool { store.presenters.last == id }

    func body(content: Content) -> some View {
        content
            .onAppear { store.presenters.removeAll { $0 == id }; store.presenters.append(id) }
            .onDisappear { store.presenters.removeAll { $0 == id } }
            .alert(store.actionError?.title ?? "", isPresented: Binding(get: { active && store.actionError != nil },
                                                                       set: { if !$0 { store.actionError = nil } })) {
                Button("好") { store.actionError = nil }
            } message: {
                Text([store.actionError?.message, store.actionError?.hint].compactMap { $0 }.joined(separator: "\n"))
            }
    }
}
