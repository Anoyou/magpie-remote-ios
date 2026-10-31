import SwiftUI
import UIKit
import UniformTypeIdentifiers
import MagpieRemoteCore

/// 网关密钥：Agent 和这台 iPhone 调用网关时用的密钥。创建 / 轮换 / 停用 / 删除，以及用签发密钥签发临时密钥。
struct ManageKeysView: View {
    let store: ManageStore
    @State private var creating = false
    @State private var issuing = false
    @State private var pendingRemove: WebCallerKey?
    @State private var pendingRotate: WebCallerKey?
    @State private var pendingRevoke: IssuedKey?

    var body: some View {
        List {
            Section {
                if store.keys.isEmpty {
                    Text(store.phase == .ready ? "还没有网关密钥。" : "正在读取…").foregroundStyle(.secondary)
                }
                ForEach(store.keys) { key in
                    KeyRow(key: key)
                        .contextMenu { menu(for: key) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("删除", role: .destructive) { pendingRemove = key }
                            Button(key.off ? "启用" : "停用") {
                                Task { await store.callerKey(key.off ? .on : .off, WebRequests.callerKey(key.id)) }
                            }
                            .tint(.orange)
                        }
                        .overlay(alignment: .trailing) {
                            Menu { menu(for: key) } label: {
                                Image(systemName: "ellipsis.circle").padding(.leading, 12)
                            }
                            .accessibilityLabel("\(key.name) 的操作")
                            .accessibilityIdentifier("key.menu.\(key.name)")
                        }
                }
            } header: {
                Text("网关密钥")
            } footer: {
                Text("每个 Agent 或设备用一把自己的密钥，丢了或泄露时只需轮换或删除那一把。名为 Magpie 的是「在局域网共享」自带的密钥。")
            }

            if store.canIssue {
                Section {
                    ForEach(store.issued) { key in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key.name)
                            Text([key.key, key.expired ? "已过期" : key.expires.map { "到期：\($0)" }].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button("吊销", role: .destructive) { pendingRevoke = key }
                        }
                    }
                    Button {
                        issuing = true
                    } label: {
                        Label("签发临时密钥", systemImage: "clock.badge.checkmark")
                    }
                    .accessibilityIdentifier("key.issue")
                } header: {
                    Text("临时密钥")
                } footer: {
                    Text("用「主机」设置里的签发密钥签发，到期自动失效，适合临时借给别的设备用。")
                }
            }
        }
        .navigationTitle("网关密钥")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { creating = true } label: { Label("新建密钥", systemImage: "plus") }
                    .accessibilityIdentifier("key.add")
            }
        }
        .refreshable { await store.refresh() }
        .sheet(isPresented: $creating) { NewKeySheet(store: store) }
        .sheet(isPresented: $issuing) { IssueKeySheet(store: store) }
        .confirmationDialog("删除密钥「\(pendingRemove?.name ?? "")」？", isPresented: present($pendingRemove), titleVisibility: .visible, presenting: pendingRemove) { key in
            Button("删除密钥", role: .destructive) {
                Task { await store.callerKey(.remove, WebRequests.callerKey(key.id)) }
            }
            .accessibilityIdentifier("key.remove.confirm")
        } message: { _ in
            Text("删除后，正在用这把密钥的 Agent 或设备会立即无法调用网关。")
        }
        .confirmationDialog("轮换密钥「\(pendingRotate?.name ?? "")」？", isPresented: present($pendingRotate), titleVisibility: .visible, presenting: pendingRotate) { key in
            Button("轮换", role: .destructive) {
                Task { await store.callerKey(.rotate, WebRequests.callerKey(key.id), title: "「\(key.name)」的新密钥") }
            }
        } message: { _ in
            Text("会生成一个新的密钥值，旧值立即失效。")
        }
        .confirmationDialog("吊销临时密钥「\(pendingRevoke?.name ?? "")」？", isPresented: present($pendingRevoke), titleVisibility: .visible, presenting: pendingRevoke) { key in
            Button("吊销", role: .destructive) { Task { await store.revokeIssued(key.id) } }
        }
        .manageAlerts(store: store, id: "keys")
    }

    @ViewBuilder
    private func menu(for key: WebCallerKey) -> some View {
        Button { Task { await store.callerKey(.copy, WebRequests.callerKey(key.id), title: "「\(key.name)」") } } label: {
            Label("显示密钥", systemImage: "eye")
        }
        Button { pendingRotate = key } label: { Label("轮换", systemImage: "arrow.triangle.2.circlepath") }
        Button { Task { await store.callerKey(key.off ? .on : .off, WebRequests.callerKey(key.id)) } } label: {
            Label(key.off ? "启用" : "停用", systemImage: key.off ? "checkmark.circle" : "pause.circle")
        }
        Button(role: .destructive) { pendingRemove = key } label: { Label("删除", systemImage: "trash") }
    }
}

/// 可选值绑定成「是否显示」。
func present<T>(_ binding: Binding<T?>) -> Binding<Bool> {
    Binding(get: { binding.wrappedValue != nil }, set: { if !$0 { binding.wrappedValue = nil } })
}

private struct KeyRow: View {
    let key: WebCallerKey

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(key.name).foregroundStyle(key.off ? .secondary : .primary)
                if key.off { badge("已停用", .secondary) }
                if key.readOnly { badge("只读", .blue) }
                if key.lan { badge("共享", .green) }
                if key.issues { badge("可签发", .purple) }
            }
            Text(key.masked).font(.caption.monospaced()).foregroundStyle(.secondary)
            if let limit = key.limitSummary {
                Text(limit).font(.caption).foregroundStyle(.secondary)
            }
            if !key.models.isEmpty {
                Text("仅限：" + key.models.joined(separator: "、")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.trailing, 36)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("key.row")
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.12), in: .capsule)
    }
}

private struct NewKeySheet: View {
    let store: ManageStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = "iPhone"
    @State private var readOnly = false
    @State private var created: RevealedSecret?

    var body: some View {
        if let created {
            SecretRevealView(secret: created)
        } else {
            form
        }
    }

    private var form: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称，例如 iPhone 或 Codex", text: $name)
                        .accessibilityIdentifier("key.new.name")
                    Toggle("只读（只能看用量与额度，不能对话）", isOn: $readOnly)
                } footer: {
                    Text("创建后会显示一次完整的密钥，请立刻复制保存；之后只能看到脱敏后的值。")
                }
            }
            .navigationTitle("新建网关密钥")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        Task {
                            let result = await store.callerKey(.add, WebRequests.callerKeyAdd(name: name, readOnly: readOnly),
                                                               title: "「\(name)」", reveal: false)
                            if let secret = result.secret { created = secret } else if result.ok { dismiss() }
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name.count > 120 || store.busy)
                    .accessibilityIdentifier("key.new.create")
                }
            }
        }
    }
}

private struct IssueKeySheet: View {
    let store: ManageStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = "临时"
    @State private var ttl = "1h"
    @State private var created: RevealedSecret?

    var body: some View {
        if let created {
            SecretRevealView(secret: created)
        } else {
            form
        }
    }

    private var form: some View {
        NavigationStack {
            Form {
                TextField("名称", text: $name)
                Picker("有效期", selection: $ttl) {
                    Text("30 分钟").tag("30m")
                    Text("1 小时").tag("1h")
                    Text("1 天").tag("24h")
                    Text("7 天").tag("168h")
                }
            }
            .navigationTitle("签发临时密钥")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("签发") {
                        Task { created = await store.issueKey(name: name, ttl: ttl) }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || store.busy)
                }
            }
        }
    }
}

/// 只显示一次的明文密钥：复制、保存为当前主机的网关密钥。
struct SecretRevealView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let secret: RevealedSecret
    @State private var copied = false
    @State private var saved = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(secret.secret)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("key.secret.value")
                    Button {
                        UIPasteboard.general.setItems([[UTType.plainText.identifier: secret.secret]],
                                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)])
                        copied = true
                    } label: {
                        Label(copied ? "已复制（5 分钟后从剪贴板清除）" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityIdentifier("key.secret.copy")
                } header: {
                    Text(secret.title.isEmpty ? "密钥" : secret.title)
                } footer: {
                    Label("完整密钥只显示这一次。请现在复制并妥善保存，不要发到群聊或公开的地方。", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("key.secret.warning")
                }
                if !model.isFixture {
                    Section {
                        Button(saved ? "已保存到这台 iPhone" : "用作这台 iPhone 的网关密钥") {
                            do {
                                try model.useAsGatewayKey(secret.secret)
                                saved = true
                            } catch {
                                saved = false
                            }
                        }
                        .disabled(saved)
                    } footer: {
                        Text("保存到本机钥匙串，额度和对话页面会改用这把密钥。")
                    }
                }
            }
            .navigationTitle("新密钥")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("key.secret.done")
                }
            }
        }
        .interactiveDismissDisabled(!copied && !saved)
    }
}
