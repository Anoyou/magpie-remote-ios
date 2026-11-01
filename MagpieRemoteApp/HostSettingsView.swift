import SwiftUI
import MagpieRemoteCore

/// 「主机」设置（空状态的「添加主机」、「更新 Web 密钥」等处弹出）：添加 / 编辑 / 删除 / 切换主机。
struct HostSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HostListContent()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                            .accessibilityIdentifier("hosts.done")
                    }
                }
        }
    }
}

/// 主机列表本身：「更多 › 当前主机」推入的就是它（切换主机的唯一入口），也用在弹出的「主机」设置里。
struct HostListContent: View {
    @Environment(AppModel.self) private var model
    @State private var editing: HostEditorTarget?

    var body: some View {
        List {
            if model.hosts.hosts.isEmpty {
                Section {
                    Text("还没有添加主机。主机就是运行 magpie 的那台 Mac。")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(model.hosts.hosts) { host in
                        HostRow(host: host, isActive: host.id == model.activeHost?.id) {
                            model.activate(host.id)
                        } edit: {
                            editing = .existing(host)
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { model.hosts.hosts[$0].id }
                        for id in ids { model.delete(id) }
                    }
                } header: {
                    Text("我的主机")
                } footer: {
                    Text("点一下切换当前主机；左滑可删除，删除时会一并清除这台主机保存在本机钥匙串里的密钥。")
                }
            }

            Section {
                Button {
                    editing = .new
                } label: {
                    Label("添加主机", systemImage: "plus.circle.fill")
                }
                .accessibilityIdentifier("hosts.add")
                NavigationLink {
                    SetupGuideView(showsDone: false)
                } label: {
                    Label("配置引导", systemImage: "list.number")
                }
                .accessibilityIdentifier("guide.open")
            }
        }
        .navigationTitle("主机")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $editing) { target in
            HostEditorView(target: target)
        }
    }
}

enum HostEditorTarget: Hashable, Identifiable {
    case new
    case existing(HostProfile)

    var id: String {
        switch self {
        case .new: "new"
        case .existing(let host): host.id.uuidString
        }
    }
}

private struct HostRow: View {
    let host: HostProfile
    let isActive: Bool
    let select: () -> Void
    let edit: () -> Void

    var body: some View {
        HStack {
            Button(action: select) {
                HStack(spacing: 12) {
                    Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(host.name).foregroundStyle(.primary)
                        Text(host.hostLabel).font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: edit) {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("编辑 \(host.name)")
            .accessibilityIdentifier("hosts.edit")
        }
        .accessibilityIdentifier("hosts.row")
    }
}

/// 添加 / 编辑一台主机：地址、三种密钥（存 Keychain）、测试连接。
struct HostEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let original: HostProfile?
    @State private var name: String
    @State private var address: String
    @State private var webAddress: String
    @State private var keys: [HostSecretKind: String] = [:]
    @State private var testing = false
    @State private var testResult: Result<ConnectionReport, MagpieError>?
    @State private var saveError: String?
    @State private var confirmDelete = false

    init(target: HostEditorTarget) {
        switch target {
        case .new:
            original = nil
            _name = State(initialValue: "我的 Mac")
            _address = State(initialValue: "")
            _webAddress = State(initialValue: "")
        case .existing(let host):
            original = host
            _name = State(initialValue: host.name)
            _address = State(initialValue: host.gatewayURL.absoluteString)
            _webAddress = State(initialValue: host.webURL.absoluteString)
        }
    }

    /// 由表单生成主机；地址无效时为 nil。Web 地址留空则用网关地址的主机名 + 3430。
    private var draft: HostProfile? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let gateway = HostProfile.normalizedURL(address, defaultPort: HostProfile.defaultGatewayPort) else { return nil }
        let web: URL?
        if webAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var components = URLComponents(url: gateway, resolvingAgainstBaseURL: false)
            components?.port = HostProfile.defaultWebPort
            web = components?.url
        } else {
            web = HostProfile.normalizedURL(webAddress, defaultPort: HostProfile.defaultWebPort)
        }
        guard let web else { return nil }
        return HostProfile(id: original?.id ?? UUID(), name: trimmedName, gatewayURL: gateway, webURL: web)
    }

    var body: some View {
        Form {
            Section {
                TextField("名称", text: $name)
                    .accessibilityIdentifier("host.name")
                TextField("主机地址，如 100.64.0.1", text: $address)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("host.address")
                TextField("Web 地址（可不填，默认端口 3430）", text: $webAddress)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("host.webAddress")
            } header: {
                Text("主机")
            } footer: {
                Text("在家可以填 Mac 的局域网地址；在外面请先打开 Tailscale（或 WireGuard），填它分配的地址，例如 100.64.0.1 或 my-mac.tailnet.example。网关默认端口 3425。")
            }

            Section {
                ForEach(HostSecretKind.allCases, id: \.self) { kind in
                    SecureField(placeholder(kind), text: binding(kind))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("host.secret.\(kind.rawValue)")
                }
            } header: {
                Text("密钥")
            } footer: {
                Text("密钥只保存在这台 iPhone 的钥匙串里，不会上传到任何地方。网关密钥用于额度和对话；Web 密钥（主机上的 MAGPIE_WEB_KEY）用于用量和管理；签发密钥用于管理网关密钥，可以先不填。")
            }

            Section {
                Button {
                    Task { await runTest() }
                } label: {
                    HStack {
                        Text("测试连接")
                        if testing { Spacer(); ProgressView() }
                    }
                }
                .disabled(draft == nil || testing)
                .accessibilityIdentifier("host.test")
                if let testResult {
                    TestResultView(result: testResult)
                }
            }

            if let saveError {
                Section { Text(saveError).foregroundStyle(.red) }
            }

            if let original {
                Section {
                    Button("删除这台主机", role: .destructive) { confirmDelete = true }
                        .accessibilityIdentifier("host.delete")
                }
                .confirmationDialog("删除「\(original.name)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("删除主机和它的密钥", role: .destructive) {
                        model.delete(original.id)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(original == nil ? "添加主机" : "编辑主机")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .disabled(draft == nil)
                    .accessibilityIdentifier("host.save")
            }
        }
    }

    private func placeholder(_ kind: HostSecretKind) -> String {
        if let original, model.hasSecret(kind, host: original.id) { return "\(kind.title)（已保存，留空保持不变）" }
        return kind.title
    }

    private func binding(_ kind: HostSecretKind) -> Binding<String> {
        Binding(get: { keys[kind] ?? "" }, set: { keys[kind] = $0 })
    }

    private func runTest() async {
        guard let host = draft else { return }
        testing = true
        testResult = await model.testConnection(host, gatewayKey: keys[.gatewayKey]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        testing = false
    }

    private func save() {
        guard let host = draft else { return }
        var secrets: [HostSecretKind: String?] = [:]
        for (kind, value) in keys {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { secrets[kind] = trimmed }
        }
        do {
            try model.save(host, secrets: secrets)
            dismiss()
        } catch {
            saveError = "保存密钥失败：\(error.localizedDescription)"
        }
    }
}

private struct TestResultView: View {
    let result: Result<ConnectionReport, MagpieError>

    var body: some View {
        switch result {
        case .success(let report):
            VStack(alignment: .leading, spacing: 4) {
                Label("连接成功", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text(details(report)).font(.footnote).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("host.testResult")
        case .failure(let error):
            VStack(alignment: .leading, spacing: 4) {
                Label(error.title, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                Text(error.message).font(.footnote)
                if let hint = error.hint { Text(hint).font(.footnote).foregroundStyle(.secondary) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("host.testResult")
        }
    }

    private func details(_ report: ConnectionReport) -> String {
        var parts: [String] = []
        if let version = report.hostVersion { parts.append("magpie \(version)") }
        if let count = report.modelCount { parts.append("\(count) 个模型") }
        let ms = Int(report.latency.components.seconds * 1000 + report.latency.components.attoseconds / 1_000_000_000_000_000)
        parts.append("耗时 \(ms) 毫秒")
        return parts.joined(separator: " · ")
    }
}
