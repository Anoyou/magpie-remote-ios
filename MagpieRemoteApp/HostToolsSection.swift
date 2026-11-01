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
                    Label("主机更新", systemImage: "arrow.down.app")
                }
                .accessibilityIdentifier("manage.update")
                NavigationLink {
                    HostTuneView(service: service)
                } label: {
                    Label("自动调优", systemImage: "dial.medium")
                }
                .accessibilityIdentifier("manage.tune")
                NavigationLink {
                    HostPrivacyModelView(service: service)
                } label: {
                    Label("隐私模型", systemImage: "eye.slash.circle")
                }
                .accessibilityIdentifier("manage.privacyModel")
                NavigationLink {
                    DisabledModelsView(store: store)
                } label: {
                    LabeledContent {
                        if let count = store.settings?.disabledModels.count, count > 0 { Text("\(count) 条") }
                    } label: {
                        Label("已停用的模型", systemImage: "nosign")
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
