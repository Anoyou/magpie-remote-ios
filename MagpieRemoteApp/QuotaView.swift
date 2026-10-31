import SwiftUI
import MagpieRemoteCore

struct QuotaView: View {
    @Environment(AppModel.self) private var model
    @State private var items: [QuotaItem]?
    @State private var error: MagpieError?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HostStatusCard()
                ConnectedContent {
                    content
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .refreshable { await reload() }
        .task(id: model.connection) { await reload() }
    }

    @ViewBuilder private var content: some View {
        if let error {
            ErrorStateView(error: error) { Task { await reload() } }
        } else if let items {
            if items.isEmpty {
                ComingSoonView(title: "暂无额度数据", message: "额度接口正在接入，下一个版本显示各供应商账号的剩余额度。", symbol: "gauge.with.dots.needle.0percent")
            } else {
                GlassEffectContainer(spacing: 12) {
                    VStack(spacing: 12) {
                        ForEach(items) { QuotaCard(item: $0) }
                    }
                }
            }
        } else {
            ProgressView().padding()
        }
    }

    private func reload() async {
        guard case .connected = model.connection else { items = nil; error = nil; return }
        do {
            items = try await model.loadQuota()
            error = nil
        } catch {
            self.error = MagpieError.from(error)
        }
    }
}

private struct QuotaCard: View {
    let item: QuotaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.provider).font(.headline)
                Spacer()
                if let remaining = item.remainingText { Text(remaining).font(.subheadline.monospacedDigit()) }
            }
            Text(item.account).font(.footnote).foregroundStyle(.secondary)
            if let used = item.usedFraction {
                ProgressView(value: min(max(used, 0), 1))
                    .tint(used > 0.85 ? .orange : .accentColor)
            }
        }
        .padding(16)
        .glassCard()
        .accessibilityElement(children: .combine)
    }
}
