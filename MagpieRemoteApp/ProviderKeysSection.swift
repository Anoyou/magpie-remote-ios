import SwiftUI
import UIKit
import UniformTypeIdentifiers
import MagpieRemoteCore

/// 供应商详情里的「API Key」区：与 magpie 网页端编辑器的「Accounts」一样，一个供应商可以有多把 Key，
/// 请求先发给第一把，它额度用完或被限流时由下一把在用的接上。
///
/// 主机列表里只有脱敏信息；点眼睛按钮时才向主机要这一把的明文（`POST /api/provider/key`，与网页端「显示」/复制相同），
/// 明文只放在这个页面的内存里，再点一次、离开页面或 App 退到后台就丢掉，不写入日志或钥匙串。
struct ProviderKeysSection: View {
    let store: ManageStore
    let provider: WebProvider
    /// 明文与弹窗状态放在详情页持有的对象里：这个区是 List 里的一个 Section，挂在它上面的
    /// sheet / alert / onDisappear 会被 SwiftUI 分到每一行上（同一个弹窗挂了好几份、点「添加另一个 Key」不弹出，
    /// 滚走一行就把明文清掉），所以弹窗统一由 `providerKeyPresentations(_:store:provider:)` 挂在整个表单上。
    @Bindable var ui: ProviderKeysUI
    @Environment(\.scenePhase) private var scenePhase
    @State private var loading: Set<String> = []
    @State private var copiedID: String?

    private var revealed: [String: String] { ui.revealed }

    var body: some View {
        Section {
            ForEach(provider.keyList) { key in
                row(key)
            }
            Button {
                ui.adding = true
            } label: {
                Label("添加另一个 Key", systemImage: "plus.circle")
            }
            .disabled(store.busy)
            .accessibilityIdentifier("provider.key.add")
        } header: {
            Text("API Key（\(provider.keyList.count)）")
        } footer: {
            Text(footer)
        }
    }

    private var footer: String {
        var lines = ["排在第一的先用；它额度用完或被限流时，由下一把在用的接上。"]
        if provider.keysOn > 1, !(provider.raw["routing"]?.string ?? "").isEmpty {
            lines = ["多把 Key 按「路由」设置分摊请求。"]
        }
        lines.append("点眼睛会从你的 Mac 取回这一把的完整 Key，只在这个页面显示，离开页面或切到后台就隐藏。")
        return lines.joined(separator: "")
    }

    @ViewBuilder
    private func row(_ key: WebProviderKey) -> some View {
        let can = provider.permissions(for: key)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(key.name.isEmpty ? "Key" : key.name)
                    .foregroundStyle(key.on ? .primary : .secondary)
                if key.active {
                    badge(provider.keysOn > 1 ? "首选" : "在用", color: .green)
                } else if !key.on {
                    badge("已停用", color: .secondary)
                }
                if key.resting() {
                    badge(restText(key), color: .orange)
                }
                if !key.keyProtocol.isEmpty {
                    badge("仅 \(protocolName(key.keyProtocol))", color: .secondary)
                }
            }
            secretLine(key)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("provider.key.row.\(key.id)")
        .contextMenu { actions(key, can: can) }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if can.canRemove {
                Button("删除", role: .destructive) { ui.pendingRemove = key }
            }
            if can.canSwitch {
                Button(key.on ? "停用" : "启用") {
                    Task { await store.providerKeys(key.on ? .off : .on, WebRequests.providerKeyRef(provider.id, ref: key.id)) }
                }
                .tint(.orange)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if can.canMakeFirst {
                Button("设为首选") {
                    Task { await store.providerKeys(.use, WebRequests.providerKeyRef(provider.id, ref: key.id)) }
                }
                .tint(.blue)
            }
        }
    }

    /// 圆点 / 明文，最右边是眼睛按钮（与网页端的「显示 / 隐藏」相同）。
    private func secretLine(_ key: WebProviderKey) -> some View {
        let plain = revealed[key.id]
        return HStack(spacing: 8) {
            Group {
                if let plain {
                    Text(plain)
                        .textSelection(.enabled)
                        .privacySensitive()
                } else {
                    Text(String(repeating: "•", count: 16))
                        .accessibilityLabel("已隐藏的 Key")
                }
            }
            .font(.callout.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(plain == nil ? 1 : 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("provider.key.value.\(key.id)")

            if loading.contains(key.id) {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    toggle(key)
                } label: {
                    Image(systemName: plain == nil ? "eye" : "eye.slash")
                        .imageScale(.medium)
                        .frame(width: 32, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(plain == nil ? "显示 Key" : "隐藏 Key")
                .accessibilityIdentifier("provider.key.reveal.\(key.id)")
            }
        }
    }

    @ViewBuilder
    private func actions(_ key: WebProviderKey, can: ProviderKeyPermissions) -> some View {
        Button {
            copy(key)
        } label: {
            Label(copiedID == key.id ? "已复制" : "复制 Key", systemImage: "doc.on.doc")
        }
        Button {
            ui.newName = key.name
            ui.renaming = key
        } label: {
            Label("重命名", systemImage: "pencil")
        }
        Button {
            ui.replacing = key
        } label: {
            Label("更换 Key 的值", systemImage: "arrow.triangle.2.circlepath")
        }
        if can.canMakeFirst {
            Button {
                Task { await store.providerKeys(.use, WebRequests.providerKeyRef(provider.id, ref: key.id)) }
            } label: {
                Label("设为首选", systemImage: "arrow.up.to.line")
            }
        }
        if can.canSwitch {
            Button {
                Task { await store.providerKeys(key.on ? .off : .on, WebRequests.providerKeyRef(provider.id, ref: key.id)) }
            } label: {
                Label(key.on ? "停用这把 Key" : "启用这把 Key", systemImage: key.on ? "pause.circle" : "play.circle")
            }
        }
        if can.canRemove {
            Button(role: .destructive) {
                ui.pendingRemove = key
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func toggle(_ key: WebProviderKey) {
        if revealed[key.id] != nil {
            ui.revealed[key.id] = nil
            return
        }
        loading.insert(key.id)
        Task {
            let secret = await store.providerKeySecret(provider.id, key: key.id)
            loading.remove(key.id)
            if let secret, !secret.isEmpty, scenePhase == .active { ui.revealed[key.id] = secret }
        }
    }

    private func copy(_ key: WebProviderKey) {
        Task {
            let secret: String?
            if let shown = revealed[key.id] { secret = shown } else { secret = await store.providerKeySecret(provider.id, key: key.id) }
            guard let secret, !secret.isEmpty else { return }
            // 只留在这台设备上，5 分钟后自动从剪贴板清除
            UIPasteboard.general.setItems([[UTType.plainText.identifier: secret]],
                                          options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)])
            copiedID = key.id
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func restText(_ key: WebProviderKey) -> String {
        let why: String
        switch key.restWhy ?? "" {
        case "rate": why = "被限流"
        case "credit": why = "余额不足"
        case "quota": why = "额度用完"
        case "auth": why = "需要重新登录"
        case "verify": why = "需要验证"
        case "refused": why = "被安全过滤拒绝"
        case "proxy": why = "代理连不上"
        case "slow": why = "启动太慢"
        default: why = "失败"
        }
        guard let until = key.restUntil else { return "暂停 · \(why)" }
        return "暂停 · \(why) · \(until.formatted(date: .omitted, time: .shortened)) 恢复"
    }

    private func protocolName(_ value: String) -> String {
        switch value {
        case "openai", "chat": return "OpenAI"
        case "responses": return "Responses"
        case "anthropic": return "Anthropic"
        case "gemini": return "Gemini"
        default: return value
        }
    }
}

/// 「API Key」区的明文与弹窗状态，由供应商详情页持有（见 `ProviderKeysSection` 的说明）。
@MainActor
@Observable
final class ProviderKeysUI {
    /// 已显示明文的 Key（Key 的 id → 明文）。
    var revealed: [String: String] = [:]
    var adding = false
    var renaming: WebProviderKey?
    var newName = ""
    var replacing: WebProviderKey?
    var pendingRemove: WebProviderKey?
}

extension View {
    /// 「API Key」区的弹窗（添加、更换值、重命名、删除确认）和明文的清除：挂在整个供应商表单上，只挂一份。
    func providerKeyPresentations(_ ui: ProviderKeysUI, store: ManageStore, provider: WebProvider) -> some View {
        modifier(ProviderKeyPresentations(ui: ui, store: store, provider: provider))
    }
}

private struct ProviderKeyPresentations: ViewModifier {
    @Bindable var ui: ProviderKeysUI
    let store: ManageStore
    let provider: WebProvider
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { ui.revealed = [:] }
            }
            .onChange(of: provider.keyList.map(\.id)) { _, ids in
                // 删掉或换了值的 Key：丢掉已显示的明文
                ui.revealed = ui.revealed.filter { ids.contains($0.key) }
            }
            .onDisappear { ui.revealed = [:] }
            .sheet(isPresented: $ui.adding) { AddProviderKeySheet(store: store, provider: provider) }
            .sheet(item: $ui.replacing) { key in ReplaceProviderKeySheet(store: store, provider: provider, key: key) }
            .alert("重命名 Key", isPresented: present($ui.renaming), presenting: ui.renaming) { key in
                TextField("名称，例如 个人 或 团队", text: $ui.newName)
                    .accessibilityIdentifier("provider.key.rename.field")
                Button("取消", role: .cancel) {}
                Button("保存") {
                    let name = ui.newName
                    Task { await store.providerKeys(.rename, WebRequests.providerKeyRename(provider.id, ref: key.id, name: name)) }
                }
            } message: { _ in
                Text("名字只用来区分几把 Key；留空就显示脱敏的 Key。")
            }
            .confirmationDialog("删除 Key「\(ui.pendingRemove?.label ?? "")」？", isPresented: present($ui.pendingRemove),
                                titleVisibility: .visible, presenting: ui.pendingRemove) { key in
                Button("删除 Key", role: .destructive) {
                    Task { await store.providerKeys(.remove, WebRequests.providerKeyRef(provider.id, ref: key.id)) }
                }
                .accessibilityIdentifier("provider.key.remove.confirm")
            } message: { _ in
                Text("这把 Key 会从 Mac 上的 magpie 里删除，无法恢复。")
            }
    }
}

/// 添加 Key：一把（可带名字），或一次粘贴多把（换行、逗号、空格分隔，已有的跳过）。与网页端「Add another key / Paste several」相同。
struct AddProviderKeySheet: View {
    let store: ManageStore
    let provider: WebProvider
    @Environment(\.dismiss) private var dismiss
    @State private var bulk = false
    @State private var name = ""
    @State private var key = ""
    @State private var keys = ""
    @State private var showKey = false
    @State private var result: String?

    private var count: Int { WebRequests.splitKeys(bulk ? keys : key).count }
    private var valid: Bool { count > 0 || (!bulk && provider.anonKey != nil) }

    var body: some View {
        NavigationStack {
            Form {
                Picker("方式", selection: $bulk) {
                    Text("添加一把").tag(false)
                    Text("粘贴多把").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("provider.key.new.mode")

                if bulk {
                    Section {
                        TextEditor(text: $keys)
                            .font(.callout.monospaced())
                            .frame(minHeight: 140)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("provider.key.new.bulk")
                    } header: {
                        Text(count > 0 ? "\(count) 把 Key" : "Key")
                    } footer: {
                        Text("一行一把，或用逗号、空格隔开。供应商已经有的会跳过。")
                    }
                } else {
                    Section {
                        TextField("名称（可选），例如 团队", text: $name)
                            .accessibilityIdentifier("provider.key.new.name")
                        HStack {
                            Group {
                                if showKey {
                                    TextField(keyPrompt, text: $key)
                                } else {
                                    SecureField(keyPrompt, text: $key)
                                }
                            }
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("provider.key.new.value")
                            Button {
                                showKey.toggle()
                            } label: {
                                Image(systemName: showKey ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(showKey ? "隐藏 Key" : "显示 Key")
                        }
                    } footer: {
                        Text(count > 1
                             ? "粘贴了 \(count) 把 Key，会一起添加（名字不会用上）。"
                             : "新的 Key 排在后面：前面的额度用完或被限流时由它接上。Key 直接发给 Mac 上的 magpie 保存，不会留在这台 iPhone 上。")
                    }
                }
            }
            .navigationTitle("添加 Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if store.busy {
                        ProgressView()
                    } else {
                        Button("添加") { Task { await add() } }
                            .disabled(!valid)
                            .accessibilityIdentifier("provider.key.new.save")
                    }
                }
            }
            .alert("已添加", isPresented: present($result)) {
                Button("好") { dismiss() }
            } message: {
                Text(result ?? "")
            }
            .manageAlerts(store: store, id: "provider.key.add")
        }
    }

    private var keyPrompt: String {
        provider.anonKey.map { "粘贴 API Key，或留空使用 \($0)（只能用免费模型）" } ?? "粘贴 API Key"
    }

    private func add() async {
        if bulk || count > 1 {
            // 网页端：粘贴多把走 keys/import，主机负责拆分与去重
            guard let list = await store.providerKeys(.import, WebRequests.providerKeyImport(provider.id, keys: bulk ? keys : key)) else { return }
            key = ""; keys = ""
            result = list.keysHad > 0 ? "添加了 \(list.keysAdded) 把，\(list.keysHad) 把原来就有。" : "添加了 \(list.keysAdded) 把 Key。"
        } else {
            if await store.providerKeys(.add, WebRequests.providerKeyAdd(provider.id, name: name, key: key)) != nil {
                key = ""
                dismiss()
            }
        }
    }
}

/// 更换一把 Key 的值（在供应商那边轮换了）：名字、位置和设置不变（`keys/replace`）。
struct ReplaceProviderKeySheet: View {
    let store: ManageStore
    let provider: WebProvider
    let key: WebProviderKey
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("粘贴这把 Key 的新值", text: $value)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("provider.key.replace.value")
                } footer: {
                    Text("「\(key.label)」的名字、排序和设置保持不变，只换成新的值。")
                }
            }
            .navigationTitle("更换 Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            if await store.providerKeys(.replace, WebRequests.providerKeyReplace(provider.id, ref: key.id, key: value)) != nil {
                                value = ""
                                dismiss()
                            }
                        }
                    }
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.busy)
                    .accessibilityIdentifier("provider.key.replace.save")
                }
            }
            .manageAlerts(store: store, id: "provider.key.replace")
        }
    }
}
