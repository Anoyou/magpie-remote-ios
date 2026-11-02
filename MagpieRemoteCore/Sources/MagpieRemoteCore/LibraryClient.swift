import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// 资源库页的接口（internal/gui/library.go）。认证同其它 Web 接口：Cookie `magpie_web_<端口>`。
// 每个改动都是 `POST /api/library/{what}/{action}`，请求体是同一个无标签结构体（Go 解码时字段名不分大小写：
// name / old / agents / names / source / paths / server / hook / subagent / agent / id / values / on / how / replace
// + InstructionsChange 的 shared / extra / rewrite / texts / activate / create / rename / remove），
// 响应是改动后的整页（指令的改动只回指令那部分，part = "instructions"）。

/// 资源库的一个改动（`what/action`）。只列 App 用到的；路由与动作名都进了 contract/web-contract.json。
public enum LibraryAction: String, CaseIterable, Sendable {
    case instructionsSave = "instructions/save"
    case instructionsImport = "instructions/import"
    case serversSave = "servers/save"
    case serversAgents = "servers/agents"
    case serversHub = "servers/hub"
    case serversTools = "servers/tools"
    case serversAgentsAll = "servers/agents-all"
    case serversRemove = "servers/remove"
    case serversRemoveAll = "servers/remove-all"
    case serversImport = "servers/import"
    case serversRemoveFound = "servers/remove-found"
    case hooksSave = "hooks/save"
    case hooksAgents = "hooks/agents"
    case hooksRemove = "hooks/remove"
    case hooksRemoveAll = "hooks/remove-all"
    case subagentsSave = "subagents/save"
    case subagentsAgents = "subagents/agents"
    case subagentsRemove = "subagents/remove"
    case skillsInstall = "skills/install"
    case skillsUpdate = "skills/update"
    case skillsRemoveGone = "skills/remove-gone"
    case skillsUpdateAll = "skills/update-all"
    case skillsAgents = "skills/agents"
    case skillsHere = "skills/here"
    case skillsAgentsAll = "skills/agents-all"
    case skillsRemove = "skills/remove"
    case skillsRemoveAll = "skills/remove-all"
    case skillsAddNew = "skills/add-new"
    case skillsIgnoreNew = "skills/ignore-new"
    case skillsImport = "skills/import"
    case skillsImportAll = "skills/import-all"
    case skillsRemoveFound = "skills/remove-found"
    case skillsHandOver = "skills/hand-over"
    case skillsHow = "skills/how"
    case marketServer = "market/server"
    case marketSkill = "market/skill"
    case allSync = "all/sync"

    public var isInstructions: Bool { rawValue.hasPrefix("instructions/") }
}

/// 资源库请求体（照官方 client.js 发的字段）。
public enum LibraryRequests {
    /// 一行的 Agent 改了（servers / skills / hooks / subagents 的 agents）。
    public static func agents(_ name: String, _ agents: [String]) -> WebJSON { ["name": .string(name), "agents": .strings(agents)] }
    public static func name(_ name: String) -> WebJSON { ["name": .string(name)] }
    public static func names(_ names: [String]) -> WebJSON { ["names": .strings(names)] }
    /// 全部启用 / 全部关闭：这些 Agent 的每一项。
    public static func every(agents: [String], on: Bool) -> WebJSON { ["agents": .strings(agents), "on": .bool(on)] }
    public static func on(_ on: Bool) -> WebJSON { ["on": .bool(on)] }
    public static func saveServer(old: String, _ server: LibraryServer) -> WebJSON { ["old": .string(old), "server": server.saveBody] }
    public static func tools(_ name: String, off: [String]) -> WebJSON { ["name": .string(name), "names": .strings(off)] }
    public static func saveHook(old: String, _ hook: LibraryHook) -> WebJSON { ["old": .string(old), "hook": hook.saveBody] }
    public static func saveSubagent(old: String, _ subagent: LibrarySubagent) -> WebJSON { ["old": .string(old), "subagent": subagent.saveBody] }
    public static func update(_ name: String, replace: Bool) -> WebJSON {
        replace ? ["name": .string(name), "replace": true] : ["name": .string(name)]
    }
    public static func here(_ name: String, on: Bool) -> WebJSON { ["name": .string(name), "on": .bool(on)] }
    public static func install(source: String, paths: [String], agents: [String]) -> WebJSON {
        ["source": .string(source), "paths": .strings(paths), "agents": .strings(agents)]
    }
    public static func how(agent: String, how: String) -> WebJSON { ["agent": .string(agent), "how": .string(how)] }
    public static func marketServer(id: String, values: [String: String], agents: [String]) -> WebJSON {
        ["id": .string(id), "values": .object(values.mapValues(WebJSON.string)), "agents": .strings(agents)]
    }
    public static func marketSkill(source: String, id: String, agents: [String]) -> WebJSON {
        ["source": .string(source), "id": .string(id), "agents": .strings(agents)]
    }

    // 指令（library.InstructionsChange）

    /// 保存改过的几套文本与只给某个 Agent 的部分。
    public static func saveTexts(_ texts: [String: String], extra: [String: String]) -> WebJSON {
        var out: [String: WebJSON] = [:]
        if !texts.isEmpty { out["texts"] = .object(texts.mapValues(WebJSON.string)) }
        if !extra.isEmpty { out["extra"] = .object(extra.mapValues(WebJSON.string)) }
        return .object(out)
    }
    /// 读共享指令的 Agent（整份列表）。
    public static func instructionAgents(_ agents: [String]) -> WebJSON { ["agents": .strings(agents)] }
    /// 让 Agent 改用这一套（顺带保存还没保存的文本）。
    public static func activate(_ id: String, texts: [String: String] = [:]) -> WebJSON {
        texts.isEmpty ? ["activate": .string(id)] : ["activate": .string(id), "texts": .object(texts.mapValues(WebJSON.string))]
    }
    public static func createSet(id: String, name: String, file: String = "") -> WebJSON {
        var set: WebJSON = ["id": .string(id), "name": .string(name)]
        if !file.isEmpty { set["file"] = .string(file) }
        return ["create": set]
    }
    public static func renameSet(id: String, name: String) -> WebJSON { ["rename": ["id": .string(id), "name": .string(name)]] }
    public static func removeSet(_ id: String) -> WebJSON { ["remove": .string(id)] }
    public static func rewrite(_ agent: String) -> WebJSON { ["rewrite": .strings([agent])] }

    /// 新一套指令的 id（官方 "s" + Date.now().toString(36)）。
    public static func newSetID(now: Date = Date()) -> String {
        "s" + String(Int64(now.timeIntervalSince1970 * 1000), radix: 36)
    }
}

extension WebClient {
    /// `GET /api/library`；`glance` = 先读不含 Agent 自带技能的「一瞥」（大主机上快很多）。
    public func library(glance: Bool = false) async throws -> LibrarySnapshot {
        LibrarySnapshot(json: try await get("/api/library", query: glance ? [URLQueryItem(name: "glance", value: "1")] : []))
    }

    /// 资源库的一个改动；回改动后的整页（指令的改动只回指令那部分，并进 `current`）。
    public func library(_ action: LibraryAction, _ body: WebJSON, current: LibrarySnapshot?) async throws -> LibrarySnapshot {
        var request = try makeRequest("/api/library/" + action.rawValue, method: "POST", body: body)
        // 安装、更新技能要从 GitHub 拉取，可能要一会儿
        if [.skillsInstall, .skillsUpdate, .skillsUpdateAll, .marketSkill, .marketServer, .skillsAddNew].contains(action) {
            request.timeoutInterval = max(timeout, 180)
        }
        let json = try await send(request)
        if json["part"]?.string == "instructions" {
            var page: LibrarySnapshot
            if let current { page = current } else { page = try await library() }
            page.merge(instructionsAnswer: json)
            return page
        }
        if json["agents"] == nil {
            // skills/ignore-new 等不改文件的动作回 {} 之类：重读一次
            return try await library()
        }
        return LibrarySnapshot(json: json)
    }

    /// `GET /api/library/skill?name=`：SKILL.md 的全文。
    public func librarySkillText(_ name: String) async throws -> String {
        try await get("/api/library/skill", query: [URLQueryItem(name: "name", value: name)])["text"]?.string ?? ""
    }

    /// `POST /api/library/skills/check`：向来源查询哪些技能有改动，回整页（各技能带 check）。
    public func checkLibrarySkills() async throws -> LibrarySnapshot {
        var request = try makeRequest("/api/library/skills/check", method: "POST", body: [:])
        request.timeoutInterval = max(timeout, 120)
        return LibrarySnapshot(json: try await send(request))
    }

    /// `POST /api/library/skills/regroup`：重新分组，回整页 + regrouped。
    public func regroupLibrarySkills() async throws -> LibrarySnapshot {
        var request = try makeRequest("/api/library/skills/regroup", method: "POST", body: [:])
        request.timeoutInterval = max(timeout, 120)
        return LibrarySnapshot(json: try await send(request))
    }

    /// `POST /api/library/skills/probe`：查找一个来源里的技能。
    public func probeLibrarySkills(source: String) async throws -> LibraryProbe {
        var request = try makeRequest("/api/library/skills/probe", method: "POST", body: ["source": .string(source)])
        request.timeoutInterval = max(timeout, 120)
        return LibraryProbe(json: try await send(request))
    }

    /// `POST /api/library/mcp/check`：连接服务器看它能不能用（names 空 = 全部；fresh = 不用本次会话的缓存）。
    public func checkLibraryServers(_ names: [String], fresh: Bool) async throws -> [String: LibraryServerHealth] {
        var request = try makeRequest("/api/library/mcp/check", method: "POST", body: ["names": .strings(names), "fresh": .bool(fresh)])
        request.timeoutInterval = max(timeout, 90)
        let json = try await send(request)
        return (json["servers"]?.object ?? [:]).mapValues(LibraryServerHealth.init(json:))
    }

    /// `POST /api/library/mcp/config`：这些服务器在某个 Agent 的项目文件里长什么样（只读，不写任何文件）。
    public func libraryServersConfig(agent: String, names: [String]) async throws -> (file: String, text: String, skipped: [String]) {
        let json = try await post("/api/library/mcp/config", ["agent": .string(agent), "names": .strings(names)])
        return (json["file"]?.string ?? "", json["text"]?.string ?? "", json["skipped"]?.strings ?? [])
    }

    /// `POST /api/library/mcp-signout`：忘掉 magpie 对它的登录，回整页。
    public func signOutLibraryServer(_ name: String) async throws -> LibrarySnapshot {
        LibrarySnapshot(json: try await post("/api/library/mcp-signout", ["name": .string(name)]))
    }

    /// `GET /api/library/market/servers?q=`。
    public func libraryMarketServers(_ query: String) async throws -> LibraryMarket<LibraryMarketServer> {
        var request = try makeRequest("/api/library/market/servers", query: [URLQueryItem(name: "q", value: query)])
        request.timeoutInterval = max(timeout, 40)
        return LibraryMarket(json: try await send(request), item: LibraryMarketServer.init(json:))
    }

    /// `GET /api/library/market/skills?q=`。
    public func libraryMarketSkills(_ query: String) async throws -> LibraryMarket<LibraryMarketSkill> {
        var request = try makeRequest("/api/library/market/skills", query: [URLQueryItem(name: "q", value: query)])
        request.timeoutInterval = max(timeout, 40)
        return LibraryMarket(json: try await send(request), item: LibraryMarketSkill.init(json:))
    }

    /// `POST /api/library/market/about {ids}`：skills.sh 技能的描述（id → 描述）。
    public func libraryMarketAbout(_ ids: [String]) async throws -> [String: String] {
        (try await post("/api/library/market/about", ["ids": .strings(Array(ids.prefix(60)))])).stringMap
    }

    /// `GET /api/library/rtk`。
    public func libraryRTK() async throws -> LibraryRTK {
        var request = try makeRequest("/api/library/rtk")
        request.timeoutInterval = max(timeout, 30)
        return LibraryRTK(json: try await send(request))
    }

    /// `POST /api/library/rtk {agent, on}`：为一个 Agent 打开 / 关闭 RTK。
    public func setLibraryRTK(agent: String, on: Bool) async throws -> LibraryRTK {
        var request = try makeRequest("/api/library/rtk", method: "POST", body: ["agent": .string(agent), "on": .bool(on)])
        request.timeoutInterval = max(timeout, 120)
        return LibraryRTK(json: try await send(request))
    }

    /// `POST /api/library/rtk/upgrade`、`/rtk/install`、`/rtk/path`。
    public func libraryRTK(_ step: LibraryRTKStep) async throws -> LibraryRTK {
        var request = try makeRequest("/api/library/rtk/" + step.rawValue, method: "POST", body: [:])
        request.timeoutInterval = max(timeout, 600)
        return LibraryRTK(json: try await send(request))
    }
}

public enum LibraryRTKStep: String, Sendable {
    case upgrade, install, path
}
