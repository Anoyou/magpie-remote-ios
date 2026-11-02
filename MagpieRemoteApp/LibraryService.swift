import Foundation
import MagpieRemoteCore

/// 「资源库」页访问主机的方式。真实实现走 `WebClient`（和其它管理页同一把 Web 密钥），fixture 实现只改内存里的示例数据。
protocol LibraryServing: Sendable {
    func page(glance: Bool) async throws -> LibrarySnapshot
    func change(_ action: LibraryAction, _ body: WebJSON, current: LibrarySnapshot?) async throws -> LibrarySnapshot
    func skillText(_ name: String) async throws -> String
    func checkSkills() async throws -> LibrarySnapshot
    func regroupSkills() async throws -> LibrarySnapshot
    func probe(source: String) async throws -> LibraryProbe
    func checkServers(_ names: [String], fresh: Bool) async throws -> [String: LibraryServerHealth]
    func serversConfig(agent: String, names: [String]) async throws -> (file: String, text: String, skipped: [String])
    func signOut(_ name: String) async throws -> LibrarySnapshot
    func marketServers(_ query: String) async throws -> LibraryMarket<LibraryMarketServer>
    func marketSkills(_ query: String) async throws -> LibraryMarket<LibraryMarketSkill>
    func rtk() async throws -> LibraryRTK
    func setRTK(agent: String, on: Bool) async throws -> LibraryRTK
    func rtk(_ step: LibraryRTKStep) async throws -> LibraryRTK
}

enum LibraryServices {
    /// 跟着「管理」页当前用的服务走：真实主机用同一个 WebClient，fixture 用示例数据。
    static func make(from manage: (any ManageServing)?) -> (any LibraryServing)? {
        if let live = manage as? LiveManageService { return LiveLibraryService(web: live.web) }
        if manage is FixtureManageService { return FixtureLibraryService.shared }
        return nil
    }
}

struct LiveLibraryService: LibraryServing {
    let web: WebClient

    func page(glance: Bool) async throws -> LibrarySnapshot { try await web.library(glance: glance) }
    func change(_ action: LibraryAction, _ body: WebJSON, current: LibrarySnapshot?) async throws -> LibrarySnapshot {
        try await web.library(action, body, current: current)
    }
    func skillText(_ name: String) async throws -> String { try await web.librarySkillText(name) }
    func checkSkills() async throws -> LibrarySnapshot { try await web.checkLibrarySkills() }
    func regroupSkills() async throws -> LibrarySnapshot { try await web.regroupLibrarySkills() }
    func probe(source: String) async throws -> LibraryProbe { try await web.probeLibrarySkills(source: source) }
    func checkServers(_ names: [String], fresh: Bool) async throws -> [String: LibraryServerHealth] {
        try await web.checkLibraryServers(names, fresh: fresh)
    }
    func serversConfig(agent: String, names: [String]) async throws -> (file: String, text: String, skipped: [String]) {
        try await web.libraryServersConfig(agent: agent, names: names)
    }
    func signOut(_ name: String) async throws -> LibrarySnapshot { try await web.signOutLibraryServer(name) }
    func marketServers(_ query: String) async throws -> LibraryMarket<LibraryMarketServer> { try await web.libraryMarketServers(query) }
    func marketSkills(_ query: String) async throws -> LibraryMarket<LibraryMarketSkill> {
        var market = try await web.libraryMarketSkills(query)
        // skills.sh 的描述要另外问（官方 describeSkills）；问不到就不显示
        let missing = market.items.filter { $0.description.isEmpty }.map(\.id)
        if !missing.isEmpty, let about = try? await web.libraryMarketAbout(missing) {
            for index in market.items.indices where market.items[index].description.isEmpty {
                market.items[index].description = about[market.items[index].id] ?? ""
            }
        }
        return market
    }
    func rtk() async throws -> LibraryRTK { try await web.libraryRTK() }
    func setRTK(agent: String, on: Bool) async throws -> LibraryRTK { try await web.setLibraryRTK(agent: agent, on: on) }
    func rtk(_ step: LibraryRTKStep) async throws -> LibraryRTK { try await web.libraryRTK(step) }
}

/// fixture：一台有几个 Agent 的示例主机。改动只改内存里的整页 JSON，再按真实主机的样子回整页 + result。
actor FixtureLibraryService: LibraryServing {
    static let shared = FixtureLibraryService()

    private var json: WebJSON = LibraryFixtureData.page
    private var rtkJSON: WebJSON = LibraryFixtureData.rtk

    private func pause() async throws { try await Task.sleep(for: .milliseconds(120)) }

    private var snapshot: LibrarySnapshot { LibrarySnapshot(json: json) }

    func page(glance: Bool) async throws -> LibrarySnapshot {
        try await pause()
        var out = json
        out["result"] = nil
        if glance { out["partial"] = true; out["foundSkills"] = [] }
        return LibrarySnapshot(json: out)
    }

    // MARK: 改动

    private func list(_ key: String) -> [WebJSON] { json[key]?.array ?? [] }
    private func setList(_ key: String, _ items: [WebJSON]) { json[key] = .array(items) }
    private func index(_ key: String, _ name: String) -> Int? { list(key).firstIndex { $0["name"]?.string == name } }

    private func update(_ key: String, _ name: String, _ change: (inout WebJSON) -> Void) {
        var items = list(key)
        guard let i = items.firstIndex(where: { $0["name"]?.string == name }) else { return }
        change(&items[i])
        setList(key, items)
    }

    private func answer(changed: [String], error: String? = nil) throws -> LibrarySnapshot {
        if let error { throw MagpieError.webRejected(message: error, code: nil) }
        var out = json
        out["result"] = ["changed": .strings(changed), "problems": []]
        return LibrarySnapshot(json: out)
    }

    private func save(_ key: String, item: WebJSON, old: String, kind: String) throws -> [String] {
        let name = item["name"]?.string ?? ""
        guard !name.isEmpty else { throw MagpieError.webRejected(message: "a \(kind) needs a name", code: nil) }
        var items = list(key)
        if old.isEmpty || old != name, items.contains(where: { $0["name"]?.string == name }) {
            throw MagpieError.webRejected(message: "a \(kind) called \(name) is in the library already", code: nil)
        }
        var stored = item
        if let i = items.firstIndex(where: { $0["name"]?.string == (old.isEmpty ? name : old) }), !old.isEmpty {
            // 只读字段（图标、登录）按真实主机的样子保留
            for field in ["icon", "signIn", "files", "native"] where items[i][field] != nil { stored[field] = items[i][field] }
            items[i] = stored
        } else {
            items.append(stored)
        }
        setList(key, items)
        return item["agents"]?.strings ?? []
    }

    func change(_ action: LibraryAction, _ body: WebJSON, current: LibrarySnapshot?) async throws -> LibrarySnapshot {
        try await pause()
        let name = body["name"]?.string ?? ""
        let agents = body["agents"]?.strings ?? []
        let names = body["names"]?.strings ?? []
        switch action {
        case .serversAgents: update("servers", name) { $0["agents"] = .strings(agents) }; return try answer(changed: agents)
        case .skillsAgents: update("skills", name) { $0["agents"] = .strings(agents) }; return try answer(changed: agents)
        case .hooksAgents: update("hooks", name) { $0["agents"] = .strings(agents) }; return try answer(changed: agents)
        case .subagentsAgents: update("subagents", name) { $0["agents"] = .strings(agents) }; return try answer(changed: agents)
        case .serversSave:
            return try answer(changed: try save("servers", item: body["server"] ?? [:], old: body["old"]?.string ?? "", kind: "server"))
        case .hooksSave:
            return try answer(changed: try save("hooks", item: body["hook"] ?? [:], old: body["old"]?.string ?? "", kind: "hook"))
        case .subagentsSave:
            return try answer(changed: try save("subagents", item: body["subagent"] ?? [:], old: body["old"]?.string ?? "", kind: "subagent"))
        case .serversRemove, .skillsRemove, .hooksRemove, .subagentsRemove:
            let key = ["servers/remove": "servers", "skills/remove": "skills", "hooks/remove": "hooks"][action.rawValue] ?? "subagents"
            let had = list(key).first { $0["name"]?.string == name }?["agents"]?.strings ?? []
            setList(key, list(key).filter { $0["name"]?.string != name })
            return try answer(changed: had)
        case .serversRemoveAll, .skillsRemoveAll, .hooksRemoveAll, .skillsRemoveGone:
            let key = action == .serversRemoveAll ? "servers" : action == .hooksRemoveAll ? "hooks" : "skills"
            let gone = action == .skillsRemoveGone
            setList(key, list(key).filter { item in
                let n = item["name"]?.string ?? ""
                if gone { return !(names.isEmpty ? LibrarySkill(json: item).isGone : names.contains(n)) }
                return !names.contains(n)
            })
            return try answer(changed: [])
        case .serversAgentsAll, .skillsAgentsAll:
            let key = action == .serversAgentsAll ? "servers" : "skills"
            let on = body["on"]?.bool ?? false
            setList(key, list(key).map { item in
                var item = item
                var now = Set(item["agents"]?.strings ?? [])
                if on { now.formUnion(agents) } else { now.subtract(agents) }
                item["agents"] = .strings(now.sorted())
                return item
            })
            return try answer(changed: agents)
        case .serversTools: update("servers", name) { $0["disabledTools"] = .strings(names) }; return try answer(changed: ["claude"])
        case .serversHub: json["mcpHub"] = .bool(body["on"]?.bool ?? false); return try answer(changed: ["claude", "codex"])
        case .serversImport, .serversRemoveFound:
            let found = list("foundServers")
            setList("foundServers", found.filter { $0["server"]?["name"]?.string != name })
            if action == .serversImport, let f = found.first(where: { $0["server"]?["name"]?.string == name })?["server"] {
                setList("servers", list("servers") + [f])
            }
            return try answer(changed: [])
        case .skillsImport, .skillsImportAll, .skillsRemoveFound:
            let picked = action == .skillsImportAll ? (names.isEmpty ? list("foundSkills").compactMap { $0["name"]?.string } : names) : [name]
            let found = list("foundSkills")
            setList("foundSkills", found.filter { !picked.contains($0["name"]?.string ?? "") })
            if action != .skillsRemoveFound {
                for f in found where picked.contains(f["name"]?.string ?? "") {
                    setList("skills", list("skills") + [["name": f["name"] ?? "", "description": f["description"] ?? "", "kind": "", "agents": f["agents"] ?? []]])
                }
            }
            return try answer(changed: [])
        case .skillsHere: update("skills", name) { $0["offHere"] = .bool(!(body["on"]?.bool ?? false)) }; return try answer(changed: ["claude"])
        case .skillsUpdate:
            update("skills", name) { $0["check"] = ["name": .string(name), "status": "current"]; $0["edited"] = nil; $0["behind"] = nil }
            return try answer(changed: ["claude"])
        case .skillsUpdateAll:
            var updated: [String] = []
            setList("skills", list("skills").map { item in
                var item = item
                let skill = LibrarySkill(json: item)
                if skill.canUpdate && !skill.edited { item["check"] = ["name": .string(skill.name), "status": "current"]; updated.append(skill.name) }
                return item
            })
            var out = json
            let kept = LibrarySnapshot(json: json).skills.filter { $0.canUpdate && $0.edited }.map { WebJSON.object(["agent": "", "what": .string("skill:" + $0.name), "error": "changed here"]) }
            out["result"] = ["changed": [], "problems": [], "updated": .strings(updated), "unupdated": .array(kept)]
            return LibrarySnapshot(json: out)
        case .skillsInstall, .marketSkill:
            let paths = action == .marketSkill ? [body["id"]?.string ?? ""] : (body["paths"]?.strings ?? [])
            let source = body["source"]?.string ?? ""
            var installed: [String] = []
            for path in paths where !path.isEmpty {
                let skillName = path.split(separator: "/").last.map(String.init) ?? path
                guard index("skills", skillName) == nil else { continue }
                setList("skills", list("skills") + [["name": .string(skillName), "description": "示例技能", "kind": "github",
                                                     "source": .string("https://github.com/\(source)/tree/main/\(path)"), "repo": .string(source), "agents": .strings(agents)]])
                installed.append(skillName)
            }
            var out = json
            out["result"] = ["changed": .strings(agents), "problems": [], "installed": .strings(installed)]
            return LibrarySnapshot(json: out)
        case .marketServer:
            let id = body["id"]?.string ?? ""
            let market = LibraryMarket(json: LibraryFixtureData.marketServers, item: LibraryMarketServer.init(json:))
            let serverName = market.items.first { $0.id == id }?.name ?? id
            if index("servers", serverName) == nil {
                setList("servers", list("servers") + [["name": .string(serverName), "transport": "stdio", "command": "magpie", "args": ["mcp", "search"], "agents": .strings(agents)]])
            }
            return try answer(changed: agents)
        case .skillsAddNew, .skillsIgnoreNew:
            let picked = names.isEmpty ? list("newSkills").compactMap { $0["id"]?.string } : names
            let found = list("newSkills")
            setList("newSkills", found.filter { !picked.contains($0["id"]?.string ?? "") })
            if action == .skillsAddNew {
                for f in found where picked.contains(f["id"]?.string ?? "") {
                    setList("skills", list("skills") + [["name": f["name"] ?? "", "description": f["description"] ?? "", "kind": "github", "repo": f["repo"] ?? "", "agents": f["agents"] ?? []]])
                }
            }
            return try answer(changed: [])
        case .skillsHandOver:
            for n in names.isEmpty ? [name] : names { update("skills", n) { $0["shared"] = nil; $0["always"] = nil } }
            return try answer(changed: [])
        case .skillsHow:
            let agent = body["agent"]?.string ?? ""
            let how = body["how"]?.string ?? ""
            if agent.isEmpty { json["copySkills"] = .bool(how == "copy") }
            var all = list("agents")
            for i in all.indices where agent.isEmpty || all[i]["id"]?.string == agent {
                if !agent.isEmpty { all[i]["howOwn"] = .bool(!how.isEmpty) }
                if all[i]["howOwn"]?.bool != true || !agent.isEmpty {
                    all[i]["how"] = .string(how.isEmpty ? (json["copySkills"]?.bool == true ? "copy" : "link") : how)
                }
            }
            setList("agents", all)
            return try answer(changed: [])
        case .allSync:
            json["problems"] = []
            setList("skills", list("skills").map { $0.removing(["behind"]) })
            return try answer(changed: ["codex"])
        case .instructionsSave, .instructionsImport:
            return instructions(body, action: action)
        }
    }

    private func instructions(_ body: WebJSON, action: LibraryAction) -> LibrarySnapshot {
        var iv = json["instructions"] ?? [:]
        var sets = iv["sets"]?.array ?? []
        var agents = iv["agents"]?.array ?? []
        var changed: [String] = []
        if action == .instructionsImport, let name = body["name"]?.string, let i = agents.firstIndex(where: { $0["agent"]?.string == name }) {
            agents[i]["own"] = 0
            agents[i]["on"] = true
            changed = [name]
        }
        for (id, text) in body["texts"]?.object ?? [:] {
            if let i = sets.firstIndex(where: { $0["id"]?.string == id }) { sets[i]["text"] = text }
        }
        for (id, text) in body["extra"]?.object ?? [:] {
            if let i = agents.firstIndex(where: { $0["agent"]?.string == id }) { agents[i]["extra"] = text; changed.append(id) }
        }
        if let on = body["agents"]?.strings {
            for i in agents.indices {
                let id = agents[i]["agent"]?.string ?? ""
                if (agents[i]["on"]?.bool ?? false) != on.contains(id) { changed.append(id) }
                agents[i]["on"] = .bool(on.contains(id))
            }
        }
        if let id = body["activate"]?.string {
            for i in sets.indices { sets[i]["active"] = .bool(sets[i]["id"]?.string == id) }
        }
        if let create = body["create"], let id = create["id"]?.string {
            sets.append(["id": .string(id), "name": create["name"] ?? "", "text": "", "file": create["file"] ?? ""])
        }
        if let rename = body["rename"], let i = sets.firstIndex(where: { $0["id"]?.string == rename["id"]?.string }) { sets[i]["name"] = rename["name"] ?? "" }
        if let remove = body["remove"]?.string { sets.removeAll { $0["id"]?.string == remove } }
        if let rewrite = body["rewrite"]?.strings {
            for i in agents.indices where rewrite.contains(agents[i]["agent"]?.string ?? "") { agents[i]["edited"] = false }
            changed += rewrite
        }
        iv["sets"] = .array(sets)
        iv["agents"] = .array(agents)
        iv["shared"] = sets.first(where: { $0["active"]?.bool == true })?["text"] ?? sets.first?["text"] ?? ""
        json["instructions"] = iv
        json["problems"] = .array((json["problems"]?.array ?? []).filter { $0["what"]?.string != "instructions" })
        var out = json
        out["result"] = ["changed": .strings(changed), "problems": []]
        return LibrarySnapshot(json: out)
    }

    // MARK: 其它

    func skillText(_ name: String) async throws -> String {
        try await pause()
        return LibraryFixtureData.skillText(name)
    }

    func checkSkills() async throws -> LibrarySnapshot {
        try await pause()
        json["checkDue"] = false
        return snapshot
    }

    func regroupSkills() async throws -> LibrarySnapshot {
        try await pause()
        var out = json
        out["regrouped"] = 0
        return LibrarySnapshot(json: out)
    }

    func probe(source: String) async throws -> LibraryProbe {
        try await pause()
        guard !source.trimmingCharacters(in: .whitespaces).isEmpty else { throw MagpieError.webRejected(message: "No SKILL.md found there", code: nil) }
        var probe = LibraryProbe(json: LibraryFixtureData.probe(source: source))
        let have = Set(snapshot.skills.map(\.name))
        for i in probe.candidates.indices where have.contains(probe.candidates[i].name) { probe.candidates[i].have = true }
        return probe
    }

    func checkServers(_ names: [String], fresh: Bool) async throws -> [String: LibraryServerHealth] {
        try await pause()
        let all = (LibraryFixtureData.health.object ?? [:]).mapValues(LibraryServerHealth.init(json:))
        var out: [String: LibraryServerHealth] = [:]
        for name in names.isEmpty ? snapshot.servers.map(\.name) : names {
            out[name] = all[name] ?? LibraryServerHealth(json: ["state": "ok", "tools": 3, "toolList": [["name": "search"], ["name": "fetch"], ["name": "read"]]])
        }
        return out
    }

    func serversConfig(agent: String, names: [String]) async throws -> (file: String, text: String, skipped: [String]) {
        try await pause()
        let servers = snapshot.servers.filter { names.contains($0.name) }
        var map: [String: WebJSON] = [:]
        for s in servers { map[s.name] = s.isRemote ? ["type": .string(s.transport), "url": .string(s.url)] : ["command": .string(s.command), "args": .strings(s.args)] }
        let text = String(decoding: (try? WebJSON.object(["mcpServers": .object(map)]).encoded()) ?? Data(), as: UTF8.self)
        return (".mcp.json", text, [])
    }

    func signOut(_ name: String) async throws -> LibrarySnapshot {
        try await pause()
        update("servers", name) { $0["signIn"] = nil }
        return snapshot
    }

    func marketServers(_ query: String) async throws -> LibraryMarket<LibraryMarketServer> {
        try await pause()
        var market = LibraryMarket(json: LibraryFixtureData.marketServers, item: LibraryMarketServer.init(json:))
        let words = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !words.isEmpty { market.items = market.items.filter { $0.title.lowercased().contains(words) || $0.description.lowercased().contains(words) } }
        let have = Set(snapshot.servers.map(\.name))
        for i in market.items.indices { market.items[i].have = have.contains(market.items[i].name) ? market.items[i].name : "" }
        return market
    }

    func marketSkills(_ query: String) async throws -> LibraryMarket<LibraryMarketSkill> {
        try await pause()
        var market = LibraryMarket(json: LibraryFixtureData.marketSkills, item: LibraryMarketSkill.init(json:))
        let words = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !words.isEmpty { market.items = market.items.filter { $0.name.lowercased().contains(words) } }
        let have = Set(snapshot.skills.map(\.name))
        for i in market.items.indices { market.items[i].have = have.contains(market.items[i].skillID) ? market.items[i].skillID : "" }
        return market
    }

    func rtk() async throws -> LibraryRTK {
        try await pause()
        return LibraryRTK(json: rtkJSON)
    }

    func setRTK(agent: String, on: Bool) async throws -> LibraryRTK {
        try await pause()
        var agents = rtkJSON["agents"]?.array ?? []
        for i in agents.indices where agents[i]["id"]?.string == agent { agents[i]["on"] = .bool(on) }
        rtkJSON["agents"] = .array(agents)
        return LibraryRTK(json: rtkJSON)
    }

    func rtk(_ step: LibraryRTKStep) async throws -> LibraryRTK {
        try await pause()
        switch step {
        case .upgrade: rtkJSON["version"] = rtkJSON["latest"] ?? ""
        case .install: rtkJSON["path"] = "/opt/homebrew/bin/rtk"
        case .path: rtkJSON["offPath"] = false
        }
        return LibraryRTK(json: rtkJSON)
    }
}
