import SwiftUI
import MagpieRemoteCore

struct ManageView: View {
    @Environment(AppModel.self) private var model
    @State private var keys: [GatewayKeySummary]?

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

            Section {
                if case .connected = model.connection {
                    if let keys {
                        if keys.isEmpty {
                            Text("密钥管理接口正在接入：之后可以在这里查看、停用和签发网关密钥（需要签发密钥）。")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            ForEach(keys) { key in
                                LabeledContent {
                                    Text(key.enabled ? "启用" : "已停用").foregroundStyle(key.enabled ? .green : .secondary)
                                } label: {
                                    Text(key.name)
                                    Text(key.masked).font(.caption.monospaced())
                                }
                            }
                        }
                    } else {
                        ProgressView()
                    }
                } else {
                    Text("连上主机后显示。").foregroundStyle(.secondary)
                }
            } header: {
                Text("网关密钥")
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
        .task(id: model.connection) {
            guard case .connected = model.connection else { keys = nil; return }
            keys = (try? await model.loadGatewayKeys()) ?? []
        }
    }
}
