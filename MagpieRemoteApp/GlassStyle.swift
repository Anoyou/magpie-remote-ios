import SwiftUI

extension View {
    /// Liquid Glass 卡片（iOS 26 起的系统玻璃材质）；系统「降低透明度」打开时由系统自动改为不透明背景。
    func glassCard(cornerRadius: CGFloat = 22) -> some View {
        glassEffect(.regular, in: .rect(cornerRadius: cornerRadius, style: .continuous))
    }
}
