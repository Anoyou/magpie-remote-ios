import SwiftUI
import MagpieRemoteCore

/// 统一处理「没有主机 / 连接中 / 连不上」，连上之后才显示页面内容。
struct ConnectedContent<Content: View>: View {
    @Environment(AppModel.self) private var model
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        switch model.connection {
        case .noHost:
            NoHostView()
        case .connecting:
            ProgressView("正在连接 \(model.activeHost?.name ?? "主机")…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("state.connecting")
        case .failed(let error):
            ErrorStateView(error: error) { Task { await model.reconnect() } }
        case .connected:
            content
        }
    }
}

struct NoHostView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("还没有添加主机", systemImage: "desktopcomputer")
        } description: {
            Text("添加运行 magpie 的 Mac，就能在 iPhone 上查看额度、用量和对话。")
        } actions: {
            Button("添加主机") { model.sheet = .hosts }
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("state.addHost")
            Button("配置引导") { model.sheet = .guide }
                .buttonStyle(.glass)
                .accessibilityIdentifier("guide.open")
        }
        .accessibilityIdentifier("state.noHost")
    }
}

struct ErrorStateView: View {
    @Environment(AppModel.self) private var model
    private let error: MagpieError
    private let retry: () -> Void

    init(error: MagpieError, retry: @escaping () -> Void) {
        self.error = error
        self.retry = retry
    }

    var body: some View {
        ContentUnavailableView {
            Label(error.title, systemImage: "exclamationmark.triangle")
        } description: {
            VStack(spacing: 8) {
                Text(error.message)
                if let hint = error.hint {
                    Text(hint).font(.footnote).foregroundStyle(.secondary)
                }
            }
        } actions: {
            Button("重试", action: retry)
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("state.retry")
            if error.suggestsSetupGuide {
                Button("配置引导") { model.sheet = .guide }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("guide.open")
            }
        }
        .accessibilityIdentifier("state.error")
    }
}

/// 当前主机与连接状态的玻璃卡片。
struct HostStatusCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.activeHost?.name ?? "未选择主机").font(.headline)
                Text(statusText).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if model.isFixture {
                Text("示例数据").font(.caption2.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 4)
                    .glassEffect(.regular, in: .capsule)
            }
        }
        .padding(16)
        .glassCard()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("host.status")
    }

    private var statusText: String {
        switch model.connection {
        case .noHost: "还没有添加主机"
        case .connecting: "正在连接…"
        case .failed(let error): error.title
        case .connected(let report):
            if let version = report.hostVersion { "已连接 · magpie \(version)" } else { "已连接" }
        }
    }
}

/// 列表页在接口接入前的空状态。
struct ComingSoonView: View {
    let title: String
    let message: String
    let symbol: String

    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(message))
    }
}
