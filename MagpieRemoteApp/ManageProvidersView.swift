import SwiftUI
import MagpieRemoteCore

/// 供应商列表：拖动排序（= 尝试顺序）、启用 / 停用、删除、添加；点进去编辑名称、地址、Key 与模型开关。
struct ManageProvidersView: View {
    let store: ManageStore
    @State private var adding = false
    @State private var pendingDelete: WebProvider?

    var body: some View {
        List {
            if store.providers.isEmpty {
                Section {
                    Text(store.phase == .ready ? "还没有供应商。点右上角「+」添加，或在网页中登录订阅账号。" : "正在读取…")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(store.providers) { provider in
                    NavigationLink {
                        ProviderDetailView(store: store, id: provider.id)
                    } label: {
                        ProviderRow(provider: provider)
                    }
                    .accessibilityIdentifier("provider.row.\(provider.id)")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("删除", role: .destructive) { pendingDelete = provider }
                        Button(provider.off ? "启用" : "停用") {
                            Task { await store.setProvider(provider.id, enabled: provider.off) }
                        }
                        .tint(.orange)
                    }
                }
                .onMove { source, destination in
                    Task { await store.moveProviders(from: source, to: destination) }
                }
            } footer: {
                if !store.providers.isEmpty {
                    Text("排在前面的先用。点「编辑」后拖动可以调整顺序；左滑可停用或删除。")
                }
            }
        }
        .navigationTitle("供应商")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Label("添加供应商", systemImage: "plus") }
                    .accessibilityIdentifier("provider.add")
            }
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        .refreshable { await store.refresh() }
        .sheet(isPresented: $adding) { AddProviderSheet(store: store) }
        .confirmationDialog("删除供应商「\(pendingDelete?.name ?? "")」？", isPresented: present($pendingDelete), titleVisibility: .visible, presenting: pendingDelete) { provider in
            Button("删除供应商", role: .destructive) { Task { await store.deleteProvider(provider.id) } }
        } message: { _ in
            Text("会删除它保存的 Key 和设置；正在用它的模型的 Agent 会被换到别的模型。")
        }
        .manageAlerts(store: store, id: "providers")
    }
}

private struct ProviderRow: View {
    let provider: WebProvider

    var body: some View {
        HStack(spacing: 12) {
            BrandIcon(provider.officialIcon, size: 22).opacity(provider.off ? 0.5 : 1)
            details
        }
        .accessibilityElement(children: .combine)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(provider.name).foregroundStyle(provider.off ? .secondary : .primary)
                if provider.off {
                    Text("已停用").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                } else if !provider.ready {
                    Text("未就绪").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                }
            }
            Text("\(provider.subtitle) · 开放 \(provider.models.filter(\.on).count)/\(provider.models.count) 个模型")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// 一个供应商的详情：基本信息（整份保存）、启用开关、模型开关、删除。
struct ProviderDetailView: View {
    let store: ManageStore
    let id: String
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var chat = ""
    @State private var key = ""
    @State private var loadedFrom: WebProvider?
    @State private var confirmDelete = false
    /// 「API Key」区的明文与弹窗（见 ProviderKeysSection）。
    @State private var keysUI = ProviderKeysUI()

    private var provider: WebProvider? { store.provider(id) }

    private var dirty: Bool {
        guard let provider else { return false }
        return name != provider.name || chat != provider.chat || !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if let provider {
                form(provider)
            } else {
                ContentUnavailableView("供应商已不存在", systemImage: "server.rack")
            }
        }
        .navigationTitle(provider?.name ?? "供应商")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .manageAlerts(store: store, id: "provider.\(id)")
    }

    private func load() {
        guard let provider, loadedFrom == nil else { return }
        name = provider.name
        chat = provider.chat
        key = ""
        loadedFrom = provider
    }

    @ViewBuilder
    private func form(_ provider: WebProvider) -> some View {
        Form {
            if provider.isAccount {
                Section {
                    LabeledContent("名称", value: provider.name)
                    Text("这是登录得来的订阅账号。账号的登录、切换在「在网页中打开 › 账号登录」里管理；这里可以开关它和它的模型。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Section {
                    TextField("名称", text: $name)
                        .accessibilityIdentifier("provider.name")
                    if provider.preset.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Base URL").font(.caption).foregroundStyle(.secondary)
                            TextField("例如 https://relay.example/v1", text: $chat)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .accessibilityIdentifier("provider.chat")
                        }
                    } else {
                        LabeledContent("预设", value: provider.preset)
                    }
                    // 其余已保存的地址（Responses / Anthropic / Gemini，以及预设自带的地址）只读显示
                    ForEach(provider.baseURLs.filter { !(provider.preset.isEmpty && $0.api == "OpenAI Chat") }) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Base URL · \(item.api)").font(.caption).foregroundStyle(.secondary)
                            Text(item.url)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("provider.url.\(item.api)")
                    }
                    // 还没有 Key 时在这里填第一把；已有 Key 时到下面的「API Key」区管理（与网页端相同）
                    if provider.keyList.isEmpty {
                        SecureField(provider.keySet ? "API Key（已保存 \(provider.keyMasked)，留空不变）" : "API Key", text: $key)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("provider.key")
                    }
                    Button("保存修改") {
                        Task {
                            let edits = WebRequests.ProviderEdits(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                                                  chat: provider.preset.isEmpty ? chat.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                                                                  key: key)
                            if await store.saveProvider(provider, edits: edits) {
                                key = ""
                                if let fresh = store.provider(id) { name = fresh.name; chat = fresh.chat }
                            }
                        }
                    }
                    .disabled(!dirty || store.busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("provider.save")
                } header: {
                    Text("基本信息")
                } footer: {
                    Text(provider.keyList.isEmpty
                         ? "保存时其余设置（备用、请求头、代理、并发、计价等）保持不变。"
                         : "保存只改名称和地址；Key 在下面单独管理，已保存的 Key 和其余设置（备用、请求头、代理、并发、计价等）都保持不变。")
                }

                if !provider.keyList.isEmpty {
                    ProviderKeysSection(store: store, provider: provider, ui: keysUI)
                }
            }

            Section {
                Toggle("启用", isOn: Binding(get: { !provider.off }, set: { on in
                    Task { await store.setProvider(provider.id, enabled: on) }
                }))
                .accessibilityIdentifier("provider.enabled")
            } footer: {
                Text("停用后保留 Key 和设置，但 Agent 不会再用到它的模型。")
            }

            Section {
                if provider.models.isEmpty {
                    Text(provider.listError.map { "读取模型列表失败：\($0)" } ?? "还没有读到模型列表。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(provider.models) { model in
                    Toggle(isOn: Binding(get: { model.on }, set: { on in
                        Task { await store.setModel(model.id, on: on, in: provider) }
                    })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.displayName)
                            if model.displayName != model.id {
                                Text(model.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .disabled(store.busy)
                    .accessibilityIdentifier("provider.model.\(model.id)")
                }
                Button("从供应商重新读取模型列表") { Task { await store.refetchModels(provider.id) } }
                    .disabled(store.busy)
            } header: {
                Text("模型（开放 \(provider.models.filter(\.on).count)/\(provider.models.count)）")
            } footer: {
                Text("打开的模型会出现在 Agent 的模型列表里。")
            }

            Section {
                Button("删除这个供应商", role: .destructive) { confirmDelete = true }
                    .accessibilityIdentifier("provider.delete")
            }
        }
        .providerKeyPresentations(keysUI, store: store, provider: provider)
        .confirmationDialog("删除供应商「\(provider.name)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除供应商", role: .destructive) {
                Task { if await store.deleteProvider(provider.id) { dismiss() } }
            }
            .accessibilityIdentifier("provider.delete.confirm")
        } message: {
            Text("会删除它保存的 Key 和设置；正在用它的模型的 Agent 会被换到别的模型。")
        }
    }
}

/// 添加供应商：自定义（OpenAI 兼容地址 + Key）或预设（只填 Key）。
private struct AddProviderSheet: View {
    let store: ManageStore
    @Environment(\.dismiss) private var dismiss
    @State private var usePreset = false
    @State private var preset = ""
    @State private var name = ""
    @State private var chat = ""
    @State private var key = ""

    private var valid: Bool {
        let hasKey = !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if usePreset { return !preset.isEmpty && hasKey }
        return !name.trimmingCharacters(in: .whitespaces).isEmpty && HostProfile.normalizedURL(chat, defaultPort: 443) != nil
            && chat.contains("://")
    }

    var body: some View {
        NavigationStack {
            Form {
                if !store.presets.isEmpty {
                    Picker("类型", selection: $usePreset) {
                        Text("自定义").tag(false)
                        Text("预设").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                if usePreset {
                    Picker("预设", selection: $preset) {
                        Text("请选择").tag("")
                        ForEach(store.presets) { item in Text(item.name).tag(item.id) }
                    }
                } else {
                    TextField("名称", text: $name).accessibilityIdentifier("provider.new.name")
                    TextField("Base URL，例如 https://relay.example/v1", text: $chat)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("provider.new.chat")
                }
                Section {
                    SecureField("API Key", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("provider.new.key")
                } footer: {
                    Text("Key 直接发给你的 Mac 上的 magpie 保存，不会留在这台 iPhone 上。保存后 magpie 会尝试读取模型列表，可能要等几秒。")
                }
            }
            .navigationTitle("添加供应商")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if store.busy {
                        ProgressView()
                    } else {
                        Button("添加") {
                            Task {
                                if await store.addProvider(name: name, chat: chat, key: key, preset: usePreset ? preset : nil) { dismiss() }
                            }
                        }
                        .disabled(!valid)
                        .accessibilityIdentifier("provider.new.save")
                    }
                }
            }
            .manageAlerts(store: store, id: "provider.add")
        }
    }
}
