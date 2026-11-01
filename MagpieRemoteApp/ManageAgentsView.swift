import SwiftUI
import MagpieRemoteCore

/// Agent：magpie 在 Mac 上找到的编程助手（Codex、Claude Code…），可以直接切换它们用的模型。
struct ManageAgentsView: View {
    let store: ManageStore

    var body: some View {
        List {
            if store.agents.isEmpty {
                Section {
                    Text(store.phase == .ready ? "magpie 还没有在这台 Mac 上发现 Agent。" : "正在读取…").foregroundStyle(.secondary)
                }
            }
            ForEach(store.agents) { agent in
                Section {
                    if let field = agent.modelField {
                        AgentModelPicker(store: store, agent: agent, field: field)
                    } else {
                        Text("这个 Agent 没有可切换的模型。").foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        BrandIcon(agent.officialIcon, size: 16)
                        Text(agent.name)
                        Spacer()
                        Text(agent.wired ? "已接入 magpie" : "未接入").foregroundStyle(agent.wired ? .green : .secondary)
                    }
                } footer: {
                    if !agent.path.isEmpty { Text("配置文件：\(agent.path)") }
                }
            }
        }
        .navigationTitle("Agent")
        .refreshable { await store.refresh() }
        .manageAlerts(store: store, id: "agents")
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
