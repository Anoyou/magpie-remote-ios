import SwiftUI
import MagpieRemoteCore

/// magpie 官方标志（供应商 / 模型厂商 / Agent）。照网页 `icon()`：彩色图原样显示，单色图跟随文字颜色，
/// `generic` 画通用的立方体轮廓（次要颜色），没有图标时留同样大小的空位。纯装饰，不进无障碍朗读。
struct BrandIcon: View {
    let name: String?
    var size: CGFloat = 18

    init(_ name: String?, size: CGFloat = 18) {
        self.name = name
        self.size = size
    }

    var body: some View {
        content
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        switch OfficialIcon.mark(name) {
        case .blank:
            Color.clear
        case .generic:
            GenericMark()
                .stroke(.secondary, style: StrokeStyle(lineWidth: max(1, size * 1.4 / 16), lineCap: .round, lineJoin: .round))
        case let .color(asset, shrunk):
            Image(decorative: asset).resizable().interpolation(.high).scaledToFit()
                .frame(width: shrunk ? size * 0.82 : size, height: shrunk ? size * 0.82 : size)
        case let .mono(asset, shrunk):
            Image(decorative: asset).renderingMode(.template).resizable().interpolation(.high).scaledToFit()
                .frame(width: shrunk ? size * 0.82 : size, height: shrunk ? size * 0.82 : size)
        }
    }

    /// 有真正的标志可画（不是空位，也不是通用图标）。
    static func isBrand(_ name: String?) -> Bool {
        switch OfficialIcon.mark(name) {
        case .color, .mono: true
        case .blank, .generic: false
        }
    }
}

/// 网页 `icon("generic")` 的立方体轮廓（16 格：`M8 2.2 13.2 5.1v5.8L8 13.8 2.8 10.9V5.1Z M8 8v5.8 M2.8 5.1 8 8l5.2-2.9`）。
private struct GenericMark: Shape {
    func path(in rect: CGRect) -> Path {
        let k = min(rect.width, rect.height) / 16
        let origin = CGPoint(x: rect.midX - 8 * k, y: rect.midY - 8 * k)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * k, y: origin.y + y * k) }
        var path = Path()
        path.move(to: p(8, 2.2))
        path.addLine(to: p(13.2, 5.1))
        path.addLine(to: p(13.2, 10.9))
        path.addLine(to: p(8, 13.8))
        path.addLine(to: p(2.8, 10.9))
        path.addLine(to: p(2.8, 5.1))
        path.closeSubpath()
        path.move(to: p(8, 8))
        path.addLine(to: p(8, 13.8))
        path.move(to: p(2.8, 5.1))
        path.addLine(to: p(8, 8))
        path.addLine(to: p(13.2, 5.1))
        return path
    }
}

// MARK: 页面图标

extension AppPage {
    /// 页面图标：magpie 网页导航栏有对应页面时用它的线条图，否则用 SF Symbol（`symbol`）。
    var image: Image {
        if let glyph = OfficialIcon.navGlyph(page: rawValue) {
            return Image(decorative: glyph).renderingMode(.template)
        }
        return Image(systemName: symbol)
    }
}

extension Label where Title == Text, Icon == Image {
    /// 带页面图标的标签（替代 `Label(title, systemImage: page.symbol)`）。
    init(_ title: String, page: AppPage) {
        self.init { Text(title) } icon: { page.image }
    }
}
