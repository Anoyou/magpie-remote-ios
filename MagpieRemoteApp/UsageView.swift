import SwiftUI
import MagpieRemoteCore

struct UsageView: View {
    @Environment(AppModel.self) private var model
    @State private var rows: [UsageRow]?
    @State private var error: MagpieError?

    var body: some View {
        ConnectedContent {
            List {
                if let error {
                    Section { ErrorStateView(error: error) { Task { await reload() } } }
                } else if let rows {
                    if rows.isEmpty {
                        ComingSoonView(title: "暂无用量数据", message: "用量统计需要主机开启 Web 接口（magpie daemon web on）并填写 Web 密钥；接口正在接入。", symbol: "chart.bar")
                            .listRowBackground(Color.clear)
                    } else {
                        Section("按天汇总") {
                            ForEach(rows) { row in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(row.label).font(.headline)
                                    Text("\(row.requests) 次请求 · 输入 \(row.inputTokens) 词元 · 输出 \(row.outputTokens) 词元")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .refreshable { await reload() }
        }
        .task(id: model.connection) { await reload() }
    }

    private func reload() async {
        guard case .connected = model.connection else { rows = nil; error = nil; return }
        do {
            rows = try await model.loadUsage()
            error = nil
        } catch {
            self.error = MagpieError.from(error)
        }
    }
}
