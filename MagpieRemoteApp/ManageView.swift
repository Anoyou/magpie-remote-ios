import SwiftUI
import MagpieRemoteCore

/// 需要 Web 密钥的页面（供应商、路由、Agent、会话、网关密钥、插件、主机工具、网页功能）的外壳：
/// 还没有主机、没有 Web 密钥、第一次读取失败时显示原来的中文引导 / 错误，准备好后才显示页面本身。
/// 不管页面在底栏还是在「更多」里，都用 `MainTabs` 里同一个 `ManageStore`。
struct ManageGate<Content: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(ManageStore.self) private var store
    let title: String
    @ViewBuilder let content: (ManageStore) -> Content

    /// 从来没读成功过（例如密钥不对、连不上）：整页显示错误。读成功过之后的失败只在顶部提示，不打断当前页面。
    private var failure: MagpieError? {
        if case .failed(let error) = store.phase { return error }
        return nil
    }

    var body: some View {
        Group {
            if store.service != nil, failure == nil || store.settings != nil {
                content(store)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if let failure { ManageFailureBanner(error: failure, store: store) }
                    }
            } else {
                placeholder
                    .navigationTitle(title)
            }
        }
        .onAppear { Task { await store.configure(model: model) } }
    }

    @ViewBuilder private var placeholder: some View {
        switch store.phase {
        case .noHost where model.activeHost == nil:
            NoHostView()
        case .noWebKey:
            List {
                Section {
                    WebKeyGuide()
                } header: {
                    Text("需要 Web 密钥")
                }
            }
        case .failed(let error):
            // 密钥不对时用右上角「主机」按钮更新 Web 密钥。
            ErrorStateView(error: error) { Task { await store.refresh() } }
        case .noHost, .loading, .ready:
            // 刚启动、还没按当前主机配置好时也显示读取中，不闪一下「还没有添加主机」。
            ProgressView("正在读取 magpie 设置…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("manage.loading")
        }
    }
}

/// 读成功过之后再次读取失败：页面上方的一条提示，可重试。
private struct ManageFailureBanner: View {
    let error: MagpieError
    let store: ManageStore

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(error.title).font(.subheadline.weight(.semibold))
                Text(error.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            Button("重试") { Task { await store.refresh() } }
                .buttonStyle(.glass)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(.horizontal)
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("manage.error.banner")
    }
}

/// 「更多」顶部的 magpie 连接状态：没有 Web 密钥的引导、读取中、错误、版本 / 不兼容提示。
struct ManageStatusSection: View {
    @Environment(AppModel.self) private var model
    let store: ManageStore

    var body: some View {
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

/// 只能在 magpie 网页里完成的功能（账号登录、备份与同步、脱敏）。
struct MagpieWebSection: View {
    let store: ManageStore

    var body: some View {
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
