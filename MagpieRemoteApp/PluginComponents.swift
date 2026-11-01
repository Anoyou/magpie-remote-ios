import SwiftUI
import UIKit
import MagpieRemoteCore

// 插件页共用的小部件：图标、种类标签、状态标签、卡片、卡片上的按钮、README。
// 样子照 magpie 网页 plugins.css（pm-logo、pm-chip、pm-card、pm-act），换成系统控件与 Liquid Glass。

// MARK: 图标（官方 logo）

/// 插件的图标：主机保存的图片（`file:`）、App 里有的品牌图标，否则按种类显示一个符号。
struct PluginLogo: View {
    let store: PluginStore
    let icon: String
    let kind: PluginKind
    var big = false

    private var size: CGFloat { big ? 52 : 38 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: big ? 14 : 10, style: .continuous)
                .fill(.thinMaterial)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(big ? 9 : 7)
            } else {
                Image(systemName: kind.symbol)
                    .font(.system(size: big ? 22 : 16, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: icon) { await store.loadIcon(icon) }
    }

    private var image: UIImage? {
        if icon.hasPrefix("file:") { return store.icons[icon].flatMap(UIImage.init(data:)) }
        guard !icon.isEmpty, !icon.contains("/"), !icon.contains(":") else { return nil }
        return UIImage(named: "Brand/" + icon) ?? UIImage(named: icon)
    }
}

// MARK: 标签（官方 pm-chip）

struct PluginChip: View {
    enum Tone { case plain, accent, good, warn, bad, soft }
    let text: String
    var symbol: String?
    var tone: Tone = .plain

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(foreground)
        .background(background, in: Capsule())
    }

    private var foreground: Color {
        switch tone {
        case .plain, .soft: .secondary
        case .accent: .accentColor
        case .good: .green
        case .warn: .orange
        case .bad: .red
        }
    }

    private var background: Color {
        switch tone {
        case .plain: Color.secondary.opacity(0.12)
        case .soft: Color.secondary.opacity(0.08)
        case .accent: Color.accentColor.opacity(0.14)
        case .good: Color.green.opacity(0.14)
        case .warn: Color.orange.opacity(0.14)
        case .bad: Color.red.opacity(0.14)
        }
    }
}

/// 种类标签（官方 kindChip）。
struct PluginKindChip: View {
    let kind: PluginKind
    var title: String?

    var body: some View {
        PluginChip(text: title ?? kind.title, symbol: kind.symbol, tone: .plain)
            .accessibilityHint(kind.detail)
    }
}

// MARK: 卡片上的按钮（官方 actionFor）

struct PluginActionButton: View {
    let store: PluginStore
    let listing: WebPluginListing
    /// 安装前要确认（App 里先确认，再交给主机）。
    let onInstall: (WebPluginListing) -> Void
    let onMove: (PluginMoveCandidate) -> Void
    let onSignIn: (PluginSub) -> Void
    let onOpen: (PluginSub) -> Void

    var body: some View {
        let action = store.action(for: listing)
        Group {
            switch action {
            case .waiting, .installing, .updating, .moving:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    if !action.title.isEmpty { Text(action.title).font(.caption) }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            case .comingSoon:
                Text(action.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .accessibilityHint("还没有发布到 npm")
            case .install:
                Button(action.title) { onInstall(listing) }
                    .buttonStyle(.glassProminent)
                    .disabled(store.isBusy)
            case .move(let candidate, _):
                Button(action.title) { onMove(candidate) }
                    .buttonStyle(.glassProminent)
                    .disabled(store.isBusy)
                    .accessibilityHint("改由此插件运行 \(candidate.name)，账号不变")
            case .switchOn(let spec):
                Button(action.title) {
                    if let plugin = store.plugin(spec) { Task { await store.setEnabled(plugin, true) } }
                }
                .buttonStyle(.glass)
            case .signIn(let sub):
                Button(action.title) { onSignIn(sub) }
                    .buttonStyle(.glassProminent)
            case .update(let spec, let to):
                Button(action.title) {
                    if let plugin = store.plugin(spec) { Task { await store.upgrade(plugin) } }
                }
                .buttonStyle(.glassProminent)
                .tint(.blue)
                .disabled(store.isBusy || store.checking)
                .accessibilityHint(to.isEmpty ? "重新获取最新提交" : "更新到 v\(to)")
            case .signedIn(let sub):
                Button { onOpen(sub) } label: { Label(action.title, systemImage: "checkmark") }
                    .buttonStyle(.glass)
                    .tint(.green)
            case .installed:
                Label(action.title, systemImage: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
        .controlSize(.small)
        .accessibilityIdentifier("plugins.card.action.\(listing.package)")
    }
}

// MARK: 卡片（官方 card）

struct PluginCard: View {
    let store: PluginStore
    let listing: WebPluginListing
    let open: (WebPluginListing) -> Void
    let onInstall: (WebPluginListing) -> Void
    let onMove: (PluginMoveCandidate) -> Void
    let onSignIn: (PluginSub) -> Void
    let onOpen: (PluginSub) -> Void

    var body: some View {
        let entry = store.market.entry(for: listing.package)
        let action = store.action(for: listing)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                PluginLogo(store: store, icon: listing.logo, kind: listing.pluginKind)
                VStack(alignment: .leading, spacing: 2) {
                    Text(listing.name).font(.headline).lineLimit(1)
                    HStack(spacing: 4) {
                        if listing.community {
                            Image(systemName: "checkmark.shield").imageScale(.small)
                            Text("magpie 社区")
                        } else {
                            Text(listing.author)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(listing.community ? Color.accentColor : .secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 6)
                PluginActionButton(store: store, listing: listing, onInstall: onInstall, onMove: onMove, onSignIn: onSignIn, onOpen: onOpen)
            }
            if !listing.summary.isEmpty {
                Text(listing.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    PluginKindChip(kind: listing.pluginKind, title: listing.kind == "hooks" ? "请求 Hook" : nil)
                    if let gh = listing.github {
                        PluginChip(text: PluginFormat.count(gh.stars), symbol: "star")
                            .accessibilityLabel("GitHub 上 \(gh.stars) 个 Star")
                    }
                    if let weekly = listing.npm?.weekly, weekly > 0 {
                        PluginChip(text: "\(PluginFormat.count(weekly))/周", symbol: "arrow.down.to.line")
                            .accessibilityLabel("上周在 npm 下载 \(weekly) 次")
                    }
                    if let version = listing.npm?.version, !version.isEmpty {
                        let up: Bool = {
                            if case .update = action, let entry, entry.npmUpdate { return true }
                            return false
                        }()
                        PluginChip(text: "v" + (entry?.version.isEmpty == false ? entry!.version : version) + (up ? " → v\(entry!.latest)" : ""),
                                   tone: up ? .accent : .soft)
                    }
                    if let entry, entry.error != nil, !entry.off { PluginChip(text: "加载失败", tone: .bad) }
                    else if let entry, entry.off { PluginChip(text: "关闭") }
                    if !listing.replaces.isEmpty {
                        PluginChip(text: "替代内置", tone: .soft)
                            .accessibilityHint("magpie 内置的此订阅登录已弃用：由此插件接替，内置里登录的账号会迁到插件")
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { open(listing) }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "详情") { open(listing) }
        .accessibilityIdentifier("plugins.card.\(listing.package)")
    }
}

// MARK: README（官方 markdown）

struct PluginReadmeView: View {
    let blocks: [ReadmeBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text, _):
                    Self.inline(text)
                        .font(level <= 1 ? .title3.weight(.bold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                        .padding(.top, level <= 2 ? 6 : 2)
                case .paragraph(let text):
                    Self.inline(text).font(.callout)
                case .code(_, let text):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(text).font(.caption.monospaced()).textSelection(.enabled).padding(10)
                    }
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                case .list(let ordered, let items):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(ordered ? "\(i + 1)." : "•").font(.callout).foregroundStyle(.secondary)
                                Self.inline(item).font(.callout)
                            }
                        }
                    }
                case .quote(let text):
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.4)).frame(width: 3)
                        Self.inline(text).font(.callout).foregroundStyle(.secondary)
                    }
                case .table(let rows):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                                GridRow {
                                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                        Self.inline(cell).font(r == 0 ? .caption.weight(.semibold) : .caption)
                                    }
                                }
                                if r == 0 { Divider() }
                            }
                        }
                        .padding(8)
                    }
                case .rule:
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 行内 Markdown（粗体、斜体、代码、链接）；解析失败时原样显示。
    static func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: text, options: options) { return Text(attributed) }
        return Text(text)
    }
}

// MARK: 网页（插件页面、登录）

/// 插件自带的页面、供应商登录要在 magpie 网页里完成：在 App 内打开 `/?view=<页面>`，Cookie 带 Web 密钥。
struct PluginWebPageView: View {
    let service: (any PluginServing)?
    let view: String
    var extra: [URLQueryItem] = []
    let title: String

    var body: some View {
        Group {
            if let target = service?.webPage(view: view, extra: extra) {
                MagpieWebView(url: target.url, cookieName: target.cookieName, key: target.key)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                ContentUnavailableView {
                    Label(title, systemImage: "macwindow")
                } description: {
                    Text(service == nil ? "先为这台主机填写 Web 密钥。" : "示例模式下不会打开网页。连接真实主机后，这里显示 magpie 网页里的「\(title)」。")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("plugins.web.placeholder")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 网页里打开的目标（sheet 用）。
struct PluginWebTarget: Identifiable, Hashable {
    var view: String
    var extra: [URLQueryItem] = []
    var title: String
    var id: String { view + "?" + extra.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&") }
}

struct PluginWebSheet: View {
    let service: (any PluginServing)?
    let target: PluginWebTarget
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PluginWebPageView(service: service, view: target.view, extra: target.extra, title: target.title)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                }
        }
    }
}

// MARK: 弹窗

extension View {
    /// 插件页的操作失败提示。导航栈与弹出的表单里可能同时有好几个插件页面，只由最上面的那个负责弹出（`id` 区分）。
    func pluginAlerts(store: PluginStore, id: String) -> some View {
        modifier(PluginAlerts(store: store, id: id))
    }
}

private struct PluginAlerts: ViewModifier {
    let store: PluginStore
    let id: String

    private var active: Bool { store.presenters.last == id }

    func body(content: Content) -> some View {
        content
            .onAppear { store.presenters.removeAll { $0 == id }; store.presenters.append(id) }
            .onDisappear { store.presenters.removeAll { $0 == id } }
            .alert(store.actionError?.title ?? "", isPresented: Binding(get: { active && store.actionError != nil },
                                                                       set: { if !$0 { store.actionError = nil } })) {
                Button("好") { store.actionError = nil }
            } message: {
                Text([store.actionError?.message, store.actionError?.hint].compactMap { $0 }.joined(separator: "\n"))
            }
    }
}

/// 页面顶部的一句提示（官方状态栏）。
struct PluginNoticeRow: View {
    let notice: PluginStore.Notice

    var body: some View {
        Label(notice.text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(color)
            .accessibilityIdentifier("plugins.notice")
    }

    private var symbol: String {
        switch notice.kind {
        case .ok: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch notice.kind {
        case .ok: .green
        case .warn: .orange
        case .error: .red
        }
    }
}
