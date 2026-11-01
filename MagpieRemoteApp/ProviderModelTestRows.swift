import SwiftUI
import Observation
import MagpieRemoteCore

/// 供应商详情「模型」一栏的「测试模型」（官方编辑器 Models 底部的 Test models）：向 Agent 看得到的每个模型各发一个极小请求，
/// 测试中按钮变成「停止」；每个模型旁边一个圆点（测试中 / 通过 / 失败），测过之后有「只选可用」。
@MainActor
@Observable
final class ProviderModelTests {
    /// 每个模型的结果；nil = 还在测。
    var results: [String: ProviderTestResult?] = [:]
    /// 正在跑的那次（「停止」用）。
    private(set) var run: String?
    private var task: Task<Void, Never>?

    var running: Bool { run != nil }
    var answered: [String: ProviderTestResult] { results.compactMapValues { $0 } }

    func start(store: ManageStore, provider: WebProvider, models ids: [String]) {
        guard run == nil else { return }
        guard !ids.isEmpty else {
            store.actionError = .webRejected(message: "请先选择模型。", code: nil)
            return
        }
        let run = UUID().uuidString.lowercased()
        self.run = run
        results = Dictionary(uniqueKeysWithValues: ids.map { ($0, nil) })
        task = Task {
            let answer = await store.testProviderModels(provider.id, models: ids, run: run)
            guard self.run == run else { return }
            self.run = nil
            guard let answer else {
                results = [:]
                return
            }
            for (i, result) in answer.enumerated() where i < ids.count { results[ids[i]] = result }
            let summary = ProviderModelTest.summary(ids: ids, results: answer)
            if summary.ok { store.status = summary.text } else { store.actionError = .webRejected(message: summary.text, code: nil) }
        }
    }

    /// 「停止」：结束主机上的这次测试，丢掉还没回来的结果。
    func stop(store: ManageStore) {
        guard let run else { return }
        self.run = nil
        task?.cancel()
        results = [:]
        store.status = "已停止测试"
        Task { await store.stopProviderTest(run: run) }
    }
}

/// 「测试模型」/「停止」与「只选可用」两行。
struct ProviderModelTestRows: View {
    let store: ManageStore
    let provider: WebProvider
    let tests: ProviderModelTests
    @State private var confirmWorking = false

    var body: some View {
        let unavailable = ProviderModelTest.unavailable(provider)
        Button {
            if tests.running { tests.stop(store: store) } else { tests.start(store: store, provider: provider, models: ProviderModelTest.models(of: provider)) }
        } label: {
            HStack {
                Label(tests.running ? "停止" : "测试模型", systemImage: tests.running ? "stop.circle" : "stethoscope")
                if tests.running { Spacer(); ProgressView() }
            }
        }
        .disabled(unavailable != nil || store.service == nil)
        .accessibilityHint(unavailable ?? "向 Agent 可见的每个模型发一个极小请求，找出无响应的模型")
        .accessibilityIdentifier("provider.testModels")
        if let unavailable {
            Text(unavailable).font(.footnote).foregroundStyle(.secondary)
        }
        if !tests.answered.isEmpty {
            let working = ProviderModelTest.workingOnly(provider, results: tests.answered)
            Button {
                confirmWorking = true
            } label: {
                Label("只选可用", systemImage: "checkmark.seal")
            }
            .disabled(working.dropped == 0 || store.busy)
            .accessibilityHint(working.dropped == 0 ? "已测试的选中模型都有响应" : "取消选中上次测试失败的模型；测试通过的和未测试的保持选中")
            .accessibilityIdentifier("provider.workingOnly")
            .confirmationDialog(ProviderModelTest.droppedSaid(working.dropped).replacingOccurrences(of: "已取消选中", with: "取消选中") + "？",
                                isPresented: $confirmWorking, titleVisibility: .visible) {
                Button("只选可用", role: .destructive) {
                    Task {
                        if await store.saveProvider(provider, edits: .init(enabledModels: Set(working.keep))) {
                            store.status = ProviderModelTest.droppedSaid(working.dropped)
                        }
                    }
                }
                .accessibilityIdentifier("provider.workingOnly.confirm")
                Button("取消", role: .cancel) {}
            } message: {
                Text("这些模型会从 Agent 的模型列表里拿掉；测试通过的和未测试的保持选中。")
            }
        }
    }
}

/// 一个模型旁边的测试结果圆点（官方 tdot）：测试中 / 通过 / 失败；失败时下面一行写原因。
struct ProviderModelTestMark: View {
    let tests: ProviderModelTests
    let model: String

    var body: some View {
        if let entry = tests.results[model] {
            Group {
                if let result = entry {
                    Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.ok ? .green : .red)
                        .accessibilityLabel(ProviderModelTest.detail(result))
                } else {
                    ProgressView().controlSize(.mini).accessibilityLabel("测试中…")
                }
            }
            .accessibilityIdentifier("provider.modelTest.\(model)")
        }
    }
}

/// 失败原因（或通过的用时），放在模型名下面。
struct ProviderModelTestDetail: View {
    let tests: ProviderModelTests
    let model: String

    var body: some View {
        if let entry = tests.results[model], let result = entry {
            Text(ProviderModelTest.detail(result))
                .font(.caption)
                .foregroundStyle(result.ok ? Color.secondary : Color.red)
                .lineLimit(2)
        }
    }
}
