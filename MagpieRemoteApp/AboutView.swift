import SwiftUI
import UIKit
import MagpieRemoteCore

struct AboutView: View {
    static let repositoryURL = URL(string: "https://github.com/Anoyou/magpie-remote-ios")!
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "未知" }

    var body: some View {
        List {
            Section {
                LabeledContent("版本", value: Self.version)
                    .accessibilityIdentifier("about.version")
                LabeledContent("构建号", value: Self.build)
                    .accessibilityIdentifier("about.build")
                LabeledContent("系统", value: UIDevice.current.systemName + " " + UIDevice.current.systemVersion)
            }
            Section {
                NavigationLink("更新日志") { ChangelogView() }
                    .accessibilityIdentifier("about.changelog")
                Link("项目主页（GitHub）", destination: Self.repositoryURL)
            } footer: {
                Text("Magpie Remote 是 magpie 的非官方 iOS 遥控器。它只连接你自己的主机，不收集任何数据。")
            }
        }
        .navigationTitle("关于")
    }
}

/// 读取随 App 打包的 CHANGELOG.md，离线显示。
struct ChangelogView: View {
    private let releases: [ChangelogRelease]

    init(bundle: Bundle = .main) {
        if let url = bundle.url(forResource: "CHANGELOG", withExtension: "md"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            releases = Changelog.parse(text)
        } else {
            releases = []
        }
    }

    var body: some View {
        Group {
            if releases.isEmpty {
                ContentUnavailableView("没有找到更新日志", systemImage: "doc.text")
            } else {
                List {
                    ForEach(releases) { release in
                        Section {
                            if let note = release.note {
                                Text(note).font(.footnote).foregroundStyle(.secondary)
                            }
                            ForEach(release.groups) { group in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(group.title).font(.subheadline.weight(.semibold))
                                    ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                                            Text("•").foregroundStyle(.secondary)
                                            Text(Self.inline(item)).font(.callout).fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(release.version).font(.headline)
                                Text([release.date, release.theme].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption)
                            }
                        }
                    }
                }
                .accessibilityIdentifier("changelog.list")
            }
        }
        .navigationTitle("更新日志")
    }

    /// 支持 **粗体**、`代码` 等行内 Markdown；解析失败时原样显示。
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
