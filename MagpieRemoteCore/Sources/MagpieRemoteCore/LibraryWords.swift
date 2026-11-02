import Foundation

// 资源库页的中文文案，逐字照官方 plugins/library/i18n.js 的 zh（App 里的 Agent 名用「、」连接）。

public enum LibraryWords {
    /// 一次改动之后底部状态栏的一句话（官方 report）。`done` 是这个动作自己的说法；`given` 是一行 chip 改动后有它的 Agent。
    public static func report(_ result: LibraryResult?, done: String?, given: [String]? = nil, name: (String) -> String) -> (text: String, warn: Bool)? {
        guard let result else { return done.map { ($0, false) } }
        if !result.gone.isEmpty { return (goneSaid(result.gone), true) }
        if !result.had.isEmpty || !result.skipped.isEmpty {
            var parts: [String] = []
            let n = result.installed.count
            if n > 0 { parts.append(n == 1 ? "已安装 1 个技能" : "已安装 \(n) 个技能") }
            if !result.had.isEmpty { parts.append("资源库里已有：" + result.had.joined(separator: ", ")) }
            for p in result.skipped { parts.append("已跳过 \(p.what.replacingOccurrences(of: "skill:", with: ""))：\(p.error)") }
            return (parts.joined(separator: " · "), !result.skipped.isEmpty)
        }
        if let p = result.problems.first {
            return ("\(name(p.agent))：\(p.error)" + (result.problems.count > 1 ? " （另有 \(result.problems.count - 1) 项）" : ""), true)
        }
        let n = result.changed.count
        let out = given.map { g in result.changed.filter { !g.contains($0) }.count } ?? 0
        if let done { return (done, false) }
        if out > 0 && out == n { return (n == 1 ? "已从 \(name(result.changed[0])) 中移除" : "已从 \(n) 个 Agent 中移除", false) }
        if out > 0 { return ("已更新 \(n) 个 Agent", false) }
        if n > 0 { return (n == 1 ? "已写入 \(name(result.changed[0]))" : "已写入 \(n) 个 Agent", false) }
        return ("已保存 — Agent 中已是最新", false)
    }

    /// 来源里已经没有的技能（官方 goneSaid）。
    public static func goneSaid(_ names: [String]) -> String {
        names.count == 1 ? "\(names[0]) 已从来源中删除" : "\(names.count) 个技能已从来源中删除：\(names.joined(separator: ", "))"
    }

    /// 问题说的是哪一项（官方 problemWhat）。
    public static func problemWhat(_ what: String) -> String {
        let parts = what.split(separator: ":", maxSplits: 1).map(String.init)
        let kind = parts.first ?? what
        let name = parts.count > 1 ? parts[1] : ""
        switch kind {
        case "instructions": return "指令"
        case "mcp": return name.isEmpty ? "MCP 服务器" : "MCP 服务器 \(name)"
        case "skill": return "技能 \(name)"
        case "hook": return "Hook \(name)"
        case "subagent": return "子代理 \(name)"
        case "project": return name.isEmpty ? "项目" : "技能 \(name)"
        default: return what
        }
    }

    /// 「它会从资源库中删除，并从 X 中移除。」（官方 confirmRemoveOne）
    public static func removeOneMessage(agents: [String]) -> String {
        agents.isEmpty ? "它会从资源库中删除；目前没有 Agent 启用它。" : "它会从资源库中删除，并从 \(agents.joined(separator: "、")) 中移除。"
    }

    /// 删除 MCP 服务器前的说明（官方 confirmRemoveServer）。
    public static func removeServerMessage(_ server: LibraryServer, agents: [String], projects: Int) -> String {
        var lines = [removeOneMessage(agents: agents)]
        if projects > 0 { lines.append("magpie 放进 \(projects) 个项目里的它也会一并移除。") }
        if server.signedIn || server.signInDead { lines.append("magpie 对它的登录也会一并清除。") }
        lines.append("Agent 自己的、不在资源库中的服务器保持不变。")
        return lines.joined(separator: "\n")
    }

    /// 删除技能前的说明（官方 confirmRemoveSkill）。
    public static func removeSkillMessage(_ skill: LibrarySkill) -> String {
        skill.kind == "folder" ? "将从所有已启用的 Agent 中移除，链接的原文件夹保持不动。" : "将从所有已启用的 Agent 中移除，文件夹移到 magpie 的备份。"
    }

    /// 删除 Hook 前的说明（官方 confirmRemoveHook）。
    public static func removeHookMessage(agents: [String]) -> String {
        removeOneMessage(agents: agents) + "\nAgent 自己的、不在资源库中的 Hook 保持不变，你在 Agent 文件里改过的也一样。"
    }

    /// 「全部删除」前的标题与说明（官方 confirmRemoveEverySkill / Server / Hook）。
    public static func removeEvery(_ kind: LibraryTab, count n: Int, agents: [String]) -> (title: String, message: String) {
        let what: String
        var extra: [String] = []
        switch kind {
        case .skills: what = "技能"
        case .mcp:
            what = "服务器"
            extra.append("Agent 自己的、不在资源库中的服务器保持不变。")
        default:
            what = "Hook"
            extra.append("Agent 自己的、不在资源库中的 Hook 保持不变，你在 Agent 文件里改过的也一样。")
        }
        let first = agents.isEmpty ? "将从资源库中删除；没有 Agent 启用它们。" : "它们会从资源库中删除，并从 \(agents.joined(separator: "、")) 中移除。"
        return ("删除全部 \(n) 个\(what)？", ([first] + extra).joined(separator: "\n"))
    }

    /// 「全部关闭」前的标题与说明（官方 confirmEveryOff）。
    public static func everyOff(_ kind: LibraryTab, count n: Int, agents: [String]) -> (title: String, message: String) {
        let who = agents.joined(separator: "、")
        if kind == .skills { return ("关闭全部 \(n) 个技能？", "所有技能将从 \(who) 中移除，仍保留在资源库中，可随时重新启用。") }
        return ("关闭全部 \(n) 个服务器？", "所有服务器将从 \(who) 中移除，仍保留在资源库中，可随时重新启用。")
    }

    /// 移除 Agent 里已有的服务器前的说明（官方 confirmRemoveFoundServer）。
    public static func removeFoundServerMessage(_ found: LibraryFoundServer, name: (String) -> String) -> String {
        var text = "将从 \(found.server.agents.map(name).joined(separator: "、")) 的 MCP 配置中移除。每个文件改动前都会先复制到 magpie 的备份。"
        if !found.others.isEmpty { text += "\n\(found.others.map(name).joined(separator: "、")) 中有另一个同名服务器，那个保持不动。" }
        return text
    }

    /// 移除 Agent 里已有的技能前的说明（官方 confirmRemoveFoundSkill）。
    public static func removeFoundSkillMessage(_ found: LibraryFoundSkill, name: (String) -> String, tilde: (String) -> String) -> String {
        let who = found.agents.map(name).joined(separator: "、")
        var lines: [String] = []
        if found.agents.isEmpty { lines.append("文件夹将移到 magpie 的备份。") }
        else if !found.link.isEmpty { lines.append("将从 \(who) 中移除。它链接到的原文件夹保持不动。") }
        else { lines.append("将从 \(who) 中移除，文件夹移到 magpie 的备份。") }
        if !found.shared.isEmpty { lines.append("它在 \(tilde(found.shared)) 中的条目也会移到备份，不会再有 Agent 从那里读取。") }
        if !found.others.isEmpty { lines.append("\(found.others.map(name).joined(separator: "、")) 中有另一个同名 Skill，那个保持不动。") }
        return lines.joined(separator: "\n")
    }

    /// 「交给 magpie 管理」前的说明（官方 confirmHandOver 的简化）。
    public static func handOverMessage(_ skill: LibrarySkill, libraryDir: String, tilde: (String) -> String) -> String {
        if skill.sharedElsewhere { return "它在 ~/.agents/skills 里的条目（指向 \(tilde(skill.source)) 的链接）会被移除。文件夹留在原处，资源库链接到它。" }
        return "它的文件夹会从 \(tilde(skill.shared)) 移入 magpie 的资源库文件夹 \(tilde(libraryDir))。"
    }

    /// 用来源的版本替换本地改动前（官方 confirmUpdateEdited）。
    public static func updateEdited(_ skill: LibrarySkill) -> (title: String, message: String) {
        let repo = skill.gitRepo
        if !repo.isEmpty {
            return ("用 \(repo) 中的版本替换你对 \(skill.name) 的改动？",
                    "从 \(repo) 获取 \(skill.name) 后你在本地改动过它。更新会用那里的版本替换它，你的版本会保存在 magpie 的备份里（资源库顶部的「备份」）。")
        }
        return ("用 GitHub 的版本替换你对 \(skill.name) 的改动？",
                "从 GitHub 获取 \(skill.name) 后你在本地改动过它。更新会用 GitHub 的版本替换它，你的版本会保存在 magpie 的备份里（资源库顶部的「备份」）。")
    }

    /// 清理来源里已经没有的技能前（官方 confirmRemoveGone）。
    public static func removeGone(_ skills: [LibrarySkill]) -> (title: String, message: String) {
        let title = skills.count == 1 ? "移除 \(skills[0].name)？" : "移除 \(skills.count) 个上游已删除的技能？"
        let repos = Set(skills.map(\.groupRepo))
        var first: String
        if repos.count == 1, let repo = repos.first, !repo.isEmpty {
            first = skills.count == 1 ? "\(repo) 里已经没有这个技能了：它在那里被删除了。" : "\(repo) 里已经没有这些技能了：它们在那里被删除了。"
        } else {
            first = "它们的来源里已经没有这些技能了：它们在那里被删除了。"
        }
        let edited = skills.filter(\.edited).map(\.name)
        if !edited.isEmpty { first += "\n本地已改动：" + edited.joined(separator: ", ") }
        return (title, first + "\n它们的文件夹会移到 magpie 的备份里（资料库顶部的“备份”），不会被删除。")
    }

    /// 「全部更新」之后（官方 updateAllSkills）。`page` 是更新后的整页（判断哪些是本地改过的）。
    public static func updatedAll(_ page: LibrarySnapshot) -> (text: String, warn: Bool) {
        guard let result = page.result else { return ("0 个技能已是最新", false) }
        let up = result.updated.count
        let edited = Set(page.skills.filter(\.edited).map { "skill:" + $0.name })
        let kept = result.unupdated.filter { edited.contains($0.what) }.map { $0.what.replacingOccurrences(of: "skill:", with: "") }
        let failed = result.unupdated.filter { !edited.contains($0.what) }
        guard !result.unupdated.isEmpty || !result.gone.isEmpty else {
            return report(result, done: "\(up) 个技能已是最新", name: page.name(of:)) ?? ("\(up) 个技能已是最新", false)
        }
        var parts: [String] = []
        if !result.gone.isEmpty { parts.append(goneSaid(result.gone)) }
        if let p = failed.first {
            parts.append("\(p.what.replacingOccurrences(of: "skill:", with: "")) 未能更新：\(p.error)" + (failed.count > 1 ? " （另有 \(failed.count - 1) 项）" : ""))
        }
        if !kept.isEmpty { parts.append("已保留你改动过的：\(kept.joined(separator: ", "))。如要用 GitHub 的版本替换，请在各自的行里单独更新。") }
        if up > 0 { parts.append("\(up) 个已是最新") }
        return (parts.joined(separator: " · "), true)
    }

    /// 「检查更新」之后（官方 checkSkills）。
    public static func checked(_ page: LibrarySnapshot) -> String {
        let n = page.skillsWithUpdates.count
        var text = n == 0 ? "所有技能都是最新的" : (n == 1 ? "1 个技能有更新" : "\(n) 个技能有更新")
        let more = page.newSkills.count
        if more > 0 { text += " · " + (more == 1 ? "同一仓库里还有 1 个技能" : "同一仓库里还有 \(more) 个技能") }
        let unknown = page.skills.filter { $0.check?.status == "unknown" }
        if let first = unknown.first { text += " · \(unknown.count) 个无法检查：\(first.check?.error ?? "")" }
        return text
    }

    /// 「全部启用 / 全部关闭」按钮下面的小字（官方 everyButtons 的 title）。
    public static func everyHint(_ kind: LibraryTab, on: Bool, agents n: Int) -> String {
        switch (kind, on) {
        case (.skills, true): "为全部 \(n) 个可用的 Agent 启用每个技能"
        case (.skills, false): "从全部 \(n) 个 Agent 中关闭每个技能"
        case (_, true): "为全部 \(n) 个 Agent 启用每个服务器（各自只启用能连接的）"
        case (_, false): "从全部 \(n) 个 Agent 中关闭每个服务器"
        }
    }

    /// 分页顶部的一句介绍（官方各 render* 的 intro）。
    public static func intro(_ tab: LibraryTab) -> String {
        switch tab {
        case .instructions: "只需写一次：下方开启的 Agent 会在每次对话前从各自的指令文件中读取。"
        case .mcp: "服务器只需添加一次，再为需要的 Agent 开启，magpie 会按各 Agent 的格式写入其配置。"
        case .skills: "技能是一个带 SKILL.md 的文件夹，Agent 在需要时加载。资源库只保存一份，再链接到你选的 Agent 中。"
        case .hooks: "Hook 是 Agent 在一轮对话的某个时刻运行的命令——结束时发个通知，改完文件后跑一下格式化。只需添加一次，magpie 会按每个 Agent 自己读取的格式，写进你选中的 Agent。"
        case .subagents: "子代理是有自己提示词的助手，Agent 可以把任务交给它——比如审阅者、测试编写者。添加一次，magpie 就会把它写进你选的每个 Agent，成为该 Agent 自己的子代理文件。"
        case .rtk: "RTK 改写 Agent 执行的命令行命令（git status、cargo test、ls……），只输出模型需要的部分，节省 token。为 Agent 打开后，magpie 会运行 RTK 自带的安装程序。"
        }
    }

    /// 一行 chip 上的说明（官方 agentChips 的 tip）。
    public static func chipHint(agent: LibraryAgent, has: Bool) -> String {
        if agent.gone { return "本机没有安装 \(agent.name)——点一下把它移除" }
        if agent.unseen { return "WSL \(agent.asleep) 未运行，magpie 还没见过 \(agent.name) 在那里的文件：启动该发行版后才能修改" }
        if !agent.asleep.isEmpty {
            return has ? "WSL \(agent.asleep) 未运行：\(agent.name) 已启用——点一下移除，magpie 会在它下次运行时写入"
                : "WSL \(agent.asleep) 未运行：点一下，\(agent.name) 会在该发行版下次运行时启用"
        }
        return has ? "\(agent.name) 已启用 — 点击移除" : "给 \(agent.name) 启用"
    }

    /// 全部 Agent 都开 / 有的开 / 都关的一句话（官方 reportAll 的成功部分）。
    public static func allSaid(_ name: String, on: Int) -> String {
        on > 0 ? "已为全部 \(on) 个 Agent 启用 \(name)" : "已从所有 Agent 中移除 \(name)"
    }
}
