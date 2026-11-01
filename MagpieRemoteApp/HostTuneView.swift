import SwiftUI
import Observation
import MagpieRemoteCore

/// 自动调优的数据与操作。
@MainActor
@Observable
final class HostTuneModel {
    let service: any HostToolsServing
    private(set) var state: TuneState?
    private(set) var loadError: MagpieError?
    /// 正在提交的建议 id（"全部" 时为 "*"）。
    private(set) var busy: String?
    var actionError: MagpieError?
    var saved: String?
    var days = 7

    init(service: any HostToolsServing) { self.service = service }

    func load() async {
        do {
            state = try await service.tune(days: days)
            loadError = nil
        } catch {
            let error = MagpieError.from(error)
            if error != .cancelled { loadError = error }
        }
    }

    func apply(_ change: TuneChange, id: String) async {
        await run(id) { _ = try await self.service.applyTune(change) }
        if actionError == nil { saved = "已保存：\(TuneState.agentName(change.agent)) 从下一个会话开始使用。" }
    }

    func undo(_ change: TuneChange, id: String) async {
        await run(id) { _ = try await self.service.undoTune(change) }
        if actionError == nil { saved = "已恢复原来的设置。" }
    }

    /// 逐条应用；遇到失败就停下，已成功的保留。
    func applyAll() async {
        guard let changes = state?.applicable, !changes.isEmpty else { return }
        var done = 0
        await run("*") {
            for change in changes {
                _ = try await self.service.applyTune(change)
                done += 1
            }
        }
        if actionError == nil { saved = "已应用 \(done) 条建议，各 Agent 从下一个会话开始使用。" }
    }

    private func run(_ id: String, _ operation: () async throws -> Void) async {
        busy = id
        defer { busy = nil }
        do {
            try await operation()
        } catch {
            let error = MagpieError.from(error)
            if error != .cancelled { actionError = error }
        }
        await load()
    }
}

/// 「管理 › 自动调优」：用这台 Mac 上 Agent 的真实调用重放，给出最省词元的设置，可以逐条或全部应用、撤销。
struct HostTuneView: View {
    @State private var model: HostTuneModel
    @State private var confirmAll = false
    @State private var confirming: TuneAdvice?

    init(service: any HostToolsServing) {
        _model = State(initialValue: HostTuneModel(service: service))
    }

    var body: some View {
        List {
            Section {
                Picker("统计范围", selection: Binding(get: { model.days }, set: { model.days = $0; Task { await model.load() } })) {
                    ForEach(TuneState.dayOptions, id: \.self) { days in
                        Text(days == 1 ? "今天" : "近 \(days) 天").tag(days)
                    }
                }
                .accessibilityIdentifier("tune.days")
            } footer: {
                Text("magpie 读取这台 Mac 上 Claude Code 和 Codex 的会话文件，把这段时间的每次调用按不同设置重放一遍，找出最省词元的设置（缓存读取按厂商计价算十分之一）。")
            }

            if let state = model.state {
                if state.shown.isEmpty {
                    Section {
                        Text("这段时间的调用太少，还给不出建议。").foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("tune.empty")
                } else {
                    if !state.applicable.isEmpty {
                        Section {
                            Button {
                                confirmAll = true
                            } label: {
                                Label("全部应用（\(state.applicable.count) 条）", systemImage: "wand.and.stars")
                            }
                            .disabled(model.busy != nil)
                            .accessibilityIdentifier("tune.applyAll")
                        }
                    }
                    ForEach(state.shown) { agent in
                        Section {
                            ForEach(agent.advice) { advice in
                                TuneAdviceRow(advice: advice, busy: model.busy != nil, working: model.busy == advice.id || model.busy == "*",
                                              apply: { confirming = advice },
                                              undo: { Task { await model.undo(advice.undoChange, id: advice.id) } },
                                              applyBackground: { bg in Task { await model.apply(.background(bg), id: advice.id) } },
                                              undoBackground: { bg in Task { await model.undo(TuneChange.background(bg), id: advice.id) } })
                            }
                        } header: {
                            Text("\(agent.name) · \(agent.calls) 次调用")
                        }
                    }
                }
            } else if let error = model.loadError {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(error.title, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Text(error.message).font(.footnote)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("tune.error")
                    Button("重试") { Task { await model.load() } }
                }
            } else {
                Section { HStack { ProgressView(); Text("正在重放这段时间的调用…").foregroundStyle(.secondary) } }
            }
        }
        .navigationTitle("自动调优")
        .refreshable { await model.load() }
        .task { await model.load() }
        .confirmationDialog("应用全部建议？", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("全部应用") { Task { await model.applyAll() } }
                .accessibilityIdentifier("tune.confirmAll")
            Button("取消", role: .cancel) {}
        } message: {
            Text(allMessage)
        }
        .confirmationDialog(confirming.map { "把\($0.title)改成 \($0.bestText)？" } ?? "",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { advice in
            Button("改成 \(advice.bestText)") { Task { await model.apply(advice.applyChange, id: advice.id) } }
                .accessibilityIdentifier("tune.confirm")
            Button("取消", role: .cancel) {}
        } message: { advice in
            Text(message(for: advice))
        }
        .alert(model.actionError?.title ?? "", isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
            Button("好") { model.actionError = nil }
        } message: {
            Text([model.actionError?.message, model.actionError?.hint].compactMap { $0 }.joined(separator: "\n"))
        }
        .alert("已保存", isPresented: Binding(get: { model.saved != nil && model.actionError == nil }, set: { if !$0 { model.saved = nil } })) {
            Button("好") { model.saved = nil }
        } message: {
            Text(model.saved ?? "")
        }
    }

    private var allMessage: String {
        let lines = (model.state?.shown ?? []).flatMap(\.advice).filter(\.canApply).map { "· \($0.agentName) \($0.title)：\($0.currentText) → \($0.bestText)" }
        return (lines + ["", "改的是 Mac 上各 Agent 的配置文件（或 magpie 的「长对话」设置），每条都可以单独撤销。"]).joined(separator: "\n")
    }

    private func message(for advice: TuneAdvice) -> String {
        var parts = ["\(advice.agentName)：\(advice.currentText) → \(advice.bestText)，\(advice.verdict)。"]
        if advice.replacesUserValue { parts.append("会替换你自己设置的 \(advice.currentText)，之后可以撤销恢复。") }
        if let caveat = advice.caveat { parts.append(caveat) }
        return parts.joined(separator: "\n\n")
    }
}

private struct TuneAdviceRow: View {
    let advice: TuneAdvice
    let busy: Bool
    let working: Bool
    let apply: () -> Void
    let undo: () -> Void
    let applyBackground: (TuneAsync) -> Void
    let undoBackground: (TuneAsync) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(advice.title).font(.headline)
                if !advice.model.isEmpty {
                    Text(advice.model).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if working { ProgressView() }
            }
            Text(advice.sourceText).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                value("现在", advice.currentText)
                if !advice.isSame {
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    value(advice.isTimed ? "词元 + 等待" : "最省词元", advice.bestText).foregroundStyle(.tint)
                }
            }
            Label(advice.verdict, systemImage: advice.isSame || advice.isApplied ? "checkmark.circle.fill" : "leaf")
                .font(.footnote.weight(.medium))
                .foregroundStyle(advice.isSame || advice.isApplied ? .green : .blue)
            Text(advice.explanation).font(.footnote)
            if let caveat = advice.caveat {
                Text(caveat).font(.caption).foregroundStyle(.secondary)
            }
            if let bg = advice.background {
                Text(bg.text).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                if advice.canApply {
                    Button("改成 \(advice.bestText)", action: apply)
                        .buttonStyle(.glassProminent)
                        .accessibilityIdentifier("tune.apply.\(advice.agent).\(advice.knob)")
                }
                if advice.canUndo {
                    Button("撤销", action: undo)
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("tune.undo.\(advice.agent).\(advice.knob)")
                }
                if let bg = advice.background {
                    if bg.isApplied {
                        Button("撤销后台压缩") { undoBackground(bg) }.buttonStyle(.glass)
                    } else if bg.canApply {
                        Button("后台压缩") { applyBackground(bg) }.buttonStyle(.glass)
                            .accessibilityIdentifier("tune.background")
                    }
                }
            }
            .disabled(busy)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tune.advice.\(advice.agent).\(advice.knob)")
    }

    private func value(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(text).font(.title3.weight(.semibold).monospacedDigit())
        }
    }
}
