import SwiftUI

/// A compact, Google Translate-inspired mark with overlapping language pages.
public struct SnapLexTranslationIcon: View {
    private let size: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    public init(size: CGFloat = 17) {
        self.size = max(12, size)
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: size * 0.07, style: .continuous)
                .fill(paper)
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.07, style: .continuous)
                        .stroke(ink, lineWidth: max(0.8, size * 0.065))
                }
                .frame(width: size * 0.51, height: size * 0.65)
                .offset(x: size * 0.45, y: size * 0.29)

            RoundedRectangle(cornerRadius: size * 0.07, style: .continuous)
                .fill(ink)
                .frame(width: size * 0.61, height: size * 0.76)
                .offset(x: size * 0.02, y: size * 0.02)

            Text("G")
                .font(.system(size: size * 0.40, weight: .bold, design: .rounded))
                .foregroundStyle(paper)
                .frame(width: size * 0.42, height: size * 0.45)
                .offset(x: size * 0.06, y: size * 0.07)

            Text("文")
                .font(.system(size: size * 0.31, weight: .bold))
                .foregroundStyle(ink)
                .frame(width: size * 0.32, height: size * 0.40)
                .offset(x: size * 0.58, y: size * 0.39)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var ink: Color {
        SnapLexTheme.toolbarForeground(for: colorScheme)
    }

    private var paper: Color {
        SnapLexTheme.toolbarBackground(for: colorScheme)
    }
}
