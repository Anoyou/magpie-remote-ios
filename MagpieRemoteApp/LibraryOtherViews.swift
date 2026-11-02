import SwiftUI
import MagpieRemoteCore

// 资源库 › 指令、Hooks、子代理、RTK（官方 renderInstructions / renderHooks / renderSubagents / renderRTK）。

// MARK: 指令

struct LibraryInstructionsTab: View {
    let store: LibraryStore
    let page: LibrarySnapshot
    @Environment(LibraryPresenter.self) private var presenter

    private var iv: LibraryInstructions { page.instructions }
    private var rows: [LibraryInstructionAgent] { iv.agents.filter { !store.hidden.contains($0.agent) || $0.on } }

    var body: some View {
        Group {
            Section {
                ForEach(iv.sets) { set in
                    HStack(spacing: 10) {
                        Button {
                            guard !set.active else { return }
                            Task { await store.run(.instructionsSave, LibraryRequests.activate(set.id), done: "Agent 现在读的是「\(set.title)」") }
                        } label: {
                            Image(systemName: set.active ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(set.active ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.borderless)
                        .disabled(store.busy)
                        .accessibilityLabel(set.active ? "下面开启的 Agent 读的是这一套" : "让 Agent 改用这一套")
                        .accessibilityIdentifier("library.set.\(set.id).use")
                        NavigationLink {
                            LibraryInstructionSetEditor(store: store, setID: set.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(set.title)
                                    if set.active { LibraryTag("使用中") }
                                    if !set.file.isEmpty { LibraryTag("你的文件") }
                                }
                                Text(set.firstLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .accessibilityIdentifier("library.set.\(set.id)")
                    }
                }
                Button("+ 新建一套") { presenter.show(.newSet) }
                    .disabled(store.busy)
                    .accessibilityIdentifier("library.sets.add")
            } header: {
                Text("共享指令")
            } footer: {
                Text("Markdown")
            }

            Section {
                if rows.isEmpty {
                    Text("你的 Agent 都没有 magpie 已知的用户级指令文件。").foregroundStyle(.secondary)
                }
                ForEach(rows) { a in
                    LibraryInstructionAgentRow(store: store, page: page, agent: a)
                }
            } header: {
                HStack {
                    Text("Agent")
                    if let inUse = iv.inUse {
                        Text("它们读「\(inUse.title)」" + (inUse.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? " · 空" : ""))
                            .textCase(nil).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("magpie 只写两行标记之间的部分 — 文件其余内容仍归你")
                    let skip = page.shownAgents(hidden: store.hidden).filter { $0.instructions.isEmpty && $0.asleep.isEmpty }
                    if !skip.isEmpty { Text("\(skip.map(\.name).joined(separator: "、")) 没有用户级指令文件。") }
                    ForEach(Array(Set(rows.map(\.asleep).filter { !$0.isEmpty })).sorted(), id: \.self) { distro in
                        Text("WSL \(distro) 未运行：其中的 Agent 显示的是 magpie 上次看到的内容，你的修改会在它下次运行时写入。")
                    }
                }
            }
        }
    }
}

private struct LibraryInstructionAgentRow: View {
    let store: LibraryStore
    let page: LibrarySnapshot
    let agent: LibraryInstructionAgent

    var body: some View {
        HStack(spacing: 10) {
            BrandIcon(agent.icon.isEmpty ? OfficialIcon.agent(agent.agent) : agent.icon, size: 22)
            NavigationLink {
                LibraryInstructionAgentDetail(store: store, agentID: agent.agent)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.name)
                    Text(page.tilde(agent.path)).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    HStack(spacing: 4) {
                        if store.hidden.contains(agent.agent) { LibraryTag("已隐藏") }
                        if agent.on && !agent.extra.isEmpty { LibraryTag("+ 专属") }
                        if agent.edited { LibraryTag("文件中已被修改", warn: true) }
                        if agent.own > 0 { LibraryTag(agent.own == 1 ? "1 行自有内容" : "\(agent.own) 行自有内容") }
                    }
                }
            }
            .accessibilityIdentifier("library.instr.\(agent.agent)")
            Toggle("", isOn: Binding(get: { agent.on }, set: { on in toggle(on) }))
                .labelsHidden()
                .disabled(store.busy || agent.unseen)
                .accessibilityLabel("\(agent.name) 读取共享指令")
                .accessibilityIdentifier("library.instr.\(agent.agent).on")
        }
    }

    private func toggle(_ on: Bool) {
        let iv = page.instructions
        let agents = iv.agents.filter { $0.agent == agent.agent ? on : $0.on }.map(\.agent)
        var done = "已从 \(agent.name) 的文件中移除"
        if on {
            if iv.shared.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && agent.extra.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let inUse = iv.inUse, iv.sets.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    done = "\(agent.name) 已开启，但它读的是「\(inUse.title)」，这一套是空的 — 请让 Agent 改用要读的那一套"
                } else {
                    done = "\(agent.name) 已开启 — 有共享指令后就会写入"
                }
            } else {
                done = "\(agent.name) 现在读取共享指令"
            }
        }
        if !agent.asleep.isEmpty { done = "WSL \(agent.asleep) 未运行：其中的 Agent 显示的是 magpie 上次看到的内容，你的修改会在它下次运行时写入。" }
        Task { await store.run(.instructionsSave, LibraryRequests.instructionAgents(agents), done: done) }
    }
}

/// 一套共享指令的全文（官方 setRow 打开后）。
private struct LibraryInstructionSetEditor: View {
    let store: LibraryStore
    let setID: String
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var name = ""
    @State private var loaded = false
    @State private var confirm: LibraryConfirm?

    private var set: LibraryInstructionSet? { store.page?.instructions.sets.first { $0.id == setID } }
    private var dirty: Bool { loaded && text != (set?.text ?? "") }

    var body: some View {
        Form {
            if let set {
                Section {
                    TextField("名称", text: $name)
                        .onSubmit { rename(set) }
                } header: {
                    Text("名称")
                }
                Section {
                    TextEditor(text: $text)
                        .font(.footnote.monospaced())
                        .frame(minHeight: 240)
                        .accessibilityIdentifier("library.setEditor.text")
                } header: {
                    Text("共享指令")
                } footer: {
                    Text(set.file.isEmpty ? "每个 Agent 都该知道的事 — 你喜欢的代码风格、使用的技术栈、跑测试的命令……"
                         : "保存在 \(store.page?.tilde(set.file) ?? set.file)，不在资料库里：在那里改的内容会同步给 Agent，点保存也写到那里")
                }
                Section {
                    if !set.active {
                        Button("让 Agent 改用这一套") {
                            Task {
                                let texts = dirty ? [set.id: text] : [:]
                                await store.run(.instructionsSave, LibraryRequests.activate(set.id, texts: texts), done: "Agent 现在读的是「\(set.title)」")
                            }
                        }
                        .disabled(store.busy)
                    }
                    if set.id != "default" {
                        Button(set.file.isEmpty ? "删除「\(set.title)」及其内容" : "删除「\(set.title)」— 文件保留", role: .destructive) {
                            confirm = LibraryConfirm(title: "删除「\(set.title)」？", message: set.file.isEmpty ? "这一套的内容会一起删除。" : "文件保留。", button: "移除") {
                                if await store.run(.instructionsSave, LibraryRequests.removeSet(set.id), done: "已移除 \(set.title)") { dismiss() }
                            }
                        }
                        .disabled(store.busy || set.active)
                        .accessibilityIdentifier("library.setEditor.remove")
                    }
                } footer: {
                    if set.active && set.id != "default" { Text("先让 Agent 改用别的一套，才能删除这一套") }
                }
            } else {
                Text("这一套已经不在了。").foregroundStyle(.secondary)
            }
        }
        .cardSpacing()
        .detailHeader(set?.title ?? "共享指令")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    Task { await store.run(.instructionsSave, LibraryRequests.saveTexts([setID: text], extra: [:])) }
                }
                .disabled(!dirty || store.busy)
                .accessibilityIdentifier("library.setEditor.save")
            }
        }
        .onAppear {
            guard !loaded, let set else { return }
            text = set.text
            name = set.title
            loaded = true
        }
        .libraryConfirm($confirm)
        .safeAreaInset(edge: .bottom) { LibraryStatusLine(store: store) }
        .libraryAlerts(store: store, id: "library.set")
    }

    private func rename(_ set: LibraryInstructionSet) {
        let v = name.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, v != set.title else { name = set.title; return }
        Task { await store.run(.instructionsSave, LibraryRequests.renameSet(id: set.id, name: v), done: "已改名为 \(v)") }
    }
}

struct LibraryNewSetSheet: View {
    let store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var inFile = false
    @State private var file = "~/.agents/AGENTS.md"
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名字，例如 公司规范", text: $name)
                        .accessibilityIdentifier("library.newSet.name")
                }
                Section {
                    Toggle("保存在一个文件里…", isOn: $inFile)
                    if inFile {
                        TextField("Markdown 文件的完整路径", text: $file)
                            .font(.footnote.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
            }
            .cardSpacing()
            .detailHeader("新建一套")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") { Task { await add() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || store.busy)
                        .accessibilityIdentifier("library.newSet.add")
                }
            }
        }
    }

    private func add() async {
        let n = name.trimmingCharacters(in: .whitespaces)
        let inUse = store.page?.instructions.sets.first(where: \.active)
        let said = inUse == nil || !(inUse?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            ? "已添加「\(n)」— 写好后再让 Agent 改用它" : "已添加「\(n)」— Agent 从现在起读这一套"
        let body = LibraryRequests.createSet(id: LibraryRequests.newSetID(), name: n, file: inFile ? file.trimmingCharacters(in: .whitespaces) : "")
        guard await store.run(.instructionsSave, body, done: said) else {
            error = store.failure
            store.failure = nil
            return
        }
        dismiss()
    }
}

/// 一个 Agent 的指令（官方 instructionsRow 打开后）：只给它的内容、把它自己的移入共享、重新写入。
private struct LibraryInstructionAgentDetail: View {
    let store: LibraryStore
    let agentID: String
    @State private var extra = ""
    @State private var loaded = false

    private var agent: LibraryInstructionAgent? { store.page?.instructions.agents.first { $0.agent == agentID } }

    var body: some View {
        Form {
            if let a = agent, let page = store.page {
                Section {
                    LabeledContent("文件", value: page.tilde(a.path))
                    if !a.override.isEmpty {
                        Text("只要 \(page.tilde(a.override)) 有内容，\(a.name) 就会读它而不是这个文件。").font(.footnote).foregroundStyle(.orange)
                    }
                    if ["opencode", "mimocode", "deveco"].contains(a.agent) {
                        LibraryAside("\(a.name) 在没有自己的 AGENTS.md 时会读取 Claude Code 的 CLAUDE.md。")
                    }
                    if a.agent == "agy" {
                        LibraryAside("Antigravity 除此文件外还会读取 Gemini CLI 的 ~/.gemini/GEMINI.md，两边都写的内容会读两遍。")
                    }
                    if a.profile {
                        LibraryAside("该文件是 \(a.name) 对你的个人资料：magpie 会把它的部分加在你的内容之后，你自己的内容保留在文件里。工作区中的 USER.md 会代替此文件被读取。")
                    }
                    if a.edited { LibraryAside("文件中 magpie 的部分已在别处修改；资源库内容变化前不会覆盖") }
                    if a.own > 0 { LibraryAside("文件中除 magpie 的部分外还有其他指令，均会保留，Agent 两者都读") }
                }
                Section {
                    TextEditor(text: $extra)
                        .font(.footnote.monospaced())
                        .frame(minHeight: 140)
                        .accessibilityIdentifier("library.instrAgent.extra")
                    Button("保存") {
                        Task { await store.run(.instructionsSave, LibraryRequests.saveTexts([:], extra: [a.agent: extra])) }
                    }
                    .disabled(!loaded || extra == a.extra || store.busy)
                    .accessibilityIdentifier("library.instrAgent.save")
                } header: {
                    Text("仅给 \(a.name)，接在共享内容之后")
                } footer: {
                    Text(a.on ? "只需告诉 \(a.name) 的内容" : "开启 \(a.name) 后它才会读到这些。")
                }
                if a.own > 0 && !a.profile {
                    Section {
                        Button("把它的内容移入共享指令") {
                            Task { await store.run(.instructionsImport, LibraryRequests.name(a.agent), done: "已移入共享指令 — \(a.name) 读到的内容与之前相同") }
                        }
                        .disabled(store.busy)
                    } footer: {
                        Text("从文件中取出这 \(a.own) 行加入共享指令，并开启 \(a.name) — 它读到的不变，其他 Agent 也能读到")
                    }
                }
                if a.edited {
                    Section {
                        Button("重新写入资源库的内容") {
                            Task { await store.run(.instructionsSave, LibraryRequests.rewrite(a.agent), done: "\(a.name) 的文件已恢复为资源库的内容") }
                        }
                        .disabled(store.busy)
                    } footer: {
                        Text("覆盖文件中 magpie 部分的改动；会先备份文件")
                    }
                }
            }
        }
        .cardSpacing()
        .detailHeader(agent?.name ?? "")
        .onAppear {
            guard !loaded, let a = agent else { return }
            extra = a.extra
            loaded = true
        }
        .safeAreaInset(edge: .bottom) { LibraryStatusLine(store: store) }
        .libraryAlerts(store: store, id: "library.instrAgent")
    }
}

// MARK: Hooks

struct LibraryHooksTab: View {
    let store: LibraryStore
    let page: LibrarySnapshot
    @Environment(LibraryPresenter.self) private var presenter
    /// 确认弹窗由页面根上的 LibraryPresenter 弹出（见 LibraryPresenter 的说明）。
    private var confirm: LibraryConfirm? {
        get { presenter.confirm }
        nonmutating set { presenter.confirm = newValue }
    }

    private var all: [LibraryAgent] { page.hookTargets(hidden: store.hidden) }
    private var newDraft: LibraryHookDraft {
        let blank = LibraryHook()
        return LibraryHookDraft(old: "", hook: LibraryHook(agents: all.filter { page.hookBlocked(blank, agent: $0) == nil }.map(\.id)))
    }

    var body: some View {
        Group {
            if page.hooks.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("资源库里还没有 Hook", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    } description: {
                        Text("添加一个，再选要运行它的 Agent。")
                    } actions: {
                        Button("＋ 添加 Hook") { presenter.show(.hook(newDraft)) }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("library.hooks.addEmpty")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("library.hooks.empty")
                }
            } else {
                Section {
                    ForEach(page.hooks.sorted { $0.name < $1.name }) { hook in
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                presenter.show(.hook(LibraryHookDraft(old: hook.name, hook: hook)))
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(hook.name).font(.body.monospaced()).foregroundStyle(.primary)
                                    if !hook.description.isEmpty { Text(hook.description).font(.caption).foregroundStyle(.primary) }
                                    Text(hook.line(agentName: page.name(of:))).font(.caption).foregroundStyle(.secondary)
                                    Text(hook.command).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("library.hook.\(hook.name)")
                            LibraryChips(agents: page.withGone(all, on: hook.agents, hidden: store.hidden),
                                         on: store.agents(.hooksAgents, hook.name, current: hook.agents),
                                         blocked: { page.hookBlocked(hook, agent: $0) }, problems: hook.problems,
                                         id: "library.hook.\(hook.name).agents",
                                         onChange: { next, every in store.setAgents(.hooksAgents, name: hook.name, to: next, allChip: every) },
                                         onBlocked: { store.say($0, warn: true) })
                        }
                        .padding(.vertical, 2)
                    }
                    Button("＋ 添加 Hook") { presenter.show(.hook(newDraft)) }
                        .disabled(store.busy)
                        .accessibilityIdentifier("library.hooks.add")
                    if page.hooks.count > 1 {
                        Button("全部删除", role: .destructive) {
                            let who = Set(page.hooks.flatMap(\.agents)).map(page.name(of:)).sorted()
                            let words = LibraryWords.removeEvery(.hooks, count: page.hooks.count, agents: who)
                            confirm = LibraryConfirm(title: words.title, message: words.message, button: "删除全部 \(page.hooks.count) 个") {
                                await store.run(.hooksRemoveAll, LibraryRequests.names(page.hooks.map(\.name)))
                            }
                        }
                        .disabled(store.busy)
                    }
                } header: {
                    Text("资源库中 · \(page.hooks.count)")
                }
            }
            Section {
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    let given: (String) -> Bool = { id in page.hooks.contains { $0.agents.contains(id) } }
                    ForEach(all.filter { page.hookAgent($0.id)?.off == true && given($0.id) }) { a in
                        Text("\(a.name) 在自己的设置里关闭了 Hook：在那里重新打开之前，它一个也不会运行。")
                    }
                    if given("codex") { Text("新加或改过的 Hook，Codex 要等你信任后才会运行：请在 Codex 的 /hooks 里审阅。") }
                    if page.hooks.contains(where: { $0.agents.contains("cursor") && $0.agents.contains("claude") }) {
                        Text("Cursor 也会运行 Claude Code 的 Hook：同时给两者启用的 Hook，在 Cursor 里会运行两次。")
                    }
                    let skip = all.filter { !(page.hookAgent($0.id)?.no ?? "").isEmpty }
                    if !skip.isEmpty { Text("magpie 还不能给 \(skip.map(\.name).joined(separator: "、")) 写入 Hook：它们的图标是灰的，点一下可看原因。") }
                }
            }
        }
    }
}

struct LibraryHookDraft: Identifiable {
    let id = UUID()
    var old: String
    var hook: LibraryHook
}

struct LibraryHookEditor: View {
    let store: LibraryStore
    @State var draft: LibraryHookDraft
    @Environment(\.dismiss) private var dismiss
    @State private var timeout = ""
    @State private var error: String?
    @State private var confirm: LibraryConfirm?

    init(store: LibraryStore, draft: LibraryHookDraft) {
        self.store = store
        _draft = State(initialValue: draft)
        _timeout = State(initialValue: draft.hook.timeout > 0 ? String(draft.hook.timeout) : "")
    }

    private var page: LibrarySnapshot? { store.page }
    private var all: [LibraryAgent] { page?.hookTargets(hidden: store.hidden) ?? [] }
    private var isNew: Bool { draft.old.isEmpty }

    /// 何时运行的选项：通用事件 + 各 Agent 自己的事件。
    private var events: [(id: String, title: String)] {
        var out = LibraryHook.events
        for a in all {
            guard let ha = page?.hookAgent(a.id), ha.no.isEmpty else { continue }
            for ev in ha.events { out.append((a.id + ":" + ev, a.name + " · " + ev)) }
        }
        return out
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例如 notify", text: $draft.hook.name)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("library.hookEditor.name")
                } header: { Text("名称") } footer: { Text("字母、数字、- 和 _") }

                Section {
                    TextField("例如：一轮结束时提醒我", text: $draft.hook.description, axis: .vertical)
                        .lineLimit(1...4)
                } header: { Text("描述") } footer: { Text("可选：用任何语言写下它的用途，只保存在资源库里") }

                Section {
                    Picker("何时运行", selection: Binding(get: { draft.hook.event }, set: { setEvent($0) })) {
                        ForEach(events.indices, id: \.self) { i in
                            Text(events[i].title).tag(events[i].id)
                        }
                    }
                    .accessibilityIdentifier("library.hookEditor.event")
                    if draft.hook.ownAgent != nil {
                        TextField("全部工具", text: $draft.hook.matcher)
                            .font(.footnote.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else if draft.hook.isToolEvent {
                        Picker("对哪些工具", selection: $draft.hook.matcher) {
                            ForEach(LibraryHook.tools.indices, id: \.self) { i in
                                Text(LibraryHook.tools[i].title).tag(LibraryHook.tools[i].id)
                            }
                        }
                    }
                } footer: {
                    if draft.hook.ownAgent != nil { Text("Agent 自己的匹配规则，照它的 Hook 文件里的写法；留空表示全部") }
                    else if draft.hook.isToolEvent { Text("按每个 Agent 自己对它们的叫法") }
                }

                Section {
                    TextField("curl -s https://api.day.app/KEY/done", text: $draft.hook.command, axis: .vertical)
                        .font(.footnote.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("library.hookEditor.command")
                    TextField("沿用 Agent 自己的", text: $timeout)
                        .keyboardType(.numberPad)
                } header: {
                    Text("命令")
                } footer: {
                    Text("由 Agent 的 shell 在会话的文件夹里运行；Agent 会把发生了什么以 JSON 传到它的标准输入。下面一行是超时（秒）。")
                }

                Section {
                    let hook = draft.hook
                    LibraryChips(agents: all, on: draft.hook.agents, blocked: { page?.hookBlocked(hook, agent: $0) }, id: "library.hookEditor.agents",
                                 onChange: { next, _ in draft.hook.agents = next }, onBlocked: { error = $0 })
                } header: { Text("Agent") }

                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }

                if !isNew {
                    Section {
                        Button("从资源库移除", role: .destructive) {
                            let who = draft.hook.agents.map { page?.name(of: $0) ?? $0 }
                            confirm = LibraryConfirm(title: "删除钩子 \(draft.old)？", message: LibraryWords.removeHookMessage(agents: who), button: "移除") {
                                if await store.run(.hooksRemove, LibraryRequests.name(draft.old), done: "\(draft.old) 已从资源库及相关 Agent 中移除") { dismiss() }
                            }
                        }
                        .accessibilityIdentifier("library.hookEditor.remove")
                    }
                }
            }
            .cardSpacing()
            .detailHeader(isNew ? "新 Hook" : draft.old)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "添加" : "保存") { Task { await save() } }
                        .disabled(store.busy)
                        .accessibilityIdentifier("library.hookEditor.save")
                }
            }
            .libraryConfirm($confirm)
        }
    }

    private func setEvent(_ event: String) {
        draft.hook.event = event
        if let own = draft.hook.ownAgent {
            draft.hook.agents = [own]
            draft.hook.matcher = ""
        } else if !draft.hook.isToolEvent || !LibraryHook.tools.contains(where: { $0.id == draft.hook.matcher }) {
            draft.hook.matcher = ""
        }
    }

    private func save() async {
        var hook = draft.hook
        hook.name = hook.name.trimmingCharacters(in: .whitespaces)
        guard LibraryShell.validName(hook.name) else { error = "名称只能用字母、数字、- 和 _"; return }
        guard !hook.command.trimmingCharacters(in: .whitespaces).isEmpty else { error = "请填写命令"; return }
        hook.timeout = Int(timeout.trimmingCharacters(in: .whitespaces)) ?? 0
        let checked = hook
        hook.agents = hook.agents.filter { id in all.first { $0.id == id }.map { page?.hookBlocked(checked, agent: $0) == nil } ?? true }
        guard await store.run(.hooksSave, LibraryRequests.saveHook(old: draft.old, hook), done: isNew ? nil : "已保存 \(hook.name)") else {
            error = store.failure
            store.failure = nil
            return
        }
        dismiss()
    }
}

// MARK: 子代理

struct LibrarySubagentsTab: View {
    let store: LibraryStore
    let page: LibrarySnapshot
    @Environment(LibraryPresenter.self) private var presenter

    private var all: [LibraryAgent] { page.subagentTargets(hidden: store.hidden) }
    private var newDraft: LibrarySubagentDraft {
        LibrarySubagentDraft(old: "", subagent: LibrarySubagent(agents: all.filter { page.subagentBlocked($0) == nil }.map(\.id)))
    }

    var body: some View {
        Group {
            if page.subagents.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("资源库里还没有子代理", systemImage: "person.2")
                    } description: {
                        Text("添加一个，并选择可以把任务交给它的 Agent。")
                    } actions: {
                        Button("＋ 添加子代理") { presenter.show(.subagent(newDraft)) }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("library.subagents.addEmpty")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("library.subagents.empty")
                }
            } else {
                Section {
                    ForEach(page.subagents.sorted { $0.name < $1.name }) { sub in
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                presenter.show(.subagent(LibrarySubagentDraft(old: sub.name, subagent: sub)))
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(sub.name).font(.body.monospaced()).foregroundStyle(.primary)
                                    Text(sub.description).font(.caption).foregroundStyle(.primary).lineLimit(3)
                                    if !sub.line.isEmpty { Text(sub.line).font(.caption).foregroundStyle(.secondary) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("library.subagent.\(sub.name)")
                            LibraryChips(agents: all, on: store.agents(.subagentsAgents, sub.name, current: sub.agents),
                                         blocked: { page.subagentBlocked($0) }, problems: sub.problems,
                                         id: "library.subagent.\(sub.name).agents",
                                         onChange: { next, every in store.setAgents(.subagentsAgents, name: sub.name, to: next, allChip: every) },
                                         onBlocked: { store.say($0, warn: true) })
                        }
                        .padding(.vertical, 2)
                    }
                    Button("＋ 添加子代理") { presenter.show(.subagent(newDraft)) }
                        .disabled(store.busy)
                        .accessibilityIdentifier("library.subagents.add")
                } header: {
                    Text("资源库中 · \(page.subagents.count)")
                }
            }
            Section {
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    let unbound: (KeyPath<LibrarySubagentAgent, Bool>, KeyPath<LibrarySubagent, [String]>) -> [String] = { can, uses in
                        let ids = Set(page.subagents.filter { !$0[keyPath: uses].isEmpty }.flatMap(\.agents))
                        return all.filter { ids.contains($0.id) && page.subagentBlocked($0) == nil && !(page.subagentAgent($0.id)?[keyPath: can] ?? false) }.map(\.name)
                    }
                    let noSkills = unbound(\.skills, \.skills)
                    let noMCP = unbound(\.mcp, \.mcp)
                    if !noSkills.isEmpty { Text("\(noSkills.joined(separator: "、")) 不能给子代理单独绑定技能：它们拿到的子代理只有提示词，可用该 Agent 的全部技能。") }
                    if !noMCP.isEmpty { Text("\(noMCP.joined(separator: "、")) 不能给子代理单独绑定 MCP 服务器：它们拿到的子代理只有提示词，可用该 Agent 的全部服务器。") }
                    if page.subagents.contains(where: { $0.agents.contains("cursor") }) {
                        Text("Cursor 应用会读取这些子代理；它的 cursor-agent 命令只读取项目自己的 .cursor/agents。")
                    }
                    let skip = all.filter { page.subagentBlocked($0) != nil }
                    if !skip.isEmpty { Text("magpie 还不能给 \(skip.map(\.name).joined(separator: "、")) 写入子代理：它们的图标是灰的，点一下可看原因。") }
                }
            }
        }
    }
}

struct LibrarySubagentDraft: Identifiable {
    let id = UUID()
    var old: String
    var subagent: LibrarySubagent
}

struct LibrarySubagentEditor: View {
    let store: LibraryStore
    @State var draft: LibrarySubagentDraft
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var confirm: LibraryConfirm?

    init(store: LibraryStore, draft: LibrarySubagentDraft) {
        self.store = store
        _draft = State(initialValue: draft)
    }

    private var page: LibrarySnapshot? { store.page }
    private var all: [LibraryAgent] { page?.subagentTargets(hidden: store.hidden) ?? [] }
    private var isNew: Bool { draft.old.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例如 code-reviewer", text: $draft.subagent.name)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("library.subagentEditor.name")
                } header: { Text("名称") } footer: { Text("小写字母、数字和 -；它也是每个 Agent 里的文件名") }

                Section {
                    TextField("例如：审阅 diff 里的 bug。改完代码后使用。", text: $draft.subagent.description, axis: .vertical)
                        .lineLimit(1...4)
                        .accessibilityIdentifier("library.subagentEditor.description")
                } header: { Text("描述") } footer: { Text("它做什么、何时使用：Agent 据此决定何时把任务交给它") }

                Section {
                    TextEditor(text: $draft.subagent.prompt)
                        .font(.footnote)
                        .frame(minHeight: 160)
                        .accessibilityIdentifier("library.subagentEditor.prompt")
                } header: { Text("提示词") } footer: { Text("子代理开始任务前收到的指示") }

                Section {
                    NavigationLink {
                        LibraryNamesPicker(title: "技能", names: page?.skills.map(\.name).sorted() ?? [], picked: $draft.subagent.skills, empty: "资源库里还没有技能")
                    } label: {
                        LabeledContent("技能", value: draft.subagent.skills.isEmpty ? "无" : draft.subagent.skills.joined(separator: ", "))
                    }
                    NavigationLink {
                        LibraryNamesPicker(title: "MCP 服务器", names: page?.servers.map(\.name).sorted() ?? [], picked: $draft.subagent.mcp, empty: "资源库里还没有 MCP 服务器")
                    } label: {
                        LabeledContent("MCP 服务器", value: draft.subagent.mcp.isEmpty ? "无" : draft.subagent.mcp.joined(separator: ", "))
                    }
                } footer: {
                    let ids = Set(draft.subagent.agents)
                    let noSkills = all.filter { ids.contains($0.id) && !(page?.subagentAgent($0.id)?.skills ?? false) }.map(\.name)
                    let noMCP = all.filter { ids.contains($0.id) && !(page?.subagentAgent($0.id)?.mcp ?? false) }.map(\.name)
                    VStack(alignment: .leading, spacing: 4) {
                        if !draft.subagent.skills.isEmpty && !noSkills.isEmpty { Text("\(noSkills.joined(separator: "、")) 不会绑定：其子代理可用该 Agent 的全部技能") }
                        if !draft.subagent.mcp.isEmpty && !noMCP.isEmpty { Text("\(noMCP.joined(separator: "、")) 不会绑定：其子代理可用该 Agent 的全部服务器") }
                    }
                }

                Section {
                    LibraryChips(agents: all, on: draft.subagent.agents, blocked: { page?.subagentBlocked($0) }, id: "library.subagentEditor.agents",
                                 onChange: { next, _ in draft.subagent.agents = next }, onBlocked: { error = $0 })
                } header: { Text("Agent") }

                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }

                if !isNew {
                    Section {
                        Button("从资源库移除", role: .destructive) {
                            let who = draft.subagent.agents.map { page?.name(of: $0) ?? $0 }
                            confirm = LibraryConfirm(title: "移除 \(draft.old)？", message: LibraryWords.removeOneMessage(agents: who), button: "移除") {
                                if await store.run(.subagentsRemove, LibraryRequests.name(draft.old), done: "\(draft.old) 已从资源库及相关 Agent 中移除") { dismiss() }
                            }
                        }
                        .accessibilityIdentifier("library.subagentEditor.remove")
                    }
                }
            }
            .cardSpacing()
            .detailHeader(isNew ? "新子代理" : draft.old)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "添加" : "保存") { Task { await save() } }
                        .disabled(store.busy)
                        .accessibilityIdentifier("library.subagentEditor.save")
                }
            }
            .libraryConfirm($confirm)
        }
    }

    private func save() async {
        var sub = draft.subagent
        sub.name = sub.name.trimmingCharacters(in: .whitespaces)
        sub.description = sub.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LibraryShell.validSubagentName(sub.name) else { error = "名称只能用小写字母、数字和 -"; return }
        guard !sub.description.isEmpty else { error = "请填写描述"; return }
        sub.agents = sub.agents.filter { id in all.first { $0.id == id }.map { page?.subagentBlocked($0) == nil } ?? true }
        guard await store.run(.subagentsSave, LibraryRequests.saveSubagent(old: draft.old, sub), done: isNew ? nil : "已保存 \(sub.name)") else {
            error = store.failure
            store.failure = nil
            return
        }
        dismiss()
    }
}

/// 勾选几个名字（子代理的技能 / MCP 服务器；官方 namesPick）。
private struct LibraryNamesPicker: View {
    let title: String
    let names: [String]
    @Binding var picked: [String]
    let empty: String

    var body: some View {
        List {
            if names.isEmpty { Text(empty).foregroundStyle(.secondary) }
            ForEach(names, id: \.self) { name in
                Button {
                    if picked.contains(name) { picked.removeAll { $0 == name } } else { picked.append(name) }
                } label: {
                    HStack {
                        Text(name).font(.body.monospaced()).foregroundStyle(.primary)
                        Spacer()
                        if picked.contains(name) { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                    }
                }
            }
            if !picked.isEmpty {
                Button("无") { picked = [] }
            }
        }
        .cardSpacing()
        .detailHeader(title)
    }
}

// MARK: RTK

struct LibraryRTKTab: View {
    let store: LibraryStore
    @Environment(LibraryPresenter.self) private var presenter
    /// 确认弹窗由页面根上的 LibraryPresenter 弹出（见 LibraryPresenter 的说明）。
    private var confirm: LibraryConfirm? {
        get { presenter.confirm }
        nonmutating set { presenter.confirm = newValue }
    }

    var body: some View {
        Group {
            if let rtk = store.rtk {
                card(rtk)
                agents(rtk)
            } else if let error = store.rtkError {
                Section {
                    Text(error).foregroundStyle(.red).font(.footnote)
                    Button("重新检测") { Task { await store.loadRTK(force: true) } }
                }
            } else {
                Section {
                    HStack { ProgressView(); Text("正在读取 RTK…").foregroundStyle(.secondary) }
                }
                .task { await store.loadRTK() }
            }
        }
    }

    private func card(_ rtk: LibraryRTK) -> some View {
        Section {
            if rtk.installed {
                LabeledContent("RTK", value: rtk.version.isEmpty ? (store.page?.tilde(rtk.path) ?? rtk.path) : "v" + rtk.version)
                if let note = rtk.versionNote { Text(note).font(.footnote).foregroundStyle(rtk.behind ? Color.accentColor : Color.secondary) }
                if rtk.behind {
                    if rtk.upgrade.isEmpty {
                        Text(rtk.noUpgrade.isEmpty ? "无法判断 RTK 的安装方式，请按原安装方式更新" : rtk.noUpgrade).font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Button(store.rtkStep == .upgrade ? "升级中…" : "升级") {
                            confirm = LibraryConfirm(title: "升级 RTK？", message: "将在 Mac 上运行 \(rtk.upgrade)，可能需要几分钟。", button: "升级", destructive: false) {
                                await store.rtk(.upgrade)
                            }
                        }
                        .disabled(store.rtkStep != nil)
                        .accessibilityIdentifier("library.rtk.upgrade")
                    }
                }
                if !rtk.waiting.isEmpty && !rtk.latest.isEmpty {
                    Text("RTK \(rtk.latest) 已发布，但 \(rtk.waiting) 目前只有 \(rtk.waitingHas.isEmpty ? rtk.version : rtk.waitingHas)，通常几天内会跟上。\(rtk.waiting) 有了新版后会重新显示“升级”。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if rtk.offPath {
                    Text("RTK 所在的文件夹不在 PATH 中。Agent 按名称调用 rtk，找不到它时 RTK 不起作用。").font(.footnote).foregroundStyle(.orange)
                    if !rtk.pathDir.isEmpty {
                        Button(store.rtkStep == .path ? "正在加到 PATH…" : "加到 PATH") { Task { await store.rtk(.path) } }
                            .disabled(store.rtkStep != nil)
                    }
                }
                Text(rtk.gainLine).font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("尚未安装 RTK。magpie 可以帮你安装，也可以去官网获取。").font(.footnote)
                if !rtk.install.isEmpty {
                    Text(rtk.install).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Button(store.rtkStep == .install ? "安装中…" : "安装 RTK") {
                        confirm = LibraryConfirm(title: "安装 RTK？", message: "将在 Mac 上运行 \(rtk.install)，可能需要一分钟。", button: "安装 RTK", destructive: false) {
                            await store.rtk(.install)
                        }
                    }
                    .disabled(store.rtkStep != nil)
                    .accessibilityIdentifier("library.rtk.install")
                }
                if let url = URL(string: rtk.url), !rtk.url.isEmpty { Link("获取 RTK", destination: url) }
            }
            Button("重新检测") { Task { await store.loadRTK(force: true) } }
                .disabled(store.rtkStep != nil)
                .accessibilityIdentifier("library.rtk.recheck")
        } header: {
            Text("RTK")
        } footer: {
            if rtk.installed && rtk.hasGain { Text("来自 RTK 自身的统计（rtk gain）：本机经过 RTK 的所有命令，不分 Agent 和终端。") }
        }
    }

    private func agents(_ rtk: LibraryRTK) -> some View {
        Section {
            if rtk.agents.isEmpty { Text("你的 Agent 中没有 RTK 支持的。").foregroundStyle(.secondary) }
            ForEach(rtk.agents) { agent in
                VStack(alignment: .leading, spacing: 3) {
                    Toggle(isOn: Binding(get: { agent.on }, set: { on in Task { await store.setRTK(agent, on: on) } })) {
                        HStack(spacing: 8) {
                            BrandIcon(agent.icon.isEmpty ? OfficialIcon.agent(agent.id) : agent.icon, size: 20)
                            Text(agent.name)
                            if let tag = rtk.tag(agent) { LibraryTag(tag, warn: tag != "未运行") }
                            if store.rtkBusy.contains(agent.id) { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(store.rtkBusy.contains(agent.id) || agent.noHook || agent.asleep || (!agent.blocked.isEmpty && !agent.on))
                    .accessibilityIdentifier("library.rtk.\(agent.id)")
                    if !agent.blocked.isEmpty { Text(agent.blocked).font(.caption).foregroundStyle(.secondary) }
                }
            }
        } header: {
            Text("Agent")
        } footer: {
            Text("切换后需重启对应 Agent")
        }
    }
}
