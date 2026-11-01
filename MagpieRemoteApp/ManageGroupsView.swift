import SwiftUI
import MagpieRemoteCore

/// 「路由」页：照 magpie 网页的「路由」页（plugins/routing）排布——上面是实时路由的舞台与最近的请求，
/// 下面是路由组卡片（路由方式、成员、标签、开关）、自动创建路由组的开关、多账号 / 多 Key 的供应商。
struct ManageGroupsView: View {
    let store: ManageStore
    @State private var live = RoutesLiveModel()
    @State private var pendingDelete: WebGroup?
    @State private var editing: WebGroup?
    @State private var creating = false

    private var groups: [WebGroup] { store.groups?.visible ?? [] }

    private func agentName(_ id: String) -> String {
        if let agent = store.agents.first(where: { $0.id == id }) { return agent.name }
        return id.isEmpty || id == "other" ? "你的 Agent" : id
    }

    var body: some View {
        List {
            Section {
                RoutesStageView(model: live, agentName: agentName) { route in
                    if let id = route.groupID, let group = store.groups?[group: id] { editing = group }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 8, trailing: 12))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                RoutesRequestList(model: live, agentName: agentName)
                    .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
            } header: {
                HStack(spacing: 6) {
                    Text("路由")
                    LiveDot(on: live.phase == .live)
                    Text("实时 · 网关正在做的决定").font(.caption2).foregroundStyle(.tertiary).textCase(nil)
                }
            }

            Section {
                if groups.isEmpty {
                    Text(store.groups == nil ? "正在读取…" : (store.groups?.found == false
                         ? "还没有路由组。点右上角「+」用任意模型新建一个。"
                         : "还没有路由组。两个供应商都提供的模型会自动成组；点右上角「+」用任意模型新建一个。"))
                        .foregroundStyle(.secondary)
                }
                ForEach(groups) { group in
                    GroupCard(store: store, group: group, open: { editing = group }, delete: { pendingDelete = group })
                        .accessibilityIdentifier("group.row.\(group.id)")
                }
                .onMove { source, destination in Task { await store.moveGroups(from: source, to: destination) } }
            } header: {
                HStack {
                    Text("路由组")
                    Spacer()
                    Text("Agent 当作一个模型来选").font(.caption2).foregroundStyle(.tertiary).textCase(nil)
                }
            } footer: {
                Text("按住拖动可调整顺序，Agent 的模型列表也按这个顺序显示。")
            }

            if let all = store.groups {
                Section {
                    Toggle(isOn: Binding(get: { all.found }, set: { on in Task { await store.setFoundGroups(on) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("自动创建路由组")
                            Text(all.found ? "两个及以上供应商都提供的模型会自动成组（auto/…）。关闭后只列出和提供你新建或改过的组。"
                                 : "已关闭：只列出和提供你新建或改过的组。选了自动组的 Agent 改用其中一个供应商的该模型，仍指定自动组的请求也发往那里。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("groups.found")
                }

                if !all.pools.isEmpty {
                    Section {
                        ForEach(all.pools) { pool in PoolRow(store: store, pool: pool) }
                    } header: {
                        HStack {
                            Text("多账号 / 多 Key")
                            Spacer()
                            Text("各供应商在自己的账号或 Key 间路由").font(.caption2).foregroundStyle(.tertiary).textCase(nil)
                        }
                    }
                }
            }
        }
        .navigationTitle("路由")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { creating = true } label: { Label("新建路由组", systemImage: "plus") }
                    .accessibilityIdentifier("group.add")
            }
        }
        .navigationDestination(item: $editing) { group in GroupEditorView(store: store, group: group) }
        .navigationDestination(isPresented: $creating) { GroupEditorView(store: store, group: nil) }
        .refreshable {
            await store.refresh()
            await store.refreshSpeeds()
        }
        .onAppear { live.start(service: store.service) }
        .onDisappear { live.stop() }
        .confirmationDialog("删除路由组「\(pendingDelete?.name ?? "")」？", isPresented: present($pendingDelete), titleVisibility: .visible, presenting: pendingDelete) { group in
            Button("删除路由组", role: .destructive) { Task { await store.deleteGroup(group.id) } }
                .accessibilityIdentifier("group.delete.confirm")
        } message: { _ in
            Text("Agent 将不能再选这个路由组；正在用它的 Agent 需要另选模型。")
        }
        .manageAlerts(store: store, id: "groups")
    }
}

/// 标题旁的小绿点：在读实时路由时亮（routing.css .rt-livedot）。
private struct LiveDot: View {
    let on: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Circle().fill(on ? RT.green : RT.muted).frame(width: 6, height: 6)
            .opacity(on && pulse && !reduceMotion ? 0.35 : 1)
            .onAppear { if !reduceMotion && !RT.uiTesting { withAnimation(.easeInOut(duration: 1.2).repeatForever()) { pulse = true } } }
            .accessibilityHidden(true)
    }
}

// MARK: 路由组卡片

/// 一张路由组卡片（网页 groupRow）：名字与 group/… 地址、成员摘要（按顺序用 →）、标签、开关。
private struct GroupCard: View {
    let store: ManageStore
    let group: WebGroup
    let open: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: group.routingKind.symbol)
                    .font(.body)
                    .foregroundStyle(group.ready ? Color.accentColor : .secondary)
                    .frame(width: 26, height: 26)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 7))
                Button(action: open) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(group.name).fontWeight(.semibold).foregroundStyle(group.disabled ? .secondary : .primary)
                            if group.auto { Text("magpie 自动发现").font(.caption2).foregroundStyle(.secondary) }
                        }
                        Text(group.ref).font(.caption.monospaced()).foregroundStyle(.secondary)
                        if group.routingKind != .manual {
                            Text(group.memberSummary).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .tint(.primary)
                .accessibilityIdentifier("group.open.\(group.id)")
                if !group.auto {
                    Toggle("启用", isOn: Binding(get: { !group.disabled }, set: { on in Task { await store.setGroup(group.id, on: on) } }))
                        .labelsHidden()
                        .accessibilityIdentifier("group.enabled.\(group.id)")
                }
            }
            if group.routingKind == .manual { ManualPicks(store: store, group: group) }
            ForEach(group.patterns, id: \.pattern) { pattern in
                Text("\(pattern.pattern) · \(pattern.models > 0 ? "\(pattern.models) 个模型" : "现在没有匹配到模型")")
                    .font(.caption.monospaced()).foregroundStyle(pattern.models > 0 ? Color.secondary : Color.orange)
            }
            if let failure = group.classifierFailure {
                Label("分类模型上次没能回答：\(failure)", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(RT.red)
            }
            TagFlow(spacing: 6) {
                RoutingTag(store: store, group: group)
                if group.affinity != .auto { Tag(text: "会话保持 · " + group.affinity.title) }
                if group.sink && group.routingKind.sinkable { Tag(text: "限流后排到最后") }
                if group.unlists { Tag(text: "成员模型不单独列出") }
                if group.firstToken > 0 && group.routingKind != .manual { Tag(text: "\(GroupTimeouts.firstTokenTitle(group.firstToken)) 无首字换下一个") }
                if group.ruleCount > 0 { Tag(text: "\(group.ruleCount) 条规则", idle: group.routingKind == .manual) }
                if group.offCount > 0 && group.routingKind != .manual { Tag(text: "\(group.offCount) 个已关闭", idle: true) }
                if group.disabled { Tag(text: "已关闭", idle: true) } else if !group.ready { Tag(text: "没有可用成员", bad: true) }
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("编辑", systemImage: "slider.horizontal.3", action: open)
            Button("复制", systemImage: "doc.on.doc") { Task { await store.copyGroup(group) } }
            if !group.auto { Button("删除", systemImage: "trash", role: .destructive, action: delete) }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !group.auto { Button("删除", role: .destructive, action: delete) }
        }
    }
}

/// 卡片上的路由方式标签：点开直接换（网页 routeTag），只改路由方式，其余原样保存。
private struct RoutingTag: View {
    let store: ManageStore
    let group: WebGroup

    var body: some View {
        Menu {
            Picker("路由", selection: Binding(get: { group.routingKind }, set: { routing in
                guard routing != group.routingKind else { return }
                Task { await store.saveGroup(group, edits: GroupEdits(routing: routing)) }
            })) {
                ForEach(choices) { routing in Label(routing.title, systemImage: routing.symbol).tag(routing) }
            }
        } label: {
            HStack(spacing: 3) {
                Text(group.routingKind.title)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.tint.opacity(0.12), in: .capsule)
        }
        .accessibilityIdentifier("group.routing.\(group.id)")
    }

    private var choices: [GroupRouting] {
        GroupRouting.groupChoices + (GroupRouting.groupChoices.contains(group.routingKind) ? [] : [group.routingKind])
    }
}

private struct Tag: View {
    let text: String
    var idle = false
    var bad = false

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(bad ? RT.red : idle ? Color.secondary : Color.primary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(bad ? RT.red.opacity(0.5) : Color.secondary.opacity(0.3)))
    }
}

/// 手动路由的组：卡片上列出成员，点哪个所有请求就发给哪个（网页 pickRow）。
private struct ManualPicks: View {
    let store: ManageStore
    let group: WebGroup

    var body: some View {
        let picked = group.pickedMember
        VStack(alignment: .leading, spacing: 4) {
            Text("所有请求发往的模型").font(.caption).foregroundStyle(.secondary)
            ForEach(group.memberDetails) { member in
                let on = member.id == picked
                Button {
                    if !on { Task { await store.pickGroupMember(group.id, member: member.id) } }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: on ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(on ? Color.accentColor : .secondary)
                        Text(member.title).foregroundStyle(member.ready ? .primary : .secondary)
                        Text(member.subtitle).font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .font(.subheadline)
                    .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("group.pick.\(member.id)")
            }
        }
    }
}

/// 自动换行的标签行。
struct TagFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { y += line + spacing; x = 0; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

// MARK: 多账号 / 多 Key

private struct PoolRow: View {
    let store: ManageStore
    let pool: WebGroupPool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(pool.name).fontWeight(.semibold)
                Text(pool.countText).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityHint(pool.who.joined(separator: "、"))
            Picker("路由", selection: Binding(get: { pool.routing }, set: { routing in
                Task { await store.setPool(pool.provider, routing: routing) }
            })) {
                ForEach(GroupRouting.poolChoices + (GroupRouting.poolChoices.contains(pool.routing) ? [] : [pool.routing])) { routing in
                    Text(routing.title).tag(routing)
                }
            }
            .accessibilityIdentifier("pool.routing.\(pool.provider)")
            Picker("会话保持", selection: Binding(get: { pool.affinity }, set: { affinity in
                Task { await store.setPool(pool.provider, affinity: affinity) }
            })) {
                ForEach(GroupAffinity.allCases) { Text($0.title).tag($0) }
            }
            if pool.routing.sinkable {
                Toggle("被限流时排到最后", isOn: Binding(get: { pool.sink }, set: { sink in Task { await store.setPool(pool.provider, sink: sink) } }))
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: 编辑

/// 新建 / 编辑路由组（网页 groupEditor 的手机版）。保存是整组覆盖：这里没有的设置（规则、模式、分类模型、推理等级、上下文）原样保留。
struct GroupEditorView: View {
    let store: ManageStore
    let group: WebGroup?
    @Environment(\.dismiss) private var dismiss
    @State private var id: String
    @State private var name: String
    @State private var members: [String]
    @State private var routing: GroupRouting
    @State private var affinity: GroupAffinity
    @State private var sink: Bool
    @State private var off: Set<String>
    @State private var weights: [String: Int]
    @State private var fast: Set<String>
    @State private var firstToken: Int
    @State private var patience: Int
    @State private var unlists: Bool
    @State private var confirmDelete = false

    init(store: ManageStore, group: WebGroup?) {
        self.store = store
        self.group = group
        _id = State(initialValue: group?.id ?? "")
        _name = State(initialValue: group?.name ?? "")
        _members = State(initialValue: group?.members ?? [])
        _routing = State(initialValue: group?.routingKind ?? .smart)
        _affinity = State(initialValue: group?.affinity ?? .auto)
        _sink = State(initialValue: group?.sink ?? false)
        _off = State(initialValue: Set(group?.off ?? []))
        _weights = State(initialValue: group?.weights ?? [:])
        _fast = State(initialValue: Set(group?.fast ?? []))
        _firstToken = State(initialValue: group?.firstToken ?? 0)
        _patience = State(initialValue: group?.patience == 60 ? 0 : group?.patience ?? 0)
        _unlists = State(initialValue: group?.unlists ?? false)
    }

    private var slug: String { id.trimmingCharacters(in: .whitespaces).lowercased() }
    private var idValid: Bool {
        !slug.isEmpty && slug.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }
    }
    private var allOff: Bool { routing != .manual && !members.isEmpty && members.allSatisfy(off.contains) }

    private func detail(_ member: String) -> GroupMemberDetail {
        var detail = group?.memberDetails.first { $0.id == member }
            ?? GroupMemberDetail.candidate(member, models: store.groups?.models ?? [], groups: store.groups?.groups ?? [])
        detail.off = off.contains(member)
        detail.fast = fast.contains(member)
        detail.weight = max(weights[member] ?? 1, 1)
        return detail
    }

    private func share(_ member: String) -> Int {
        let on = members.filter { !off.contains($0) }
        let total = on.reduce(0) { $0 + max(weights[$1] ?? 1, 1) }
        guard total > 0, on.contains(member) else { return 0 }
        return Int((100 * Double(max(weights[member] ?? 1, 1)) / Double(total)).rounded())
    }

    private struct Candidate: Identifiable {
        var id: String
        var title: String
        var section: String
    }

    private var candidates: [Candidate] {
        let models = (store.groups?.models ?? []).map { Candidate(id: $0.id, title: $0.name, section: $0.providerName) }
        let others = (store.groups?.visible ?? []).filter { $0.id != group?.id && !$0.auto }.map { Candidate(id: $0.ref, title: $0.name, section: "路由组") }
        return (others + models).filter { !members.contains($0.id) }
    }

    var body: some View {
        Form {
            Section {
                TextField("名称（例：到处都能用的 Opus）", text: $name).disabled(group?.auto == true)
                    .accessibilityIdentifier("group.name")
                TextField("id（小写字母、数字、- 和 .）", text: $id)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("group.id")
            } footer: {
                if let group, group.auto {
                    Text("magpie 自动发现的组：保存改动后它就成为你的组。")
                } else {
                    Text("Agent 选它时用 group/\(slug.isEmpty ? "…" : slug)。" + (group.map { slug != $0.id ? "正在用 \($0.ref) 的 Agent 会一起改过去。" : "" } ?? ""))
                }
            }

            Section {
                if members.isEmpty { Text("还没有成员。").foregroundStyle(.secondary) }
                ForEach(Array(members.enumerated()), id: \.element) { index, member in
                    MemberEditRow(detail: detail(member), index: index, routing: routing, share: share(member),
                                  speed: store.speeds.speed(for: detail(member)),
                                  fastest: routing == .fast && store.speeds.fastest(in: members.map(detail)) == member,
                                  onToggle: { on in toggle(member, on: on) },
                                  onWeight: { weights[member] = $0 > 1 ? $0 : nil },
                                  onFast: { toggleFast(member) })
                        .deleteDisabled(detail(member).matched)
                        .accessibilityIdentifier("group.member.\(index)")
                }
                .onMove { members.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { offsets in
                    let removed = offsets.map { members[$0] }
                    members.remove(atOffsets: offsets)
                    for member in removed { off.remove(member); fast.remove(member); weights[member] = nil }
                }
                Menu {
                    let sections = Dictionary(grouping: candidates, by: \.section)
                    ForEach(sections.keys.sorted { $0 == "路由组" ? true : $1 == "路由组" ? false : $0 < $1 }, id: \.self) { section in
                        Section(section) {
                            ForEach(sections[section] ?? []) { candidate in
                                Button(candidate.title) { members.append(candidate.id) }
                            }
                        }
                    }
                } label: {
                    Label(members.isEmpty ? "添加模型" : "再添加一个模型", systemImage: "plus.circle")
                }
                .disabled(candidates.isEmpty)
                .accessibilityIdentifier("group.addMember")
                if routing == .weight, members != byWeight {
                    Button("按权重排序") { members = byWeight }
                        .accessibilityIdentifier("group.sortWeight")
                }
            } header: {
                Text("模型")
            } footer: {
                Text(allOff ? "所有模型都关掉了：至少开一个，否则组里没有可以发送的模型。" : "排第一的模型决定本组对外的能力；按顺序模式下从上往下尝试。拖动调整顺序，左滑移除；按模式匹配进来的只能关掉。")
                    .foregroundStyle(allOff ? RT.red : Color.secondary)
            }

            Section {
                ForEach(GroupRouting.groupChoices + (GroupRouting.groupChoices.contains(routing) ? [] : [routing])) { choice in
                    Button {
                        routing = choice
                    } label: {
                        HStack {
                            Label(choice.title, systemImage: choice.symbol).foregroundStyle(.primary)
                            Spacer()
                            if choice == routing { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                    .accessibilityIdentifier("group.routing.choice.\(choice.id)")
                    .accessibilityAddTraits(choice == routing ? .isSelected : [])
                }
            } header: {
                Text("路由")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(routing.hint)
                    Text("成员中的路由组，以及供应商路由不是「智能」的模型，都保留自己的路由：本组只在它与其他成员间选择，选中后按它自己的顺序尝试。")
                }
            }

            Section {
                if routing.sinkable {
                    Picker("被限流时", selection: $sink) {
                        Text("保持原位").tag(false)
                        Text("排到最后").tag(true)
                    }
                }
                if routing != .manual {
                    Picker("迟迟不出字", selection: $firstToken) {
                        ForEach(timeoutChoices(GroupTimeouts.firstToken, current: firstToken)) { Text($0.title).tag($0.seconds) }
                    }
                }
                Picker("成员全都忙", selection: $patience) {
                    ForEach(timeoutChoices(GroupTimeouts.patience, current: patience)) { Text($0.title).tag($0.seconds) }
                }
                Picker("会话保持", selection: $affinity) {
                    ForEach(GroupAffinity.allCases) { Text($0.title).tag($0) }
                }
                Picker("模型列表", selection: $unlists) {
                    Text("也列出成员模型").tag(false)
                    Text("只列出本组").tag(true)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if routing.sinkable {
                        Text(sink ? "仍有额度却被限流（429）的账号排到最后，前面的账号依次被限流后才再轮到它，负载因此轮转。额度用完的照常休息。"
                             : "仍有额度却被限流的账号按厂商要求休息，之后回到原位继续使用。")
                    }
                    if routing != .manual {
                        Text(firstToken > 0 ? "成员 \(GroupTimeouts.firstTokenTitle(firstToken)) 还没开始回答（没有文字、推理或工具调用）就放弃它、改问下一个，Agent 不会收到它的半截回答。"
                             : "每个成员都会一直等到它开始回答，不论多久。")
                    }
                    Text(patience < 0 ? "每个成员都失败时，Agent 立刻拿到最后一个的错误。"
                         : "每个成员都因暂时性的错误（过载、不可用、短暂限流）失败时，在 \(GroupTimeouts.patienceTitle(patience)) 内隔一会儿再依次重试。")
                    Text(affinity.hint)
                    Text(unlists ? "Agent 的模型列表和网关的 /v1/models 只列出本组，成员模型通过本组使用。" : "Agent 的模型列表和网关的 /v1/models 会列出本组，也列出组里的每个模型。")
                }
            }

            if let group, group.ruleCount > 0 || !group.patterns.isEmpty || !group.classifier.isEmpty {
                Section {
                    if group.ruleCount > 0 { LabeledContent("规则", value: "\(group.ruleCount) 条") }
                    ForEach(group.patterns, id: \.pattern) { pattern in
                        LabeledContent("模式", value: "\(pattern.pattern) · \(pattern.models) 个")
                    }
                    if !group.classifier.isEmpty { LabeledContent("分类模型", value: group.classifier) }
                } header: {
                    Text("其他设置")
                } footer: {
                    Text("这些设置在 Mac 上的 magpie 网页里编辑；在这里保存时原样保留。")
                }
            }

            if let group, !group.auto {
                Section {
                    Button("删除这个路由组", role: .destructive) { confirmDelete = true }
                        .accessibilityIdentifier("group.delete")
                }
                .confirmationDialog("删除路由组「\(group.name)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("删除路由组", role: .destructive) {
                        Task { if await store.deleteGroup(group.id) { dismiss() } }
                    }
                    .accessibilityIdentifier("group.delete.confirm")
                } message: {
                    Text("Agent 将不能再选这个路由组。")
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle(group == nil ? "新建路由组" : group?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(group == nil ? "添加" : "保存") {
                    Task { if await store.saveGroup(group, edits: edits) { dismiss() } }
                }
                .disabled(!idValid || members.isEmpty && (group?.patterns.isEmpty ?? true) || allOff || store.busy)
                .accessibilityIdentifier("group.save")
            }
        }
        .manageAlerts(store: store, id: "group.\(group?.id ?? "new")")
    }

    private func toggle(_ member: String, on: Bool) {
        if on {
            off.remove(member)
        } else {
            off.insert(member)
        }
    }

    private func toggleFast(_ member: String) {
        if fast.contains(member) {
            fast.remove(member)
        } else {
            fast.insert(member)
        }
    }

    private var byWeight: [String] {
        members.enumerated().sorted { a, b in
            let wa = max(weights[a.element] ?? 1, 1), wb = max(weights[b.element] ?? 1, 1)
            return wa != wb ? wa > wb : a.offset < b.offset
        }.map(\.element)
    }

    private var edits: GroupEdits {
        GroupEdits(id: slug, name: name.isEmpty ? slug : name, members: members, routing: routing, affinity: affinity,
                   sink: sink, off: off, weights: weights, fast: fast, firstToken: firstToken, patience: patience, unlists: unlists)
    }

    private func timeoutChoices(_ presets: [GroupTimeout], current: Int) -> [GroupTimeout] {
        presets.contains { $0.seconds == current } ? presets : presets + [GroupTimeout(current, GroupTimeouts.firstTokenTitle(current))]
    }
}

/// 编辑页里的一个成员（网页 editor 的 fbrow）：开关、序号、名字、速度 / 上下文 / 图片标签、权重、快速模式。
private struct MemberEditRow: View {
    let detail: GroupMemberDetail
    let index: Int
    let routing: GroupRouting
    let share: Int
    let speed: ModelSpeed?
    let fastest: Bool
    let onToggle: (Bool) -> Void
    let onWeight: (Int) -> Void
    let onFast: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Toggle(detail.title, isOn: Binding(get: { !detail.off }, set: onToggle))
                    .labelsHidden()
                    .accessibilityIdentifier("group.member.on.\(index)")
                Text("\(index + 1)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .frame(width: 20, height: 20)
                    .background(.quaternary, in: .circle)
                VStack(alignment: .leading, spacing: 1) {
                    Text(detail.title).foregroundStyle(detail.off || !detail.ready ? .secondary : .primary).lineLimit(1)
                    Text(detail.subtitle.isEmpty ? detail.id : detail.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            TagFlow(spacing: 5) {
                if let speed, !speed.text.isEmpty {
                    chip(speed.text + (fastest ? " · 最快" : ""), symbol: "hare", tint: fastest ? .green : .secondary)
                }
                if let context = detail.context, context > 0 { chip(UsageFormat.tokens(context), symbol: "text.alignleft") }
                if detail.images { chip("看图", symbol: "photo") } else if detail.imagesUnknown { chip("图片未知", symbol: "photo") }
                if detail.matched { chip("按模式匹配", symbol: "asterisk") }
                if detail.canFast {
                    Button(action: onFast) { chip(detail.fast ? "快速" : "标准速度", symbol: "bolt", tint: detail.fast ? .orange : .secondary) }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("group.member.fast.\(index)")
                }
            }
            if routing == .weight {
                Stepper(value: Binding(get: { detail.weight }, set: onWeight), in: 1...1000) {
                    Text(detail.off ? "权重 \(detail.weight)" : "权重 \(detail.weight) · \(share)%").font(.subheadline)
                }
                .accessibilityIdentifier("group.member.weight.\(index)")
            }
            if let reason = detail.unavailableReason {
                Text(reason).font(.caption).foregroundStyle(RT.red)
            }
        }
        .opacity(detail.off ? 0.6 : 1)
        .padding(.vertical, 2)
    }

    private func chip(_ text: String, symbol: String, tint: Color = .secondary) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption2)
            .foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary.opacity(0.5), in: .capsule)
    }
}
