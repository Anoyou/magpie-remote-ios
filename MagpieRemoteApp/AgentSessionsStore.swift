import Foundation
import Observation
import MagpieRemoteCore

/// 「Agent 会话记录」的数据与操作：列表、筛选、按内容搜索、删除、导出。
@MainActor
@Observable
final class AgentSessionsStore {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(MagpieError)
    }

    enum SearchScope: String, CaseIterable, Identifiable {
        case titles, content
        var id: String { rawValue }
        var title: String { self == .titles ? "标题与目录" : "对话内容" }
    }

    let service: any AgentSessionsServing
    private(set) var phase: Phase = .loading
    private(set) var overview: SessionsOverview?
    /// 正在看的 Agent（为空时由主机挑会话最多的）。
    private(set) var agent: String = ""
    var query = ""
    var scope: SearchScope = .titles
    var sort: SessionSort = .recent
    /// 按对话内容搜索的结果（只对 `searchedQuery` 有效）。
    private(set) var contentResult: SessionSearchResult?
    private(set) var searchedQuery = ""
    private(set) var searching = false
    private(set) var busy = false
    var actionError: MagpieError?
    /// 操作完成后的提示（例如导出到 Mac 的路径）。
    var notice: String?
    /// 当前显示中的会话页面（最后一个负责弹窗）。
    var presenters: [String] = []

    init(service: any AgentSessionsServing) {
        self.service = service
    }

    var agents: [SessionAgent] { overview?.agents ?? [] }
    var currentAgent: SessionAgent? { overview?.currentAgent }
    var blockedReads: [SessionReads.Agent] {
        guard let reads = overview?.reads else { return [] }
        return reads.blocked
    }

    /// 按搜索与排序处理后的列表。
    var visibleSessions: [AgentSession] {
        let all = overview?.sessions ?? []
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [AgentSession]
        switch scope {
        case .titles:
            filtered = all.filter { $0.matches(trimmed) }
        case .content:
            if trimmed.isEmpty {
                filtered = all
            } else if let result = contentResult, searchedQuery == trimmed {
                let ids = Set(result.hits.map(\.id))
                filtered = all.filter { ids.contains($0.sessionID) }
            } else {
                filtered = []
            }
        }
        return sort.sorted(filtered)
    }

    func hit(for session: AgentSession) -> SessionSearchHit? {
        guard scope == .content, searchedQuery == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return contentResult?.hit(for: session.sessionID)
    }

    func load(agent: String? = nil) async {
        if overview == nil { phase = .loading }
        do {
            let overview = try await service.overview(agent: agent ?? (self.agent.isEmpty ? nil : self.agent))
            self.overview = overview
            self.agent = overview.agent
            phase = .ready
        } catch {
            let error = MagpieError.from(error)
            if error == .cancelled { return }
            if overview == nil { phase = .failed(error) } else { actionError = error }
        }
    }

    func select(agent: String) async {
        guard agent != self.agent else { return }
        self.agent = agent
        contentResult = nil
        searchedQuery = ""
        await load(agent: agent)
    }

    /// 按对话内容搜索（magpie 至少要 2 个字）。
    func searchContent() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard scope == .content, !agent.isEmpty else { return }
        guard SessionSearchResult.canSearch(text) else {
            contentResult = nil
            searchedQuery = ""
            return
        }
        guard text != searchedQuery || contentResult == nil else { return }
        searching = true
        defer { searching = false }
        do {
            let result = try await service.search(agent: agent, query: text)
            contentResult = result
            searchedQuery = text
        } catch {
            let error = MagpieError.from(error)
            if error != .cancelled { actionError = error }
        }
    }

    /// 移到 magpie 回收站。返回是否删掉了。
    @discardableResult
    func delete(_ session: AgentSession) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            let result = try await service.delete(agent: session.agent, ids: [session.sessionID])
            if let message = result.failureMessage, !result.deleted.contains(session.sessionID) {
                actionError = .webRejected(message: message, code: nil)
                return false
            }
            if var overview {
                overview.sessions.removeAll { $0.id == session.id }
                if let index = overview.agents.firstIndex(where: { $0.id == session.agent }) {
                    overview.agents[index].count = max(0, overview.agents[index].count - 1)
                }
                self.overview = overview
            }
            await load()
            return true
        } catch {
            let error = MagpieError.from(error)
            if error != .cancelled { actionError = error }
            return false
        }
    }

    /// 取回 Markdown 并写进临时文件，交给系统分享面板。
    func markdownFile(for session: AgentSession) async -> URL? {
        busy = true
        defer { busy = false }
        do {
            let markdown = try await service.markdown(agent: session.agent, id: session.sessionID)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-export", isDirectory: true)
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(markdown.filename)
            try Data(markdown.text.utf8).write(to: url, options: .atomic)
            return url
        } catch {
            let error = MagpieError.from(error)
            if error != .cancelled { actionError = error }
            return nil
        }
    }

    func exportOnHost(_ session: AgentSession) async {
        busy = true
        defer { busy = false }
        do {
            let path = try await service.exportOnHost(agent: session.agent, id: session.sessionID)
            notice = path.isEmpty ? "已保存到 Mac 的「下载」文件夹。" : "已保存到 Mac：\(path)"
        } catch {
            let error = MagpieError.from(error)
            if error != .cancelled { actionError = error }
        }
    }

    /// 允许 magpie 读取这些 Agent 的会话（只改列出的，其它不变）。
    func allowReads(_ ids: [String]) async {
        busy = true
        defer { busy = false }
        do {
            _ = try await service.allowReads(Dictionary(uniqueKeysWithValues: ids.map { ($0, true) }))
            await load()
        } catch {
            let error = MagpieError.from(error)
            if error != .cancelled { actionError = error }
        }
    }

    // MARK: 回收站（官方会话页的 Trash）

    var trash: [TrashedSession] { overview?.trash ?? [] }

    /// 把回收站里的一个会话放回原处。
    func restore(_ item: TrashedSession) async {
        busy = true
        defer { busy = false }
        do {
            let title = try await service.restore(key: item.key)
            notice = "已恢复「\(title.isEmpty ? item.displayTitle : title)」"
            await load()
        } catch {
            let error = MagpieError.from(error)
            if error != .cancelled { actionError = error }
        }
    }

    /// 彻底删除（`items` 为空 = 清空回收站）。调用方先确认。
    func purge(_ items: [TrashedSession]) async {
        busy = true
        defer { busy = false }
        do {
            let result = try await service.purge(keys: items.map(\.key), all: items.isEmpty)
            if let message = result.failureMessage { actionError = .webRejected(message: message, code: nil) }
            else { notice = result.purged.count == 1 ? "已彻底删除" : "已彻底删除 \(result.purged.count) 个会话" }
            await load()
        } catch {
            let error = MagpieError.from(error)
            if error != .cancelled { actionError = error }
        }
    }

    func transcript(for session: AgentSession, sub: String? = nil) async throws -> SessionTranscript {
        try await service.transcript(agent: session.agent, id: session.sessionID, sub: sub)
    }
}
