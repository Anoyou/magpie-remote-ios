import SwiftUI
import MagpieRemoteCore

/// 选择模型：路由组单独一组，其余模型按供应商分组；支持图片的标图片图标。来自主机的 `GET /v1/models`。
struct ChatModelPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let chat = model.chat
        NavigationStack {
            List {
                if let error = chat.catalogError {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(error.title, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                            Text(error.message).font(.footnote)
                            if let hint = error.hint { Text(hint).font(.footnote).foregroundStyle(.secondary) }
                        }
                        Button("重新加载模型") { Task { await chat.loadModels(app: model, force: true) } }
                            .accessibilityIdentifier("chat.models.retry")
                    }
                }
                if let catalog = chat.catalog {
                    if catalog.isEmpty {
                        ContentUnavailableView("没有可用的模型", systemImage: "cpu",
                                               description: Text("这台主机上的 magpie 还没有配置模型，或这把网关密钥没有被允许使用任何模型。"))
                    }
                    if !catalog.routingGroups.isEmpty {
                        Section {
                            ForEach(catalog.routingGroups) { row($0) }
                        } header: {
                            Text("路由组")
                        } footer: {
                            Text("路由组由 magpie 按规则挑选组里的模型来回答；回答下方会显示实际回答的模型。")
                        }
                    }
                    ForEach(catalog.providers) { provider in
                        Section("模型 · \(provider.name)") {
                            ForEach(provider.models) { row($0) }
                        }
                    }
                } else if chat.catalogError == nil {
                    HStack {
                        Spacer()
                        ProgressView("正在读取模型…")
                        Spacer()
                    }
                }
            }
            .navigationTitle("选择模型")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await chat.loadModels(app: model, force: true) }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("chat.models.done")
                }
            }
            .task { await chat.loadModels(app: model) }
        }
    }

    private func row(_ item: GatewayModel) -> some View {
        let selected = model.chat.session.model == item.id
        return Button {
            model.chat.selectModel(item.id)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).foregroundStyle(.primary)
                    Text(item.id).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if item.supportsImages {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("支持图片")
                }
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor).accessibilityLabel("已选择")
                }
            }
        }
        .accessibilityIdentifier("chat.model.\(item.id)")
    }
}
