import SwiftUI
import MagpieRemoteCore

/// 「{agent} 的模型列表」（官方 openAgentModels）：这个 Agent 的模型选择器里放哪些 magpie 模型。
/// 关掉的模型不会出现在它的列表里，别的 Agent 照常能用；它正在用的那个不能隐藏。
/// 「全部 / 已显示 / 排序」三页；「只显示我勾选的模型」；整组和全部的「全部隐藏 / 全部显示」（全部的先确认）。
/// 每次改动马上保存，一个接一个地发（同官方）。
struct AgentModelListView: View {
    let store: ManageStore
    let agent: WebAgent

    enum Mode: String, CaseIterable, Identifiable {
        case all = "全部", shown = "已显示", order = "排序"
        var id: String { rawValue }
    }

    @State private var list: AgentModelList?
    @State private var failed = false
    @State private var mode: Mode = .all
    @State private var search = ""
    @State private var folded: Set<String> = []
    /// 「已显示」里刚关掉的先留着，换页再消失（官方 kept）。
    @State private var kept: Set<String> = []
    @State private var saving: Task<Void, Never>?
    @State private var asksAll: Bool?

    var body: some View {
        Group {
            if let list {
                content(list)
            } else if failed {
                ContentUnavailableView {
                    Label("读不到模型列表", systemImage: "exclamationmark.triangle")
                } actions: {
                    Button("重试") { Task { await load() } }
                }
            } else {
                ProgressView("正在读取…")
            }
        }
        .navigationTitle("\(agent.name) 的模型列表")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .safeAreaInset(edge: .bottom) { ManageStatusLine(store: store) }
        .manageAlerts(store: store, id: "agent.models")
    }

    private func load() async {
        failed = false
        if let loaded = await store.agentModels(agent.id) {
            list = loaded
            folded = loaded.initiallyFolded
        } else {
            failed = true
        }
    }

    // MARK: 内容

    @ViewBuilder
    private func content(_ list: AgentModelList) -> some View {
        List {
            Section {
                Picker("显示", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .accessibilityIdentifier("agentModels.mode")
                .onChange(of: mode) { kept = [] }
            } footer: {
                Text(mode == .order ? AgentModelList.orderNote(agentID: agent.id, agentName: agent.name)
                                    : "关掉的模型不会出现在 \(agent.name) 的模型列表里，别的 Agent 照常能用。")
            }
            if mode == .order {
                orderSection(list)
            } else {
                switches(list)
                ForEach(list.groups) { group in groupSection(group) }
                if list.groups.allSatisfy({ rows(of: $0).isEmpty }) {
                    Section { Text("没有匹配项。").foregroundStyle(.secondary) }
                }
            }
        }
        .searchable(text: $search, prompt: "搜索模型")
        .environment(\.editMode, .constant(mode == .order ? .active : .inactive))
        .confirmationDialog(confirmTitle(list), isPresented: present($asksAll), titleVisibility: .visible, presenting: asksAll) { hide in
            Button(hide ? "全部隐藏" : "全部显示", role: hide ? .destructive : nil) {
                change { $0.setAll(hidden: hide) }
            }
            .accessibilityIdentifier("agentModels.all.confirm")
            Button("取消", role: .cancel) {}
        }
    }

    private func confirmTitle(_ list: AgentModelList) -> String {
        guard let hide = asksAll else { return "" }
        return hide ? "隐藏所有供应商的 \(list.models.filter { !$0.inUse && !$0.hidden }.count) 个模型？"
                    : "显示所有供应商已隐藏的 \(list.models.filter(\.hidden).count) 个模型？"
    }

    /// 「只显示我勾选的模型」、自带模型开关、全部隐藏 / 全部显示。
    @ViewBuilder
    private func switches(_ list: AgentModelList) -> some View {
        Section {
            Toggle(isOn: Binding(get: { list.only }, set: setOnly)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("只显示我勾选的模型")
                    Text("关：新模型默认显示。开：只显示这里勾选的模型，之后新增的模型，无论来自哪个供应商，勾选前都不显示")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("agentModels.only")
            if list.own {
                Toggle(isOn: Binding(get: { !list.ownHidden }, set: { setOwnHidden(!$0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("显示 \(agent.name) 自带的模型")
                        Text("\(agent.name) 自己直连、不经 magpie 的模型。关：它的模型选择器只列出 magpie 的模型，正在用的那个保留")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("agentModels.own")
            }
            HStack {
                Button("全部隐藏") { asksAll = true }
                    .disabled(!list.models.contains { !$0.hidden && !$0.inUse })
                    .accessibilityIdentifier("agentModels.hideAll")
                Spacer()
                Text("显示 \(list.shownCount) / \(list.models.count)").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button("全部显示") { asksAll = false }
                    .disabled(!list.models.contains(where: \.hidden))
                    .accessibilityIdentifier("agentModels.showAll")
            }
            .buttonStyle(.borderless)
        }
    }

    private func rows(of group: AgentModelList.Group) -> [AgentModelList.Model] {
        let words = search.trimmingCharacters(in: .whitespaces).lowercased()
        return group.models.filter { m in
            (mode != .shown || !m.hidden || kept.contains(m.id))
                && (words.isEmpty || [m.name, m.id, group.title].contains { $0.lowercased().contains(words) })
        }
    }

    @ViewBuilder
    private func groupSection(_ group: AgentModelList.Group) -> some View {
        let visible = rows(of: group)
        if !visible.isEmpty {
            let isFolded = search.isEmpty && folded.contains(group.name)
            Section {
                if !isFolded {
                    ForEach(visible) { model in modelRow(model) }
                }
            } header: {
                HStack {
                    Button {
                        withAnimation { if folded.contains(group.name) { folded.remove(group.name) } else { folded.insert(group.name) } }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .rotationEffect(.degrees(isFolded ? 0 : 90))
                                .font(.caption.weight(.semibold))
                            if group.isRoutingGroup {
                                Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                            } else {
                                BrandIcon(group.icon.isEmpty ? "generic" : group.icon, size: 14)
                            }
                            Text(group.title)
                            Text("\(group.shownCount) / \(group.models.count)").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(isFolded ? "已收起" : "已展开")
                    .accessibilityIdentifier("agentModels.group.\(group.name)")
                    Spacer()
                    if !group.free.isEmpty {
                        let allOn = group.allOn
                        Button(allOn ? "全部隐藏" : "全部显示") {
                            change { list in
                                list.setGroup(group.name, hidden: allOn)
                            }
                            if allOn { kept.formUnion(group.free.map(\.id)) }
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("agentModels.groupAll.\(group.name)")
                    }
                }
                .textCase(nil)
            }
        }
    }

    private func modelRow(_ model: AgentModelList.Model) -> some View {
        Button {
            guard !model.inUse else { return }
            if !model.hidden { kept.insert(model.id) }
            change { $0.toggle(model.id) }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(model.name).foregroundStyle(model.hidden ? .secondary : .primary)
                        if model.inUse {
                            Text("在用").font(.caption2.weight(.semibold)).foregroundStyle(.green)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.green.opacity(0.12), in: .capsule)
                        }
                    }
                    if model.name != model.id {
                        Text(model.id).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if model.context > 0 {
                    Text(agentContextShort(model.context)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Image(systemName: model.hidden ? "circle" : "checkmark.circle.fill")
                    .foregroundStyle(model.hidden ? Color.secondary : Color.accentColor)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.hidden ? [] : .isSelected)
        .accessibilityHint(model.inUse ? "\(agent.name) 正在使用它，不能隐藏" : model.id)
        .accessibilityIdentifier("agentModels.model.\(model.id)")
    }

    // MARK: 排序

    @ViewBuilder
    private func orderSection(_ list: AgentModelList) -> some View {
        let shown = list.inOrder
        Section {
            if shown.isEmpty { Text("没有匹配项。").foregroundStyle(.secondary) }
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, model in
                HStack(spacing: 8) {
                    Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 18)
                    Text(model.name)
                    Spacer()
                    Text(model.isRoutingGroup ? "路由组" : model.group).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("agentModels.order.\(model.id)")
            }
            .onMove { source, destination in
                var next = list
                let ids = next.move(fromOffsets: source, toOffset: destination)
                self.list = next
                enqueue(AgentModelList.orderBody(ids))
            }
        }
        Section {
            Button("恢复默认顺序") { resetOrder() }
                .disabled(!list.ordered)
                .accessibilityIdentifier("agentModels.defaultOrder")
        }
    }

    // MARK: 保存

    /// 改本地的列表，再按「只显示我勾选的」发 shown 或 hidden。
    private func change(_ edit: (inout AgentModelList) -> Void) {
        guard var next = list else { return }
        edit(&next)
        list = next
        enqueue(next.visibilityBody)
    }

    /// 一个接一个地发（官方 me.saving 链）。返回这次的回答。
    @discardableResult
    private func enqueue(_ body: WebJSON) -> Task<WebJSON?, Never> {
        let previous = saving
        let id = agent.id
        let task = Task { () -> WebJSON? in
            await previous?.value
            return await store.setAgentModels(id, body)
        }
        saving = Task { _ = await task.value }
        return task
    }

    private func setOnly(_ on: Bool) {
        list?.only = on
        let task = enqueue(AgentModelList.onlyBody(on))
        Task { if await task.value == nil { list?.only = !on } }
    }

    private func setOwnHidden(_ hidden: Bool) {
        list?.ownHidden = hidden
        let task = enqueue(AgentModelList.ownHiddenBody(hidden))
        Task { if await task.value == nil { list?.ownHidden = !hidden } }
    }

    private func resetOrder() {
        let task = enqueue(AgentModelList.orderBody([]))
        Task {
            guard let answer = await task.value else { return }
            list?.merge(answer)
            list?.ordered = false
        }
    }
}
