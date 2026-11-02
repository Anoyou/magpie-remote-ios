import Foundation

// 官方网页「资源库」（Library）页：internal/gui/library.go 的 `GET /api/library`（libraryJSON = library.View
// + result + home + problems），六个分页：指令、MCP 服务器、技能、Hooks、子代理、RTK。
// 字段名照 internal/library 里各个 *View 结构体的 json 标签；解码都按「可能没有」处理，旧版主机少字段也能读。

extension WebJSON {
    /// `{"k": "v"}` → `[k: v]`；不是对象或值不是字符串的项跳过。
    var stringMap: [String: String] {
        guard let object else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in object { if let text = value.string { out[key] = text } }
        return out
    }

    /// `{"k": ["a", "b"]}` → `[k: [a, b]]`。
    var stringListMap: [String: [String]] {
        guard let object else { return [:] }
        return object.mapValues(\.strings)
    }
}

/// 资源库里的一个 Agent（library.AgentView）：它能接收哪些东西、写在哪个文件里。
public struct LibraryAgent: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var icon: String
    /// 用户级指令文件；空 = 没有可写的指令文件。
    public var instructions: String
    /// MCP 配置文件；空 = 不能写 MCP 服务器。
    public var mcp: String
    /// 技能文件夹；空 = 没有技能文件夹。
    public var skills: String
    /// 它也会读取的其它 Agent 的技能文件夹（那个 Agent 有的技能它也能用到）。
    public var skillsAlso: [String]
    public var note: String
    public var noSSE: Bool
    public var noRemote: Bool
    public var noEnvRefs: Bool
    public var toolsOff: Bool
    /// 只有 Codex：MCP 服务器可以设「启动超时」。
    public var startup: Bool
    /// 通过某个扩展读取 MCP 服务器（例如 Pi）。
    public var mcpVia: String
    /// MCP 路由打开时：on = 拿到 magpie 这一个服务器；其它 = 原因。
    public var hub: String
    /// 技能给它的方式：link / copy。
    public var how: String
    public var howOwn: Bool
    public var mustCopy: Bool
    /// 本机已卸载（只在它还有东西的行上显示，用来移除）。
    public var gone: Bool
    /// 在一个未运行的 WSL 发行版里（发行版名）。
    public var asleep: String
    /// 未运行的发行版里、magpie 从没见过它的文件。
    public var unseen: Bool

    public init(json: WebJSON) {
        id = json["id"]?.string ?? ""
        name = json["name"]?.string ?? id
        icon = json["icon"]?.string ?? ""
        instructions = json["instructions"]?.string ?? ""
        mcp = json["mcp"]?.string ?? ""
        skills = json["skills"]?.string ?? ""
        skillsAlso = json["skillsAlso"]?.strings ?? []
        note = json["note"]?.string ?? ""
        noSSE = json["noSSE"]?.bool ?? false
        noRemote = json["noRemote"]?.bool ?? false
        noEnvRefs = json["noEnvRefs"]?.bool ?? false
        toolsOff = json["toolsOff"]?.bool ?? false
        startup = json["startup"]?.bool ?? false
        mcpVia = json["mcpVia"]?.string ?? ""
        hub = json["hub"]?.string ?? ""
        how = json["how"]?.string ?? ""
        howOwn = json["howOwn"]?.bool ?? false
        mustCopy = json["mustCopy"]?.bool ?? false
        gone = json["gone"]?.bool ?? false
        asleep = json["asleep"]?.string ?? ""
        unseen = json["unseen"]?.bool ?? false
    }
}

/// 一次改动没能写进某个 Agent 的原因（library.Problem）。`what` = instructions / mcp:<名> / skill:<名> / hook:<名> / subagent:<名> / project:…
public struct LibraryProblem: Hashable, Sendable {
    public var agent: String
    public var what: String
    public var error: String
    /// Agent 自带一个同名技能挡住了资源库的（不是写入失败）。
    public var own: Bool

    public init(agent: String, what: String, error: String, own: Bool = false) {
        self.agent = agent
        self.what = what
        self.error = error
        self.own = own
    }

    public init(json: WebJSON) {
        agent = json["agent"]?.string ?? ""
        what = json["what"]?.string ?? ""
        error = json["error"]?.string ?? ""
        own = json["own"]?.bool ?? false
    }

    static func list(_ json: WebJSON?) -> [LibraryProblem] { (json?.array ?? []).map(LibraryProblem.init(json:)) }

    /// 它属于哪个分页（官方 problemTab）。
    public var tab: LibraryTab? {
        switch what.split(separator: ":", maxSplits: 1).first.map(String.init) ?? what {
        case "instructions": .instructions
        case "mcp": .mcp
        case "skill", "skills", "project": .skills
        case "hook", "hooks": .hooks
        case "subagent": .subagents
        default: nil
        }
    }
}

/// 一次改动的结果（library.Result）。
public struct LibraryResult: Hashable, Sendable {
    /// 写入了文件的 Agent。
    public var changed: [String]
    public var problems: [LibraryProblem]
    public var backup: String
    public var updated: [String]
    public var unupdated: [LibraryProblem]
    /// 来源里已经没有的技能。
    public var gone: [String]
    public var unimported: [LibraryProblem]
    public var unremoved: [LibraryProblem]
    public var unmoved: [LibraryProblem]
    public var installed: [String]
    public var had: [String]
    public var skipped: [LibraryProblem]

    public init(json: WebJSON) {
        changed = json["changed"]?.strings ?? []
        problems = LibraryProblem.list(json["problems"])
        backup = json["backup"]?.string ?? ""
        updated = json["updated"]?.strings ?? []
        unupdated = LibraryProblem.list(json["unupdated"])
        gone = json["gone"]?.strings ?? []
        unimported = LibraryProblem.list(json["unimported"])
        unremoved = LibraryProblem.list(json["unremoved"])
        unmoved = LibraryProblem.list(json["unmoved"])
        installed = json["installed"]?.strings ?? []
        had = json["had"]?.strings ?? []
        skipped = LibraryProblem.list(json["skipped"])
    }
}

// MARK: MCP 服务器

/// 资源库里的一个 MCP 服务器（library.ServerView：Server 的字段 + icon / problems / signIn）。
/// `raw` 保留整份对象：保存时原样带回 App 不认识的字段（OAuth 应用、插件、关掉的工具……）。
public struct LibraryServer: Identifiable, Hashable, Sendable {
    public var raw: WebJSON
    public var name: String
    /// stdio / http / sse。
    public var transport: String
    public var command: String
    public var args: [String]
    public var env: [String: String]
    public var url: String
    public var headers: [String: String]
    public var agents: [String]
    public var disabledTools: [String]
    public var startupTimeout: Int
    /// 只在这台电脑（同步不会带走）。
    public var local: Bool
    /// 由某个插件提供。
    public var plugin: String
    /// direct = 不经过 MCP 路由。
    public var hub: String
    public var icon: String
    /// Agent id → 写不进去的原因。
    public var problems: [String: String]
    public var signedIn: Bool
    /// 登录已失效。
    public var signInDead: Bool
    /// 有自己的 OAuth 应用（客户端 ID）。
    public var oauthClientID: String

    public var id: String { name }

    public init(json: WebJSON) {
        raw = json
        name = json["name"]?.string ?? ""
        transport = json["transport"]?.string ?? "stdio"
        command = json["command"]?.string ?? ""
        args = json["args"]?.strings ?? []
        env = json["env"]?.stringMap ?? [:]
        url = json["url"]?.string ?? ""
        headers = json["headers"]?.stringMap ?? [:]
        agents = json["agents"]?.strings ?? []
        disabledTools = json["disabledTools"]?.strings ?? []
        startupTimeout = json["startupTimeout"]?.int ?? 0
        local = json["local"]?.bool ?? false
        plugin = json["plugin"]?.string ?? ""
        hub = json["hub"]?.string ?? ""
        icon = json["icon"]?.string ?? ""
        problems = json["problems"]?.stringMap ?? [:]
        signedIn = json["signIn"]?["signedIn"]?.bool ?? false
        signInDead = json["signIn"]?["dead"]?.bool ?? false
        oauthClientID = json["oauth"]?["clientId"]?.string ?? ""
    }

    /// 新建时的空白服务器（官方 editServer 的默认值：命令启动，给全部 Agent）。
    public static func blank(agents: [String]) -> LibraryServer {
        LibraryServer(json: ["name": "", "transport": "stdio", "command": "", "args": [], "env": [:], "url": "", "headers": [:], "agents": .strings(agents)])
    }

    public var isRemote: Bool { transport == "http" || transport == "sse" }

    /// 一行显示：命令 + 参数（照 sh 的引号规则），远程的显示地址（官方 serverLine）。
    public var line: String {
        isRemote ? url : ([command] + args).map(LibraryShell.quote).joined(separator: " ")
    }

    /// 请求头（远程）或环境变量（命令）里用了 `${NAME}`。
    public var usesEnvRefs: Bool {
        (isRemote ? headers : env).values.contains { LibraryShell.hasEnvRef($0) }
    }

    /// 这个 Agent 不能拿到它的原因；能拿到时为 nil（官方 sseBlocked）。
    public func blocked(for agent: LibraryAgent) -> String? {
        if isRemote && agent.noRemote { return "\(agent.name) 的配置文件只支持命令启动的服务器 — 远程服务器请在它的「连接器」里添加" }
        if transport == "sse" && agent.noSSE { return "\(agent.name) 不支持 SSE 服务器 — 只支持命令或 Streamable HTTP" }
        if usesEnvRefs && agent.noEnvRefs { return "\(agent.name) 无法从设置中读取 ${NAME} — 给它这个服务器，令牌就会以明文写进它的设置" }
        return nil
    }

    /// `POST /api/library/servers/save` 的 server：原始对象 + 编辑过的字段，去掉只读的展示字段。
    public var saveBody: WebJSON {
        var out = raw.removing(["icon", "problems", "signIn"])
        out["name"] = .string(name)
        out["transport"] = .string(transport)
        if isRemote {
            out["url"] = .string(url)
            out["headers"] = .object(headers.mapValues(WebJSON.string))
            out["command"] = nil
            out["args"] = nil
            out["env"] = nil
        } else {
            out["command"] = .string(command)
            out["args"] = .strings(args)
            out["env"] = .object(env.mapValues(WebJSON.string))
            out["url"] = nil
            out["headers"] = nil
        }
        out["agents"] = .strings(agents)
        out["local"] = .bool(local)
        out["startupTimeout"] = startupTimeout > 0 ? .int(Int64(startupTimeout)) : nil
        if hub.isEmpty { out["hub"] = nil } else { out["hub"] = .string(hub) }
        return out
    }
}

/// Agent 里已有、但不在资源库里的服务器（library.Found）。
public struct LibraryFoundServer: Identifiable, Hashable, Sendable {
    public var server: LibraryServer
    /// 有另一个同名、但内容不同的服务器的 Agent。
    public var others: [String]
    public var icon: String
    /// Agent 自己每次启动都会加上的（例如 Codex 的 node_repl）：页面不列。
    public var own: Bool
    public var id: String { server.name }

    public init(json: WebJSON) {
        server = LibraryServer(json: json["server"] ?? [:])
        others = json["others"]?.strings ?? []
        icon = json["icon"]?.string ?? ""
        own = json["own"]?.bool ?? false
    }
}

/// 服务器检测结果（library.ServerHealth，`POST /api/library/mcp/check` 的 servers[名]）。
public struct LibraryServerHealth: Hashable, Sendable {
    public struct Tool: Hashable, Sendable, Identifiable {
        public var name: String
        public var description: String
        public var id: String { name }
    }

    /// ok / auth / fail…
    public var state: String
    public var tools: Int
    public var toolList: [Tool]
    public var why: String
    public var code: Int
    public var detail: String
    public var oauth: Bool
    public var agentSignIn: [String]
    public var step: String
    public var waited: Int64
    public var at: Int64

    public init(json: WebJSON) {
        state = json["state"]?.string ?? ""
        tools = json["tools"]?.int ?? 0
        toolList = (json["toolList"]?.array ?? []).map { Tool(name: $0["name"]?.string ?? "", description: $0["description"]?.string ?? "") }
        why = json["why"]?.string ?? ""
        code = json["code"]?.int ?? 0
        detail = json["detail"]?.string ?? ""
        oauth = json["oauth"]?.bool ?? false
        agentSignIn = json["agentSignIn"]?.strings ?? []
        step = json["step"]?.string ?? ""
        waited = Int64(json["waited"]?.double ?? 0)
        at = Int64(json["at"]?.double ?? 0)
    }

    public var isOK: Bool { state == "ok" }

    /// 没能检测（缺环境变量、WSL 未运行）：画成「未检测」而不是红色。
    public var isUnknown: Bool { why == "novar" || why == "wsldown" }

    /// 一行短状态和完整说明（官方 healthWords）。`name` 把 Agent id 换成名字。
    public func words(transport: String, name: (String) -> String = { $0 }) -> (short: String, long: String) {
        if state == "ok" { return (tools == 1 ? "1 个工具" : "\(tools) 个工具", "已启动并列出了它的工具") }
        if state == "auth" && !agentSignIn.isEmpty {
            let names = agentSignIn.map(name)
            let short = "已在 \(names[0]) 登录" + (names.count > 1 ? " +\(names.count - 1)" : "")
            return (short, "\(names.joined(separator: "、"))：已自行登录并在使用。magpie 的检查没有这份登录，所以列不出工具：打开它，也在 magpie 中登录一次即可")
        }
        if state == "auth" {
            let why = oauth
                ? (transport == "http" ? "服务器要求登录：打开它，在 magpie 中登录一次" : "服务器要求登录")
                : "服务器拒绝了 magpie（HTTP \(code == 0 ? 401 : code)）— Headers 里的密钥可能缺失或有误"
            return ("需要登录", detail.isEmpty ? why : why + "\n" + detail)
        }
        func more(_ text: String) -> String { detail.isEmpty ? text : text + "\n" + detail }
        switch why {
        case "notfound": return ("无法启动：找不到 \(detail)", "无法启动：magpie 的 PATH 里没有 \(detail)")
        case "start": return ("无法启动", more("无法启动"))
        case "exited":
            return (code != 0 ? "已退出（\(code)）" : "已退出", more(code != 0 ? "列出工具前就退出了，退出码 \(code)" : "列出工具前就退出了"))
        case "timeout":
            let seconds = Int((Double(waited) / 1000).rounded())
            if step.isEmpty { return ("无响应", more("\(seconds) 秒内没有响应")) }
            return ("\(step) 无响应", more("等了 \(seconds) 秒，\(step) 仍没有响应"))
        case "http": return ("HTTP \(code)", "服务器返回 \(detail)")
        case "refused": return ("连接被拒绝", more("该地址上没有服务在监听"))
        case "unreachable": return ("无法连接", more("无法连接到服务器"))
        case "protocol": return ("响应无效", more("有响应，但不是 MCP 服务器的格式"))
        case "novar": return ("\(detail) 未设置", "magpie 无法检查：magpie 运行的环境里没有设置 \(detail)。在设置了它的环境中启动的智能体仍会拿到它")
        case "wsldown": return ("WSL \(detail) 未运行", "magpie 无法检查：用它的智能体运行在 WSL \(detail) 里，而它没有在运行，检查不会去启动它")
        default: return ("无法检查", more("magpie 无法检查它"))
        }
    }
}

// MARK: 技能

/// 技能「检查更新」的结果（library.SkillCheck）。
public struct LibrarySkillCheck: Hashable, Sendable {
    /// current / update / unknown / gone。
    public var status: String
    public var commit: String
    public var date: String
    public var message: String
    public var url: String
    public var error: String

    public init(json: WebJSON) {
        status = json["status"]?.string ?? ""
        commit = json["commit"]?.string ?? ""
        date = json["date"]?.string ?? ""
        message = json["message"]?.string ?? ""
        url = json["url"]?.string ?? ""
        error = json["error"]?.string ?? ""
    }
}

/// 资源库里的一个技能（library.SkillView）。
public struct LibrarySkill: Identifiable, Hashable, Sendable {
    public var name: String
    public var description: String
    public var source: String
    /// github / git / folder；空 = 放在资源库里的。
    public var kind: String
    public var origin: String
    public var repo: String
    public var icon: String
    public var agents: [String]
    /// 文件夹已不在资源库中。
    public var missing: Bool
    public var problems: [String: String]
    public var check: LibrarySkillCheck?
    /// 自己读取 ~/.agents/skills、不管勾没勾都有它的 Agent。
    public var always: [String]
    public var shared: String
    public var sharedElsewhere: Bool
    /// 副本已落后的 Agent。
    public var behind: [String]
    /// 本地改过。
    public var edited: Bool
    public var gone: String
    /// 本机已关闭。
    public var offHere: Bool

    public var id: String { name }

    public init(json: WebJSON) {
        name = json["name"]?.string ?? ""
        description = json["description"]?.string ?? ""
        source = json["source"]?.string ?? ""
        kind = json["kind"]?.string ?? ""
        origin = json["origin"]?.string ?? ""
        repo = json["repo"]?.string ?? ""
        icon = json["icon"]?.string ?? ""
        agents = json["agents"]?.strings ?? []
        missing = json["missing"]?.bool ?? false
        problems = json["problems"]?.stringMap ?? [:]
        check = json["check"].flatMap { $0.isNull ? nil : LibrarySkillCheck(json: $0) }
        always = json["always"]?.strings ?? []
        shared = json["shared"]?.string ?? ""
        sharedElsewhere = json["sharedElsewhere"]?.bool ?? false
        behind = json["behind"]?.strings ?? []
        edited = json["edited"]?.bool ?? false
        gone = json["gone"]?.string ?? ""
        offHere = json["offHere"]?.bool ?? false
    }

    /// 来源里已经没有它了（官方 isGone）。
    public var isGone: Bool { !gone.isEmpty || check?.status == "gone" }
    public var hasUpdate: Bool { check?.status == "update" }
    /// 能从来源更新（GitHub、git 仓库或 CC Switch 记下的 GitHub 来源）。
    public var canUpdate: Bool { !isGone && (kind == "github" || kind == "git" || !origin.isEmpty) }
    /// git 仓库来源的显示名（官方 gitRepoOf）。
    public var gitRepo: String {
        guard kind == "git" else { return "" }
        var text = source
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        if let range = text.range(of: "/-/tree/") { text = String(text[..<range.lowerBound]) }
        return text
    }
    /// 分组用的仓库（官方 skillRepo）。
    public var groupRepo: String {
        if !repo.isEmpty { return repo }
        if kind == "github" { return LibrarySkill.repoOf(source) }
        if !origin.isEmpty { return LibrarySkill.repoOf(origin) }
        return ""
    }

    /// `https://github.com/o/r/tree/…` → `o/r`。
    static func repoOf(_ url: String) -> String {
        var text = url
        if text.hasPrefix("https://github.com/") { text.removeFirst("https://github.com/".count) }
        let parts = text.split(separator: "/")
        return parts.count >= 2 ? "\(parts[0])/\(parts[1])" : text
    }

    /// 来源一行：GitHub 的去掉前缀，文件夹的写「链接自 …」。
    public var sourceLine: String {
        guard !source.isEmpty else { return "" }
        switch kind {
        case "github": return source.replacingOccurrences(of: "https://github.com/", with: "")
        case "git": return source.replacingOccurrences(of: "https://", with: "")
        default: return "链接自 " + source
        }
    }

    /// 这个 Agent 不管勾没勾都有它时的说明（官方 alwaysFor）。
    public func alwaysNote(for agent: LibraryAgent) -> String? {
        always.contains(agent.id) ? "\(agent.name) 会自己读取 ~/.agents/skills（这个技能就放在那里）——不管这里勾没勾都有它" : nil
    }
}

/// Agent 里已有、但不在资源库里的技能（library.FoundSkill）。
public struct LibraryFoundSkill: Identifiable, Hashable, Sendable {
    public var name: String
    public var description: String
    public var agents: [String]
    public var others: [String]
    public var copies: [String]
    public var link: String
    public var shared: String
    public var library: String
    public var id: String { name }

    public init(json: WebJSON) {
        name = json["name"]?.string ?? ""
        description = json["description"]?.string ?? ""
        agents = json["agents"]?.strings ?? []
        others = json["others"]?.strings ?? []
        copies = json["copies"]?.strings ?? []
        link = json["link"]?.string ?? ""
        shared = json["shared"]?.string ?? ""
        library = json["library"]?.string ?? ""
    }
}

/// 检查更新时在同一仓库里发现的、资源库还没有的技能（library.NewSkill）。
public struct LibraryNewSkill: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var repo: String
    public var agents: [String]

    public init(json: WebJSON) {
        id = json["id"]?.string ?? ""
        name = json["name"]?.string ?? ""
        description = json["description"]?.string ?? ""
        repo = json["repo"]?.string ?? ""
        agents = json["agents"]?.strings ?? []
    }
}

// MARK: Hooks、子代理

/// 资源库里的一个 Hook（library.HookView）。
public struct LibraryHook: Identifiable, Hashable, Sendable {
    public var name: String
    public var description: String
    /// turn-end / after-tool / before-tool / prompt / session-start，或 `<agent>:<事件>`。
    public var event: String
    public var matcher: String
    public var command: String
    /// 秒；0 = Agent 自己的。
    public var timeout: Int
    public var agents: [String]
    public var problems: [String: String]
    public var id: String { name }

    public init(json: WebJSON) {
        name = json["name"]?.string ?? ""
        description = json["description"]?.string ?? ""
        event = json["event"]?.string ?? "turn-end"
        matcher = json["matcher"]?.string ?? ""
        command = json["command"]?.string ?? ""
        timeout = json["timeout"]?.int ?? 0
        agents = json["agents"]?.strings ?? []
        problems = json["problems"]?.stringMap ?? [:]
    }

    public init(name: String = "", description: String = "", event: String = "turn-end", matcher: String = "", command: String = "", timeout: Int = 0, agents: [String] = []) {
        self.name = name
        self.description = description
        self.event = event
        self.matcher = matcher
        self.command = command
        self.timeout = timeout
        self.agents = agents
        problems = [:]
    }

    /// 某个 Agent 自己的事件：那个 Agent 的 id。
    public var ownAgent: String? {
        guard let index = event.firstIndex(of: ":"), index != event.startIndex else { return nil }
        return String(event[..<index])
    }

    public var isToolEvent: Bool { event == "after-tool" || event == "before-tool" }

    public var saveBody: WebJSON {
        ["name": .string(name), "description": .string(description.trimmingCharacters(in: .whitespacesAndNewlines)), "event": .string(event),
         "matcher": .string(matcher), "command": .string(command), "timeout": .int(Int64(max(0, timeout))), "agents": .strings(agents)]
    }

    /// 通用事件（官方 HOOK_EVENTS）。
    public static let events: [(id: String, title: String)] = [
        ("turn-end", "一轮结束时"), ("after-tool", "工具运行后"), ("before-tool", "工具运行前"),
        ("prompt", "发送提示词时"), ("session-start", "会话开始时"),
    ]
    /// 工具事件可以限定的工具（官方 HOOK_TOOLS）。
    public static let tools: [(id: String, title: String)] = [("", "任意工具"), ("shell", "Shell 命令"), ("edit", "文件编辑")]

    /// 「何时运行 · 对哪些工具」（官方 hookLine）。
    public func line(agentName: (String) -> String = { $0 }) -> String {
        var text: String
        if let own = ownAgent {
            text = agentName(own) + " · " + event.dropFirst(own.count + 1)
        } else {
            text = Self.events.first { $0.id == event }?.title ?? event
        }
        if !matcher.isEmpty {
            text += " · " + (ownAgent != nil ? matcher : (Self.tools.first { $0.id == matcher }?.title ?? matcher))
        }
        return text
    }
}

/// 每个 Agent 能接收哪些 Hook（library.HookAgentView）。
public struct LibraryHookAgent: Hashable, Sendable {
    public var id: String
    public var file: String
    /// 不能写入的原因。
    public var no: String
    public var wsl: Bool
    /// 在自己的设置里关掉了全部 Hook。
    public var off: Bool
    /// 它自己的事件名。
    public var events: [String]

    public init(json: WebJSON) {
        id = json["id"]?.string ?? ""
        file = json["file"]?.string ?? ""
        no = json["no"]?.string ?? ""
        wsl = json["wsl"]?.bool ?? false
        off = json["off"]?.bool ?? false
        events = json["events"]?.strings ?? []
    }
}

/// 资源库里的一个子代理（library.SubagentView）。
public struct LibrarySubagent: Identifiable, Hashable, Sendable {
    public var name: String
    public var description: String
    public var prompt: String
    public var skills: [String]
    public var mcp: [String]
    public var agents: [String]
    public var problems: [String: String]
    public var id: String { name }

    public init(json: WebJSON) {
        name = json["name"]?.string ?? ""
        description = json["description"]?.string ?? ""
        prompt = json["prompt"]?.string ?? ""
        skills = json["skills"]?.strings ?? []
        mcp = json["mcp"]?.strings ?? []
        agents = json["agents"]?.strings ?? []
        problems = json["problems"]?.stringMap ?? [:]
    }

    public init(name: String = "", description: String = "", prompt: String = "", skills: [String] = [], mcp: [String] = [], agents: [String] = []) {
        self.name = name
        self.description = description
        self.prompt = prompt
        self.skills = skills
        self.mcp = mcp
        self.agents = agents
        problems = [:]
    }

    public var saveBody: WebJSON {
        ["name": .string(name), "description": .string(description), "prompt": .string(prompt),
         "skills": .strings(skills), "mcp": .strings(mcp), "agents": .strings(agents)]
    }

    /// 「技能：… · MCP 服务器：…」（官方 subagentLine）。
    public var line: String {
        var parts: [String] = []
        if !skills.isEmpty { parts.append("技能：" + skills.joined(separator: ", ")) }
        if !mcp.isEmpty { parts.append("MCP 服务器：" + mcp.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

/// 每个 Agent 能接收哪些子代理（library.SubagentAgentView）。
public struct LibrarySubagentAgent: Hashable, Sendable {
    public var id: String
    public var dir: String
    public var no: String
    public var wsl: Bool
    /// 能给子代理单独绑定技能 / MCP 服务器。
    public var skills: Bool
    public var mcp: Bool

    public init(json: WebJSON) {
        id = json["id"]?.string ?? ""
        dir = json["dir"]?.string ?? ""
        no = json["no"]?.string ?? ""
        wsl = json["wsl"]?.bool ?? false
        skills = json["skills"]?.bool ?? false
        mcp = json["mcp"]?.bool ?? false
    }
}

// MARK: 指令

/// 一套共享指令（library.SetView）。
public struct LibraryInstructionSet: Identifiable, Hashable, Sendable {
    public var id: String
    /// 空 = 第一套，页面叫「默认」。
    public var name: String
    public var text: String
    public var active: Bool
    /// 保存在用户自己的文件里（不在资源库里）。
    public var file: String

    public init(json: WebJSON) {
        id = json["id"]?.string ?? ""
        name = json["name"]?.string ?? ""
        text = json["text"]?.string ?? ""
        active = json["active"]?.bool ?? false
        file = json["file"]?.string ?? ""
    }

    public var title: String { name.isEmpty ? "默认" : name }
    /// 第一行有字的内容（去掉标题的 #），空的写「空」。
    public var firstLine: String {
        let line = text.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let line else { return "空" }
        return String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
    }
}

/// 每个 Agent 的指令文件（library.AgentInstructions）。
public struct LibraryInstructionAgent: Identifiable, Hashable, Sendable {
    public var agent: String
    public var name: String
    public var icon: String
    public var path: String
    public var on: Bool
    /// 只给它、接在共享内容之后的部分。
    public var extra: String
    /// 文件里用户自己的行数。
    public var own: Int
    public var edited: Bool
    public var override: String
    public var profile: Bool
    public var asleep: String
    public var unseen: Bool
    public var id: String { agent }

    public init(json: WebJSON) {
        agent = json["agent"]?.string ?? ""
        name = json["name"]?.string ?? agent
        icon = json["icon"]?.string ?? ""
        path = json["path"]?.string ?? ""
        on = json["on"]?.bool ?? false
        extra = json["extra"]?.string ?? ""
        own = json["own"]?.int ?? 0
        edited = json["edited"]?.bool ?? false
        override = json["override"]?.string ?? ""
        profile = json["profile"]?.bool ?? false
        asleep = json["asleep"]?.string ?? ""
        unseen = json["unseen"]?.bool ?? false
    }
}

/// 指令分页（library.InstructionsView）。
public struct LibraryInstructions: Hashable, Sendable {
    public var shared: String
    public var sets: [LibraryInstructionSet]
    public var agents: [LibraryInstructionAgent]

    public init(json: WebJSON) {
        shared = json["shared"]?.string ?? ""
        sets = (json["sets"]?.array ?? []).map(LibraryInstructionSet.init(json:))
        agents = (json["agents"]?.array ?? []).map(LibraryInstructionAgent.init(json:))
    }

    /// Agent 正在读的一套（没有标记时是第一套）。
    public var inUse: LibraryInstructionSet? { sets.first(where: \.active) ?? sets.first }
}

/// 项目（library.ProjectView）。App 只列出来；添加项目要在 Mac 上选文件夹。
public struct LibraryProject: Identifiable, Hashable, Sendable {
    public var dir: String
    public var name: String
    public var copy: Bool
    public var skills: [String: [String]]
    public var servers: [String: [String]]
    public var missing: Bool
    public var id: String { dir }

    public init(json: WebJSON) {
        dir = json["dir"]?.string ?? ""
        name = json["name"]?.string ?? dir
        copy = json["copy"]?.bool ?? false
        skills = json["skills"]?.stringListMap ?? [:]
        servers = json["servers"]?.stringListMap ?? [:]
        missing = json["missing"]?.bool ?? false
    }
}

// MARK: 整页

/// 资源库的分页（官方 libHead 的 segs）。
public enum LibraryTab: String, CaseIterable, Identifiable, Hashable, Sendable {
    case instructions, mcp, skills, hooks, subagents, rtk

    public static let defaultsKey = "library.tab"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .instructions: "指令"
        case .mcp: "MCP 服务器"
        case .skills: "技能"
        case .hooks: "Hooks"
        case .subagents: "子代理"
        case .rtk: "RTK"
        }
    }

    /// 分页器上的短名（手机放不下「MCP 服务器」）。
    public var shortTitle: String {
        switch self {
        case .mcp: "MCP"
        default: title
        }
    }

    public init(stored: String?) { self = stored.flatMap(LibraryTab.init(rawValue:)) ?? .instructions }
}

/// `GET /api/library` 的整页（libraryJSON）。
public struct LibrarySnapshot: Hashable, Sendable {
    public var agents: [LibraryAgent]
    public var servers: [LibraryServer]
    public var hooks: [LibraryHook]
    public var hookAgents: [LibraryHookAgent]
    public var subagents: [LibrarySubagent]
    public var subagentAgents: [LibrarySubagentAgent]
    public var foundServers: [LibraryFoundServer]
    public var skills: [LibrarySkill]
    public var foundSkills: [LibraryFoundSkill]
    public var newSkills: [LibraryNewSkill]
    public var projects: [LibraryProject]
    public var instructions: LibraryInstructions
    public var dir: String
    public var backups: String
    public var copySkills: Bool
    public var mcpHub: Bool
    public var hubPath: String
    public var checkDue: Bool
    /// 先读的「一瞥」：Agent 自带的技能和副本是否落后还没读。
    public var partial: Bool
    public var home: String
    /// 最近一次改动还没解决的问题。
    public var problems: [LibraryProblem]
    /// 这次改动的结果（只有改动的响应里有）。
    public var result: LibraryResult?
    /// 「重新分组」归进分组的技能数。
    public var regrouped: Int?

    public init(json: WebJSON) {
        agents = (json["agents"]?.array ?? []).map(LibraryAgent.init(json:))
        servers = (json["servers"]?.array ?? []).map(LibraryServer.init(json:))
        hooks = (json["hooks"]?.array ?? []).map(LibraryHook.init(json:))
        hookAgents = (json["hookAgents"]?.array ?? []).map(LibraryHookAgent.init(json:))
        subagents = (json["subagents"]?.array ?? []).map(LibrarySubagent.init(json:))
        subagentAgents = (json["subagentAgents"]?.array ?? []).map(LibrarySubagentAgent.init(json:))
        foundServers = (json["foundServers"]?.array ?? []).map(LibraryFoundServer.init(json:))
        skills = (json["skills"]?.array ?? []).map(LibrarySkill.init(json:))
        foundSkills = (json["foundSkills"]?.array ?? []).map(LibraryFoundSkill.init(json:))
        newSkills = (json["newSkills"]?.array ?? []).map(LibraryNewSkill.init(json:))
        projects = (json["projects"]?.array ?? []).map(LibraryProject.init(json:))
        instructions = LibraryInstructions(json: json["instructions"] ?? [:])
        dir = json["dir"]?.string ?? ""
        backups = json["backups"]?.string ?? ""
        copySkills = json["copySkills"]?.bool ?? false
        mcpHub = json["mcpHub"]?.bool ?? false
        hubPath = json["hubPath"]?.string ?? ""
        checkDue = json["checkDue"]?.bool ?? false
        partial = json["partial"]?.bool ?? false
        home = json["home"]?.string ?? ""
        problems = LibraryProblem.list(json["problems"])
        result = json["result"].flatMap { $0.isNull ? nil : LibraryResult(json: $0) }
        regrouped = json["regrouped"]?.int
    }

    /// 指令的改动只回指令那一部分（instructionsJSON，part = instructions），其余保持原样。
    public mutating func merge(instructionsAnswer json: WebJSON) {
        instructions = LibraryInstructions(json: json["instructions"] ?? [:])
        problems = LibraryProblem.list(json["problems"])
        result = json["result"].flatMap { $0.isNull ? nil : LibraryResult(json: $0) }
    }

    public func agent(_ id: String) -> LibraryAgent? { agents.first { $0.id == id } }
    public func name(of id: String) -> String { agent(id)?.name ?? id }

    /// 路径里的家目录写成 ~（官方 tilde）。
    public func tilde(_ path: String) -> String {
        guard !home.isEmpty, path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    // 官方 shownAgents / mcpAgents / skillAgents / hookAgents / subagentAgents：
    // 已卸载的、未见过的和在 Agent 页隐藏的不显示（已有东西的行上再补上，见 withGone）。

    public func shownAgents(hidden: [String] = []) -> [LibraryAgent] {
        agents.filter { !$0.gone && !$0.unseen && !hidden.contains($0.id) }
    }
    public func mcpAgents(hidden: [String] = []) -> [LibraryAgent] { shownAgents(hidden: hidden).filter { !$0.mcp.isEmpty } }
    public func skillAgents(hidden: [String] = []) -> [LibraryAgent] { shownAgents(hidden: hidden).filter { !$0.skills.isEmpty } }
    public func hookAgent(_ id: String) -> LibraryHookAgent? { hookAgents.first { $0.id == id } }
    public func hookTargets(hidden: [String] = []) -> [LibraryAgent] { shownAgents(hidden: hidden).filter { hookAgent($0.id) != nil } }
    public func subagentAgent(_ id: String) -> LibrarySubagentAgent? { subagentAgents.first { $0.id == id } }
    public func subagentTargets(hidden: [String] = []) -> [LibraryAgent] { shownAgents(hidden: hidden).filter { subagentAgent($0.id) != nil } }

    /// 一行的 Agent：显示的那些 + 已卸载 / 未见过、但这一项还在它那里的（官方 withGone）。
    public func withGone(_ all: [LibraryAgent], on: [String], hidden: [String] = []) -> [LibraryAgent] {
        all + agents.filter { a in
            (a.gone || (a.unseen && !hidden.contains(a.id))) && on.contains(a.id) && !all.contains { $0.id == a.id }
        }
    }

    /// 这个 Agent 不能拿到这个 Hook 的原因（官方 hookBlocked）。
    public func hookBlocked(_ hook: LibraryHook, agent: LibraryAgent) -> String? {
        guard let ha = hookAgent(agent.id), ha.no.isEmpty else {
            return hookAgent(agent.id)?.wsl == true ? "magpie 目前只给这台电脑上的 Agent 写入 Hook，还不支持 WSL 里的 \(agent.name)" : "\(agent.name) 没有 magpie 能写入的 Hook"
        }
        if let own = hook.ownAgent, own != agent.id {
            return "\(hook.event.dropFirst(own.count + 1)) 是 \(name(of: own)) 自己的事件：只有它能运行这个 Hook"
        }
        return nil
    }

    /// 这个 Agent 不能拿到子代理的原因（官方 subagentBlocked）。
    public func subagentBlocked(_ agent: LibraryAgent) -> String? {
        guard let sa = subagentAgent(agent.id), sa.no.isEmpty else {
            return subagentAgent(agent.id)?.wsl == true ? "magpie 目前只给这台电脑上的 Agent 写入子代理，还不支持 WSL 里的 \(agent.name)" : "\(agent.name) 没有 magpie 能写入的子代理"
        }
        return nil
    }

    /// 某一项这个 Agent 写不进去的原因（chip 上的黄点）。
    public func problem(for what: String, agent: String) -> String? {
        problems.first { $0.what == what && $0.agent == agent }?.error
    }

    /// 页面顶部「资源库有部分内容未能写入」里的问题：只算这一页的（官方 problemsCard 里本页那部分）。
    public func problems(on tab: LibraryTab) -> [LibraryProblem] {
        problems.filter { !$0.own && ($0.tab == nil || $0.tab == tab) }
    }

    /// 别的分页还有几个问题。
    public func problemCounts(except tab: LibraryTab) -> [(tab: LibraryTab, count: Int)] {
        LibraryTab.allCases.filter { $0 != tab }.compactMap { other in
            let n = problems.filter { !$0.own && $0.tab == other }.count
            return n > 0 ? (other, n) : nil
        }
    }

    /// 页头分页上的数量（官方 libHead 的 counts）。
    public func count(_ tab: LibraryTab) -> Int? {
        switch tab {
        case .mcp: servers.count
        case .skills: skills.count
        case .hooks: hooks.count
        case .subagents: subagents.count
        case .instructions, .rtk: nil
        }
    }

    /// 要列出的 Agent 里已有的服务器（Agent 自己每次启动都会加上的不列）。
    public var listedFoundServers: [LibraryFoundServer] { foundServers.filter { !$0.own } }

    /// 技能按来源仓库分组（官方 skillGroups 的简化：同一仓库两个及以上才成组，其余放在「其他」）。
    public func skillGroups(filter: String = "") -> [(repo: String, skills: [LibrarySkill])] {
        let words = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = skills
            .filter { words.isEmpty || $0.name.lowercased().contains(words) || $0.description.lowercased().contains(words) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var order: [String] = []
        var groups: [String: [LibrarySkill]] = [:]
        for skill in shown {
            let repo = skill.groupRepo
            if groups[repo] == nil { order.append(repo) }
            groups[repo, default: []].append(skill)
        }
        var named: [(String, [LibrarySkill])] = []
        var rest: [LibrarySkill] = []
        for repo in order {
            let list = groups[repo] ?? []
            if repo.isEmpty || list.count < 2 { rest.append(contentsOf: list) } else { named.append((repo, list)) }
        }
        named.sort { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
        if !rest.isEmpty {
            rest.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            named.append(("", rest))
        }
        return named
    }

    /// 有更新的技能（检查过之后）。
    public var skillsWithUpdates: [LibrarySkill] { skills.filter { $0.hasUpdate && !$0.isGone } }
    /// 能从来源更新的技能（「全部更新」）。
    public var updatableSkills: [LibrarySkill] { skills.filter(\.canUpdate) }
    /// 来源里已经没有的技能。
    public var goneSkills: [LibrarySkill] { skills.filter(\.isGone) }
}

// MARK: RTK

/// RTK 分页（library.RTKView，`GET /api/library/rtk`）。
public struct LibraryRTK: Hashable, Sendable {
    public struct Agent: Identifiable, Hashable, Sendable {
        public var id: String
        public var name: String
        public var icon: String
        public var on: Bool
        /// 不能打开的原因（需要更新 RTK 等）。
        public var blocked: String
        /// RTK 没有它的 hook。
        public var noHook: Bool
        public var wsl: String
        public var asleep: Bool
    }

    /// 空 = 没有安装 RTK。
    public var path: String
    public var version: String
    public var latest: String
    public var upgrade: String
    public var noUpgrade: String
    public var manual: String
    public var waiting: String
    public var waitingHas: String
    public var offPath: Bool
    public var pathDir: String
    public var gainCommands: Int
    public var gainSaved: Int64
    public var gainPct: Double
    public var hasGain: Bool
    public var gainErr: String
    public var agents: [Agent]
    public var url: String
    public var install: String
    public var restart: [String]

    public init(json: WebJSON) {
        path = json["path"]?.string ?? ""
        version = json["version"]?.string ?? ""
        latest = json["latest"]?.string ?? ""
        upgrade = json["upgrade"]?.string ?? ""
        noUpgrade = json["noUpgrade"]?.string ?? ""
        manual = json["manual"]?.string ?? ""
        waiting = json["waiting"]?.string ?? ""
        waitingHas = json["waitingHas"]?.string ?? ""
        offPath = json["offPath"]?.bool ?? false
        pathDir = json["pathDir"]?.string ?? ""
        let gain = json["gain"]
        hasGain = gain.map { !$0.isNull } ?? false
        gainCommands = gain?["commands"]?.int ?? 0
        gainSaved = Int64(gain?["saved"]?.double ?? 0)
        gainPct = gain?["pct"]?.double ?? 0
        gainErr = json["gainErr"]?.string ?? ""
        agents = (json["agents"]?.array ?? []).map {
            Agent(id: $0["id"]?.string ?? "", name: $0["name"]?.string ?? "", icon: $0["icon"]?.string ?? "",
                  on: $0["on"]?.bool ?? false, blocked: $0["blocked"]?.string ?? "", noHook: $0["noHook"]?.bool ?? false,
                  wsl: $0["wsl"]?.string ?? "", asleep: $0["asleep"]?.bool ?? false)
        }
        url = json["url"]?.string ?? ""
        install = json["install"]?.string ?? ""
        restart = json["restart"]?.strings ?? []
    }

    public var installed: Bool { !path.isEmpty }

    /// 有比当前更新的版本（官方 vNewer）。
    public var behind: Bool {
        guard waiting.isEmpty, !latest.isEmpty, !version.isEmpty else { return false }
        return LibraryRTK.newer(latest, than: version)
    }

    /// 版本号逐段比较。
    public static func newer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// 版本那一行的状态（官方 renderRTK 的 ttl）。
    public var versionNote: String? {
        if !waiting.isEmpty && !latest.isEmpty { return "v\(latest) 已发布 · 等待 \(waiting)" }
        if behind { return "v\(latest) 可升级" }
        if !latest.isEmpty && !version.isEmpty { return "已是最新" }
        return nil
    }

    /// 节省统计那一行。
    public var gainLine: String {
        if hasGain && gainCommands > 0 {
            return "\(gainCommands) 条命令共节省 \(LibraryRTK.tokens(gainSaved)) token，平均省 \(Int(gainPct.rounded()))%"
        }
        if !gainErr.isEmpty { return "magpie 读不到 RTK 的节省记录：\(gainErr)" }
        return "还没有节省记录：打开后重启 Agent，它的命令就会经过 RTK。"
    }

    static func tokens(_ n: Int64) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return String(n)
    }

    /// 这个 Agent 的开关上方的标签（官方 renderRTK 的 agent 行）。
    public func tag(_ agent: Agent) -> String? {
        if agent.asleep { return "未运行" }
        if agent.noHook { return "RTK 暂不支持" }
        if !agent.blocked.isEmpty { return "需更新 RTK" }
        if agent.on && !installed { return "RTK 缺失" }
        if agent.on && offPath { return "不在 PATH 中" }
        return nil
    }
}

// MARK: 市场、查找技能

/// 「查找技能」的结果（library.Probe）。
public struct LibraryProbe: Hashable, Sendable {
    public struct Candidate: Identifiable, Hashable, Sendable {
        /// 在仓库或文件夹里的路径；空 = 根目录。
        public var path: String
        public var name: String
        public var description: String
        /// 资源库已经有它（同一来源，或文件完全一样）。
        public var have: Bool
        /// 会以这个名字加入（资源库已有另一个同名的）。
        public var addsAs: String
        public var id: String { path + "\n" + name }
    }

    public var source: String
    public var kind: String
    public var candidates: [Candidate]
    /// 太大、被略过的技能（路径与大小）。
    public var left: [(path: String, size: Int64)]

    public init(json: WebJSON) {
        source = json["source"]?.string ?? ""
        kind = json["kind"]?.string ?? ""
        candidates = (json["candidates"]?.array ?? []).map {
            Candidate(path: $0["path"]?.string ?? "", name: $0["name"]?.string ?? "", description: $0["description"]?.string ?? "",
                      have: $0["have"]?.bool ?? false, addsAs: $0["as"]?.string ?? "")
        }
        left = (json["left"]?.array ?? []).map { ($0["path"]?.string ?? "", Int64($0["size"]?.double ?? 0)) }
    }

    public static func == (a: LibraryProbe, b: LibraryProbe) -> Bool {
        a.source == b.source && a.kind == b.kind && a.candidates == b.candidates && a.left.map(\.path) == b.left.map(\.path)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(source)
        hasher.combine(candidates)
    }
}

/// 市场里的一个 MCP 服务器（library.MarketServer）。
public struct LibraryMarketServer: Identifiable, Hashable, Sendable {
    public struct Input: Hashable, Sendable, Identifiable {
        public var key: String
        /// env / header / arg。
        public var place: String
        public var label: String
        public var description: String
        public var placeholder: String
        public var secret: Bool
        public var required: Bool
        public var id: String { place + ":" + key }
    }

    public var id: String
    public var name: String
    public var title: String
    public var description: String
    public var publisher: String
    public var icon: String
    public var homepage: String
    public var transport: String
    public var runs: String
    public var signIn: Bool
    public var featured: Bool
    public var unready: String
    public var inputs: [Input]
    /// 已在资源库里时的名字。
    public var have: String

    public init(json: WebJSON) {
        id = json["id"]?.string ?? ""
        name = json["name"]?.string ?? ""
        title = json["title"]?.string ?? name
        description = json["description"]?.string ?? ""
        publisher = json["publisher"]?.string ?? ""
        icon = json["icon"]?.string ?? ""
        homepage = json["homepage"]?.string ?? ""
        transport = json["transport"]?.string ?? ""
        runs = json["runs"]?.string ?? ""
        signIn = json["signIn"]?.bool ?? false
        featured = json["featured"]?.bool ?? false
        unready = json["unready"]?.string ?? ""
        inputs = (json["inputs"]?.array ?? []).map {
            Input(key: $0["key"]?.string ?? "", place: $0["where"]?.string ?? "", label: $0["label"]?.string ?? "",
                  description: $0["description"]?.string ?? "", placeholder: $0["placeholder"]?.string ?? "",
                  secret: $0["secret"]?.bool ?? false, required: $0["required"]?.bool ?? false)
        }
        have = json["have"]?.string ?? ""
    }

    /// 「远程 · 需登录」/「远程」/「本地」（官方 runsLabel）。
    public var runsLabel: String {
        if transport == "http" || transport == "sse" { return signIn ? "远程 · 需登录" : "远程" }
        return "本地"
    }
}

/// 市场里的一个技能（library.MarketSkill，skills.sh）。
public struct LibraryMarketSkill: Identifiable, Hashable, Sendable {
    public var id: String
    public var source: String
    public var skillID: String
    public var name: String
    public var installs: Int
    public var official: Bool
    public var icon: String
    public var description: String
    public var have: String

    public init(json: WebJSON) {
        id = json["id"]?.string ?? ""
        source = json["source"]?.string ?? ""
        skillID = json["skillId"]?.string ?? ""
        name = json["name"]?.string ?? skillID
        installs = json["installs"]?.int ?? 0
        official = json["official"]?.bool ?? false
        icon = json["icon"]?.string ?? ""
        description = json["description"]?.string ?? ""
        have = json["have"]?.string ?? ""
    }
}

/// 市场搜索的结果（marketJSON）：搜不到注册表时，items 只是 magpie 自己精选的。
public struct LibraryMarket<Item: Hashable & Sendable>: Hashable, Sendable {
    public var items: [Item]
    public var error: String
    public var failed: String
    public var cause: String

    public init(json: WebJSON, item: (WebJSON) -> Item) {
        items = (json["items"]?.array ?? []).map(item)
        error = json["error"]?.string ?? ""
        failed = json["failed"]?.string ?? ""
        cause = json["cause"]?.string ?? ""
    }
}

// MARK: 命令行引号

/// 命令与参数的拆分和引号（官方 quote / words，按 sh 的规则：主机多半是 Mac）。
public enum LibraryShell {
    public static func quote(_ arg: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        if !arg.isEmpty, arg.unicodeScalars.allSatisfy(safe.contains) { return arg }
        return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 把「命令 参数…」拆成词（支持单双引号与反斜杠）。
    public static func words(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quote: Character?
        var any = false
        var chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if c == q { quote = nil }
                else if c == "\\" && q == "\"" && i + 1 < chars.count { i += 1; current.append(chars[i]) }
                else { current.append(c) }
            } else if c == "'" || c == "\"" {
                quote = c
                any = true
            } else if c == "\\" && i + 1 < chars.count {
                i += 1
                current.append(chars[i])
                any = true
            } else if c.isWhitespace {
                if !current.isEmpty || any { out.append(current) }
                current = ""
                any = false
            } else {
                current.append(c)
            }
            i += 1
        }
        if !current.isEmpty || any { out.append(current) }
        chars.removeAll()
        return out
    }

    /// 值里有 `${NAME}` 这样的变量引用。
    public static func hasEnvRef(_ value: String) -> Bool {
        value.range(of: #"\$\{[A-Za-z_][A-Za-z0-9_]*\}"#, options: .regularExpression) != nil
    }

    /// 服务器名只能是字母、数字、- 和 _。
    public static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
    }

    /// 子代理名：小写字母、数字和 -。
    public static func validSubagentName(_ name: String) -> Bool {
        !name.isEmpty && name.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil
    }

    /// 从 README 粘贴的 JSON 里读出服务器（官方 serversIn：`{"mcpServers": {...}}`、一个条目、VS Code 的 `{"servers": {...}}`）。
    public static func servers(fromPasted text: String) -> [LibraryServer]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed.replacingOccurrences(of: #",\s*([}\]])"#, with: "$1", options: .regularExpression)
        var value = try? WebJSON.decode(Data(cleaned.utf8))
        if value == nil {
            var inner = trimmed
            while inner.hasSuffix(",") { inner.removeLast() }
            value = try? WebJSON.decode(Data(("{" + inner + "}").utf8))
        }
        guard let value, let object = value.object else { return nil }
        func one(_ name: String, _ entry: WebJSON) -> LibraryServer? {
            guard entry.object != nil else { return nil }
            let cleanName = name.replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            let url = entry["url"]?.string ?? entry["serverUrl"]?.string ?? entry["httpUrl"]?.string ?? entry["uri"]?.string
            if let url {
                let sse = entry["type"]?.string == "sse" || entry["transport"]?.string == "sse" || url.hasSuffix("/sse") || url.hasSuffix("/sse/")
                let headers = entry["headers"] ?? entry["http_headers"] ?? [:]
                return LibraryServer(json: ["name": .string(cleanName), "transport": sse ? "sse" : "http", "url": .string(url), "headers": headers, "agents": []])
            }
            var command: [String] = []
            if let list = entry["command"]?.array { command = list.map { $0.string ?? "" } }
            else if let single = entry["command"]?.string { command = [single] }
            guard let first = command.first else { return nil }
            let args = Array(command.dropFirst()) + (entry["args"]?.array ?? []).map { $0.string ?? ($0.int.map(String.init) ?? "") }
            let env = entry["env"] ?? entry["environment"] ?? [:]
            return LibraryServer(json: ["name": .string(cleanName), "transport": "stdio", "command": .string(first), "args": .strings(args), "env": env, "agents": []])
        }
        if let map = (object["mcpServers"] ?? object["servers"] ?? object["mcp"] ?? object["context_servers"])?.object {
            let list = map.keys.sorted().compactMap { one($0, map[$0] ?? .null) }
            return list.isEmpty ? nil : list
        }
        if object["command"] != nil || object["url"] != nil || object["serverUrl"] != nil || object["httpUrl"] != nil {
            return one(object["name"]?.string ?? "", value).map { [$0] }
        }
        let list = object.keys.sorted().compactMap { key -> LibraryServer? in
            let entry = object[key] ?? .null
            guard entry["command"] != nil || entry["url"] != nil || entry["serverUrl"] != nil || entry["httpUrl"] != nil else { return nil }
            return one(key, entry)
        }
        return list.isEmpty ? nil : list
    }
}
