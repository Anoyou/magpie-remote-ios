import Foundation

/// 发给主机的 User-Agent。
///
/// magpie 按 User-Agent 开头的名字把请求记到「来源 / Agent」下，开头是 `magpie` 的会被当成 magpie 自己，
/// iOS 默认的 `MagpieRemote/1 CFNetwork/…` 正好会被误判。所以这里固定用不以 magpie 开头的名字，
/// 让「用量」里能看出哪些请求来自这台 iPhone。
public enum ClientIdentity {
    public static let product = "iPhone-Remote"

    public static var userAgent: String {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
        return "\(product)/\(version) (MagpieRemote iOS)"
    }
}
