import SwiftUI
import MagpieRemoteCore

/// 「更多 › 资源库」：官方网页 Library 页的原生版本。六个分页（指令、MCP 服务器、技能、Hooks、子代理、RTK），
/// 每一项只需添加一次，再为需要的 Agent 打开，magpie 按各 Agent 自己的格式写进它的文件。
/// 只在 Mac 上有意义的操作（在访达里打开资源库 / 备份文件夹、选项目文件夹、MCP 服务器的 OAuth 登录）不做，
/// 页面底部有「在网页中打开资源库」兜底。
struct LibraryPage: View {
    let manage: ManageStore

    var body: some View {
        if let service = LibraryServices.make(from: manage.service) {
            LibraryRoot(manage: manage, service: service)
                .id(manage.configurationKey)
        } else {
            ContentUnavailableView("资源库", systemImage: "books.vertical", description: Text("这台主机暂时不能读取资源库。"))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("library.unavailable")
                .pageHeader(AppPage.library.title, subtitle: AppPage.library.headerSubtitle)
        }
    }
}

private struct LibraryRoot: View {
    let manage: ManageStore
    @State private var store: LibraryStore
    @State private var presenter = LibraryPresenter()

    init(manage: ManageStore, service: any LibraryServing) {
        self.manage = manage
        _store = State(initialValue: LibraryStore(service: service))
    }

    var body: some View {
        @Bindable var presenter = presenter
        // ZStack 而不是 Group：Group 的修饰符会分给它里面的每个视图，换分支（读取中 → 列表）时弹窗的宿主也跟着换掉。
        ZStack {
            if store.turnedOff {
                PageTopStripStack { turnedOffView }
            } else {
                phaseContent
            }
        }
        .pageHeader(AppPage.library.title, subtitle: AppPage.library.headerSubtitle)
        .environment(store)
        .task {
            store.hidden = manage.settings?.agentsHidden ?? []
            await store.load()
        }
        .refreshable { await store.load() }
        .safeAreaInset(edge: .bottom) { LibraryStatusLine(store: store) }
        // 六个分页的弹窗都由这里（页面根）弹出，见 LibraryPresenter。
        .environment(presenter)
        .sheet(item: $presenter.sheet) { sheet in
            LibrarySheetContent(store: store, sheet: sheet)
                .environment(store)
        }
        .libraryConfirm($presenter.confirm)
        .libraryAlerts(store: store, id: "library")
    }

    private var turnedOffView: some View {
        ContentUnavailableView {
            Label("资源库已关闭", systemImage: "books.vertical")
        } description: {
            Text("magpie 的「插件 › 内置」里关掉了资源库。启用后，指令、MCP 服务器和技能只需添加一次，就能给每个 Agent。")
        } actions: {
            Button("启用资源库") { Task { await store.enable() } }
                .buttonStyle(.borderedProminent)
                .disabled(store.busy)
                .accessibilityIdentifier("library.enable")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.off")
    }

    @ViewBuilder private var phaseContent: some View {
        Group {
            switch store.phase {
            case .loading where store.page == nil:
                PageTopStripStack {
                    ProgressView("正在读取资源库…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("library.loading")
                }
            case .failed(let error) where store.page == nil:
                PageTopStripStack { ContentUnavailableView {
                    Label("读不到资源库", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.message)
                } actions: {
                    Button("重试") { Task { await store.load() } }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("library.retry")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("library.failed") }
            default:
                if let page = store.page {
                    LibraryContent(store: store, manage: manage, page: page)
                }
            }
        }
    }
}

private struct LibraryContent: View {
    @Bindable var store: LibraryStore
    let manage: ManageStore
    let page: LibrarySnapshot

    var body: some View {
        List {
            PageTopStripSection()
            Section {
                Picker("分页", selection: $store.tab) {
                    ForEach(LibraryTab.allCases) { tab in
                        Text(tab.shortTitle).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("library.tabs")
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            } footer: {
                Text(LibraryWords.intro(store.tab))
            }

            if page.agents.isEmpty {
                Section {
                    ContentUnavailableView("没有可写入的 Agent", systemImage: "person.2.slash",
                                           description: Text("安装 Claude Code、Codex、Gemini CLI、OpenCode 等之后，资源库就能给它们同一份指令、MCP 服务器和技能。"))
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("library.noAgents")
                }
            } else {
                LibraryProblemsSection(store: store, page: page)
                switch store.tab {
                case .instructions: LibraryInstructionsTab(store: store, page: page)
                case .mcp: LibraryServersTab(store: store, page: page)
                case .skills: LibrarySkillsTab(store: store, page: page)
                case .hooks: LibraryHooksTab(store: store, page: page)
                case .subagents: LibrarySubagentsTab(store: store, page: page)
                case .rtk: LibraryRTKTab(store: store)
                }
            }

            Section {
                NavigationLink {
                    ManageWebPageView(store: manage, page: .library)
                } label: {
                    Label("在网页中打开资源库", systemImage: "safari")
                }
                .accessibilityIdentifier("library.web")
            } footer: {
                Text("在访达里打开资源库 / 备份文件夹、给项目选文件夹、MCP 服务器的 OAuth 登录只在 Mac 上有意义，App 里不做；需要时在网页里操作。")
            }
        }
        .animation(.default, value: store.tab)
        // RTK 的状态每次打开这个分页都重新读（官方：装了新 Agent 之后要能看到）
        .onChange(of: store.tab) { _, tab in
            if tab == .rtk { Task { await store.loadRTK(force: true) } }
        }
    }
}

// MARK: 弹窗（页面根上的唯一宿主）

/// 资源库页面上「新建 / 添加 / 发现 / 编辑」的表单和确认弹窗，统一挂在页面根上。
///
/// 0.6.0 把它们挂在每个分页的某个 `Section` 上：`List` 里 `Section` 的修饰符会分给这一节的每一行（还有页脚），
/// 一个开关就有好几个弹窗宿主，而且这些行是懒加载的，滚出屏幕就被拆掉。真机上点「新建一套」「添加服务器」「添加技能」，
/// 表单弹出来马上又被另一个宿主收回去，开关却还停在「打开」，之后再点就没有反应（连带别的按钮也像失灵）。
/// 现在每个分页只设置 `sheet` / `confirm`，由页面根上唯一的宿主弹出；表单关掉时 `sheet` 自动回到 nil，下次一定能再打开。
@MainActor
@Observable
final class LibraryPresenter {
    var sheet: LibrarySheet?
    var confirm: LibraryConfirm?

    func show(_ next: LibrarySheet) { sheet = next }

    var confirmBinding: Binding<LibraryConfirm?> {
        Binding(get: { self.confirm }, set: { self.confirm = $0 })
    }
}

enum LibrarySheet: Identifiable {
    case newSet
    case server(LibraryServerDraft)
    case serverMarket
    case skillInstall
    case skillMarket
    case skillHow
    case hook(LibraryHookDraft)
    case subagent(LibrarySubagentDraft)

    var id: String {
        switch self {
        case .newSet: "newSet"
        case .server(let d): "server.\(d.id)"
        case .serverMarket: "serverMarket"
        case .skillInstall: "skillInstall"
        case .skillMarket: "skillMarket"
        case .skillHow: "skillHow"
        case .hook(let d): "hook.\(d.id)"
        case .subagent(let d): "subagent.\(d.id)"
        }
    }
}

private struct LibrarySheetContent: View {
    let store: LibraryStore
    let sheet: LibrarySheet

    var body: some View {
        switch sheet {
        case .newSet: LibraryNewSetSheet(store: store)
        case .server(let draft): LibraryServerEditor(store: store, draft: draft)
        case .serverMarket: LibraryServerMarket(store: store)
        case .skillInstall: LibrarySkillInstall(store: store)
        case .skillMarket: LibrarySkillMarket(store: store)
        case .skillHow: LibrarySkillHowSheet(store: store)
        case .hook(let draft): LibraryHookEditor(store: store, draft: draft)
        case .subagent(let draft): LibrarySubagentEditor(store: store, draft: draft)
        }
    }
}

// MARK: 顶部的问题

/// 「资源库有部分内容未能写入」（官方 problemsCard）：只列这一页的，别的分页只说几项，点一下过去。
private struct LibraryProblemsSection: View {
    let store: LibraryStore
    let page: LibrarySnapshot

    var body: some View {
        let here = page.problems(on: store.tab)
        let away = page.problemCounts(except: store.tab)
        if !here.isEmpty || !away.isEmpty {
            Section {
                ForEach(Array(here.enumerated()), id: \.offset) { _, p in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(page.name(of: p.agent)) · \(LibraryWords.problemWhat(p.what))").font(.subheadline.weight(.medium))
                        Text(p.error).font(.footnote).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                ForEach(away.indices, id: \.self) { i in
                    let tab = away[i].tab
                    Button("\(tab.title)：另有 \(away[i].count) 项") { store.tab = tab }
                }
                if !here.isEmpty {
                    Button {
                        Task { await store.run(.allSync, [:]) }
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.busy)
                    .accessibilityIdentifier("library.problems.retry")
                }
            } header: {
                Text("资源库有部分内容未能写入")
            } footer: {
                if !here.isEmpty { Text("把资源库重新写入每个 Agent") }
            }
            .accessibilityIdentifier("library.problems")
        }
    }
}

// MARK: 状态栏、弹窗

struct LibraryStatusLine: View {
    let store: LibraryStore

    var body: some View {
        if let status = store.status {
            Text(status)
                .font(.footnote)
                .foregroundStyle(store.statusIsWarning ? Color.orange : Color.primary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
                .padding(.bottom, 6)
                .padding(.horizontal)
                .transition(.opacity)
                .accessibilityIdentifier("library.status")
                .task(id: status) {
                    do { try await Task.sleep(for: .seconds(store.statusIsWarning ? 8 : 4)) } catch { return }
                    if store.status == status { withAnimation { store.status = nil } }
                }
        }
    }
}

extension View {
    /// 操作失败的弹窗：导航栈和弹窗里可能同时有好几个资源库页面，只由最上面的那个弹出。
    func libraryAlerts(store: LibraryStore, id: String) -> some View {
        modifier(LibraryAlerts(store: store, id: id))
    }
}

private struct LibraryAlerts: ViewModifier {
    let store: LibraryStore
    let id: String

    func body(content: Content) -> some View {
        content
            .onAppear { store.presenters.removeAll { $0 == id }; store.presenters.append(id) }
            .onDisappear { store.presenters.removeAll { $0 == id } }
            .alert("操作失败", isPresented: Binding(get: { store.presenters.last == id && store.failure != nil }, set: { if !$0 { store.failure = nil } })) {
                Button("好") { store.failure = nil }
            } message: {
                Text(store.failure ?? "")
            }
    }
}

// MARK: Agent 图标

/// 一行的 Agent（官方 agentChips）：每个能拿到这一项的 Agent 一个，亮着的就是有它。
/// 点一下给它 / 拿走；灰的点一下说为什么；「全部」给每个能拿的 Agent，全都有时全部拿走。
struct LibraryChips: View {
    let agents: [LibraryAgent]
    let on: [String]
    var blocked: (LibraryAgent) -> String? = { _ in nil }
    var always: (LibraryAgent) -> String? = { _ in nil }
    var problems: [String: String] = [:]
    var showAll = true
    var disabled = false
    let id: String
    let onChange: (_ next: [String], _ all: Bool) -> Void
    var onBlocked: (String) -> Void = { _ in }

    private func isBlocked(_ a: LibraryAgent) -> String? {
        if let reason = always(a) { return reason }
        if a.unseen { return LibraryWords.chipHint(agent: a, has: false) }
        return blocked(a)
    }

    private func has(_ a: LibraryAgent) -> Bool { on.contains(a.id) || always(a) != nil }

    /// 点一下不动的：没显示的 Agent，以及不管勾没勾都有它的、看不见勾选的。
    private var kept: [String] {
        on.filter { id in
            guard let a = agents.first(where: { $0.id == id }) else { return true }
            return always(a) != nil || a.unseen
        }
    }

    private var lit: [String] {
        agents.filter { on.contains($0.id) && always($0) == nil && !$0.unseen }.map(\.id)
    }

    private var takers: [String] { agents.filter { isBlocked($0) == nil && !$0.gone }.map(\.id) }

    var body: some View {
        TagFlow(spacing: 6) {
            if showAll && takers.count >= 2 {
                let full = takers.allSatisfy(lit.contains)
                Button {
                    onChange(full ? kept : Array(Set(kept + lit + takers)).sorted(), true)
                } label: {
                    Text("全部").font(.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 5)
                }
                .buttonStyle(LibraryChipStyle(on: full, dim: false))
                .disabled(disabled)
                .accessibilityLabel(full ? "全部已启用" : "全部启用")
                .accessibilityAddTraits(full ? .isSelected : [])
                .accessibilityIdentifier("\(id).all")
            }
            ForEach(agents) { agent in
                let reason = isBlocked(agent)
                let lit = has(agent)
                Button {
                    if let reason { onBlocked(reason); return }
                    let now = self.lit
                    onChange(kept + (now.contains(agent.id) ? now.filter { $0 != agent.id } : now + [agent.id]), false)
                } label: {
                    HStack(spacing: 4) {
                        BrandIcon(agent.icon.isEmpty ? OfficialIcon.agent(agent.id) : agent.icon, size: 15)
                        Text(agent.name).font(.caption).lineLimit(1)
                            .strikethrough(agent.gone)
                        if problems[agent.id] != nil {
                            Circle().fill(.orange).frame(width: 6, height: 6)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                }
                .buttonStyle(LibraryChipStyle(on: lit, dim: reason != nil && always(agent) == nil))
                .disabled(disabled)
                .accessibilityLabel(agent.name)
                .accessibilityValue(lit ? "已启用" : "未启用")
                .accessibilityHint(problems[agent.id].map { "\(agent.name)：\($0)" } ?? reason ?? LibraryWords.chipHint(agent: agent, has: lit))
                .accessibilityAddTraits(lit ? .isSelected : [])
                .accessibilityIdentifier("\(id).\(agent.id)")
            }
        }
    }
}

private struct LibraryChipStyle: ButtonStyle {
    let on: Bool
    let dim: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(on ? Color.accentColor : Color.secondary)
            .background(Capsule().fill(on ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.1)))
            .overlay(Capsule().strokeBorder(on ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1))
            .opacity(dim ? 0.45 : (configuration.isPressed ? 0.6 : 1))
            .contentShape(Capsule())
    }
}

// MARK: 小部件

/// 名字旁边的小标签（官方 tag）。
struct LibraryTag: View {
    let text: String
    var warn = false

    init(_ text: String, warn: Bool = false) {
        self.text = text
        self.warn = warn
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(warn ? Color.orange : Color.secondary)
            .background(Capsule().fill((warn ? Color.orange : Color.secondary).opacity(0.14)))
    }
}

/// 一段说明小字（官方 lib-aside）。
struct LibraryAside: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.footnote).foregroundStyle(.secondary)
    }
}

/// 确认弹窗要的内容：标题、说明、按钮名和要做的事。
struct LibraryConfirm: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var button: String
    var destructive = true
    var run: @MainActor () async -> Void
}

extension View {
    /// 破坏性操作前先确认（confirmationDialog，按钮名照官方）。
    func libraryConfirm(_ item: Binding<LibraryConfirm?>) -> some View {
        confirmationDialog(item.wrappedValue?.title ?? "", isPresented: present(item), titleVisibility: .visible, presenting: item.wrappedValue) { c in
            Button(c.button, role: c.destructive ? .destructive : nil) { Task { await c.run() } }
                .accessibilityIdentifier("library.confirm")
            Button("取消", role: .cancel) {}
        } message: { c in
            Text(c.message)
        }
    }
}

/// 键值对编辑（环境变量、请求头；官方 pairs）。
struct LibraryPairsEditor: View {
    @Binding var pairs: [(key: String, value: String)]
    let keyHint: String
    let valueHint: String
    let id: String

    var body: some View {
        ForEach(pairs.indices, id: \.self) { i in
            HStack {
                TextField(keyHint, text: Binding(get: { pairs.indices.contains(i) ? pairs[i].key : "" }, set: { if pairs.indices.contains(i) { pairs[i].key = $0 } }))
                    .font(.footnote.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(valueHint, text: Binding(get: { pairs.indices.contains(i) ? pairs[i].value : "" }, set: { if pairs.indices.contains(i) { pairs[i].value = $0 } }))
                    .font(.footnote.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    pairs.remove(at: i)
                } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("移除")
            }
        }
        Button("＋ 添加") { pairs.append(("", "")) }
            .accessibilityIdentifier("\(id).add")
    }
}
