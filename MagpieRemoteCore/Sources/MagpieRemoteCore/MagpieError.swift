import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 连不上主机时的具体原因（决定提示语）。
public enum UnreachableReason: String, Equatable, Sendable {
    case timedOut
    case refused
    case hostNotFound
    case offline
    case insecureBlocked
    case other
}

/// App 内所有与主机通信相关的错误。`title` / `message` / `hint` 都是给普通用户看的中文。
public enum MagpieError: Error, Equatable, Sendable {
    /// 主机没有开启「在局域网共享」，或这台 iPhone 不在主机的允许地址列表里（403）。
    case lanSharingOff(detail: String?)
    /// 密钥无效、已停用或已删除（401）。
    case invalidKey
    /// 这把网关密钥不允许使用该模型（403）。
    case modelNotAllowed(model: String?)
    /// 连不上主机（连接被拒、超时、找不到主机、没联网）。
    case unreachable(UnreachableReason)
    /// 主机上的 magpie 版本与 App 不兼容。
    case incompatibleHost(found: String?, required: String)
    /// 这台主机还没有填对应的密钥。
    case missingKey(HostSecretKind)
    /// 地址填写有误。
    case invalidURL
    /// 其它 HTTP 错误。
    case http(status: Int, message: String?)
    /// 主机返回的数据看不懂（多半也是版本不兼容）。
    case decoding(String)
    case cancelled
    /// Web 管理接口（3430）不认这把 Web 密钥（401 纯文本）。
    case webKeyInvalid
    /// Web 管理接口拒绝访问（403 纯文本）：`ownWindowOnly` 为 true 表示被当成了跨站请求，否则是允许列表。
    case webForbidden(ownWindowOnly: Bool, detail: String?)
    /// Web 管理接口执行操作失败（400 `{"error","code"}`），`message` 是 magpie 的原文。
    case webRejected(message: String, code: String?)

    public var title: String {
        switch self {
        case .lanSharingOff: "未开启局域网共享"
        case .invalidKey: "密钥无效"
        case .modelNotAllowed: "模型不允许"
        case .unreachable: "连不上主机"
        case .incompatibleHost: "主机版本不兼容"
        case .missingKey(let kind): "还没有填写\(kind.title)"
        case .invalidURL: "地址无效"
        case .http(let status, _): "主机返回错误（\(status)）"
        case .decoding: "主机版本不兼容"
        case .cancelled: "已取消"
        case .webKeyInvalid: "页面密钥无效"
        case .webForbidden: "主机拒绝访问"
        case .webRejected: "主机没有执行这个操作"
        }
    }

    public var message: String {
        switch self {
        case .lanSharingOff:
            return "主机拒绝了来自这台 iPhone 的请求：magpie 还没有开启「在局域网共享」，或这台设备的地址不在允许列表里。"
        case .invalidKey:
            return "主机不认这把密钥：可能填错了、已被停用或已删除。"
        case .modelNotAllowed(let model):
            if let model, !model.isEmpty { return "这把网关密钥不允许使用模型「\(model)」。" }
            return "这把网关密钥不允许使用这个模型。"
        case .unreachable(let reason):
            switch reason {
            case .timedOut: return "等了很久主机都没有回应。"
            case .refused: return "主机拒绝连接：magpie 可能没有运行，或没有开启「在局域网共享」。"
            case .hostNotFound: return "找不到这个主机地址。"
            case .offline: return "这台 iPhone 现在没有联网。"
            case .insecureBlocked: return "系统阻止了这次不安全的连接。"
            case .other: return "无法连接到主机。"
            }
        case .incompatibleHost(let found, let required):
            let current = found.map { "当前为 \($0)，" } ?? ""
            return "主机上的 magpie 版本与 App 不兼容（\(current)需要 \(required) 或更新）。"
        case .missingKey(let kind):
            return "请在「主机」设置里为这台主机填写\(kind.title)。"
        case .invalidURL:
            return "请检查主机地址，例如 100.64.0.1 或 my-mac.tailnet.example。"
        case .http(_, let message):
            return message.flatMap { $0.isEmpty ? nil : $0 } ?? "请稍后再试。"
        case .decoding:
            return "主机返回的数据 App 看不懂，通常是 magpie 版本过旧或过新。"
        case .cancelled:
            return "操作已取消。"
        case .webKeyInvalid:
            return "magpie 的网页管理不认这把 Web 密钥：可能填错了，或主机上的 MAGPIE_WEB_KEY 已更换。"
        case .webForbidden(let ownWindowOnly, let detail):
            if ownWindowOnly { return "magpie 只接受来自它自己页面的管理请求，这次请求被当成了跨站请求。" }
            let suffix = detail.flatMap { $0.isEmpty ? nil : "（\($0)）" } ?? ""
            return "这台 iPhone 的地址不在 magpie 的允许列表里\(suffix)。"
        case .webRejected(let message, _):
            return "magpie 提示：\(message)"
        }
    }

    /// 下一步怎么做（可能为空）。
    public var hint: String? {
        switch self {
        case .lanSharingOff:
            return "在 Mac 上打开 magpie → 设置 → 网络与共享，开启「在局域网共享」；需要时把 iPhone 的地址加入允许列表。"
        case .invalidKey:
            return "在 magpie 里重新创建或复制密钥，然后在 App 的「主机」设置里更新。"
        case .modelNotAllowed:
            return "在 magpie 的密钥设置里放开这个模型，或换一个允许的模型。"
        case .unreachable(let reason):
            if reason == .offline { return "连上 Wi-Fi 或蜂窝网络后再试。" }
            return "确认 Mac 已开机、magpie 正在运行、地址和端口正确。不在同一个局域网时，请先在 iPhone 和 Mac 上都打开 Tailscale（或 WireGuard），再用它分配的地址连接；不要把端口开放到公网。"
        case .incompatibleHost, .decoding:
            return "把 Mac 上的 magpie 和这个 App 都更新到最新版本。"
        case .missingKey, .invalidURL:
            return nil
        case .http(let status, _):
            return status >= 500 ? "主机内部出错，稍后再试；仍有问题请查看 magpie 的日志。" : nil
        case .cancelled:
            return nil
        case .webKeyInvalid:
            return "在 Mac 上查看 magpie daemon web 使用的 MAGPIE_WEB_KEY，然后在 App 的「主机」设置里更新 Web 密钥。"
        case .webForbidden(let ownWindowOnly, _):
            if ownWindowOnly { return "请把 App 和 magpie 都更新到最新版本；仍有问题可以改用「在网页中打开」。" }
            return "在 Mac 上打开 magpie → 设置 → 网络与共享，把这台 iPhone 的地址加入允许列表（或清空允许列表）。"
        case .webRejected(_, let code):
            switch code {
            case "runtime_unavailable": return "主机上缺少运行这个操作需要的组件，请在 Mac 上处理后再试。"
            case "config_blocked": return "Agent 的配置文件被锁定或不可写，请在 Mac 上检查。"
            default: return nil
            }
        }
    }

    /// 是否值得引导用户去「配置引导」页。
    public var suggestsSetupGuide: Bool {
        switch self {
        case .lanSharingOff, .unreachable, .invalidKey, .missingKey, .webKeyInvalid: true
        default: false
        }
    }
}

extension MagpieError: LocalizedError {
    public var errorDescription: String? { title + "：" + message }
}

extension MagpieError {
    /// 根据 HTTP 状态码与响应体判断错误类型。
    ///
    /// TODO(spec): 403 的细分目前按 magpie 源码里的英文提示做关键字匹配（"allow list"、"model"），
    /// 等 spec/ 里的错误契约确定后改为按错误码判断。
    public static func from(status: Int, body: Data?, model: String? = nil) -> MagpieError {
        let message = body.flatMap(Self.errorMessage(from:))
        switch status {
        case 401:
            return .invalidKey
        case 403:
            let text = (message ?? "").lowercased()
            if text.contains("allow list") || text.contains("not shared") || text.contains("lan") || text.contains("sharing") {
                return .lanSharingOff(detail: message)
            }
            if text.contains("model") {
                return .modelNotAllowed(model: model)
            }
            return .lanSharingOff(detail: message)
        case 404, 405, 426:
            // 接口不存在：多半是主机上的 magpie 太旧，没有这个接口。
            return .incompatibleHost(found: nil, required: MagpieCompatibility.minimumHostVersion.description)
        default:
            return .http(status: status, message: message)
        }
    }

    /// 从常见的错误响应里取出可读的提示：OpenAI 形状 `{"error":{"message":…}}`、`{"error":"…"}`、`{"message":…}` 或纯文本。
    public static func errorMessage(from body: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
            if let error = object["error"] as? String { return error }
            if let message = object["message"] as? String { return message }
            if let detail = object["detail"] as? String { return detail }
        }
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(500))
    }

    /// 把任意错误（URLError、解码错误等）统一成 `MagpieError`。
    public static func from(_ error: any Error) -> MagpieError {
        if let error = error as? MagpieError { return error }
        if error is CancellationError { return .cancelled }
        if let error = error as? URLError { return from(urlError: error) }
        if error is DecodingError { return .decoding(String(describing: error)) }
        return .unreachable(.other)
    }

    public static func from(urlError: URLError) -> MagpieError {
        switch urlError.code {
        case .cancelled: return .cancelled
        case .timedOut: return .unreachable(.timedOut)
        case .cannotConnectToHost, .networkConnectionLost: return .unreachable(.refused)
        case .cannotFindHost, .dnsLookupFailed: return .unreachable(.hostNotFound)
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: return .unreachable(.offline)
        case .appTransportSecurityRequiresSecureConnection, .secureConnectionFailed,
             .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot:
            return .unreachable(.insecureBlocked)
        case .badURL, .unsupportedURL: return .invalidURL
        case .userAuthenticationRequired: return .invalidKey
        default: return .unreachable(.other)
        }
    }
}
