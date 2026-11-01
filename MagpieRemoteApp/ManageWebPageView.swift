import SwiftUI
import UIKit
import WebKit
import MagpieRemoteCore

/// 只能在 magpie 网页里完成的功能（账号登录、备份、脱敏）：在 App 内用 WKWebView 打开主机上的管理网页。
/// 打开前把 Web 密钥写进 Cookie（`magpie_web_<端口>`），首个地址再带一次 `?k=`（主机会 303 去掉它）；
/// 供应商的登录页等外部链接交给系统浏览器打开。
struct ManageWebPageView: View {
    let store: ManageStore
    let page: MagpieWebPage

    var body: some View {
        Group {
            if let target = store.service?.page(page) {
                MagpieWebView(url: target.url, cookieName: target.cookieName, key: target.key)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                ContentUnavailableView {
                    Label(page.title, systemImage: page.symbol)
                } description: {
                    Text(store.service == nil ? "先为这台主机填写 Web 密钥。" : "示例模式下不会打开网页。连接真实主机后，这里显示 magpie 的「\(page.title)」页面。")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("manage.web.placeholder")
            }
        }
        .navigationTitle(page.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MagpieWebView: UIViewRepresentable {
    let url: URL
    let cookieName: String
    let key: String

    func makeCoordinator() -> Coordinator { Coordinator(home: url) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // 不持久化：Cookie 与网页缓存只在这次打开期间存在。
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: cookieName, .value: key, .domain: url.host ?? "", .path: "/",
        ]
        if url.scheme == "https" { properties[.secure] = "TRUE" }
        let cookie = HTTPCookie(properties: properties)
        let request = URLRequest(url: url)
        Task {
            if let cookie { await webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) }
            webView.load(request)
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let home: URL

        init(home: URL) { self.home = home }

        private func isMagpie(_ url: URL) -> Bool {
            url.host == home.host && url.port == home.port
        }

        private func openExternally(_ url: URL) {
            guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return }
            UIApplication.shared.open(url)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .allow }
            if url.scheme == "about" || url.scheme == "blob" || url.scheme == "data" || isMagpie(url) { return .allow }
            // 供应商的 OAuth 登录、官网等：系统浏览器打开（Safari 里可以用已保存的密码和通行密钥）。
            openExternally(url)
            return .cancel
        }

        /// 网页里 `window.open` / target=_blank 的链接。
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                if isMagpie(url) { webView.load(navigationAction.request) } else { openExternally(url) }
            }
            return nil
        }
    }
}
