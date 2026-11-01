import SwiftUI
import MagpieRemoteCore

/// 「已停用的模型」（官方 设置 › 模型 › Disabled models）：停用的模型在经过 magpie 的每条路径上都会被拒绝。
/// 每条规则一行，写着它现在匹配到哪些模型，可以「启用」（先确认）；「停用…」从列表里选一个，或输入 *fable* 这样的通配符。
struct DisabledModelsView: View {
    let store: ManageStore
    @State private var picking = false
    @State private var pendingEnable: String?

    private var list: [String] { store.settings?.disabledModels ?? [] }

    var body: some View {
        List {
            Section {
                Button {
                    picking = true
                } label: {
                    Label("停用…", systemImage: "nosign")
                }
                .disabled(store.busy || store.settings == nil)
                .accessibilityIdentifier("disabledModels.add")
            } header: {
                Text("停用模型")
            } footer: {
                Text(DisabledModels.explainer)
            }
            Section {
                if list.isEmpty {
                    Text("还没有停用的模型。").foregroundStyle(.secondary)
                }
                ForEach(list, id: \.self) { pattern in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pattern).font(.body.monospaced())
                            Text(DisabledModels.matches(store.settings?.disabledHits[pattern] ?? []))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("启用") { pendingEnable = pattern }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(store.busy)
                            .accessibilityLabel("启用 \(pattern)")
                            .accessibilityIdentifier("disabledModels.enable.\(pattern)")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("disabledModels.row")
                }
            } header: {
                Text("已停用的模型")
            }
        }
        .navigationTitle("已停用的模型")
        .refreshable { await store.refresh() }
        .safeAreaInset(edge: .bottom) { ManageStatusLine(store: store) }
        .sheet(isPresented: $picking) {
            DisabledModelPicker(store: store, list: list)
        }
        .confirmationDialog("启用 \(pendingEnable ?? "")？", isPresented: present($pendingEnable), titleVisibility: .visible, presenting: pendingEnable) { pattern in
            Button("启用 \(pattern)") {
                Task {
                    if await store.setDisabledModels(list.filter { $0 != pattern }) { store.status = "已启用 \(pattern)" }
                }
            }
            .accessibilityIdentifier("disabledModels.enable.confirm")
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("经过 magpie 的请求又可以用到它匹配的模型。")
        }
        .manageAlerts(store: store, id: "disabledModels")
    }
}

/// 选一个模型停用，或输入通配符（官方的 openPicker + 输入框）。
private struct DisabledModelPicker: View {
    let store: ManageStore
    let list: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @State private var search = ""

    private var groups: [(provider: String, models: [SettingsModelRef])] {
        guard let settings = store.settings else { return [] }
        let words = search.trimmingCharacters(in: .whitespaces).lowercased()
        return DisabledModels.choices(settings).compactMap { group in
            let models = group.models.filter { m in
                !list.contains { $0.lowercased() == m.id.lowercased() }
                    && (words.isEmpty || [m.id, m.name, group.provider].contains { $0.lowercased().contains(words) })
            }
            return models.isEmpty ? nil : (group.provider, models)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("输入模型 id 或 *fable* 这样的通配符", text: $typed)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                            .accessibilityIdentifier("disabledModels.typed")
                        Button("停用") { disable(typed) }
                            .disabled(DisabledModels.adding(typed, to: list) == nil || store.busy)
                            .accessibilityIdentifier("disabledModels.typed.add")
                    }
                }
                ForEach(groups, id: \.provider) { group in
                    Section(group.provider) {
                        ForEach(group.models) { model in
                            Button {
                                disable(model.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(model.name).foregroundStyle(.primary)
                                    if model.name != model.id {
                                        Text(model.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .accessibilityIdentifier("disabledModels.pick.\(model.id)")
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "搜索模型")
            .navigationTitle("停用模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
    }

    private func disable(_ pattern: String) {
        guard let next = DisabledModels.adding(pattern, to: list) else { return }
        let id = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            if await store.setDisabledModels(next) {
                store.status = "已停用 \(id)"
                dismiss()
            }
        }
    }
}
