import SwiftUI
import Observation
import MagpieRemoteCore

/// 底栏放哪 4 个页面。保存在本机 UserDefaults（每台设备一份，不分主机）；示例模式不保存。
@MainActor
@Observable
final class DockStore {
    static let defaultsKey = "dock.pages"

    private let defaults: UserDefaults?
    private(set) var layout: DockLayout

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        // 0.2 及以前的底栏（额度 / 用量 / 对话 / 管理）是固定的、没有保存过，所以老用户第一次打开就是新的默认底栏。
        let stored = defaults?.stringArray(forKey: Self.defaultsKey)
        layout = DockLayout(stored: stored)
        // 0.3 存下的 Agent / 供应商 / 额度已并入「主页」：整理后的布局写回去，下次不用再换。
        if let stored, stored != layout.stored {
            if layout.isDefault { defaults?.removeObject(forKey: Self.defaultsKey) } else { defaults?.set(layout.stored, forKey: Self.defaultsKey) }
        }
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        update { $0.move(fromOffsets: source, toOffset: destination) }
    }

    func place(_ page: AppPage, at index: Int) {
        update { $0.place(page, at: index) }
    }

    func shift(_ page: AppPage, by offset: Int) {
        update { $0.shift(page, by: offset) }
    }

    func reset() {
        update { $0.reset() }
    }

    private func update(_ change: (inout DockLayout) -> Void) {
        var next = layout
        change(&next)
        guard next != layout else { return }
        withAnimation { layout = next }
        if next.isDefault {
            defaults?.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults?.set(next.stored, forKey: Self.defaultsKey)
        }
    }
}

/// 「更多 › 自定义底栏」：选底栏前 4 个位置放哪些页面、拖动排序、恢复默认。第 5 个固定是「更多」。
struct DockCustomizeView: View {
    @Environment(AppModel.self) private var model

    private var dock: DockStore { model.dock }

    var body: some View {
        List {
            Section {
                ForEach(Array(dock.layout.pages.enumerated()), id: \.element) { index, page in
                    DockSlotRow(dock: dock, index: index, page: page)
                }
                .onMove { dock.move(fromOffsets: $0, toOffset: $1) }

                HStack(spacing: 12) {
                    Text("5").monospacedDigit().foregroundStyle(.secondary).frame(width: 18)
                    Label("更多", systemImage: "ellipsis.circle")
                    Spacer()
                    Text("固定").foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("dock.slot.more")
            } header: {
                Text("底栏")
            } footer: {
                Text("按住一行拖动可调整顺序（或点右上角「编辑」）；点右侧的按钮换成别的页面。第 5 个位置固定是「更多」。只保存在这台设备上，所有主机通用。")
            }

            Section {
                ForEach(dock.layout.morePages) { page in
                    DockCandidateRow(dock: dock, page: page)
                }
            } header: {
                Text("在「更多」里")
            } footer: {
                Text("点一个页面，选择放到底栏的哪个位置；被换下来的页面会回到「更多」。")
            }

            Section {
                Button("恢复默认") { dock.reset() }
                    .disabled(dock.layout.isDefault)
                    .accessibilityIdentifier("dock.reset")
            } footer: {
                Text("默认底栏：" + (DockLayout.defaultPages.map(\.title) + ["更多"]).joined(separator: "、") + "。")
            }
        }
        .navigationTitle("自定义底栏")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { EditButton() }
        }
    }
}

/// 底栏里的一个位置：序号、页面名，右侧菜单可换成别的页面或上下移动。
private struct DockSlotRow: View {
    let dock: DockStore
    let index: Int
    let page: AppPage

    var body: some View {
        HStack(spacing: 12) {
            Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 18)
            Label(page.title, systemImage: page.symbol)
                .accessibilityIdentifier("dock.slot.\(index)")
            Spacer()
            Menu {
                Section("换成") {
                    ForEach(dock.layout.morePages) { other in
                        Button {
                            dock.place(other, at: index)
                        } label: {
                            Label(other.title, systemImage: other.symbol)
                        }
                        .accessibilityIdentifier("dock.slot.\(index).use.\(other.rawValue)")
                    }
                }
                Section {
                    Button("左移") { dock.shift(page, by: -1) }
                        .disabled(index == 0)
                    Button("右移") { dock.shift(page, by: 1) }
                        .disabled(index == DockLayout.slotCount - 1)
                }
            } label: {
                Image(systemName: "arrow.left.arrow.right.circle")
                    .imageScale(.large)
            }
            .accessibilityLabel("更换第 \(index + 1) 个位置的「\(page.title)」")
            .accessibilityIdentifier("dock.slot.\(index).menu")
        }
    }
}

/// 「更多」里的一个页面：点开选择放进底栏的哪个位置。
private struct DockCandidateRow: View {
    let dock: DockStore
    let page: AppPage

    var body: some View {
        Menu {
            Section("放进底栏") {
                ForEach(Array(dock.layout.pages.enumerated()), id: \.element) { index, current in
                    Button("第 \(index + 1) 个位置（换下「\(current.title)」）") {
                        dock.place(page, at: index)
                    }
                    .accessibilityIdentifier("dock.place.\(index)")
                }
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(page.title).foregroundStyle(.primary)
                    Text(page.detail).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: page.symbol)
            }
            // 整行都能点开菜单（不然只有文字那一小块能点，点行的右半边没反应）。
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .accessibilityIdentifier("dock.candidate.\(page.rawValue)")
    }
}
