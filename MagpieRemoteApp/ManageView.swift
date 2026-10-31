import SwiftUI
import MagpieRemoteCore

/// 「管理」标签页：主机、供应商、模型、路由组、Agent、网关密钥，以及只能在网页里完成的功能。
/// 数据来自主机上的 magpie Web 管理接口（`magpie daemon web on --lan`，端口 3430），用 Web 密钥访问。
struct ManageView: View {
    @Environment(AppModel.self) private var model
    @State private var store = ManageStore()

    private var configurationID: String {
        guard let host = model.activeHost else { return "none" }
        return [host.id.uuidString, host.webURL.absoluteString, host.gatewayURL.absoluteString,
                "\(model.hasSecret(.webKey, host: host.id))", "\(model.hasSecret(.issuerKey, host: host.id))",
                "\(model.hosts.hosts.count)"].joined(separator: "|")
    }

    var body: some View {
        List {
            Section("主机") {
                Button {
                    model.sheet = .hosts
                } label: {
                    LabeledContent("当前主机", value: model.activeHost?.name ?? "未添加")
                }
                .accessibilityIdentifier("manage.hosts")
                Button("配置引导") { model.sheet = .guide }
                    .accessibilityIdentifier("manage.guide")
            }

            statusSection

            if store.service != nil {
                Section {
                    NavigationLink {
                        ManageProvidersView(store: store)
                    } label: {
                        row("供应商", symbol: "server.rack", detail: store.phase == .ready ? "\(store.providers.count) 个" : nil)
                    }
                    .accessibilityIdentifier("manage.providers")
                    NavigationLink {
                        ManageGroupsView(store: store)
                    } label: {
                        row("路由", symbol: "arrow.triangle.branch", detail: store.groups.map { "\($0.visible.count) 个路由组" })
                    }
                    .accessibilityIdentifier("manage.groups")
                    NavigationLink {
                        ManageAgentsView(store: store)
                    } label: {
                        row("Agent", symbol: "terminal", detail: store.phase == .ready ? "\(store.agents.count) 个" : nil)
                    }
                    .accessibilityIdentifier("manage.agents")
                    NavigationLink {
                        ManageKeysView(store: store)
                    } label: {
                        row("网关密钥", symbol: "key", detail: store.phase == .ready ? "\(store.keys.count) 把" : nil)
                    }
                    .accessibilityIdentifier("manage.keys")
                } header: {
                    Text("magpie")
                } footer: {
                    Text("模型的开关在各个供应商里。")
                }

                Section {
                    ForEach(MagpieWebPage.allCases) { page in
                        NavigationLink {
                            ManageWebPageView(store: store, page: page)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(page.title)
                                    Text(page.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: page.symbol)
                            }
                        }
                        .accessibilityIdentifier("manage.web.\(page.rawValue)")
                    }
                } header: {
                    Text("在网页中打开")
                } footer: {
                    Text("这些功能需要 magpie 的完整网页界面，会在 App 内打开主机上的管理网页；供应商的登录页会在系统浏览器里打开。")
                }
            }

            Section("App") {
                NavigationLink {
                    AboutView()
                } label: {
                    Label("关于", systemImage: "info.circle")
                }
                .accessibilityIdentifier("manage.about")
            }
        }
        .refreshable { await store.refresh() }
        .task(id: configurationID) { await store.configure(model: model) }
        .onAppear { Task { await store.configure(model: model) } }
        .manageAlerts(store: store, id: "root")
    }

    private func row(_ title: String, symbol: String, detail: String?) -> some View {
        LabeledContent {
            if let detail { Text(detail) }
        } label: {
            Label(title, systemImage: symbol)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch store.phase {
        case .noHost:
            Section { Text("添加主机后，可以在这里管理 magpie。").foregroundStyle(.secondary) }
        case .noWebKey:
            Section {
                WebKeyGuide()
            } header: {
                Text("需要 Web 密钥")
            }
        case .loading:
            Section {
                HStack { ProgressView(); Text("正在读取 magpie 设置…").foregroundStyle(.secondary) }
            }
        case .failed(let error):
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label(error.title, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(error.message).font(.footnote)
                    if let hint = error.hint { Text(hint).font(.footnote).foregroundStyle(.secondary) }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("manage.error")
                Button("重试") { Task { await store.refresh() } }
                    .accessibilityIdentifier("manage.retry")
                if error == .webKeyInvalid {
                    Button("更新 Web 密钥") { model.sheet = .hosts }
                }
            }
        case .ready:
            if let incompatible = store.incompatible {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("不兼容", systemImage: "exclamationmark.octagon.fill").foregroundStyle(.orange).font(.headline)
                        Text(incompatible.message).font(.footnote)
                        if let hint = incompatible.hint { Text(hint).font(.footnote).foregroundStyle(.secondary) }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("manage.incompatible")
                }
            } else if let version = store.settings?.version {
                Section {
                    LabeledContent("magpie 版本", value: version)
                    if model.isFixture {
                        Text("示例数据：修改只保存在这次运行里。").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// 没有 Web 密钥时的中文引导。
struct WebKeyGuide: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("管理供应商、路由组、Agent 和网关密钥要用 magpie 的网页管理接口，需要先在 Mac 上打开它，再把 Web 密钥填进 App。")
            VStack(alignment: .leading, spacing: 6) {
                Text("1. 在 Mac 的终端运行：")
                Text("magpie daemon web on --lan")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                Text("2. 终端会打印一个带 `?k=` 的链接，`k=` 后面那串就是 Web 密钥（服务会把它保存为 MAGPIE_WEB_KEY，之后不变）。想自己指定时，先设置环境变量 MAGPIE_WEB_KEY（至少 16 位，只含字母、数字和 - . _ ~）。")
                Text("3. 在 App 的「主机」设置里，为这台主机填写 Web 密钥；Web 地址默认用主机地址加端口 3430。")
            }
            .font(.footnote)
            Text("不在同一局域网时，请通过 Tailscale（或 WireGuard）访问，不要把 3430 端口开放到公网。")
                .font(.footnote).foregroundStyle(.secondary)
            Button("填写 Web 密钥") { model.sheet = .hosts }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("manage.webkey.open")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("manage.webkey.guide")
    }
}

extension View {
    /// 管理页通用的弹窗：操作失败、主机提示、只显示一次的密钥。
    /// 导航栈里可能同时有好几个管理页面，只由最上面的那个页面负责弹出（`id` 区分页面）。
    func manageAlerts(store: ManageStore, id: String) -> some View {
        modifier(ManageAlerts(store: store, id: id))
    }
}

private struct ManageAlerts: ViewModifier {
    let store: ManageStore
    let id: String

    private var active: Bool { store.presenters.last == id }

    func body(content: Content) -> some View {
        content
            .onAppear { store.presenters.removeAll { $0 == id }; store.presenters.append(id) }
            .onDisappear { store.presenters.removeAll { $0 == id } }
            .alert(store.actionError?.title ?? "", isPresented: Binding(get: { active && store.actionError != nil }, set: { if !$0 { store.actionError = nil } })) {
                Button("好") { store.actionError = nil }
            } message: {
                Text([store.actionError?.message, store.actionError?.hint].compactMap { $0 }.joined(separator: "\n"))
            }
            .alert("需要重启 Agent", isPresented: Binding(get: { active && store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
                Button("好") { store.notice = nil }
            } message: {
                Text("已切换。magpie 提示：\(store.notice ?? "")")
            }
            .sheet(item: Binding(get: { active ? store.revealed : nil }, set: { store.revealed = $0 })) { secret in
                SecretRevealView(secret: secret)
            }
    }
}
