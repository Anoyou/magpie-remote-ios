import SwiftUI
import MagpieRemoteCore

// 资源库 › 技能（官方 renderSkills / skillRow / installCard / probeResult / foundSkillRow / renderNewSkills / skillHowBar）。

struct LibrarySkillsTab: View {
    let store: LibraryStore
    let page: LibrarySnapshot
    @State private var filter = ""
    @Environment(LibraryPresenter.self) private var presenter
    /// 确认弹窗由页面根上的 LibraryPresenter 弹出（见 LibraryPresenter 的说明）。
    private var confirm: LibraryConfirm? {
        get { presenter.confirm }
        nonmutating set { presenter.confirm = newValue }
    }

    private var all: [LibraryAgent] { page.skillAgents(hidden: store.hidden) }

    var body: some View {
        Group {
            Section {
                actions
            }

            if page.skills.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("资源库里还没有技能", systemImage: "doc.text")
                    } description: {
                        Text("owner/repo、GitHub 或 GitLab 链接、任意 git 仓库地址，或本机上的文件夹")
                    } actions: {
                        Button("查找技能") { presenter.show(.skillInstall) }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("library.skills.installEmpty")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("library.skills.empty")
                }
            } else {
                if page.skills.count > 8 {
                    Section {
                        TextField("筛选 \(page.skills.count) 个技能…", text: $filter)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("library.skills.filter")
                    }
                }
                let groups = page.skillGroups(filter: filter)
                ForEach(groups.indices, id: \.self) { i in
                    let group = groups[i]
                    Section {
                        ForEach(group.skills) { skill in
                            LibrarySkillRow(store: store, page: page, skill: skill, all: all)
                        }
                    } header: {
                        LibrarySkillGroupHeader(store: store, repo: group.repo, skills: group.skills, confirm: presenter.confirmBinding)
                    }
                }
            }

            if !page.newSkills.isEmpty { newSkillsSection }
            foundSkillsSection
            LibraryProjectsSection(page: page, kind: .skills)

            Section {
                Button {
                    presenter.show(.skillMarket)
                } label: {
                    Label("发现", systemImage: "magnifyingglass")
                }
                .accessibilityIdentifier("library.skills.discover")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("在 skills.sh 搜索技能 — react、pdf、testing…")
                    let skip = page.shownAgents(hidden: store.hidden).filter { $0.skills.isEmpty }
                    if !skip.isEmpty { Text("\(skip.map(\.name).joined(separator: "、")) 没有技能文件夹。") }
                    if all.contains(where: { $0.id == "claude-desktop" }) {
                        Text("Claude Desktop 刷新窗口（⌘R）后才显示技能变化。它使用技能的副本，在 Desktop 中改过的副本不会被覆盖。")
                    }
                }
            }
        }
    }

    /// 页面上方的一排操作（官方 renderSkills 的 row-head）。
    @ViewBuilder private var actions: some View {
        Button {
            presenter.show(.skillInstall)
        } label: {
            Label("添加技能", systemImage: "plus")
        }
        .disabled(store.busy)
        .accessibilityIdentifier("library.skills.install")
        if page.skills.contains(where: { $0.kind == "github" || $0.kind == "git" }) {
            Button {
                Task { await store.checkSkills() }
            } label: {
                Label(store.checkingSkills ? "检查中…" : "检查更新", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(store.checkingSkills || store.busy)
            .accessibilityIdentifier("library.skills.check")
        }
        if !page.updatableSkills.isEmpty {
            let n = page.skillsWithUpdates.count
            Button {
                Task { await store.updateAllSkills() }
            } label: {
                Label(store.updatingAll ? "更新中…" : (n > 0 ? "更新 \(n) 个" : "全部更新"), systemImage: "arrow.up.circle")
            }
            .disabled(store.updatingAll || store.busy)
            .accessibilityIdentifier("library.skills.updateAll")
        }
        Menu {
            Button {
                Task { await store.run(.skillsAgentsAll, LibraryRequests.every(agents: all.map(\.id), on: true)) }
            } label: {
                Label("全部启用", systemImage: "checkmark.circle")
            }
            .disabled(page.skills.isEmpty)
            Button {
                let words = LibraryWords.everyOff(.skills, count: page.skills.count, agents: all.map(\.name))
                confirm = LibraryConfirm(title: words.title, message: words.message, button: "全部关闭") {
                    await store.run(.skillsAgentsAll, LibraryRequests.every(agents: all.map(\.id), on: false))
                }
            } label: {
                Label("全部关闭", systemImage: "circle")
            }
            .disabled(page.skills.isEmpty)
            Button {
                presenter.show(.skillHow)
            } label: {
                Label("Skills 启用方式", systemImage: "link")
            }
            if page.skills.contains(where: { !$0.groupRepo.isEmpty }) {
                Button {
                    Task { await store.regroupSkills() }
                } label: {
                    Label(store.regrouping ? "分组中…" : "重新分组", systemImage: "square.stack.3d.up")
                }
                .disabled(store.regrouping)
            }
            Button(role: .destructive) {
                let who = Set(page.skills.flatMap(\.agents)).map(page.name(of:)).sorted()
                var words = LibraryWords.removeEvery(.skills, count: page.skills.count, agents: who)
                let folders = page.skills.filter { $0.kind != "folder" }.count
                let linked = page.skills.count - folders
                if folders > 0 { words.message += "\n\(folders) 个技能文件夹将移到 magpie 的备份（资源库顶部的「备份」），不会删除。" }
                if linked > 0 { words.message += "\n\(linked) 个链接自你文件夹的技能只取消链接，原文件夹保留。" }
                confirm = LibraryConfirm(title: words.title, message: words.message, button: "删除全部 \(page.skills.count) 个") {
                    await store.run(.skillsRemoveAll, LibraryRequests.names(page.skills.map(\.name)))
                }
            } label: {
                Label("全部删除", systemImage: "trash")
            }
            .disabled(page.skills.count < 2)
        } label: {
            Label("更多操作", systemImage: "ellipsis.circle")
        }
        .disabled(store.busy)
        .accessibilityIdentifier("library.skills.bulk")
    }

    /// 「同一仓库里的其他技能」（官方 renderNewSkills）。
    private var newSkillsSection: some View {
        Section {
            ForEach(page.newSkills) { skill in
                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.name)
                    if !skill.description.isEmpty { Text(skill.description).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    Text(skill.repo).font(.caption2).foregroundStyle(.tertiary)
                    HStack {
                        Button("添加") {
                            Task { await store.run(.skillsAddNew, LibraryRequests.names([skill.id]), done: "\(skill.name) 已加入资源库") }
                        }
                        .buttonStyle(.bordered)
                        Button("忽略") {
                            Task { await store.run(.skillsIgnoreNew, LibraryRequests.names([skill.id]), done: "已忽略 \(skill.name)") }
                        }
                        .buttonStyle(.bordered)
                    }
                    .font(.footnote)
                    .disabled(store.busy)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("library.newSkill.\(skill.name)")
            }
            if page.newSkills.count > 1 {
                HStack {
                    Button("全部添加") {
                        Task { await store.run(.skillsAddNew, LibraryRequests.names(page.newSkills.map(\.id)), done: "已添加 \(page.newSkills.count) 个技能") }
                    }
                    Spacer()
                    Button("全部忽略") {
                        Task { await store.run(.skillsIgnoreNew, LibraryRequests.names(page.newSkills.map(\.id)), done: "已忽略 \(page.newSkills.count) 个技能") }
                    }
                }
                .buttonStyle(.borderless)
                .disabled(store.busy)
            }
        } header: {
            Text("同一仓库里的其他技能")
        } footer: {
            Text("GitHub 上与你已有技能同处一处，尚未加入资源库。忽略后，检查更新时不再提示。")
        }
    }

    /// 「Agent 中已有」（官方 foundSkillRow）。
    @ViewBuilder private var foundSkillsSection: some View {
        if page.partial {
            Section("Agent 中已有") {
                HStack {
                    ProgressView()
                    Text("正在查看各 Agent 的技能文件夹…").foregroundStyle(.secondary)
                }
            }
        } else if !page.foundSkills.isEmpty {
            Section {
                ForEach(page.foundSkills) { found in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(found.name)
                        if !found.description.isEmpty { Text(found.description).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        Text(found.agents.map(page.name(of:)).joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
                        if !found.link.isEmpty { Text("链接自 " + page.tilde(found.link)).font(.caption2.monospaced()).foregroundStyle(.tertiary) }
                        else if !found.shared.isEmpty { Text("共享于 " + page.tilde(found.shared)).font(.caption2.monospaced()).foregroundStyle(.tertiary) }
                        if !found.others.isEmpty { Text("\(found.others.map(page.name(of:)).joined(separator: "、")) 中不同").font(.caption).foregroundStyle(.orange) }
                        HStack {
                            Button("导入") {
                                Task { await store.run(.skillsImport, LibraryRequests.name(found.name), done: "\(found.name) 已加入资源库") }
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("library.foundSkill.\(found.name).import")
                            Button("移除", role: .destructive) {
                                confirm = LibraryConfirm(title: "移除 \(found.name)？", message: LibraryWords.removeFoundSkillMessage(found, name: page.name(of:), tilde: page.tilde), button: "移除") {
                                    await store.run(.skillsRemoveFound, LibraryRequests.name(found.name), done: "已移除 \(found.name)")
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                        .font(.footnote)
                        .disabled(store.busy)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("library.foundSkill.\(found.name)")
                }
                if page.foundSkills.count > 1 {
                    Button("全部导入") {
                        Task {
                            guard await store.run(.skillsImportAll, LibraryRequests.names(page.foundSkills.map(\.name))) else { return }
                            if let p = store.page?.result?.unimported.first {
                                store.say("\(p.what.replacingOccurrences(of: "skill:", with: "")) 未能导入：\(p.error)", warn: true)
                            } else {
                                store.say("\(page.foundSkills.count) 个技能已加入资源库")
                            }
                        }
                    }
                    .disabled(store.busy)
                }
            } header: {
                Text("Agent 中已有")
            } footer: {
                Text("不在资源库中 — 导入后可以给其他 Agent")
            }
        }
    }
}

/// 一组技能的标题：来源仓库、个数，有更新时「更新 N 个」，来源里没了的「清理 N 个」。
private struct LibrarySkillGroupHeader: View {
    let store: LibraryStore
    let repo: String
    let skills: [LibrarySkill]
    @Binding var confirm: LibraryConfirm?

    var body: some View {
        HStack {
            Text(repo.isEmpty ? "其他" : repo).textCase(nil)
            Text(skills.count == 1 ? "1 个技能" : "\(skills.count) 个技能").textCase(nil).foregroundStyle(.secondary)
            Spacer()
            let gone = skills.filter(\.isGone)
            if !gone.isEmpty {
                Button("清理 \(gone.count) 个") {
                    let words = LibraryWords.removeGone(gone)
                    confirm = LibraryConfirm(title: words.title, message: words.message, button: gone.count == 1 ? "移除" : "删除 \(gone.count) 个") {
                        await store.run(.skillsRemoveGone, LibraryRequests.names(gone.map(\.name)))
                    }
                }
                .font(.caption)
                .disabled(store.busy)
            }
        }
    }
}

/// 列表里的一个技能。点名字进详情（能看 SKILL.md）。
private struct LibrarySkillRow: View {
    let store: LibraryStore
    let page: LibrarySnapshot
    let skill: LibrarySkill
    let all: [LibraryAgent]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink {
                LibrarySkillDetail(store: store, name: skill.name)
            } label: {
                LibrarySkillHeader(page: page, skill: skill)
            }
            .accessibilityIdentifier("library.skill.\(skill.name)")
            LibrarySkillChips(store: store, page: page, skill: skill, all: all, id: "library.skill.\(skill.name).agents")
        }
        .padding(.vertical, 2)
        .opacity(skill.offHere ? 0.6 : 1)
    }
}

struct LibrarySkillChips: View {
    let store: LibraryStore
    let page: LibrarySnapshot
    let skill: LibrarySkill
    let all: [LibraryAgent]
    let id: String

    var body: some View {
        LibraryChips(agents: page.withGone(all, on: skill.agents, hidden: store.hidden),
                     on: store.agents(.skillsAgents, skill.name, current: skill.agents),
                     always: { skill.alwaysNote(for: $0) }, problems: skill.problems, id: id,
                     onChange: { next, every in store.setAgents(.skillsAgents, name: skill.name, to: next, allChip: every) },
                     onBlocked: { store.say($0, warn: true) })
    }
}

private struct LibrarySkillHeader: View {
    let page: LibrarySnapshot
    let skill: LibrarySkill

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(skill.name).lineLimit(1)
                LibrarySkillTags(page: page, skill: skill)
            }
            Text(skill.missing ? "它的文件夹已不在资源库中" : skill.description)
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

/// 名字旁的标签（官方 skillRow 的 tag）。
struct LibrarySkillTags: View {
    let page: LibrarySnapshot
    let skill: LibrarySkill

    var body: some View {
        if skill.isGone { LibraryTag("上游已删除", warn: true) }
        else if skill.hasUpdate { LibraryTag("有更新") }
        else if skill.check?.status == "unknown" { LibraryTag("未能检查") }
        if skill.edited { LibraryTag("本地已改动", warn: true) }
        if !skill.behind.isEmpty { LibraryTag("副本已落后") }
        if skill.offHere { LibraryTag("本机已关闭") }
    }
}

// MARK: 技能详情

struct LibrarySkillDetail: View {
    let store: LibraryStore
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var text: String?
    @State private var textError: String?
    @State private var confirm: LibraryConfirm?

    private var page: LibrarySnapshot? { store.page }
    private var skill: LibrarySkill? { page?.skills.first { $0.name == name } }

    var body: some View {
        ZStack {  // 不用 Group：Group 的修饰符会分给每个分支，换分支时弹窗宿主跟着被换掉
            if let page, let skill {
                content(page, skill)
            } else {
                ContentUnavailableView("这个技能已不在资源库中", systemImage: "doc.text")
            }
        }
        .detailHeader(name)
        .libraryConfirm($confirm)
        .safeAreaInset(edge: .bottom) { LibraryStatusLine(store: store) }
        .libraryAlerts(store: store, id: "library.skill")
        .task {
            do { text = try await store.skillText(name) } catch { textError = MagpieError.from(error).message }
        }
    }

    private func content(_ page: LibrarySnapshot, _ skill: LibrarySkill) -> some View {
        List {
            Section {
                HStack(spacing: 6) { LibrarySkillTags(page: page, skill: skill) }
                if !skill.description.isEmpty { Text(skill.description).font(.footnote) }
                if !skill.sourceLine.isEmpty {
                    if skill.kind == "github", let url = URL(string: skill.source) {
                        Link(skill.sourceLine, destination: url).font(.footnote)
                    } else {
                        Text(skill.sourceLine).font(.footnote.monospaced()).foregroundStyle(.secondary)
                    }
                }
                if skill.isGone {
                    Text(skill.groupRepo.isEmpty ? "来源里已经没有这个技能了：它在那里被删除了。在你移除之前，它会一直留在这里。" : "\(skill.groupRepo) 里已经没有这个技能了：它在那里被删除了。在你移除之前，它会一直留在这里。")
                        .font(.footnote).foregroundStyle(.orange)
                }
                if skill.edited {
                    Text(skill.gitRepo.isEmpty ? "从 GitHub 获取后你在本地改动过它。更新前会先询问，不会直接覆盖你的改动。" : "从 \(skill.gitRepo) 获取后你在本地改动过它。更新前会先询问，不会直接覆盖你的改动。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let check = skill.check, check.status == "update", !check.message.isEmpty {
                    Text("安装后 GitHub 上已有改动：\(check.message)").font(.footnote).foregroundStyle(.secondary)
                }
                if skill.offHere {
                    Text("这台电脑上的 Agent 都不会用到它。其他电脑保持各自的设置，同步也不会在这里把它重新打开。").font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section {
                LibrarySkillChips(store: store, page: page, skill: skill, all: page.skillAgents(hidden: store.hidden), id: "library.skillDetail.agents")
                ForEach(skill.problems.sorted { $0.key < $1.key }, id: \.key) { item in
                    Text("\(page.name(of: item.key))：\(item.value)").font(.footnote).foregroundStyle(.orange)
                }
                if !skill.always.isEmpty {
                    Text("\(skill.always.map(page.name(of:)).joined(separator: "、")) 会自己读取 ~/.agents/skills（这个技能就放在那里）——不管这里勾没勾都有它")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Agent")
            }

            Section {
                if skill.canUpdate {
                    Button {
                        if skill.edited {
                            let words = LibraryWords.updateEdited(skill)
                            confirm = LibraryConfirm(title: words.title, message: words.message, button: "更新") {
                                await store.run(.skillsUpdate, LibraryRequests.update(skill.name, replace: true), done: "\(skill.name) 已是最新，你的版本已存入备份")
                            }
                        } else {
                            Task { await store.run(.skillsUpdate, LibraryRequests.update(skill.name, replace: false), done: "\(skill.name) 已是最新") }
                        }
                    } label: {
                        Label(skill.gitRepo.isEmpty ? (skill.origin.isEmpty ? "从 GitHub 更新" : "从 GitHub 更新（CC Switch 安装时的来源）") : "从 \(skill.gitRepo) 更新", systemImage: "arrow.up.circle")
                    }
                    .disabled(store.busy)
                    .accessibilityIdentifier("library.skillDetail.update")
                }
                if !skill.behind.isEmpty {
                    Button {
                        Task { await store.run(.allSync, [:], done: "副本已更新") }
                    } label: {
                        Label("重新复制（\(skill.behind.map(page.name(of:)).joined(separator: "、")) 里的副本已落后）", systemImage: "doc.on.doc")
                    }
                    .disabled(store.busy)
                }
                Button {
                    Task {
                        await store.run(.skillsHere, LibraryRequests.here(skill.name, on: skill.offHere),
                                        done: skill.offHere ? "\(skill.name) 已在本机打开" : "\(skill.name) 已在本机关闭")
                    }
                } label: {
                    Label(skill.offHere ? "在本机打开" : "只在本机关闭", systemImage: "power")
                }
                .disabled(store.busy)
                .accessibilityIdentifier("library.skillDetail.here")
                if !skill.shared.isEmpty {
                    Button {
                        confirm = LibraryConfirm(title: "将 \(skill.name) 交给 magpie 管理？", message: LibraryWords.handOverMessage(skill, libraryDir: page.dir, tilde: page.tilde), button: "移入资源库", destructive: false) {
                            await store.run(.skillsHandOver, LibraryRequests.names([skill.name]), done: "\(skill.name) 已交给 magpie 的资源库管理")
                        }
                    } label: {
                        Label("交给 magpie 管理", systemImage: "tray.and.arrow.down")
                    }
                    .disabled(store.busy)
                }
                Button("移除", role: .destructive) {
                    let title = skill.isGone ? LibraryWords.removeGone([skill]).title : "移除 \(skill.name)？"
                    confirm = LibraryConfirm(title: title, message: LibraryWords.removeSkillMessage(skill), button: "移除") {
                        let action: LibraryAction = skill.isGone ? .skillsRemoveGone : .skillsRemove
                        let body = skill.isGone ? LibraryRequests.names([skill.name]) : LibraryRequests.name(skill.name)
                        if await store.run(action, body, done: "已移除 \(skill.name)") { dismiss() }
                    }
                }
                .disabled(store.busy)
                .accessibilityIdentifier("library.skillDetail.remove")
            } footer: {
                if skill.offHere { EmptyView() } else { Text("只在本机关闭：其他电脑照常使用") }
            }

            Section {
                if let text {
                    Text(text).font(.footnote.monospaced()).textSelection(.enabled)
                        .accessibilityIdentifier("library.skillDetail.text")
                } else if let textError {
                    Text(textError).font(.footnote).foregroundStyle(.red)
                } else {
                    ProgressView()
                }
            } header: {
                Text("SKILL.md")
            }
        }
    }
}

// MARK: 添加技能（查找一个来源）

struct LibrarySkillInstall: View {
    let store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var probe: LibraryProbe?
    @State private var picked: Set<String> = []
    @State private var agents: [String] = []
    @State private var looking = false
    @State private var error: String?
    @State private var filter = ""

    private var all: [LibraryAgent] { store.page?.skillAgents(hidden: store.hidden) ?? [] }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("owner/repo", text: $source)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onSubmit { Task { await look() } }
                        .accessibilityIdentifier("library.install.source")
                    Button(looking ? "查找中…" : "查找技能") { Task { await look() } }
                        .disabled(looking || source.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("library.install.look")
                } footer: {
                    Text("owner/repo、GitHub 或 GitLab 链接、任意 git 仓库地址，或本机上的文件夹")
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
                if let probe {
                    if probe.candidates.isEmpty {
                        Section { Text("那里没有技能 — 技能是一个含 SKILL.md 的文件夹。").foregroundStyle(.secondary) }
                    } else {
                        candidates(probe)
                        Section {
                            LibraryChips(agents: all, on: agents, id: "library.install.agents", onChange: { next, _ in agents = next })
                        } header: {
                            Text("给")
                        }
                    }
                }
            }
            .detailHeader("添加技能")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(picked.count == 1 ? "安装 1 个技能" : "安装 \(picked.count) 个技能") { Task { await install() } }
                        .disabled(picked.isEmpty || store.busy)
                        .accessibilityIdentifier("library.install.go")
                }
            }
            .onAppear { agents = all.map(\.id) }
            .interactiveDismissDisabled(store.busy)
        }
    }

    private func candidates(_ probe: LibraryProbe) -> some View {
        let shown = probe.candidates.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
        let open = probe.candidates.filter { !$0.have }
        return Section {
            if probe.candidates.count > 8 {
                TextField("筛选…", text: $filter).textInputAutocapitalization(.never)
            }
            ForEach(shown) { c in
                Button {
                    guard !c.have else { return }
                    if picked.contains(c.path) { picked.remove(c.path) } else { picked.insert(c.path) }
                } label: {
                    HStack(alignment: .top) {
                        Image(systemName: c.have ? "checkmark.circle" : picked.contains(c.path) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(c.have ? Color.secondary : Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(c.name).foregroundStyle(.primary)
                                if c.have { LibraryTag("已在资源库") }
                                else if !c.addsAs.isEmpty { LibraryTag("将添加为 \(c.addsAs)") }
                            }
                            if !c.description.isEmpty { Text(c.description).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }
                    }
                }
                .accessibilityIdentifier("library.install.candidate.\(c.name)")
            }
            if open.count > 1 {
                Button(picked.count == open.count ? "全不选" : "全选") {
                    picked = picked.count == open.count ? [] : Set(open.map(\.path))
                }
            }
        } header: {
            Text(probe.candidates.count == 1 ? "\(probe.source) 中有 1 个技能" : "\(probe.source) 中有 \(probe.candidates.count) 个技能")
        } footer: {
            if !probe.left.isEmpty {
                Text(probe.left.map { "\($0.path) 太大，无法安装：\(ByteCountFormatter.string(fromByteCount: $0.size, countStyle: .file))，超过单个技能 200 MB 的上限" }.joined(separator: "\n"))
            }
        }
    }

    private func look() async {
        let src = source.trimmingCharacters(in: .whitespaces)
        guard !src.isEmpty else { return }
        looking = true
        defer { looking = false }
        do {
            let p = try await store.probe(src)
            probe = p
            picked = Set(p.candidates.filter { !$0.have }.map(\.path))
            error = nil
        } catch {
            probe = nil
            self.error = MagpieError.from(error).message
        }
    }

    private func install() async {
        guard let probe else { return }
        guard await store.run(.skillsInstall, LibraryRequests.install(source: probe.source, paths: Array(picked).sorted(), agents: agents)) else {
            error = store.failure
            store.failure = nil
            return
        }
        dismiss()
    }
}

// MARK: 发现（skills.sh）

struct LibrarySkillMarket: View {
    let store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var market: LibraryMarket<LibraryMarketSkill>?
    @State private var loading = false
    @State private var error: String?
    @State private var adding: LibraryMarketSkill?

    var body: some View {
        NavigationStack {
            List {
                if loading && market == nil { ProgressView().frame(maxWidth: .infinity) }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                if let market {
                    Section {
                        ForEach(market.items) { item in
                            Button {
                                adding = item
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(item.name).foregroundStyle(.primary)
                                        if item.official { LibraryTag("官方") }
                                        if !item.have.isEmpty { LibraryTag("资源库中") }
                                    }
                                    if !item.description.isEmpty { Text(item.description).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                                    Text([item.source, item.installs > 0 ? "\(item.installs) 次安装" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                            .accessibilityIdentifier("library.market.skill.\(item.skillID)")
                        }
                    } header: {
                        Text(query.isEmpty ? "skills.sh 热门" : (market.items.count == 1 ? "1 个结果" : "\(market.items.count) 个结果"))
                    } footer: {
                        if !market.failed.isEmpty { Text("skills.sh 的搜索这次没有响应（\(market.cause)），下面只是 magpie 精选和最热门技能里匹配的结果。") }
                        else if market.items.isEmpty { Text(query.isEmpty ? "暂无内容。" : "没有与“\(query)”匹配的结果。") }
                    }
                }
            }
            .pageSearchable(text: $query, prompt: "在 skills.sh 搜索技能 — react、pdf、testing…")
            .onSubmit(of: .search) { Task { await search() } }
            .task { await search() }
            .detailHeader("发现")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .sheet(item: $adding) { item in
                LibrarySkillMarketAdd(store: store, item: item) { Task { await search() } }
            }
        }
    }

    private func search() async {
        loading = true
        defer { loading = false }
        do {
            market = try await store.marketSkills(query)
            error = nil
        } catch {
            self.error = MagpieError.from(error).message
        }
    }
}

private struct LibrarySkillMarketAdd: View {
    let store: LibraryStore
    let item: LibraryMarketSkill
    var added: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var agents: [String] = []
    @State private var error: String?

    private var all: [LibraryAgent] { store.page?.skillAgents(hidden: store.hidden) ?? [] }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(item.description.isEmpty ? "暂无描述。" : item.description).font(.footnote)
                    LabeledContent("来自", value: item.source)
                    if item.installs > 0 { LabeledContent("安装次数", value: "\(item.installs) 次安装") }
                    if item.official { Text("官方 — 来自其开发团队").font(.footnote).foregroundStyle(.secondary) }
                }
                Section {
                    LibraryChips(agents: all, on: agents, id: "library.skillMarketAdd.agents", onChange: { next, _ in agents = next })
                } header: {
                    Text("Agent")
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
                if !item.have.isEmpty { Section { Text("已在资源库中，名为 \(item.have)").foregroundStyle(.secondary) } }
            }
            .detailHeader(item.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("加入资源库") { Task { await add() } }
                        .disabled(store.busy || !item.have.isEmpty)
                        .accessibilityIdentifier("library.skillMarketAdd.add")
                }
            }
            .onAppear { agents = all.map(\.id) }
        }
    }

    private func add() async {
        guard await store.run(.marketSkill, LibraryRequests.marketSkill(source: item.source, id: item.skillID, agents: agents), done: "\(item.name) 已加入资源库") else {
            error = store.failure
            store.failure = nil
            return
        }
        added()
        dismiss()
    }
}

// MARK: 技能的启用方式（链接 / 副本）

struct LibrarySkillHowSheet: View {
    let store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let page = store.page {
                    Section {
                        Picker("Skills 启用方式", selection: Binding(get: { page.copySkills ? "copy" : "link" }, set: { how in
                            Task { await store.run(.skillsHow, LibraryRequests.how(agent: "", how: how), done: how == "copy" ? "现在各 Agent 拿到的是 Skills 的副本" : "现在各 Agent 拿到的是指向资源库的符号链接") }
                        })) {
                            Text("符号链接").tag("link")
                            Text("副本").tag("copy")
                        }
                        .pickerStyle(.segmented)
                        .disabled(store.busy)
                    } footer: {
                        Text(page.copySkills ? "每个 Agent 拿到一份独立的文件夹，资源库里的 Skill 变了就重新复制；在副本里做的修改会被覆盖。" : "符号链接跟着资源库里的 Skill 走：一更新，各 Agent 立刻就用上。")
                    }
                    Section {
                        ForEach(page.agents.filter { !$0.skills.isEmpty && !$0.gone && (!store.hidden.contains($0.id) || $0.howOwn) }) { agent in
                            if agent.mustCopy {
                                LabeledContent(agent.name, value: "只能用副本")
                            } else {
                                Picker(agent.name, selection: Binding(get: { agent.howOwn ? agent.how : "" }, set: { how in
                                    Task {
                                        let resolved = how.isEmpty ? (page.copySkills ? "copy" : "link") : how
                                        await store.run(.skillsHow, LibraryRequests.how(agent: agent.id, how: how),
                                                        done: resolved == "copy" ? "\(agent.name) 现在用的是 Skills 的副本" : "\(agent.name) 现在用的是符号链接")
                                    }
                                })) {
                                    Text("跟随资源库").tag("")
                                    Text("符号链接").tag("link")
                                    Text("副本").tag("copy")
                                }
                                .disabled(store.busy)
                            }
                        }
                    } header: {
                        Text("各 Agent 的 Skills 启用方式")
                    } footer: {
                        Text(page.copySkills ? "可以给某个 Agent 单独设定；其余的按资源库的方式，拿副本。" : "可以给某个 Agent 单独设定；其余的按资源库的方式，用符号链接。")
                    }
                }
            }
            .detailHeader("Skills 启用方式")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
