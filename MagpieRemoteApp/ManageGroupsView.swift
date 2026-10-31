import SwiftUI
import MagpieRemoteCore

/// 路由组：把几个模型组成一个 `group/<id>`，按顺序或规则分配请求。可开关、新建、编辑成员、删除。
struct ManageGroupsView: View {
    let store: ManageStore
    @State private var pendingDelete: WebGroup?

    private var groups: [WebGroup] { (store.groups?.groups ?? []).filter { !$0.hidden } }

    var body: some View {
        List {
            if groups.isEmpty {
                Section {
                    Text(store.groups == nil ? "正在读取…" : "还没有路由组。点右上角「+」新建。").foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(groups) { group in
                    NavigationLink {
                        GroupEditorView(store: store, group: group)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(group.name).foregroundStyle(group.disabled ? .secondary : .primary)
                                    if group.auto { Text("自动").font(.caption2.weight(.semibold)).foregroundStyle(.blue) }
                                    if group.disabled { Text("已关闭").font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
                                }
                                Text("\(group.ref) · \(group.members.count) 个成员").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("启用", isOn: Binding(get: { !group.disabled }, set: { on in
                                Task { await store.setGroup(group.id, on: on) }
                            }))
                            .labelsHidden()
                            .accessibilityIdentifier("group.enabled.\(group.id)")
                        }
                    }
                    .accessibilityIdentifier("group.row.\(group.id)")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !group.auto {
                            Button("删除", role: .destructive) { pendingDelete = group }
                        }
                    }
                }
            } footer: {
                Text("Agent 选择 group/… 模型时，magpie 会在组内成员之间分配请求。自动发现的组只能开关。")
            }
        }
        .navigationTitle("路由组")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    GroupEditorView(store: store, group: nil)
                } label: {
                    Label("新建路由组", systemImage: "plus")
                }
                .accessibilityIdentifier("group.add")
            }
        }
        .refreshable { await store.refresh() }
        .confirmationDialog("删除路由组「\(pendingDelete?.name ?? "")」？", isPresented: present($pendingDelete), titleVisibility: .visible, presenting: pendingDelete) { group in
            Button("删除路由组", role: .destructive) { Task { await store.deleteGroup(group.id) } }
        } message: { _ in
            Text("正在用这个组的 Agent 需要另选模型。")
        }
        .manageAlerts(store: store, id: "groups")
    }
}

/// 新建 / 编辑路由组。保存是整组覆盖：未在这里显示的设置（路由方式、规则、权重等）原样保留。
struct GroupEditorView: View {
    let store: ManageStore
    let group: WebGroup?
    @Environment(\.dismiss) private var dismiss
    @State private var id: String
    @State private var name: String
    @State private var members: [String]
    @State private var confirmDelete = false

    init(store: ManageStore, group: WebGroup?) {
        self.store = store
        self.group = group
        _id = State(initialValue: group?.id ?? "")
        _name = State(initialValue: group?.name ?? "")
        _members = State(initialValue: group?.members ?? [])
    }

    private var readOnly: Bool { group?.auto ?? false }

    private var idValid: Bool {
        let trimmed = id.trimmingCharacters(in: .whitespaces).lowercased()
        return !trimmed.isEmpty && trimmed.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }
    }

    /// 可以加进来的模型与其它路由组。
    private struct Candidate: Identifiable {
        var id: String
        var title: String
    }

    private var candidates: [Candidate] {
        let models = (store.groups?.models ?? []).map { Candidate(id: $0.id, title: "\($0.providerName) · \($0.name)") }
        let others = (store.groups?.groups ?? []).filter { $0.id != group?.id }.map { Candidate(id: $0.ref, title: "路由组 · \($0.name)") }
        return (models + others).filter { !members.contains($0.id) }
    }

    private func title(_ member: String) -> String {
        if let model = store.groups?.models.first(where: { $0.id == member }) { return "\(model.providerName) · \(model.name)" }
        return member
    }

    var body: some View {
        Form {
            Section {
                TextField("名称", text: $name).disabled(readOnly)
                    .accessibilityIdentifier("group.name")
                TextField("id（小写字母、数字、- 和 .）", text: $id)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(readOnly)
                    .accessibilityIdentifier("group.id")
            } footer: {
                Text("Agent 里看到的模型名是 group/\(id.isEmpty ? "…" : id.lowercased())。改 id 时，正在用它的 Agent 会一起改过去。")
            }

            Section {
                if members.isEmpty { Text("还没有成员。").foregroundStyle(.secondary) }
                ForEach(members, id: \.self) { member in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title(member))
                        Text(member).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .onMove { members.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { members.remove(atOffsets: $0) }
                .deleteDisabled(readOnly)
                .moveDisabled(readOnly)
                if !readOnly {
                    Menu {
                        ForEach(candidates) { candidate in
                            Button(candidate.title) { members.append(candidate.id) }
                        }
                    } label: {
                        Label("添加成员", systemImage: "plus.circle")
                    }
                    .disabled(candidates.isEmpty)
                    .accessibilityIdentifier("group.addMember")
                }
            } header: {
                Text("成员（按顺序）")
            } footer: {
                Text("按顺序路由时排在前面的先用；拖动可调整顺序，左滑移除。")
            }

            if let group, !readOnly {
                Section {
                    Button("删除这个路由组", role: .destructive) { confirmDelete = true }
                        .accessibilityIdentifier("group.delete")
                }
                .confirmationDialog("删除路由组「\(group.name)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("删除路由组", role: .destructive) {
                        Task { if await store.deleteGroup(group.id) { dismiss() } }
                    }
                    .accessibilityIdentifier("group.delete.confirm")
                }
            }
        }
        .environment(\.editMode, .constant(readOnly ? .inactive : .active))
        .navigationTitle(group == nil ? "新建路由组" : group?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !readOnly {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            if await store.saveGroup(group, id: id, name: name.isEmpty ? id : name, members: members) { dismiss() }
                        }
                    }
                    .disabled(!idValid || store.busy)
                    .accessibilityIdentifier("group.save")
                }
            }
        }
        .manageAlerts(store: store, id: "group.\(group?.id ?? "new")")
    }
}
