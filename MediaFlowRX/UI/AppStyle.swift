import SwiftUI

enum AppStyle {
    static let cardRadius: CGFloat = 12
    static let rowRadius: CGFloat = 8

    static let label = Font.system(size: 11, weight: .semibold)
    static let sectionTitle = Font.system(size: 11, weight: .bold)
    static let value = Font.system(size: 13, design: .monospaced)
    static let hint = Font.system(size: 11)
}

extension View {
    func overlayCard<S: InsettableShape>(_ shape: S) -> some View {
        background(Color.black.opacity(0.82), in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.18)))
    }

    func overlayCard() -> some View {
        overlayCard(RoundedRectangle(cornerRadius: AppStyle.cardRadius, style: .continuous))
    }
}
