import SwiftUI
import UIKit

/// 「配置引导」：用大白话说明主机（Mac）上要做的几步。
struct SetupGuideView: View {
    @Environment(\.dismiss) private var dismiss
    private let showsDone: Bool

    init(showsDone: Bool) {
        self.showsDone = showsDone
    }

    private struct Step: Identifiable {
        let id: Int
        let title: String
        let detail: String
        var command: String?
        var warning = false
    }

    private let steps: [Step] = [
        Step(id: 1, title: "在 Mac 上打开 magpie",
             detail: "这台 Mac 就是「主机」。App 只是遥控器，所有模型账号和密钥都留在 Mac 上。"),
        Step(id: 2, title: "开启「在局域网共享」",
             detail: "在 magpie 里打开 设置 → 网络与共享，打开「在局域网共享」。不打开的话，网关只接受这台 Mac 自己的请求，iPhone 会连不上。"),
        Step(id: 3, title: "创建网关密钥",
             detail: "在同一页面为这台 iPhone 创建一把网关密钥，复制下来，填到 App「主机」里的「网关密钥」。以后不想让这台 iPhone 用了，在 Mac 上停用这把密钥即可。"),
        Step(id: 4, title: "打开 Web 接口（看用量、做管理时需要）",
             detail: "在 Mac 的「终端」里运行下面这行，让 Web 接口（默认端口 3430）也能被局域网里的设备访问。它会生成一个 Web 密钥并保存为 MAGPIE_WEB_KEY；也可以先自己设置 MAGPIE_WEB_KEY（至少 16 位字母或数字）。把这个值填到 App 的「Web 密钥」。",
             command: "magpie daemon web on --lan"),
        Step(id: 5, title: "外网只用 Tailscale / WireGuard，不要开放公网端口",
             detail: "不在家时，请在 iPhone 和 Mac 上都装好并打开 Tailscale（或用 WireGuard），用它分配的地址连接，例如 100.64.0.1 或 my-mac.tailnet.example。千万不要在路由器上把 3425、3430 端口转发到公网——那等于把你的模型账号交给陌生人。",
             warning: true),
        Step(id: 6, title: "回到 App 添加主机",
             detail: "点「主机」→「添加主机」，填地址和密钥，点「测试连接」。看到「连接成功」就完成了。"),
    ]

    var body: some View {
        ScrollView {
            GlassEffectContainer(spacing: 14) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("按顺序做完这几步，大约 5 分钟。只需要在 Mac 上操作一次。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ForEach(steps) { step in
                        StepCard(step: step)
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("配置引导")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("guide.screen")
        .toolbar {
            if showsDone {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .accessibilityIdentifier("guide.done")
                }
            }
        }
    }

    private struct StepCard: View {
        let step: Step

        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                Text("\(step.id)")
                    .font(.headline.monospacedDigit())
                    .frame(width: 30, height: 30)
                    .glassEffect(.regular.tint(step.warning ? Color.orange.opacity(0.5) : Color.accentColor.opacity(0.4)), in: .circle)
                VStack(alignment: .leading, spacing: 6) {
                    Text(step.title).font(.headline)
                    Text(step.detail).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    if let command = step.command {
                        HStack {
                            Text(command)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                            Spacer(minLength: 8)
                            Button {
                                UIPasteboard.general.string = command
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("复制命令")
                        }
                        .padding(10)
                        .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 10, style: .continuous))
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
            .accessibilityElement(children: .contain)
        }
    }
}
