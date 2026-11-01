import SwiftUI
import MagpieRemoteCore

/// Agent：magpie 在 Mac 上找到的编程助手（Codex、Claude Code…），可以直接切换它们用的模型。
/// 和官方网页版一样：在用的排在上面；什么都没设置的（未设置）和在网页版里隐藏的（已隐藏）收进下面一组，默认折叠，点开才显示。
struct ManageAgentsView: View {
    let store: ManageStore
    /// 折叠组是否展开（和网页版一样只在这次打开期间记住）。
    @State private var showsFolded = false

    var body: some View {
        let arrangement = AgentArrangement(agents: store.agents, order: store.settings?.agentOrder ?? [],
                                           hidden: store.settings?.agentsHidden ?? [])
        List {
            if store.agents.isEmpty {
                Section {
                    Text(store.phase == .ready ? "magpie 还没有在这台 Mac 上发现 Agent。" : "正在读取…").foregroundStyle(.secondary)
                }
            }
            ForEach(arrangement.shown) { agent in
                AgentSection(store: store, agent: agent)
            }
            if arrangement.foldedCount > 0 {
                Section {
                    Button {
                        withAnimation { showsFolded.toggle() }
                    } label: {
                        HStack {
                            Text(showsFolded ? "收起" : foldedLabel(arrangement))
                            Spacer()
                            Image(systemName: "chevron.down")
                                .rotationEffect(.degrees(showsFolded ? 180 : 0))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("agents.folded.toggle")
                    .accessibilityValue(showsFolded ? "已展开" : "已收起")
                } footer: {
                    if !showsFolded { Text(foldedFooter(arrangement)) }
                }
                if showsFolded {
                    if !arrangement.notSetUp.isEmpty {
                        FoldCaption(text: "未设置")
                        ForEach(arrangement.notSetUp) { agent in
                            AgentSection(store: store, agent: agent)
                        }
                    }
                    if !arrangement.hidden.isEmpty {
                        FoldCaption(text: "已隐藏")
                        ForEach(arrangement.hidden) { agent in
                            AgentSection(store: store, agent: agent)
                        }
                    }
                }
            }
        }
        .navigationTitle("Agent")
        .refreshable { await store.refresh() }
        .manageAlerts(store: store, id: "agents")
    }

    private func foldedLabel(_ arrangement: AgentArrangement) -> String {
        arrangement.notSetUp.isEmpty ? "\(arrangement.hidden.count) 个已隐藏的 Agent" : "另外 \(arrangement.foldedCount) 个 Agent"
    }

    private func foldedFooter(_ arrangement: AgentArrangement) -> String {
        var parts: [String] = []
        if !arrangement.notSetUp.isEmpty { parts.append("\(arrangement.notSetUp.count) 个还没设置") }
        if !arrangement.hidden.isEmpty { parts.append("\(arrangement.hidden.count) 个在网页版里隐藏了") }
        return parts.joined(separator: "，") + "。"
    }
}

/// 折叠组里「未设置」「已隐藏」的小标题（和网页版的分组标题一样）。
private struct FoldCaption: View {
    let text: String

    var body: some View {
        Section {
            Text(text)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("agents.folded.caption")
        }
        .listSectionSpacing(.compact)
    }
}

/// 一个 Agent：模型选择、接入状态、配置文件位置。
private struct AgentSection: View {
    let store: ManageStore
    let agent: WebAgent

    var body: some View {
        Section {
            if agent.cliMissing {
                Text("找不到它的命令行程序，可能已经卸载。重新安装后这里会再显示它的设置。").foregroundStyle(.secondary)
            } else if let field = agent.modelField {
                AgentModelPicker(store: store, agent: agent, field: field)
            } else {
                Text("这个 Agent 没有可切换的模型。").foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text(agent.name)
                Spacer()
                Text(agent.wired ? "已接入 magpie" : "未接入").foregroundStyle(agent.wired ? .green : .secondary)
            }
        } footer: {
            if !agent.path.isEmpty { Text("配置文件：\(agent.path)") }
        }
    }
}

private struct AgentModelPicker: View {
    let store: ManageStore
    let agent: WebAgent
    let field: WebAgentField

    /// 按主机给的分组（供应商 / 路由组）排列；保持主机的顺序。
    private struct OptionGroup: Identifiable {
        var name: String
        var options: [WebAgentOption]
        var id: String { name }
    }

    private var groups: [OptionGroup] {
        var result: [OptionGroup] = []
        for option in field.options {
            if let index = result.firstIndex(where: { $0.name == option.group }) {
                result[index].options.append(option)
            } else {
                result.append(OptionGroup(name: option.group, options: [option]))
            }
        }
        return result
    }

    var body: some View {
        Picker(selection: Binding(get: { field.value }, set: { value in
            guard value != field.value else { return }
            Task { await store.setAgent(agent.id, field: field.key, value: value) }
        })) {
            if !field.options.contains(where: { $0.value == field.value }) {
                Text(field.value.isEmpty ? "默认" : field.value).tag(field.value)
            }
            ForEach(groups) { group in
                Section(group.name.isEmpty ? "其它" : group.name) {
                    ForEach(group.options) { option in
                        Text(option.title).tag(option.value)
                    }
                }
            }
        } label: {
            Label("模型", systemImage: "cpu")
        }
        .pickerStyle(.navigationLink)
        .disabled(store.busy)
        .accessibilityIdentifier("agent.model.\(agent.id)")
    }
}
