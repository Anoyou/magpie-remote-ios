import SwiftUI
import MagpieRemoteCore

// 网关密钥的「限额」编辑器与「此密钥可用的模型」（官方 Gateway › Keys 的 gatewayLimitEditor、gatewayModelsBadge）。

/// 一把密钥的限额（官方 gatewayLimitEditor）：周期（每日 / 每周 / 每月 / 每 N 天 / 每 N 小时）、Token、估算费用、缓存读取也计入；
/// 几条限额时上面一排切换；「添加限额」（最多 5 条）、「删除这条限额」/「不限制」、「重置额度」（先确认）。点「保存」才发出去。
struct KeyLimitSheet: View {
    let store: ManageStore
    let keyID: String
    @Environment(\.dismiss) private var dismiss
    @State private var draft: KeyLimitDraft?
    @State private var asksReset = false
    @State private var asksRemove = false
    @State private var saving = false

    private var key: WebCallerKey? { store.keys.first { $0.id == keyID } }

    var body: some View {
        NavigationStack {
            Group {
                if let key, let draft {
                    form(key, draft: Binding(get: { draft }, set: { self.draft = $0 }))
                } else {
                    ContentUnavailableView("密钥已不存在", systemImage: "key")
                }
            }
            .navigationTitle(key.map { $0.limits.isEmpty ? "为 \($0.name) 设置限额" : "修改 \($0.name) 的限额" } ?? "限额")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if draft?.limit == nil { asksRemove = true } else { save() }
                    }
                    .disabled(!(draft?.canSave ?? false) || saving)
                    .accessibilityIdentifier("key.limit.save")
                }
            }
        }
        .onAppear {
            guard draft == nil, let key else { return }
            draft = KeyLimitDraft(key: key, index: max(0, key.bindingUsage.flatMap { u in key.usages.firstIndex(of: u) } ?? 0))
        }
        .confirmationDialog(removeTitle, isPresented: $asksRemove, titleVisibility: .visible) {
            Button(removeTitle, role: .destructive) { save() }
                .accessibilityIdentifier("key.limit.remove.confirm")
            Button("取消", role: .cancel) {}
        } message: {
            Text("去掉后这条限额不再拦请求。")
        }
        .confirmationDialog("重置 \(key?.name ?? "") 的额度？", isPresented: $asksReset, titleVisibility: .visible) {
            Button("重置额度", role: .destructive) {
                guard let key, let draft else { return }
                Task {
                    if await store.callerKey(.resetLimit, WebRequests.callerKeyResetLimit(key, index: draft.index)).ok {
                        store.status = "已重置 \(key.name) 的额度"
                    }
                }
            }
            .accessibilityIdentifier("key.limit.reset.confirm")
            Button("取消", role: .cancel) {}
        } message: {
            if let key, let draft { Text(key.resetLimitMessage(index: draft.index)) }
        }
        .manageAlerts(store: store, id: "keys.limit")
    }

    private var removeTitle: String { (key?.limits.count ?? 0) > 1 ? "删除这条限额" : "取消 \(key?.name ?? "") 的限额" }

    private func save() {
        guard let key, let draft else { return }
        saving = true
        Task {
            let ok = await store.callerKey(.limit, draft.body(key: key.id)).ok
            saving = false
            if ok {
                store.status = draft.savedSaid(name: key.name)
                dismiss()
            }
        }
    }

    @ViewBuilder
    private func form(_ key: WebCallerKey, draft: Binding<KeyLimitDraft>) -> some View {
        let limits = key.limits
        let d = draft.wrappedValue
        Form {
            if limits.count > 1 || (d.isNew && !limits.isEmpty) {
                Section("这个密钥的限额") {
                    Picker("这个密钥的限额", selection: Binding(get: { d.index }, set: { self.draft = KeyLimitDraft(key: key, index: $0) })) {
                        ForEach(Array(limits.enumerated()), id: \.offset) { i, limit in Text(limit.perWords).tag(i) }
                        if d.isNew { Text("新限额").tag(limits.count) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("key.limit.which")
                }
            }
            Section {
                Picker("周期", selection: draft.period) {
                    ForEach(CallerKeyLimit.periods, id: \.value) { Text($0.title).tag($0.value) }
                }
                .accessibilityIdentifier("key.limit.period")
                if d.period == "days" {
                    LabeledContent("天数") {
                        TextField("10", text: draft.days).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                            .accessibilityLabel("每个周期的天数").accessibilityIdentifier("key.limit.days")
                    }
                }
                if d.period == "hours" {
                    LabeledContent("小时数") {
                        TextField("5", text: draft.hours).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                            .accessibilityLabel("每个周期的小时数").accessibilityIdentifier("key.limit.hours")
                    }
                }
                LabeledContent("Token") {
                    TextField("不限 Token", text: draft.tokens).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .accessibilityLabel("Token 限额").accessibilityIdentifier("key.limit.tokens")
                }
                LabeledContent("估算费用（美元）") {
                    TextField("不限费用", text: draft.cost).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        .accessibilityLabel("估算费用限额（美元）").accessibilityIdentifier("key.limit.cost")
                }
                Toggle("缓存读取也计入", isOn: draft.cacheReads)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let problem = d.problem {
                        Text(problem).foregroundStyle(.red).accessibilityIdentifier("key.limit.problem")
                    } else if d.changed {
                        Text("未保存").foregroundStyle(.orange)
                    }
                    Text("Token 计未命中缓存的输入、输出和缓存写入。费用按用量页价格估算，非账单。周期按本机时间的自然日、周、月（每周从周一起），或从设置或重置额度时起每 N 天或每 N 小时。本机无密钥的请求不受限额。")
                }
            }
            if !d.isNew, d.index < key.usages.count {
                let used = key.usages[d.index]
                Section {
                    Text(key.limitLine(used)).font(.callout).foregroundStyle(used.spent ? .red : .primary)
                        .accessibilityIdentifier("key.limit.used")
                    Button("重置额度") { asksReset = true }
                        .accessibilityHint("让此密钥的 Token 和费用一起从 0 开始重新计数")
                        .accessibilityIdentifier("key.limit.reset")
                } header: {
                    Text("已用")
                } footer: {
                    if let start = used.start, let reset = used.reset {
                        Text("自 \(start.formatted(date: .abbreviated, time: .shortened)) 起计；\(reset.formatted(date: .abbreviated, time: .shortened)) 重置"
                             + (used.unpriced > 0 ? "\n\(used.unpriced) 次调用无价格，未计入费用" : ""))
                    }
                }
            }
            Section {
                if !d.isNew && !limits.isEmpty && limits.count < CallerKeyLimit.maxLimits {
                    Button("添加限额") { self.draft = KeyLimitDraft(key: key, index: limits.count) }
                        .accessibilityHint("在另一个周期再设一条限额；每条限额都还有剩余时请求才放行")
                        .accessibilityIdentifier("key.limit.add")
                }
                if !d.isNew {
                    Button(limits.count > 1 ? "删除这条限额" : "不限制", role: .destructive) {
                        draft.wrappedValue.tokens = ""
                        draft.wrappedValue.cost = ""
                    }
                    .accessibilityHint("清空上限；点「保存」后生效")
                    .accessibilityIdentifier("key.limit.clear")
                }
            }
        }
    }
}

/// 「此密钥可用的模型」（官方 gatewayModelsBadge 的菜单）：全部模型，或只限某些模型 / 账号。点「完成」时发出去。
struct KeyModelsSheet: View {
    let store: ManageStore
    let keyID: String
    @Environment(\.dismiss) private var dismiss
    @State private var options: [CallerKeyModels.Option]?
    @State private var picked: Set<String> = []
    @State private var search = ""
    @State private var saving = false
    @State private var failed = false

    private var key: WebCallerKey? { store.keys.first { $0.id == keyID } }

    private struct Block: Identifiable {
        var title: String
        var options: [CallerKeyModels.Option]
        var id: String { title }
    }

    private var blocks: [Block] {
        let words = search.trimmingCharacters(in: .whitespaces).lowercased()
        var out: [Block] = []
        for option in options ?? [] where option.kind != .all {
            guard words.isEmpty || [option.name, option.note, option.value].contains(where: { $0.lowercased().contains(words) }) else { continue }
            let title = option.section.isEmpty ? "其它" : option.section
            if let i = out.firstIndex(where: { $0.title == title }) { out[i].options.append(option) } else { out.append(Block(title: title, options: [option])) }
        }
        return out
    }

    var body: some View {
        NavigationStack {
            Group {
                if let options, let key {
                    List {
                        Section {
                            Button {
                                picked = []
                            } label: {
                                optionLabel(options[0], on: picked.isEmpty)
                            }
                            .accessibilityIdentifier("key.models.all")
                        } footer: {
                            if !key.accounts.isEmpty || picked.contains(where: isAccount) {
                                Text(picked.contains(where: { !isAccount($0) })
                                     ? "没勾选任何账号的供应商，它的所有账号都可用；要让此密钥用不了它，请只勾选其他供应商的模型"
                                     : "没有勾选模型，此密钥只能使用所勾选账号所属供应商的模型")
                            }
                        }
                        ForEach(blocks) { block in
                            Section(block.title) {
                                ForEach(block.options) { option in
                                    Button {
                                        if picked.contains(option.value) { picked.remove(option.value) } else { picked.insert(option.value) }
                                    } label: {
                                        optionLabel(option, on: picked.contains(option.value))
                                    }
                                    .accessibilityIdentifier("key.models.option.\(option.value)")
                                }
                            }
                        }
                    }
                    .searchable(text: $search, prompt: "搜索模型")
                } else if failed {
                    ContentUnavailableView("读不到模型列表", systemImage: "exclamationmark.triangle")
                } else {
                    ProgressView("正在读取…")
                }
            }
            .navigationTitle("此密钥可用的模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { save() }
                        .disabled(options == nil || saving)
                        .accessibilityIdentifier("key.models.done")
                }
            }
        }
        .task {
            guard options == nil, let key else { return }
            if let models = await store.callerKeyModels() {
                options = models.options(for: key)
                picked = Set(key.models + key.accounts)
            } else {
                failed = true
            }
        }
        .manageAlerts(store: store, id: "keys.models")
    }

    private func isAccount(_ value: String) -> Bool {
        options?.contains { $0.value == value && $0.kind == .account } ?? false
    }

    private func optionLabel(_ option: CallerKeyModels.Option, on: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(option.name).foregroundStyle(.primary)
                if !option.note.isEmpty {
                    Text(option.note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(on ? Color.accentColor : Color.secondary)
        }
        .contentShape(.rect)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func save() {
        guard let key, let options else { return }
        // 照选项的顺序发（主机原样保存）
        let ordered = options.map(\.value).filter { picked.contains($0) }
        let split = CallerKeyModels.split(picked: ordered, options: options, key: key)
        let modelsChanged = split.models != key.models
        guard modelsChanged || split.accounts != nil else { dismiss(); return }
        saving = true
        Task {
            var ok = await store.callerKey(.models, WebRequests.callerKeyModels(key.id, models: split.models)).ok
            if ok, let accounts = split.accounts {
                ok = await store.callerKey(.accounts, WebRequests.callerKeyAccounts(key.id, accounts: accounts)).ok
            }
            saving = false
            if ok {
                store.status = CallerKeyModels.savedSaid(name: key.name, models: split.models, accounts: split.accounts ?? key.accounts)
                dismiss()
            }
        }
    }
}
