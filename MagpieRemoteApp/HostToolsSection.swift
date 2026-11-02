import SwiftUI
import MagpieRemoteCore

/// 「管理」页的「主机工具」分组：主机更新、自动调优、隐私模型。
struct HostToolsSection: View {
    let store: ManageStore

    var body: some View {
        if let service = HostTools.service(for: store.service) {
            Section {
                NavigationLink {
                    HostUpdateView(service: service)
                } label: {
                    SettingsLabel("主机更新", icon: Image(systemName: "arrow.down.app"), color: .green)
                }
                .accessibilityIdentifier("manage.update")
                NavigationLink {
                    HostTuneView(service: service)
                } label: {
                    SettingsLabel("自动调优", icon: Image(systemName: "dial.medium"), color: .orange)
                }
                .accessibilityIdentifier("manage.tune")
                NavigationLink {
                    HostPrivacyModelView(service: service)
                } label: {
                    SettingsLabel("隐私模型", icon: Image(systemName: "eye.slash.circle"), color: .indigo)
                }
                .accessibilityIdentifier("manage.privacyModel")
                NavigationLink {
                    DisabledModelsView(store: store)
                } label: {
                    LabeledContent {
                        if let count = store.settings?.disabledModels.count, count > 0 { Text("\(count) 条") }
                    } label: {
                        SettingsLabel("已停用的模型", icon: Image(systemName: "nosign"), color: .red)
                    }
                }
                .accessibilityIdentifier("manage.disabledModels")
            } header: {
                Text("主机工具")
            } footer: {
                Text("更新 Mac 上的 magpie、按你的真实用法调 Agent 设置、选择本地脱敏用的模型、停用不想让请求用到的模型。")
            }
        }
    }
}
