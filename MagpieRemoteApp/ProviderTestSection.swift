import SwiftUI
import MagpieRemoteCore

/// 供应商详情里的「端点 · 测试」（官方编辑器 Endpoints 一栏的 Test）：向已保存的每个端点各发一个最小请求，
/// 每个端点一行显示成功用时，或「状态码 · 原因」。
struct ProviderTestSection: View {
    let store: ManageStore
    let provider: WebProvider
    @State private var results: [ProviderTestResult]?
    @State private var testing = false

    var body: some View {
        Section {
            if let results {
                if results.isEmpty {
                    Text("没有可以测试的端点。").foregroundStyle(.secondary)
                }
                ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result.ok ? .green : .red)
                        Text(result.apiName)
                        Spacer()
                        Text(result.summary)
                            .font(.callout)
                            .foregroundStyle(result.ok ? Color.secondary : Color.red)
                            .multilineTextAlignment(.trailing)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityHint(result.ok && !result.model.isEmpty ? "模型 \(result.model)" : "")
                    .accessibilityIdentifier("provider.test.result.\(result.api)")
                }
            }
            Button {
                testing = true
                Task {
                    results = await store.testProvider(provider.id) ?? results
                    testing = false
                }
            } label: {
                HStack {
                    Text("测试")
                    if testing { Spacer(); ProgressView() }
                }
            }
            .disabled(testing)
            .accessibilityIdentifier("provider.test")
        } header: {
            Text("端点")
        } footer: {
            Text("向每个端点发送一个小请求")
        }
    }
}
