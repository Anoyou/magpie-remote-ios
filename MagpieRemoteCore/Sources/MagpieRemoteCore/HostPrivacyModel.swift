import Foundation

// 「管理 › 隐私模型」：脱敏时在 Mac 本地运行、用来找出规则找不到的姓名 / 地址 / 密码的小模型
// （internal/gui/privacymodel.go、internal/pii）。
//
// GET  /api/privacy-model → privacyModelJSON：{on, chosen?, <pii.Status 平铺>, minScore, defaultScore, models[pii.Status]}
// POST /api/privacy-model {"do": on|off|cancel|remove|pick|score, "model": id, "score": s} → 同上
//   on：打开（没下载时先下载，下好后才生效）；off：关闭（模型保留在磁盘上）；cancel：停止下载；
//   remove：关闭并删除所有已下载的模型；pick：选模型（打开时等于换成它，关闭时只记住）；
//   score：阈值，0 = 模型默认，否则 0.5...<1。model 只能是 privacy-filter 或 astrlink-guard。

/// 一个本地模型的状态（`pii.Status`）。
public struct PrivacyModelStatus: Hashable, Identifiable, Sendable {
    public var model: String
    public var supported: Bool
    public var installed: Bool
    public var size: Int64
    public var downloading: Bool
    public var done: Int64
    public var total: Int64
    public var error: String
    public var running: Bool
    public var device: String
    public var via: String
    public var gpu: Bool
    public var gpuError: String
    public var failed: String
    public var loading: Bool

    public var id: String { model }

    public init(json: WebJSON?) {
        model = json?["model"]?.string ?? ""
        supported = json?["supported"]?.bool ?? false
        installed = json?["installed"]?.bool ?? false
        size = Int64(json?["size"]?.int ?? 0)
        downloading = json?["downloading"]?.bool ?? false
        done = Int64(json?["done"]?.int ?? 0)
        total = Int64(json?["total"]?.int ?? 0)
        error = json?["error"]?.string ?? ""
        running = json?["running"]?.bool ?? false
        device = json?["device"]?.string ?? ""
        via = json?["via"]?.string ?? ""
        gpu = json?["gpu"]?.bool ?? false
        gpuError = json?["gpuError"]?.string ?? ""
        failed = json?["failed"]?.string ?? ""
        loading = json?["loading"]?.bool ?? false
    }

    /// 能在这台 Mac 上用（或已经下载了）。
    public var usable: Bool { supported || installed }

    public var name: String { PrivacyModelState.name(model) }
    public var about: String { PrivacyModelState.about(model) }

    /// 选择列表里的副标题。
    public var note: String {
        if !usable { return "这台主机暂不支持" }
        var parts = [about, HostToolsFormat.bytes(size)].filter { !$0.isEmpty }
        if installed { parts.append("已下载") }
        return parts.joined(separator: " · ")
    }

    public var progress: Double? { downloading && total > 0 ? min(1, Double(done) / Double(total)) : nil }
}

/// `GET /api/privacy-model` 的结果。
public struct PrivacyModelState: Hashable, Sendable {
    /// 是否打开（用户打开的，或默认打开）。
    public var on: Bool
    /// 是用户自己打开的（只有这时模型出错会扣下请求）。
    public var chosen: Bool
    /// 正在用（或打开后会用）的模型。
    public var current: PrivacyModelStatus
    public var minScore: Double
    public var defaultScore: Double
    public var models: [PrivacyModelStatus]

    public init(json: WebJSON) {
        on = json["on"]?.bool ?? false
        chosen = json["chosen"]?.bool ?? false
        current = PrivacyModelStatus(json: json)
        minScore = json["minScore"]?.double ?? 0
        defaultScore = json["defaultScore"]?.double ?? 0
        models = (json["models"]?.array ?? []).map { PrivacyModelStatus(json: $0) }
    }

    /// 正在下载的模型（可能是打开状态下换的另一个）。
    public var downloadingModel: PrivacyModelStatus? {
        models.first(where: \.downloading) ?? (current.downloading ? current : nil)
    }

    /// 上次下载失败的模型。
    public var failedDownload: PrivacyModelStatus? {
        models.first { !$0.error.isEmpty } ?? (current.error.isEmpty ? nil : current)
    }

    /// 开关在界面上显示为打开（下载中也算）。
    public var showsOn: Bool { on || current.downloading }

    /// 主机能跑本地模型。
    public var usable: Bool { current.usable }

    /// 已下载、但现在关着：可以删除。
    public var canRemove: Bool { current.installed && !on && downloadingModel == nil }

    /// 阈值用的是默认值。
    public var usesDefaultScore: Bool { minScore == defaultScore }

    /// 下载中或模型正在启动：界面应每秒再读一次。
    public var isWorking: Bool {
        downloadingModel != nil || (on && current.installed && !current.running && current.failed.isEmpty)
    }

    /// 一句话中文状态（与 magpie 网页「设置 › 隐私」相同的判断顺序）。
    public var summary: String {
        if !current.usable { return "这台主机暂时不能运行本地脱敏模型。" }
        if let d = downloadingModel {
            return "正在下载 \(d.name)：\(HostToolsFormat.bytes(d.done)) / \(HostToolsFormat.bytes(d.total))"
        }
        if let bad = failedDownload { return "下载中断了：\(bad.error)" }
        if on && !current.failed.isEmpty {
            return chosen ? "模型没有回应，请求会被扣下：\(current.failed)" : "模型没有回应，暂时只用规则脱敏：\(current.failed)"
        }
        if on && current.running {
            if current.gpu { return "已打开，运行在 GPU（\(current.device)）上。" }
            if !current.via.isEmpty {
                switch current.device {
                case "Neural Engine": return "已打开，用 CoreML 运行在神经网络引擎上。"
                case "GPU": return "已打开，用 CoreML 运行在 GPU 上。"
                case "CPU": return "已打开，用 CoreML 运行在 CPU 上。"
                default: return "已打开，用 CoreML 运行。"
                }
            }
            if !current.gpuError.isEmpty {
                return current.model == PrivacyModelState.astrLinkGuard
                    ? "已打开，运行在 CPU 上（CoreML 失败：\(current.gpuError)）。"
                    : "已打开，运行在 CPU 上（GPU 失败：\(current.gpuError)）。"
            }
            return "已打开，运行在 CPU 上。"
        }
        if on { return "已打开：下一次请求时启动模型。" }
        if current.installed { return "已关闭。模型已下载（\(HostToolsFormat.bytes(current.size))）。" }
        return "已关闭。打开时会先下载一次（\(HostToolsFormat.bytes(current.size))）。"
    }

    /// 模型 id。
    public static let privacyFilter = "privacy-filter"
    public static let astrLinkGuard = "astrlink-guard"

    public static func name(_ id: String) -> String {
        switch id {
        case privacyFilter: "Privacy Filter"
        case astrLinkGuard: "AstrLink Guard"
        default: id
        }
    }

    public static func about(_ id: String) -> String {
        switch id {
        case astrLinkGuard: "中英文都支持，代码里误报少"
        case privacyFilter: "OpenAI 出品，代码里会遮掉更多普通值"
        default: ""
        }
    }

    /// 可选阈值（0 表示模型默认），与网页一致。
    public static let scoreOptions: [Double] = [0.5, 0.6, 0.7, 0.8, 0.85, 0.9, 0.95]

    /// 阈值选项：先是「默认（x）」(值 0)，再是其余固定档。
    public var scoreChoices: [PrivacyScoreChoice] {
        [PrivacyScoreChoice(value: 0, title: "默认（\(Self.score(defaultScore))）")]
            + Self.scoreOptions.filter { $0 != defaultScore }.map { PrivacyScoreChoice(value: $0, title: Self.score($0)) }
    }

    /// 当前选中的阈值选项值（默认时为 0）。
    public var selectedScore: Double { usesDefaultScore ? 0 : minScore }

    public static func score(_ s: Double) -> String {
        var text = String(format: "%.2f", s)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// 阈值选项。
public struct PrivacyScoreChoice: Hashable, Identifiable, Sendable {
    public var value: Double
    public var title: String
    public var id: Double { value }
}

/// `POST /api/privacy-model` 的操作。
public enum PrivacyModelAction: Hashable, Sendable {
    case on(model: String?)
    case off
    case cancel
    case remove
    case pick(model: String)
    /// 0 = 模型默认。
    case score(Double, model: String?)

    public var body: WebJSON {
        switch self {
        case .on(let model):
            var b: WebJSON = ["do": "on"]
            if let model, !model.isEmpty { b["model"] = .string(model) }
            return b
        case .off: return ["do": "off"]
        case .cancel: return ["do": "cancel"]
        case .remove: return ["do": "remove"]
        case .pick(let model): return ["do": "pick", "model": .string(model)]
        case .score(let s, let model):
            var b: WebJSON = ["do": "score", "score": .double(s)]
            if let model, !model.isEmpty { b["model"] = .string(model) }
            return b
        }
    }

    /// 主机只接受 0 或 0.5...<1（pii.Floor = 0.5）。
    public static func validScore(_ s: Double) -> Bool { s == 0 || (s >= 0.5 && s < 1) }
}

extension WebClient {
    public func privacyModel() async throws -> PrivacyModelState {
        PrivacyModelState(json: try await get("/api/privacy-model"))
    }

    public func privacyModel(_ action: PrivacyModelAction) async throws -> PrivacyModelState {
        if case .score(let s, _) = action, !PrivacyModelAction.validScore(s) {
            throw MagpieError.webRejected(message: "阈值只能是默认，或 0.5 到 1 之间（不含 1）。", code: nil)
        }
        return PrivacyModelState(json: try await post("/api/privacy-model", action.body))
    }
}
