import SwiftUI
import Observation
import MagpieRemoteCore

/// 主机更新的数据与流程：读状态、检查、下载、重启并等主机回来。
@MainActor
@Observable
final class HostUpdateModel {
    enum Restart: Equatable {
        case idle
        /// 已让主机重启，正在等它回来。
        case waiting(sawDown: Bool)
        case done(version: String, upgraded: Bool)
        case failed(String)
    }

    let service: any HostToolsServing
    private(set) var status: HostUpdateStatus?
    private(set) var notes: HostUpdateNotes?
    private(set) var loadError: MagpieError?
    private(set) var busy = false
    var actionError: MagpieError?
    private(set) var restart: Restart = .idle
    /// 刚点过「重启并安装」，但主机说发布源还没回应（state=checking）：变成 ready 后再点一次。
    private var installAgain = false

    init(service: any HostToolsServing) { self.service = service }

    var compatibility: HostUpdateCompatibility? {
        guard let status, status.hasUpdate else { return nil }
        return HostUpdateCompatibility.of(status.latest)
    }

    var isRestarting: Bool { if case .waiting = restart { return true }; return false }

    func load(fresh: Bool = true) async {
        do {
            let status = try await service.updateStatus(fresh: fresh)
            self.status = status
            loadError = nil
            if status.hasUpdate, notes?.latest != status.latest {
                notes = try? await service.updateNotes()
            }
        } catch {
            let error = MagpieError.from(error)
            if error != .cancelled { loadError = error }
        }
    }

    /// 检查 / 下载 / 等空闲期间每隔一会儿再读一次；主机说 ready 后补上那次重启。
    func poll() async {
        while !Task.isCancelled, status?.isWorking == true, !isRestarting {
            try? await Task.sleep(for: service.pollInterval)
            guard !Task.isCancelled else { return }
            let before = status
            await load(fresh: false)
            // 等空闲的重启由主机自己发起：读不到状态了，就当它开始重启了。
            if let before, before.waiting, loadError != nil {
                loadError = nil
                await waitForRestart(old: before.current, expected: before.latest)
                return
            }
            if installAgain, status?.state == .ready {
                installAgain = false
                await install(.whenIdle)
            }
        }
    }

    func check() async {
        await run {
            let status = try await self.service.checkUpdate()
            self.status = status
            if status.hasUpdate { self.notes = try? await self.service.updateNotes() }
        }
    }

    func perform(_ action: HostUpdateAction, now: Bool = false) async {
        switch action {
        case .download, .retryDownload: await install(.whenIdle)
        case .restart: await install(now ? .now : .whenIdle)
        case .cancelWait: await install(.cancel)
        }
    }

    private func install(_ when: HostUpdateInstallWhen) async {
        let old = status?.current ?? ""
        let expected = status?.latest ?? ""
        let wasReady = status?.state == .ready
        await run {
            if let status = try await self.service.installUpdate(when) {
                self.status = status
                if wasReady, status.state == .checking { self.installAgain = true }
            } else {
                await self.waitForRestart(old: old, expected: expected)
            }
        }
    }

    private func waitForRestart(old: String, expected: String) async {
        restart = .waiting(sawDown: false)
        do {
            let outcome = try await HostRestartTracker.wait(oldVersion: old, expected: expected, interval: service.pollInterval,
                                                            timeout: .seconds(240), fetch: { [service] in try await service.hostVersion() },
                                                            progress: { outcome in
                                                                if case .waiting(let down) = outcome {
                                                                    await MainActor.run { self.restart = .waiting(sawDown: down) }
                                                                }
                                                            })
            if case .back(let version, let upgraded) = outcome { restart = .done(version: version, upgraded: upgraded) }
            notes = nil
            await load(fresh: false)
        } catch {
            let error = MagpieError.from(error)
            restart = error == .cancelled ? .idle : .failed("等了 4 分钟主机还没回来。请在 Mac 上确认 magpie 是否已经重新打开（更新时 Mac 可能弹出管理员密码框）。")
        }
    }

    func dismissRestart() { restart = .idle }

    private func run(_ operation: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await operation()
        } catch {
            let error = MagpieError.from(error)
            if error != .cancelled { actionError = error }
        }
    }
}

/// 「管理 › 主机更新」：主机上 magpie 的当前版本、最新版本、中文更新说明，以及下载 / 重启安装。
struct HostUpdateView: View {
    @State private var model: HostUpdateModel
    @State private var confirming: HostUpdateAction?
    @State private var confirmNow = false

    init(service: any HostToolsServing) {
        _model = State(initialValue: HostUpdateModel(service: service))
    }

    var body: some View {
        List {
            restartSection
            versionSection
            if let warning = model.compatibility?.warning {
                Section {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("update.compat")
                }
            }
            notesSection
        }
        .navigationTitle("主机更新")
        .refreshable { await model.load(fresh: true) }
        .task { await model.load(fresh: true) }
        .task(id: model.status?.isWorking == true && !model.isRestarting) { await model.poll() }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible) {
            if let action = confirming {
                Button(action == .restart && model.status?.isBusy == true ? "等空闲后重启" : action.title) {
                    Task { await model.perform(action) }
                }
                .accessibilityIdentifier("update.confirm")
                if action == .restart, model.status?.isBusy == true {
                    Button("立即重启", role: .destructive) { Task { await model.perform(action, now: true) } }
                        .accessibilityIdentifier("update.confirm.now")
                }
                Button("取消", role: .cancel) {}
            }
        } message: {
            Text(confirmMessage)
        }
        .alert(model.actionError?.title ?? "", isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
            Button("好") { model.actionError = nil }
        } message: {
            Text([model.actionError?.message, model.actionError?.hint].compactMap { $0 }.joined(separator: "\n"))
        }
    }

    private var confirmTitle: String {
        switch confirming {
        case .download, .retryDownload: "在主机上下载 \(HostToolsFormat.version(model.status?.latest ?? ""))？"
        case .restart: "重启主机上的 magpie？"
        case .cancelWait: "取消等待重启？"
        case nil: ""
        }
    }

    private var confirmMessage: String {
        switch confirming {
        case .download, .retryDownload:
            return "magpie 会在 Mac 上下载新版本，下载期间照常工作。下载好之后需要再点「重启并安装」。"
        case .restart:
            var text = "magpie 会退出并以新版本重新打开，期间（通常不到一分钟）所有页面都连不上主机，App 会自动等它回来。"
            if let warning = model.status?.restartWarning { text += "\n\n" + warning }
            text += "\n\nMac 可能会弹出管理员密码框，需要在 Mac 上确认。"
            return text
        case .cancelWait:
            return "新版本保留在主机上，之后可以再点「重启并安装」。"
        case nil:
            return ""
        }
    }

    @ViewBuilder
    private var restartSection: some View {
        switch model.restart {
        case .idle:
            EmptyView()
        case .waiting(let down):
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(down ? "主机正在重启…" : "正在让主机重启…")
                        Text("magpie 回来后这里会自动更新。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("update.restarting")
            }
        case .done(let version, let upgraded):
            Section {
                Label(upgraded ? "已更新到 \(HostToolsFormat.version(version))" : "主机已回来，但版本还是 \(HostToolsFormat.version(version))",
                      systemImage: upgraded ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(upgraded ? .green : .orange)
                    .accessibilityIdentifier("update.done")
                if !upgraded {
                    Text("安装可能没有成功（例如 Mac 上的管理员密码框被取消）。可以再试一次，或在 Mac 上打开 magpie 查看。").font(.footnote)
                }
                Button("好") { model.dismissRestart() }
            }
        case .failed(let message):
            Section {
                Label(message, systemImage: "wifi.exclamationmark").font(.footnote).foregroundStyle(.orange)
                Button("再看一次") { Task { model.dismissRestart(); await model.load(fresh: false) } }
            }
        }
    }

    @ViewBuilder
    private var versionSection: some View {
        Section {
            if let status = model.status {
                LabeledContent("当前版本", value: HostToolsFormat.version(status.current))
                    .accessibilityIdentifier("update.current")
                if !status.latest.isEmpty {
                    LabeledContent("最新版本", value: HostToolsFormat.version(status.latest))
                        .accessibilityIdentifier("update.latest")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(status.summary).font(.footnote)
                    if let progress = status.progress {
                        ProgressView(value: progress).accessibilityIdentifier("update.progress")
                    } else if status.state == .checking || status.state == .downloading {
                        ProgressView().frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("update.summary")
                if status.state == .available, let command = status.packaged?.command, !command.isEmpty {
                    Text(command).font(.callout.monospaced()).textSelection(.enabled)
                }
                if status.state == .available || status.state == .source, let url = URL(string: status.url), !status.url.isEmpty {
                    Link("在浏览器里查看发布页", destination: url)
                }
                if let action = status.action {
                    Button {
                        confirming = action
                    } label: {
                        Label(action.title, systemImage: action == .restart ? "arrow.clockwise.circle.fill" : action == .cancelWait ? "xmark.circle" : "arrow.down.circle.fill")
                    }
                    .disabled(model.busy || model.isRestarting)
                    .accessibilityIdentifier("update.action")
                }
            } else if let error = model.loadError {
                VStack(alignment: .leading, spacing: 4) {
                    Label(error.title, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(error.message).font(.footnote)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("update.error")
            } else {
                HStack { ProgressView(); Text("正在读取…").foregroundStyle(.secondary) }
            }
            Button {
                Task { await model.check() }
            } label: {
                Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(model.busy || model.isRestarting || model.status?.state == .checking)
            .accessibilityIdentifier("update.check")
        } header: {
            Text("主机上的 magpie")
        } footer: {
            Text("更新的是 Mac 上的 magpie，不是这个 App。")
        }
    }

    @ViewBuilder
    private var notesSection: some View {
        if let notes = model.notes, model.status?.hasUpdate == true {
            if notes.releases.isEmpty {
                if !notes.error.isEmpty {
                    Section("更新说明") { Text("读不到更新说明：\(notes.error)").font(.footnote).foregroundStyle(.secondary) }
                }
            } else {
                ForEach(notes.releases) { release in
                    Section(HostToolsFormat.version(release.version)) {
                        ReleaseNotesText(markdown: release.notes)
                    }
                }
                .accessibilityIdentifier("update.notes")
            }
        }
    }
}

/// 发布说明：标题、列表、段落；行内的粗体 / 代码 / 链接按 Markdown 显示。
struct ReleaseNotesText: View {
    let markdown: String

    var body: some View {
        let lines = ReleaseNotesFormat.lines(markdown)
        VStack(alignment: .leading, spacing: 6) {
            if lines.isEmpty { Text("这个版本没有写说明。").foregroundStyle(.secondary) }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                switch line {
                case .heading(let text):
                    Text(inline(text)).font(.subheadline.weight(.semibold)).padding(.top, 2)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(inline(text))
                    }
                    .font(.footnote)
                case .text(let text):
                    Text(inline(text)).font(.footnote)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
