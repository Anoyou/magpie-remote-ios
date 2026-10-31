import Foundation
import MagpieRemoteCore

/// 「Agent 会话记录」访问主机的方式。真实实现走 `WebClient`（magpie Web 管理接口 3430），fixture 实现只改内存。
protocol AgentSessionsServing: Sendable {
    func overview(agent: String?) async throws -> SessionsOverview
    func transcript(agent: String, id: String, sub: String?) async throws -> SessionTranscript
    func search(agent: String, query: String) async throws -> SessionSearchResult
    func delete(agent: String, ids: [String]) async throws -> SessionDeleteResult
    func markdown(agent: String, id: String) async throws -> SessionMarkdown
    /// 存到 Mac 的「下载」文件夹，返回主机上的路径。
    func exportOnHost(agent: String, id: String) async throws -> String
    func allowReads(_ agents: [String: Bool]) async throws -> SessionReads
}

enum AgentSessionsServices {
    /// 跟「管理」页用同一台主机、同一把 Web 密钥。
    static func make(from service: (any ManageServing)?) -> (any AgentSessionsServing)? {
        if let live = service as? LiveManageService {
            // 第一次读会话文件可能要很久；搜索在主机上最多读 8 秒。
            return LiveAgentSessionsService(web: WebClient(baseURL: live.web.baseURL, key: live.web.key, timeout: 60))
        }
        if service is FixtureManageService { return FixtureAgentSessionsService.shared }
        return nil
    }
}

struct LiveAgentSessionsService: AgentSessionsServing {
    let web: WebClient

    func overview(agent: String?) async throws -> SessionsOverview { try await web.sessionsOverview(agent: agent) }
    func transcript(agent: String, id: String, sub: String?) async throws -> SessionTranscript {
        try await web.sessionTranscript(agent: agent, id: id, sub: sub)
    }
    func search(agent: String, query: String) async throws -> SessionSearchResult { try await web.searchSessions(agent: agent, query: query) }
    func delete(agent: String, ids: [String]) async throws -> SessionDeleteResult { try await web.deleteSessions(agent: agent, ids: ids) }
    func markdown(agent: String, id: String) async throws -> SessionMarkdown { try await web.sessionMarkdown(agent: agent, id: id) }
    func exportOnHost(agent: String, id: String) async throws -> String { try await web.exportSessionOnHost(agent: agent, id: id) }
    func allowReads(_ agents: [String: Bool]) async throws -> SessionReads { try await web.setSessionReads(agents) }
}

/// fixture 模式：两个 Agent 的示例会话，删除只在这次运行里生效。
actor FixtureAgentSessionsService: AgentSessionsServing {
    static let shared = FixtureAgentSessionsService()

    private var sessions: [WebJSON]

    init() {
        func session(_ agent: String, _ id: String, _ title: String, cwd: String, last: String, model: String,
                     messages: Int, size: Int, cost: Double, tokens: Int) -> WebJSON {
            ["agent": .string(agent), "id": .string(id), "title": .string(title), "cwd": .string(cwd),
             "start": .string(last), "last": .string(last),
             "models": [["model": .string(model), "input": .int(Int64(tokens / 4)), "output": .int(Int64(tokens / 4)),
                         "cache_read": .int(Int64(tokens / 2)), "cache_write": 0, "cost": .double(cost), "priced": true]],
             "input": .int(Int64(tokens / 4)), "output": .int(Int64(tokens / 4)), "cache_read": .int(Int64(tokens / 2)), "cache_write": 0,
             "cost": .double(cost), "unpriced": 0, "transcript": true, "size": .int(Int64(size)), "messages": .int(Int64(messages)),
             "files": 1, "deletable": true, "path": .string("~/.\(agent)/sessions/\(id).jsonl")]
        }
        sessions = [
            session("claude", "fixture-claude-1", "修复登录页的样式问题", cwd: "~/code/demo-app", last: "2026-10-31T10:40:00+08:00",
                    model: "claude-sonnet-4-5", messages: 86, size: 1_288_490, cost: 0.42, tokens: 68_900),
            session("claude", "fixture-claude-2", "写一个周报模板", cwd: "~/code/notes", last: "2026-10-30T21:05:00+08:00",
                    model: "claude-haiku-4-5", messages: 12, size: 48_000, cost: 0.01, tokens: 9_000),
            session("claude", "fixture-claude-3", "给 README 加安装说明", cwd: "~/code/demo-app", last: "2026-10-20T15:00:00+08:00",
                    model: "claude-sonnet-4-5", messages: 30, size: 260_000, cost: 0.12, tokens: 21_000),
            session("codex", "fixture-codex-1", "把单元测试迁到新框架", cwd: "~/code/server", last: "2026-10-31T08:00:00+08:00",
                    model: "gpt-5", messages: 54, size: 820_000, cost: 0.31, tokens: 51_000),
            session("codex", "fixture-codex-2", "解释这个正则表达式", cwd: "~/code/server", last: "2026-10-25T12:00:00+08:00",
                    model: "gpt-5-mini", messages: 4, size: 6_000, cost: 0.002, tokens: 1_200),
        ]
    }

    private func pause() async throws { try await Task.sleep(for: .milliseconds(80)) }

    private static let names = ["claude": "Claude Code", "codex": "Codex"]

    func overview(agent: String?) async throws -> SessionsOverview {
        try await pause()
        let counts = Dictionary(grouping: sessions, by: { $0["agent"]?.string ?? "" }).mapValues(\.count)
        let agents = counts.keys.sorted { (counts[$0] ?? 0, $1) > (counts[$1] ?? 0, $0) }
        let chosen = agent.flatMap { counts[$0] != nil ? $0 : nil } ?? agents.first ?? ""
        let list: [WebJSON] = agents.map { id in
            ["agent": .string(id), "name": .string(Self.names[id] ?? id), "icon": .string(id), "count": .int(Int64(counts[id] ?? 0)), "deletable": true]
        }
        return SessionsOverview(json: [
            "agents": .array(list), "agent": .string(chosen),
            "sessions": .array(sessions.filter { $0["agent"]?.string == chosen }),
            "trash": [], "recording": false,
            "reads": ["asked": true, "all": true, "found": .array(list.map { ["agent": $0["agent"] ?? "", "name": $0["name"] ?? "", "on": true] })],
        ])
    }

    func transcript(agent: String, id: String, sub: String?) async throws -> SessionTranscript {
        try await pause()
        let title = sessions.first { $0["id"]?.string == id }?["title"]?.string ?? "示例会话"
        return SessionTranscript(json: ["parts": [
            ["role": "user", "kind": "text", "text": .string(title + "。")],
            ["role": "assistant", "kind": "thinking", "text": "先看看相关文件。", "model": "claude-sonnet-4-5"],
            ["role": "assistant", "kind": "tool_use", "name": "Read", "text": #"{"file_path":"src/login.css"}"#],
            ["role": "tool", "kind": "tool_result", "name": "Read", "text": ".button { color: #222; }"],
            ["role": "assistant", "kind": "text", "text": "示例回答：已经改好了，按钮颜色改为跟随系统的语义色。", "model": "claude-sonnet-4-5"],
            ["role": "user", "kind": "text", "text": "谢谢"],
        ]])
    }

    func search(agent: String, query: String) async throws -> SessionSearchResult {
        try await pause()
        let hits: [WebJSON] = sessions.compactMap { session in
            guard session["agent"]?.string == agent, let title = session["title"]?.string,
                  let range = title.range(of: query, options: .caseInsensitive) else { return nil }
            return ["id": session["id"] ?? "", "role": "user", "kind": "text", "before": .string(String(title[..<range.lowerBound])),
                    "match": .string(String(title[range])), "after": .string(String(title[range.upperBound...]))]
        }
        let total = sessions.filter { $0["agent"]?.string == agent }.count
        return SessionSearchResult(json: ["hits": .array(hits), "searched": .int(Int64(total)), "total": .int(Int64(total))])
    }

    func delete(agent: String, ids: [String]) async throws -> SessionDeleteResult {
        try await pause()
        sessions.removeAll { $0["agent"]?.string == agent && ids.contains($0["id"]?.string ?? "") }
        return SessionDeleteResult(json: ["deleted": .strings(ids), "refused": []])
    }

    func markdown(agent: String, id: String) async throws -> SessionMarkdown {
        try await pause()
        let title = sessions.first { $0["id"]?.string == id }?["title"]?.string ?? "示例会话"
        return SessionMarkdown(filename: SessionMarkdown.filename(contentDisposition: nil, agent: agent, id: id),
                               text: "# \(title)\n\n- **Agent:** \(Self.names[agent] ?? agent)\n- **Session ID:** `\(id)`\n\n## User\n\n\(title)。\n")
    }

    func exportOnHost(agent: String, id: String) async throws -> String {
        try await pause()
        return "~/Downloads/" + SessionMarkdown.filename(contentDisposition: nil, agent: agent, id: id)
    }

    func allowReads(_ agents: [String: Bool]) async throws -> SessionReads {
        SessionReads(asked: true, all: false, found: agents.map { SessionReads.Agent(id: $0.key, name: Self.names[$0.key] ?? $0.key, on: $0.value) })
    }
}
