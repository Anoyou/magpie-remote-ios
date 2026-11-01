import Foundation

/// fixture 模式（UI 测试与演示）里「用量 › 请求 / 会话 / 上下文」用到的网页接口示例数据：
/// 热力图、请求内容、/api/sessions、/api/sessions/stats、/api/sessions/overview、/api/context。
/// 日期都围绕「今天」生成，形状照 magpie 源码的 json 标签。名字、目录都是假的。
public struct UsageTabsFixtureData: Sendable {
    public let now: Date
    let calendar: Calendar

    public init(now: Date = Date()) {
        self.now = now
        self.calendar = Calendar(identifier: .gregorian)
    }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now)) ?? now
    }

    private func key(_ offset: Int) -> String { UsageHeatmap.key(day(offset)) }

    private func time(_ offset: Int, hour: Int) -> Date {
        min(calendar.date(byAdding: .hour, value: hour, to: day(offset)) ?? now, now)
    }

    private func stamp(_ offset: Int, hour: Int) -> WebJSON { .string(UsageTimestamp(date: time(offset, hour: hour)).raw) }

    private func iso(_ offset: Int, hour: Int) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: time(offset, hour: hour))
    }

    private static func int(_ n: Int) -> WebJSON { .int(Int64(n)) }

    // MARK: 请求 › 热力图与内容

    /// 最近 53 周：大约一半的日子有请求，越近越多。
    public func heatmap() -> WebJSON {
        let weekday = (calendar.component(.weekday, from: now) + 5) % 7
        let span = 7 * 52 + weekday
        var seed: UInt64 = 0xC0FFEE
        var days: [WebJSON] = []
        for offset in stride(from: span, through: 0, by: -1) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let r = Int((seed >> 33) % 100)
            guard r < 30 + (span - offset) * 40 / span || offset == 0 else { continue }
            let calls = 1 + r / 3
            let entry: [String: WebJSON] = ["date": .string(key(offset)), "calls": Self.int(calls),
                                            "tokens": Self.int(calls * 21_000 + r * 900), "cost": .double(Double(calls) * 0.037)]
            days.append(.object(entry))
        }
        return .object(["from": .string(key(span)), "to": .string(key(0)), "days": .array(days)])
    }

    /// 一条请求的内容：Claude Code 的可以读到，其它 Agent 的读不到。
    public func requestContent(agent: String) -> WebJSON {
        guard agent == "claude" else { return ["found": false, "why": "agent", "input": [], "output": []] }
        let input: WebJSON = [["role": "user", "kind": "text", "text": "把登录按钮改成跟随系统的颜色。"],
                              ["role": "tool", "kind": "tool_result", "name": "Read", "text": ".button { color: #222; }"]]
        let output: WebJSON = [["role": "assistant", "kind": "thinking", "text": "先看看样式文件。", "model": "claude-sonnet-4-6"],
                               ["role": "assistant", "kind": "text", "text": "示例回答：改好了，按钮颜色改为跟随系统的语义色。", "model": "claude-sonnet-4-6"]]
        return ["found": true, "model": "claude-sonnet-4-6", "input": input, "output": output]
    }

    // MARK: 会话

    private struct Sample {
        var agent: String, id: String, title: String, cwd: String, model: String, ago: Int, hour: Int
        var input: Int, output: Int, cost: Double, active: Int, messages: Int
    }

    private let samples: [Sample] = [
        .init(agent: "claude", id: "fixture-claude-1", title: "修复登录页的样式问题", cwd: "~/code/demo-app", model: "claude-sonnet-4-6", ago: 0, hour: 10, input: 52_000, output: 16_900, cost: 0.42, active: 3_100, messages: 86),
        .init(agent: "codex", id: "fixture-codex-1", title: "把单元测试迁到新框架", cwd: "~/code/server", model: "gpt-5", ago: 1, hour: 8, input: 38_000, output: 13_000, cost: 0.31, active: 2_400, messages: 54),
        .init(agent: "claude", id: "fixture-claude-2", title: "写一个周报模板", cwd: "~/code/notes", model: "claude-haiku-4-5", ago: 2, hour: 21, input: 7_000, output: 2_000, cost: 0.01, active: 600, messages: 12),
        .init(agent: "codex", id: "fixture-codex-2", title: "解释这个正则表达式", cwd: "~/code/server", model: "gpt-5-mini", ago: 6, hour: 12, input: 900, output: 300, cost: 0.002, active: 120, messages: 4),
        .init(agent: "claude", id: "fixture-claude-3", title: "给 README 加安装说明", cwd: "~/code/demo-app", model: "claude-sonnet-4-6", ago: 11, hour: 15, input: 16_000, output: 5_000, cost: 0.12, active: 1_300, messages: 30),
    ]

    private static let names = ["claude": "Claude Code", "codex": "Codex"]

    private func inRange(_ s: Sample, _ range: SessionRange) -> Bool { range.days == 0 || s.ago < range.days }

    private func matches(_ s: Sample, _ filter: SessionFilter) -> Bool {
        (filter.agent == nil || s.agent == filter.agent) && (filter.model == nil || s.model == filter.model)
            && (filter.folder == nil || s.cwd == filter.folder)
    }

    private func firstOffset(_ range: SessionRange) -> Int {
        range.days == 0 ? (samples.map(\.ago).max() ?? 0) : range.days - 1
    }

    private func modelShare(_ s: Sample) -> WebJSON {
        .object(["model": .string(s.model), "input": Self.int(s.input), "output": Self.int(s.output),
                 "cache_read": Self.int(s.input * 3), "cache_write": 0, "cost": .double(s.cost), "priced": true])
    }

    /// `GET /api/sessions`。
    public func sessionList() -> WebJSON {
        let list: [WebJSON] = samples.map { s in
            let row: [String: WebJSON] = [
                "agent": .string(s.agent), "id": .string(s.id), "title": .string(s.title), "cwd": .string(s.cwd),
                "start": stamp(s.ago, hour: s.hour - 1), "last": stamp(s.ago, hour: s.hour), "models": .array([modelShare(s)]),
                "input": Self.int(s.input), "output": Self.int(s.output), "cache_read": Self.int(s.input * 3), "cache_write": 0,
                "cost": .double(s.cost), "unpriced": 0, "transcript": true, "path": .string("~/.\(s.agent)/sessions/\(s.id).jsonl"),
                "resume": .string("\(s.agent) --resume \(s.id)"), "name": .string(Self.names[s.agent] ?? s.agent), "icon": .string(s.agent),
            ]
            return .object(row)
        }
        return .object(["sessions": .array(list), "terminal": false, "dirs": ["~/.claude/projects", "~/.codex/sessions"]])
    }

    /// `GET /api/sessions/stats?days=`。
    public func sessionStats(_ range: SessionRange) -> WebJSON {
        let first = firstOffset(range)
        var days: [WebJSON] = []
        for offset in stride(from: first, through: 0, by: -1) {
            let today = samples.filter { $0.ago == offset && inRange($0, range) }
            guard !today.isEmpty else { continue }
            let usage: [WebJSON] = today.map { s in
                .object(["agent": .string(s.agent), "cwd": .string(s.cwd), "model": .string(s.model), "input": Self.int(s.input),
                         "output": Self.int(s.output), "cache_read": Self.int(s.input * 3), "cache_write": 0,
                         "cost": .double(s.cost), "priced": true])
            }
            let active: [WebJSON] = today.map { s in
                var hours = Array(repeating: WebJSON.int(0), count: 24)
                hours[max(0, s.hour - 1)] = Self.int(s.active / 2)
                hours[s.hour] = Self.int(s.active - s.active / 2)
                return .object(["agent": .string(s.agent), "cwd": .string(s.cwd), "seconds": Self.int(s.active), "hours": .array(hours)])
            }
            days.append(.object(["date": .string(key(offset)), "usage": .array(usage), "active": .array(active)]))
        }
        let keys = samples.filter { inRange($0, range) }.map { WebJSON.string($0.agent + ":" + $0.id) }
        return .object(["from": .string(key(first)), "to": .string(key(0)), "days": .array(days), "keys": .array(keys),
                        "agents": ["claude": "Claude Code", "codex": "Codex"]])
    }

    private func summary(_ s: Sample) -> WebJSON {
        .object(["key": .string(s.agent + ":" + s.id), "agent": .string(s.agent), "id": .string(s.id), "cwd": .string(s.cwd),
                 "title": .string(s.title), "last": stamp(s.ago, hour: s.hour), "input": Self.int(s.input), "output": Self.int(s.output),
                 "cache_read": Self.int(s.input * 3), "cache_write": 0, "cost": .double(s.cost), "priced": true,
                 "active": Self.int(s.active), "models": .strings([s.model]), "days": [0],
                 "prompts": Self.int(s.messages / 3), "replies": Self.int(s.messages - s.messages / 3), "tool_calls": Self.int(s.messages / 2)])
    }

    private func shape(_ picked: [Sample], _ edges: [Int], _ value: (Sample) -> Int) -> WebJSON {
        var counts = Array(repeating: 0, count: edges.count)
        for s in picked {
            if let i = edges.lastIndex(where: { value(s) >= $0 }) { counts[i] += 1 }
        }
        return .object(["edges": .array(edges.map(Self.int)), "counts": .array(counts.map(Self.int)), "total": Self.int(counts.reduce(0, +))])
    }

    /// `GET /api/sessions/overview`。
    public func sessionOverview(_ range: SessionRange, filter: SessionFilter) -> WebJSON {
        let first = firstOffset(range)
        let picked = samples.filter { inRange($0, range) && matches($0, filter) }
        let spent = picked.map { $0.input + $0.output }.sorted()
        func perDay(_ value: (Sample) -> Int) -> WebJSON {
            .array(stride(from: first, through: 0, by: -1).map { offset in
                Self.int(picked.filter { $0.ago == offset }.reduce(0) { $0 + value($1) })
            })
        }
        let calls = picked.reduce(0) { $0 + $1.messages / 2 }
        func tool(_ name: String, _ category: String, _ share: Double) -> WebJSON {
            .object(["name": .string(name), "category": .string(category), "calls": Self.int(Int(Double(calls) * share)),
                     "sessions": Self.int(picked.count)])
        }
        let top: [String: WebJSON] = [
            "tokens": .array(picked.sorted { $0.input + $0.output > $1.input + $1.output }.prefix(8).map(summary)),
            "cost": .array(picked.sorted { $0.cost > $1.cost }.prefix(8).map(summary)),
            "active": .array(picked.sorted { $0.active > $1.active }.prefix(8).map(summary)),
        ]
        let shapes: [String: WebJSON] = [
            "messages": shape(picked, [1, 6, 16, 31, 61, 121]) { $0.messages },
            "minutes": shape(picked, [1, 6, 16, 31, 61, 121]) { $0.active / 60 },
            "autonomy": shape(picked, [0, 1, 3, 6, 11, 21]) { $0.messages / 6 },
        ]
        let toolTop: [WebJSON] = calls > 0 ? [tool("Read", "Read", 0.4), tool("Bash", "Shell", 0.3), tool("Edit", "Edit", 0.2), tool("WebSearch", "Web", 0.1)] : []
        let toolCats: [WebJSON] = calls > 0 ? [tool("Read", "", 0.4), tool("Shell", "", 0.3), tool("Edit", "", 0.2), tool("Web", "", 0.1)] : []
        let tools: [String: WebJSON] = ["calls": Self.int(calls), "sessions": Self.int(picked.count), "top": .array(toolTop),
                                        "categories": .array(toolCats), "weeks": []]
        var skillTop: [WebJSON] = []
        if !picked.isEmpty {
            skillTop.append(.object(["name": "pdf", "calls": 3, "sessions": 1, "last": .string(key(1)), "agents": ["claude": 3],
                                     "projects": [["name": "demo-app", "calls": 3, "sessions": 1]]]))
            skillTop.append(.object(["name": "review", "calls": 2, "sessions": 2, "last": .string(key(0)),
                                     "agents": ["claude": 1, "codex": 1], "projects": []]))
        }
        let skills: [String: WebJSON] = ["calls": Self.int(picked.isEmpty ? 0 : 5), "count": Self.int(skillTop.count), "top": .array(skillTop)]
        return .object([
            "count": Self.int(picked.count),
            "median": Self.int(spent.isEmpty ? 0 : spent[spent.count / 2]),
            "p90": Self.int(spent.isEmpty ? 0 : spent[min(spent.count - 1, spent.count * 9 / 10)]),
            "days": perDay { _ in 1 }, "messages": perDay(\.messages), "output": perDay(\.output),
            "top": .object(top), "shape": .object(shapes), "tools": .object(tools), "skills": .object(skills),
        ])
    }

    // MARK: 上下文

    /// `GET /api/context?days=`。
    public func context(days: Int) -> WebJSON {
        var text = Self.contextTemplate.replacingOccurrences(of: "$DAYS", with: String(days))
        for (name, offset, hour) in [("$T0_9", 0, 9), ("$T0_10", 0, 10), ("$T1_7", 1, 7), ("$T1_8", 1, 8)] {
            text = text.replacingOccurrences(of: name, with: iso(offset, hour: hour))
        }
        return (try? WebJSON.decode(Data(text.utf8))) ?? .object(["days": Self.int(days), "agents": [], "sessions": []])
    }

    private static let contextTemplate = #"""
    {"days": $DAYS,
     "agents": [
      {"agent": "claude", "requests": 120, "sessions": 4, "errors": 2, "calls": 124, "median": 52000, "p90": 98000,
       "baseline": 21000, "window": 200000, "cache": 0.86, "growth": 1800, "peakFill": 0.71, "compacts": 1,
       "shares": {"system": 0.05, "tools": 0.22, "memory": 0.06, "results": 0.18, "chat": 0.49}, "mcp": 9000, "score": 78,
       "scores": [{"key": "cache", "points": 38, "most": 40}, {"key": "lean", "points": 12, "most": 20},
                  {"key": "pace", "points": 16, "most": 20}, {"key": "reliable", "points": 12, "most": 20}],
       "tags": [{"key": "cache-friendly", "tone": "good", "value": 0.86}, {"key": "mcp-heavy", "tone": "warn", "value": 9000},
                {"key": "compacts", "tone": "info", "value": 1}],
       "models": ["anthropic/claude-sonnet-4-6"], "latestId": 9123, "latestTime": "$T0_10"},
      {"agent": "codex", "requests": 40, "sessions": 2, "errors": 0, "calls": 40, "median": 31000, "p90": 62000,
       "baseline": 9000, "window": 272000, "cache": 0.64, "growth": 2600, "peakFill": 0.4, "compacts": 0,
       "shares": {"system": 0.08, "tools": 0.1, "results": 0.32, "chat": 0.5}, "mcp": 0, "score": 66,
       "scores": [{"key": "cache", "points": 28, "most": 40}, {"key": "lean", "points": 18, "most": 20},
                  {"key": "pace", "points": 0, "most": 20}, {"key": "reliable", "points": 20, "most": 20}],
       "tags": [{"key": "tool-heavy", "tone": "info", "value": 0.32}, {"key": "steady", "tone": "good"}],
       "models": ["openai/gpt-5"], "latestId": 9090, "latestTime": "$T1_8"}
     ],
     "sessions": [
      {"agent": "claude", "key": "5f0e7c1a-1", "title": "修复登录页的样式问题", "model": "anthropic/claude-sonnet-4-6",
       "first": "$T0_9", "last": "$T0_10", "requests": 14, "peak": 61000, "window": 200000, "compacts": 0, "latestId": 9123,
       "latest": {"window": 200000, "tokens": 61000, "counted": true, "turns": 14, "parts": [
         {"kind": "system", "tokens": 3000, "items": [{"name": "prompt", "tokens": 3000}]},
         {"kind": "tools", "tokens": 14000, "items": [{"name": "github", "tag": "mcp", "n": 24, "tokens": 9000}, {"name": "Bash", "tokens": 4000},
                                                     {"name": "", "tag": "more", "n": 6, "tokens": 1000}]},
         {"kind": "memory", "tokens": 4000, "items": [{"name": "~/code/demo-app/CLAUDE.md", "tag": "project", "tokens": 4000}]},
         {"kind": "results", "tokens": 10000, "items": [{"name": "Read", "tag": "read", "n": 5, "tokens": 10000}]},
         {"kind": "chat", "tokens": 30000, "items": [{"name": "14", "tag": "turn", "tokens": 2000}, {"name": "", "tag": "turns", "n": 13, "tokens": 28000}]}]},
       "points": [{"id": 9116, "time": "$T0_9", "tokens": 22000, "window": 200000, "cache": 20000},
                  {"id": 9118, "time": "$T0_9", "tokens": 33000, "window": 200000, "cache": 30000},
                  {"id": 9120, "time": "$T0_9", "tokens": 44000, "window": 200000, "cache": 41000},
                  {"id": 9123, "time": "$T0_10", "tokens": 61000, "window": 200000, "cache": 55000}]},
      {"agent": "codex", "key": "019a2b3c-4d5e", "title": "把单元测试迁到新框架", "model": "openai/gpt-5",
       "first": "$T1_7", "last": "$T1_8", "requests": 40, "peak": 250000, "window": 272000, "compacts": 2, "latest": null, "latestId": 9090,
       "points": [{"id": 9090, "time": "$T1_8", "tokens": 90000, "window": 272000, "cache_unknown": true}]}
     ]}
    """#
}
