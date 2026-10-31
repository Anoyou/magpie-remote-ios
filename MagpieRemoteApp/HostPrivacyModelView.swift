import SwiftUI
import Observation
import MagpieRemoteCore

/// 本地脱敏模型的数据与操作。
@MainActor
@Observable
final class HostPrivacyModelModel {
    let service: any HostToolsServing
    private(set) var state: PrivacyModelState?
    private(set) var loadError: MagpieError?
    private(set) var busy = false
    var actionError: MagpieError?
    /// 打开后等模型启动：最多再读这么多次。
    private var startTries = 0

    init(service: any HostToolsServing) { self.service = service }

    func load() async {
        do {
            state = try await service.privacyModel()
            loadError = nil
        } catch {
            let error = MagpieError.from(error)
            if error != .cancelled { loadError = error }
        }
    }

    var shouldPoll: Bool {
        guard let state else { return false }
        return state.downloadingModel != nil || (state.isWorking && startTries < 30)
    }

    /// 下载中、或模型正在启动时每隔一会儿再读一次（与网页一样，启动最多等 30 次）。
    func poll() async {
        while !Task.isCancelled, shouldPoll {
            try? await Task.sleep(for: service.pollInterval)
            guard !Task.isCancelled else { return }
            if state?.downloadingModel == nil { startTries += 1 }
            await load()
        }
    }

    func act(_ action: PrivacyModelAction) async {
        busy = true
        defer { busy = false }
        startTries = 0
        do {
            state = try await service.privacyModel(action)
        } catch {
            let error = MagpieError.from(error)
            if error != .cancelled { actionError = error }
            await load()
        }
    }
}

/// 「管理 › 隐私模型」：脱敏时在 Mac 本地运行的模型（找规则找不到的姓名、地址、密码），开关、换模型、阈值。
struct HostPrivacyModelView: View {
    @State private var model: HostPrivacyModelModel
    @State private var confirmRemove = false
    @State private var confirmPick: PrivacyModelStatus?
    @State private var confirmOn = false

    init(service: any HostToolsServing) {
        _model = State(initialValue: HostPrivacyModelModel(service: service))
    }

    var body: some View {
        List {
            if let state = model.state {
                content(state)
            } else if let error = model.loadError {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(error.title, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Text(error.message).font(.footnote)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("privacy.error")
                    Button("重试") { Task { await model.load() } }
                }
            } else {
                Section { HStack { ProgressView(); Text("正在读取…").foregroundStyle(.secondary) } }
            }
        }
        .navigationTitle("隐私模型")
        .refreshable { await model.load() }
        .task { await model.load() }
        .task(id: model.shouldPoll) { await model.poll() }
        .confirmationDialog("删除已下载的模型？", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("删除模型", role: .destructive) { Task { await model.act(.remove) } }
                .accessibilityIdentifier("privacy.confirmRemove")
            Button("取消", role: .cancel) {}
        } message: {
            Text("本地模型会关闭，Mac 上所有已下载的模型都会删掉；再打开时要重新下载（\(HostToolsFormat.bytes(model.state?.current.size ?? 0))）。")
        }
        .confirmationDialog(confirmPick.map { "换成 \($0.name)？" } ?? "", isPresented: Binding(get: { confirmPick != nil }, set: { if !$0 { confirmPick = nil } }),
                            titleVisibility: .visible, presenting: confirmPick) { pick in
            Button("换成 \(pick.name)") { Task { await model.act(.pick(model: pick.model)) } }
                .accessibilityIdentifier("privacy.confirmPick")
            Button("取消", role: .cancel) {}
        } message: { pick in
            Text(pickMessage(pick))
        }
        .confirmationDialog("打开本地模型？", isPresented: $confirmOn, titleVisibility: .visible) {
            Button("下载并打开") { Task { await model.act(.on(model: nil)) } }
                .accessibilityIdentifier("privacy.confirmOn")
            Button("取消", role: .cancel) {}
        } message: {
            Text("Mac 会先下载 \(model.state?.current.name ?? "模型")（\(HostToolsFormat.bytes(model.state?.current.size ?? 0))），下载完才开始用；期间照常按规则脱敏。")
        }
        .alert(model.actionError?.title ?? "", isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
            Button("好") { model.actionError = nil }
        } message: {
            Text([model.actionError?.message, model.actionError?.hint].compactMap { $0 }.joined(separator: "\n"))
        }
    }

    private func pickMessage(_ pick: PrivacyModelStatus) -> String {
        var text = "\(pick.name)：\(pick.about)。"
        if !pick.installed { text += "\n\nMac 要先下载 \(HostToolsFormat.bytes(pick.size))。" }
        if model.state?.on == true && !pick.installed { text += "下载完成前继续用现在的模型。" }
        if model.state?.on == false { text += "\n\n本地模型现在是关着的，只是记住你的选择。" }
        return text
    }

    @ViewBuilder
    private func content(_ state: PrivacyModelState) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(state.summary).font(.footnote)
                if let d = state.downloadingModel {
                    ProgressView(value: d.progress ?? 0).accessibilityIdentifier("privacy.progress")
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("privacy.summary")

            if state.usable {
                Toggle(isOn: Binding(get: { state.showsOn }, set: { on in
                    if on {
                        if state.current.installed { Task { await model.act(.on(model: nil)) } } else { confirmOn = true }
                    } else {
                        Task { await model.act(.off) }
                    }
                })) {
                    Label("用本地模型找敏感信息", systemImage: "eye.slash")
                }
                .disabled(model.busy)
                .accessibilityIdentifier("privacy.toggle")

                if state.downloadingModel != nil {
                    Button("停止下载") { Task { await model.act(.cancel) } }
                        .disabled(model.busy)
                        .accessibilityIdentifier("privacy.cancel")
                }
            }
        } header: {
            Text("本地脱敏模型")
        } footer: {
            Text("在 Mac 上运行的小模型，帮规则找出它找不到的姓名、地址和密码，发给厂商前先遮掉。模型和数据都留在 Mac 上。")
        }

        if state.usable {
            if state.models.count > 1 {
                Section("模型") {
                    ForEach(state.models) { option in
                        Button {
                            if option.model != state.current.model { confirmPick = option }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.name).foregroundStyle(option.usable ? .primary : .secondary)
                                    Text(option.note).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if option.model == state.current.model {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .disabled(model.busy || !option.usable)
                        .accessibilityIdentifier("privacy.model.\(option.model)")
                    }
                }
            }

            if state.defaultScore > 0 {
                Section {
                    Picker("置信度阈值", selection: Binding(get: { state.selectedScore }, set: { value in
                        guard value != state.selectedScore else { return }
                        Task { await model.act(.score(value, model: state.current.model)) }
                    })) {
                        ForEach(state.scoreChoices) { choice in
                            Text(choice.title).tag(choice.value)
                        }
                    }
                    .disabled(model.busy)
                    .accessibilityIdentifier("privacy.score")
                } footer: {
                    Text("模型把握不到这个程度的内容会原样发送。越高遮得越少、误报越少；越低遮得越多。")
                }
            }

            if state.canRemove {
                Section {
                    Button("删除已下载的模型", role: .destructive) { confirmRemove = true }
                        .disabled(model.busy)
                        .accessibilityIdentifier("privacy.remove")
                }
            }
        }
    }
}
