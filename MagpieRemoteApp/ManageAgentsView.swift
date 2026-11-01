import SwiftUI
import MagpieRemoteCore

/// Agent：magpie 在 Mac 上找到的编程助手（Codex、Claude Code…）。照官方网页的 Agent 页：
/// 每个 Agent 一组，有它的所有设置（模型、推理强度、子代理、登录方式…）、「接入 magpie」开关、命令行程序的版本与「更新到 …」，
/// 配置被改过时有「重新应用」；两个以上有新版本时上面一行「全部更新」；最下面是「方案」（保存 / 应用 / 更新 / 删除）。
/// 在用的排在上面；什么都没设置的（未设置）和在网页版里隐藏的（已隐藏）收进下面一组，默认折叠，点开才显示。
struct ManageAgentsView: View {
    let store: ManageStore
    /// 折叠组是否展开（和网页版一样只在这次打开期间记住）。
    @State private var showsFolded = false
    /// 正在问「断开 X 和 magpie？」的 Agent。
    @State private var disconnecting: WebAgent?
    /// 正在解释「连不上 magpie」的 Agent。
    @State private var explaining: WebAgent?

    var body: some View {
        let arrangement = AgentArrangement(agents: store.agents, order: store.settings?.agentOrder ?? [],
                                           hidden: store.settings?.agentsHidden ?? [])
        List {
            if store.agents.isEmpty {
                Section {
                    Text(store.phase == .ready ? "magpie 还没有在这台 Mac 上发现 Agent。" : "正在读取…").foregroundStyle(.secondary)
                }
            }
            AgentUpdatesBar(store: store)
            ForEach(Array(arrangement.shown.enumerated()), id: \.element.id) { index, agent in
                AgentSection(store: store, agent: agent, place: .shown(index: index, count: arrangement.shown.count),
                             disconnect: { disconnecting = $0 }, explain: { explaining = $0 })
            }
            if arrangement.foldedCount > 0 {
                Section {
                    Button {
                        withAnimation { showsFolded.toggle() }
                    } label: {
                        HStack {
                            Text(showsFolded ? "收起" : foldedLabel(arrangement))
                            Spacer()
                            Image(systemName: "chevron.down")
                                .rotationEffect(.degrees(showsFolded ? 180 : 0))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("agents.folded.toggle")
                    .accessibilityValue(showsFolded ? "已展开" : "已收起")
                } footer: {
                    if !showsFolded { Text(foldedFooter(arrangement)) }
                }
                if showsFolded {
                    if !arrangement.notSetUp.isEmpty {
                        FoldCaption(text: "未设置")
                        ForEach(arrangement.notSetUp) { agent in
                            AgentSection(store: store, agent: agent, place: .notSetUp, disconnect: { disconnecting = $0 }, explain: { explaining = $0 })
                        }
                    }
                    if !arrangement.hidden.isEmpty {
                        FoldCaption(text: "已隐藏")
                        ForEach(arrangement.hidden) { agent in
                            AgentSection(store: store, agent: agent, place: .hidden, disconnect: { disconnecting = $0 }, explain: { explaining = $0 })
                        }
                    }
                }
            }
            if store.phase == .ready { AgentProfilesSection(store: store) }
        }
        .navigationTitle("Agent")
        .refreshable { await store.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await store.rescanAgents() }
                } label: {
                    Label("重新检测 Agent", systemImage: "arrow.clockwise")
                }
                .disabled(store.busy || store.service == nil)
                .accessibilityHint("重新检测本机的 Agent：刚安装或卸载的，或在别处改过配置的")
                .accessibilityIdentifier("agents.rescan")
            }
        }
        .safeAreaInset(edge: .bottom) { ManageStatusLine(store: store) }
        .sheet(item: $disconnecting) { agent in
            AgentDisconnectSheet(store: store, agent: agent)
        }
        .alert(explaining.flatMap { agent in agent.drift.map { $0.reason(agent: agent.name, model: $0.want) } } ?? "",
               isPresented: Binding(get: { explaining != nil }, set: { if !$0 { explaining = nil } }), presenting: explaining) { agent in
            if agent.wired {
                Button("断开 magpie（还原配置）", role: .destructive) { disconnecting = agent }
            }
            Button("知道了", role: .cancel) {}
        } message: { agent in
            Text(agent.drift?.detail ?? "")
        }
        .manageAlerts(store: store, id: "agents")
    }

    private func foldedLabel(_ arrangement: AgentArrangement) -> String {
        arrangement.notSetUp.isEmpty ? "\(arrangement.hidden.count) 个已隐藏的 Agent" : "另外 \(arrangement.foldedCount) 个 Agent"
    }

    private func foldedFooter(_ arrangement: AgentArrangement) -> String {
        var parts: [String] = []
        if !arrangement.notSetUp.isEmpty { parts.append("\(arrangement.notSetUp.count) 个还没设置") }
        if !arrangement.hidden.isEmpty { parts.append("\(arrangement.hidden.count) 个已隐藏") }
        return parts.joined(separator: "，") + "。"
    }
}

/// 一个 Agent 在列表里的位置：决定「更多操作」里有什么（官方 openAgentMenu：上面那组有上移 / 下移 / 隐藏，
/// 折叠的「未设置」只有隐藏，「已隐藏」只有显示）。
enum AgentPlace: Equatable {
    case shown(index: Int, count: Int)
    case notSetUp
    case hidden
}

/// 折叠组里「未设置」「已隐藏」的小标题（和网页版的分组标题一样）。
private struct FoldCaption: View {
    let text: String

    var body: some View {
        Section {
            Text(text)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("agents.folded.caption")
        }
        .listSectionSpacing(.compact)
    }
}

/// 官方网页底部的状态栏：操作完成后的一句话，4 秒后消失（Agent 页、网关密钥页共用）。
struct ManageStatusLine: View {
    let store: ManageStore

    var body: some View {
        if let status = store.status {
            Text(status)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
                .padding(.bottom, 6)
                .padding(.horizontal)
                .transition(.opacity)
                .accessibilityIdentifier("agents.status")
                .task(id: status) {
                    try? await Task.sleep(for: .seconds(4))
                    if store.status == status { withAnimation { store.status = nil } }
                }
        }
    }
}

// MARK: 全部更新

/// 两个以上 Agent 有新版本时列表上方的一行（官方 paintUpdateAll）；点过「全部更新」后一直显示结果，直到重新读取 Agent。
private struct AgentUpdatesBar: View {
    let store: ManageStore

    var body: some View {
        let updatable = store.updatable
        let run = store.updateRun
        if run != nil || updatable.count >= 2 {
            Section {
                HStack(spacing: 12) {
                    Text(line(run: run))
                        .font(.subheadline)
                        .foregroundStyle(run.map { !$0.running && !$0.failed.isEmpty } == true ? .red : .primary)
                        .accessibilityIdentifier("agents.updates.say")
                    Spacer(minLength: 0)
                    if run?.running == true {
                        ProgressView()
                    } else if updatable.count >= 2 {
                        Button {
                            Task { await store.updateAllCLIs() }
                        } label: {
                            Label("全部更新", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityHint(updatable.map { "\($0.name)：\(store.clis[$0.id]?.version ?? "") → \(store.clis[$0.id]?.latest ?? "")" }.joined(separator: "，"))
                        .accessibilityIdentifier("agents.updateAll")
                    }
                }
            }
        }
    }

    private func line(run: AgentUpdateRun?) -> String {
        if let run { return run.running ? run.progress : run.summary }
        let behind = store.agents.filter { store.clis[$0.id]?.update == true || store.cliBusy.contains($0.id) }
        return AgentCLIText.behind(behind.map(\.name))
    }
}

// MARK: 一个 Agent

/// 一个 Agent：命令行程序的版本与更新、配置被改过时的修复、「接入 magpie」开关、它的各项设置、更多操作。
private struct AgentSection: View {
    let store: ManageStore
    let agent: WebAgent
    let place: AgentPlace
    /// 问「断开 X 和 magpie？」（弹窗挂在整页上，避免挂在 Section 上被每一行重复）。
    let disconnect: (WebAgent) -> Void
    /// 解释连不上 magpie 的原因。
    let explain: (WebAgent) -> Void

    private var cli: AgentCLI? { store.clis[agent.id] }
    private var busy: Bool { store.cliBusy.contains(agent.id) }

    var body: some View {
        Section {
            if agent.cliMissing {
                Text("找不到它的命令行程序，可能已经卸载。重新安装后这里会再显示它的设置。").foregroundStyle(.secondary)
                if agent.wired && agent.connectable { connectToggle }
                moreActions
            } else {
                if let drift = agent.drift { driftRow(drift) }
                if agent.connectable { connectToggle }
                let fields = agent.shownFields
                if fields.isEmpty {
                    Text("这个 Agent 没有可切换的设置。").foregroundStyle(.secondary)
                }
                ForEach(fields) { field in
                    AgentFieldPicker(store: store, agent: agent, field: field)
                }
                if let count = agent.modelCount { modelListRow(count) }
                if let cli, cli.update || busy { updateRow(cli) }
                moreActions
            }
        } header: {
            HStack(spacing: 6) {
                BrandIcon(agent.officialIcon, size: 16)
                Text(agent.name)
                if let tag = cli?.versionTag {
                    Text(tag).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityLabel(cli.map { $0.versionNote(agent: agent.name) } ?? tag)
                        .accessibilityIdentifier("agent.version.\(agent.id)")
                }
                if let app = cli?.app, !app.isEmpty {
                    Text("App \(app)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if cli?.inDesktop == true {
                    Text("Claude Desktop 内置").font(.caption).foregroundStyle(.secondary)
                }
                if agent.cliMissing {
                    Text("未找到 CLI").font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Text(agent.wired ? "已接入 magpie" : "未接入").foregroundStyle(agent.wired ? .green : .secondary)
            }
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                if let cli, !cli.version.isEmpty {
                    Text(cli.versionNote(agent: agent.name))
                    if cli.offPath, !cli.path.isEmpty {
                        Text("不在终端的 PATH 里：magpie 在 \(cli.path) 找到它，但终端的 PATH 里没有这个目录。")
                    }
                }
                if !agent.path.isEmpty { Text("配置文件：\(agent.path)") }
            }
        }
    }

    // MARK: 接入

    private var connectToggle: some View {
        Toggle(isOn: Binding(get: { agent.wired }, set: { on in
            if on { Task { await store.connectAgent(agent.id) } } else { disconnect(agent) }
        })) {
            VStack(alignment: .leading, spacing: 2) {
                Text("magpie")
                Text(agent.connectSaid).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .disabled(store.busy)
        .accessibilityLabel("将 \(agent.name) 接入 magpie")
        .accessibilityHint(agent.wired ? "已接入 · 关掉即还原 \(agent.name) 接入 magpie 之前的设置" : "打开后，\(agent.name) 的模型列表里就有 magpie 的模型")
        .accessibilityIdentifier("agent.connect.\(agent.id)")
    }

    // MARK: 配置被改过

    private func driftModel(_ drift: AgentDrift) -> String {
        let field = agent.fields.first { $0.key == drift.field }
        return field?.options.first { $0.value == drift.want }?.title ?? drift.want
    }

    private func driftRow(_ drift: AgentDrift) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(drift.reason(agent: agent.name, model: driftModel(drift)), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.subheadline)
            HStack {
                Button {
                    if drift.canReapply { Task { await store.reapplyAgent(agent.id) } } else { explain(agent) }
                } label: {
                    Label(drift.fixTitle, systemImage: drift.canReapply ? "arrow.clockwise" : "info.circle")
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .accessibilityIdentifier("agent.fix.\(agent.id)")
                if drift.kind == "replaced" {
                    Button("保留当前设置") { Task { await store.keepAgent(agent.id) } }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("agent.keep.\(agent.id)")
                }
            }
            .controlSize(.small)
            .disabled(store.busy)
        }
    }

    // MARK: 更新命令行程序

    private func updateRow(_ cli: AgentCLI) -> some View {
        Button {
            Task { await store.updateCLI(agent.id) }
        } label: {
            HStack {
                Label(cli.buttonTitle(busy: busy), systemImage: busy ? "hourglass" : "arrow.down.circle")
                Spacer()
                if busy { ProgressView() }
            }
        }
        .disabled(busy || store.updateRun?.running == true)
        .accessibilityHint(cli.commandNote)
        .accessibilityIdentifier("agent.update.\(agent.id)")
    }

    // MARK: 模型列表

    /// 「全部 N 个模型」/「显示 x / y 个模型」：点开选这个 Agent 的列表里放哪些 magpie 模型（官方 ag-models）。
    private func modelListRow(_ count: AgentModelCount) -> some View {
        NavigationLink {
            AgentModelListView(store: store, agent: agent)
        } label: {
            LabeledContent {
                Text(count.entry)
            } label: {
                Label("模型列表", systemImage: "list.bullet.rectangle")
            }
        }
        .accessibilityHint("选择 \(agent.name) 列出哪些模型")
        .accessibilityIdentifier("agent.models.\(agent.id)")
    }

    // MARK: 更多操作（官方右键菜单）

    private var moreActions: some View {
        Menu {
            switch place {
            case .hidden:
                Button { Task { await store.setAgentHidden(agent, hide: false) } } label: { Label("显示", systemImage: "eye") }
            case .notSetUp:
                Button { Task { await store.setAgentHidden(agent, hide: true) } } label: { Label("隐藏", systemImage: "eye.slash") }
            case .shown(let index, let count):
                Section {
                    Button { Task { await store.moveAgent(agent.id, to: index - 1) } } label: { Label("上移", systemImage: "arrow.up") }
                        .disabled(index <= 0)
                    Button { Task { await store.moveAgent(agent.id, to: index + 1) } } label: { Label("下移", systemImage: "arrow.down") }
                        .disabled(index >= count - 1)
                }
                if agent.canReapply {
                    Section {
                        Button {
                            Task { await store.reapplyAgent(agent.id) }
                        } label: {
                            Label("重新应用", systemImage: "arrow.clockwise")
                        }
                        if agent.drift?.kind == "replaced" {
                            Button { Task { await store.keepAgent(agent.id) } } label: { Label("保留当前设置", systemImage: "checkmark") }
                        }
                    }
                }
                if agent.wired {
                    Button(role: .destructive) {
                        disconnect(agent)
                    } label: {
                        Label("断开 magpie（还原配置）", systemImage: "powerplug")
                    }
                }
                Section {
                    Button { Task { await store.setAgentHidden(agent, hide: true) } } label: { Label("隐藏", systemImage: "eye.slash") }
                }
            }
        } label: {
            Label("更多操作", systemImage: "ellipsis.circle")
        }
        .disabled(store.busy)
        .accessibilityIdentifier("agent.more.\(agent.id)")
    }
}

/// 一项设置的选择器。模型按主机给的分组（供应商 / 路由组）排列；第一个总是「默认」（Agent 自己的默认值）。
private struct AgentFieldPicker: View {
    let store: ManageStore
    let agent: WebAgent
    let field: WebAgentField

    private struct OptionGroup: Identifiable {
        var name: String
        var options: [WebAgentOption]
        var id: String { name }
    }

    private var groups: [OptionGroup] {
        var result: [OptionGroup] = []
        for option in field.options where !option.value.isEmpty {
            if let index = result.firstIndex(where: { $0.name == option.group }) {
                result[index].options.append(option)
            } else {
                result.append(OptionGroup(name: option.group, options: [option]))
            }
        }
        return result
    }

    private var isModel: Bool { field.key == "model" }

    /// 主机给的选项里的空值（例如 Codex 登录方式的「ChatGPT」）：就用它代替「默认」。
    private var emptyOption: WebAgentOption? { field.options.first { $0.value.isEmpty } }

    var body: some View {
        Picker(selection: Binding(get: { field.value }, set: { value in
            guard value != field.value else { return }
            Task { await store.setAgent(agent.id, field: field.key, value: value) }
        })) {
            Text(emptyOption.map(AgentFieldText.option) ?? "默认").tag("")
            if !field.value.isEmpty && !field.options.contains(where: { $0.value == field.value }) {
                Text(AgentFieldText.value(of: field)).tag(field.value)
            }
            ForEach(groups) { group in
                if groups.count > 1 || !group.name.isEmpty {
                    Section(group.name.isEmpty ? "其它" : group.name) {
                        ForEach(group.options) { option in
                            Text(AgentFieldText.option(option)).tag(option.value)
                        }
                    }
                } else {
                    ForEach(group.options) { option in
                        Text(AgentFieldText.option(option)).tag(option.value)
                    }
                }
            }
        } label: {
            Label(AgentFieldText.label(field.label), systemImage: symbol)
        }
        .pickerStyle(.navigationLink)
        .disabled(store.busy)
        .accessibilityIdentifier(isModel ? "agent.model.\(agent.id)" : "agent.field.\(agent.id).\(field.key)")
    }

    private var symbol: String {
        switch field.label {
        case "model", "large", "small", "planner", "executor", "subagent model", "memories": "cpu"
        case "effort", "thinking", "subagent effort": "gauge.with.dots.needle.50percent"
        case "sign-in", "auth", "account": "person.crop.circle"
        case "subagents": "person.2"
        default: field.label.hasSuffix("effort") ? "gauge.with.dots.needle.50percent" : "slider.horizontal.3"
        }
    }
}

// MARK: 断开

/// 「断开 X 和 magpie？」：先读主机的预览，列出要改回的文件，确认后断开并还原（官方 askDisconnect）。
private struct AgentDisconnectSheet: View {
    let store: ManageStore
    let agent: WebAgent
    @Environment(\.dismiss) private var dismiss
    @State private var preview: AgentDisconnectPreview?
    @State private var failure: String?
    @State private var working = false

    /// 内建运行时的 Agent 没读到预览就不能断开（官方 previewBlocked）。
    private var blocked: Bool { agent.isNative && (preview?.revision.isEmpty ?? true) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("\(agent.name) 将恢复接入前的设置，以下为要改回的项。")
                }
                Section {
                    if let failure {
                        Text(failure).foregroundStyle(.red)
                    } else if let preview {
                        if preview.changes.isEmpty {
                            Text("移除 magpie 写入 \(agent.name) 配置的所有内容（接口地址、密钥、模型和推理强度），还原 \(agent.name) 之前的设置。magpie 的供应商和账号不受影响。")
                        }
                        ForEach(preview.changes, id: \.path) { change in
                            HStack {
                                Text(change.path).font(.callout.monospaced())
                                Spacer()
                                if change.removed || change.created {
                                    Text(change.removed ? "删除" : "新建").font(.caption).foregroundStyle(change.removed ? .red : .secondary)
                                } else if change.lines > 0 {
                                    Text("\(change.lines) 行").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } else {
                        HStack {
                            ProgressView()
                            Text("正在读取要改回的地方…").foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    if agent.id.hasPrefix("codex") { Text("保留 magpie 供应商表，用 magpie 模型开过的会话还能打开") }
                    else if agent.id.hasPrefix("claude") { Text("正在运行的 \(agent.name) 重开后生效") }
                }
                Section {
                    Button(role: .destructive) {
                        working = true
                        Task {
                            await store.disconnectAgent(agent.id)
                            working = false
                            dismiss()
                        }
                    } label: {
                        HStack {
                            Text("断开并还原")
                            if working { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(working || blocked && preview != nil || failure != nil && agent.isNative)
                    .accessibilityIdentifier("agent.disconnect.confirm")
                }
            }
            .navigationTitle("断开 \(agent.name) 和 magpie？")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .task {
                do {
                    let result = try await store.disconnectPreview(agent.id)
                    if let error = result.error, agent.isNative { failure = error } else { preview = result }
                } catch {
                    if agent.isNative { failure = MagpieError.from(error).message } else { preview = AgentDisconnectPreview(json: [:]) }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: 方案

/// 「方案」：把所有 Agent 现在的设置存成一个方案，之后一键切回（官方 renderProfiles）。
private struct AgentProfilesSection: View {
    let store: ManageStore
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        Section {
            if store.profiles.isEmpty {
                Text("还没有 · 保存当前设置，之后一键切回").foregroundStyle(.secondary)
            }
            ForEach(store.profiles) { profile in
                NavigationLink {
                    AgentProfileDetail(store: store, name: profile.name)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name)
                            if !profile.summary.isEmpty {
                                Text(profile.summary).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer()
                        if profile.inUse {
                            Label("使用中", systemImage: "checkmark").labelStyle(.titleAndIcon).font(.footnote).foregroundStyle(.green)
                        }
                    }
                }
                .accessibilityIdentifier("agents.profile.\(profile.name)")
            }
            Button {
                newName = ""
                naming = true
            } label: {
                Label("保存当前", systemImage: "plus")
            }
            .disabled(store.busy)
            .accessibilityIdentifier("agents.profile.save")
            .alert("保存当前", isPresented: $naming) {
                TextField("方案名称", text: $newName)
                    .accessibilityIdentifier("agents.profile.name")
                Button("取消", role: .cancel) {}
                Button("保存") {
                    let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    Task { await store.profile(.save, name: name, update: store.profiles.contains { $0.name == name }) }
                }
                .accessibilityIdentifier("agents.profile.name.save")
            } message: {
                Text(store.profiles.isEmpty ? "给这套设置起个名字。" : "同名的方案会被当前设置覆盖。")
            }
        } header: {
            Text("方案")
        } footer: {
            Text("方案记下各 Agent 现在的设置，之后一键切回。")
        }
    }
}

/// 一个方案里存了什么（官方 profileDetail），以及应用、用当前配置更新、删除。
private struct AgentProfileDetail: View {
    let store: ManageStore
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var asksOverwrite = false
    @State private var asksDelete = false

    private var profile: WebProfile? { store.profiles.first { $0.name == name } }

    var body: some View {
        List {
            if let profile {
                Section {
                    Button {
                        Task { await store.profile(.use, name: name) }
                    } label: {
                        Label(profile.inUse ? "使用中" : "应用", systemImage: profile.inUse ? "checkmark.circle.fill" : "checkmark.circle")
                    }
                    .disabled(store.busy || profile.inUse)
                    .accessibilityHint("将 \(name) 应用到各 Agent")
                    .accessibilityIdentifier("agents.profile.apply")
                }
                if profile.agents.isEmpty {
                    Section { Text("没有保存任何 Agent 的设置").foregroundStyle(.secondary) }
                }
                ForEach(profile.agents) { agent in
                    Section {
                        ForEach(agent.fields, id: \.key) { field in
                            LabeledContent(AgentFieldText.label(field.label), value: WebProfile.display(field, in: agent))
                        }
                    } header: {
                        HStack {
                            BrandIcon(agent.icon.isEmpty ? "generic" : agent.icon, size: 14)
                            Text(agent.name)
                        }
                    }
                }
                if profile.agents.contains(where: { $0.fields.contains(where: \.hidden) }) {
                    Section { Text("•••••• 看起来是密钥或令牌，不予显示").font(.footnote).foregroundStyle(.secondary) }
                }
                Section {
                    Button("用当前配置更新") { asksOverwrite = true }
                        .accessibilityIdentifier("agents.profile.overwrite")
                    Button("删除方案", role: .destructive) { asksDelete = true }
                        .accessibilityIdentifier("agents.profile.delete")
                }
                .disabled(store.busy)
            } else {
                Text("这个方案已经不在了。").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(name)
        .confirmationDialog("覆盖？", isPresented: $asksOverwrite, titleVisibility: .visible) {
            Button("用当前配置覆盖 \(name)") { Task { await store.profile(.save, name: name, update: true) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("\(name) 里存的设置会换成各 Agent 现在的设置。")
        }
        .confirmationDialog("删除？", isPresented: $asksDelete, titleVisibility: .visible) {
            Button("删除 \(name)", role: .destructive) {
                Task {
                    await store.profile(.delete, name: name)
                    dismiss()
                }
            }
            Button("取消", role: .cancel) {}
        }
        .safeAreaInset(edge: .bottom) { ManageStatusLine(store: store) }
        .manageAlerts(store: store, id: "agents.profile")
    }
}
