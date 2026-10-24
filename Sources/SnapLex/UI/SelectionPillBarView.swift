import SwiftUI
import AppKit

// MARK: - Signature Geometric Brand Logo (Monochrome Viewfinder + Prism)

public struct SnapLexBrandLogoView: View {
    public var size: CGFloat = 24
    public var showBadgeBackground: Bool = true
    public var foregroundColor: Color = .white
    public var badgeBackgroundColor: Color = Color.white.opacity(0.10)
    public var badgeStrokeColor: Color = Color.white.opacity(0.24)

    public init(
        size: CGFloat = 24,
        showBadgeBackground: Bool = true,
        foregroundColor: Color = .white,
        badgeBackgroundColor: Color = Color.white.opacity(0.10),
        badgeStrokeColor: Color = Color.white.opacity(0.24)
    ) {
        self.size = size
        self.showBadgeBackground = showBadgeBackground
        self.foregroundColor = foregroundColor
        self.badgeBackgroundColor = badgeBackgroundColor
        self.badgeStrokeColor = badgeStrokeColor
    }

    public var body: some View {
        ZStack {
            if showBadgeBackground {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(badgeBackgroundColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                            .stroke(badgeStrokeColor, lineWidth: 0.9)
                    )
            }

            Canvas { ctx, canvasSize in
                let w = canvasSize.width
                let h = canvasSize.height
                let pad = w * 0.21
                let arm = w * 0.17
                let strokeW = max(1.3, w * 0.072)

                // 1. Four precision viewfinder corner brackets (⌜ ⌝ / ⌞ ⌟)
                var corners = Path()
                // Top-left
                corners.move(to: CGPoint(x: pad, y: pad + arm))
                corners.addLine(to: CGPoint(x: pad, y: pad))
                corners.addLine(to: CGPoint(x: pad + arm, y: pad))
                // Top-right
                corners.move(to: CGPoint(x: w - pad - arm, y: pad))
                corners.addLine(to: CGPoint(x: w - pad, y: pad))
                corners.addLine(to: CGPoint(x: w - pad, y: pad + arm))
                // Bottom-left
                corners.move(to: CGPoint(x: pad, y: h - pad - arm))
                corners.addLine(to: CGPoint(x: pad, y: h - pad))
                corners.addLine(to: CGPoint(x: pad + arm, y: h - pad))
                // Bottom-right
                corners.move(to: CGPoint(x: w - pad - arm, y: h - pad))
                corners.addLine(to: CGPoint(x: w - pad, y: h - pad))
                corners.addLine(to: CGPoint(x: w - pad, y: h - pad - arm))

                ctx.stroke(
                    corners,
                    with: .color(foregroundColor.opacity(0.95)),
                    style: StrokeStyle(lineWidth: strokeW, lineCap: .round, lineJoin: .round)
                )

                // 2. Inner geometric S-prism / lens slash
                var prism = Path()
                prism.move(to: CGPoint(x: w * 0.62, y: h * 0.34))
                prism.addLine(to: CGPoint(x: w * 0.38, y: h * 0.34))
                prism.addLine(to: CGPoint(x: w * 0.62, y: h * 0.66))
                prism.addLine(to: CGPoint(x: w * 0.38, y: h * 0.66))

                ctx.stroke(
                    prism,
                    with: .color(foregroundColor),
                    style: StrokeStyle(lineWidth: strokeW * 1.05, lineCap: .round, lineJoin: .round)
                )
            }
        }
        .frame(width: size, height: size)
    }
}

public enum SnapLexBrandLogo {
    @MainActor
    public static func makeMenuBarImage() -> NSImage {
        let size = NSSize(width: 21, height: 21)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setStroke()
            let w = rect.width
            let h = rect.height
            let pad: CGFloat = 1.7
            let arm: CGFloat = 4.5

            let path = NSBezierPath()
            path.lineWidth = 1.9
            path.lineCapStyle = .round
            path.lineJoinStyle = .round

            // Top-left (flipped=false: maxY is top)
            path.move(to: NSPoint(x: pad, y: h - pad - arm))
            path.line(to: NSPoint(x: pad, y: h - pad))
            path.line(to: NSPoint(x: pad + arm, y: h - pad))

            // Top-right
            path.move(to: NSPoint(x: w - pad - arm, y: h - pad))
            path.line(to: NSPoint(x: w - pad, y: h - pad))
            path.line(to: NSPoint(x: w - pad, y: h - pad - arm))

            // Bottom-left
            path.move(to: NSPoint(x: pad, y: pad + arm))
            path.line(to: NSPoint(x: pad, y: pad))
            path.line(to: NSPoint(x: pad + arm, y: pad))

            // Bottom-right
            path.move(to: NSPoint(x: w - pad - arm, y: pad))
            path.line(to: NSPoint(x: w - pad, y: pad))
            path.line(to: NSPoint(x: w - pad, y: pad + arm))

            // Inner geometric S-prism
            path.move(to: NSPoint(x: w * 0.63, y: h * 0.67))
            path.line(to: NSPoint(x: w * 0.37, y: h * 0.67))
            path.line(to: NSPoint(x: w * 0.63, y: h * 0.33))
            path.line(to: NSPoint(x: w * 0.37, y: h * 0.33))

            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}

// MARK: - Selection Floating Control Bar (Logo | 翻译 | 复制 | 朗读)

public struct SelectionPillBarView: View {
    @ObservedObject var vm = TranslatorViewModel.shared
    @Environment(\.colorScheme) private var colorScheme
    var onSelectAction: (TranslationTaskMode) -> Void
    var onTriggerScreenshot: () -> Void
    var onOpenSettingsWindow: () -> Void
    var onDismiss: () -> Void

    @State private var copiedFeedback: Bool = false
    @State private var logoHovered: Bool = false

    public init(
        onSelectAction: @escaping (TranslationTaskMode) -> Void,
        onTriggerScreenshot: @escaping () -> Void,
        onOpenSettingsWindow: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.onSelectAction = onSelectAction
        self.onTriggerScreenshot = onTriggerScreenshot
        self.onOpenSettingsWindow = onOpenSettingsWindow
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(spacing: 4) {
            // Brand Logo on the left of the Control Bar
            Button(action: {
                onOpenSettingsWindow()
            }) {
                SnapLexBrandLogoView(
                    size: 30,
                    showBadgeBackground: true,
                    foregroundColor: SnapLexTheme.toolbarForeground(for: colorScheme),
                    badgeBackgroundColor: SnapLexTheme.toolbarForeground(for: colorScheme).opacity(0.045),
                    badgeStrokeColor: SnapLexTheme.toolbarBorder(for: colorScheme)
                )
                    .scaleEffect(logoHovered ? 1.04 : 1.0)
            }
            .buttonStyle(.plain)
            .padding(.leading, 2)
            .padding(.trailing, 2)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.12)) {
                    logoHovered = hovering
                }
            }

            // Subtle vertical divider
            Rectangle()
                .fill(SnapLexTheme.toolbarForeground(for: colorScheme).opacity(0.16))
                .frame(width: 1, height: 15)
                .padding(.horizontal, 2)

            // 1. 翻译 (WeChat-style [文][A] icon)
            PillBarButton(
                icon: "wechat:translate",
                title: L10n.string("翻译")
            ) {
                onSelectAction(.translate)
            }

            // 2. 复制 (Copy selected text)
            PillBarButton(
                icon: copiedFeedback ? "checkmark" : "doc.on.doc",
                title: L10n.string(copiedFeedback ? "已复制" : "复制")
            ) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(vm.inputText, forType: .string)
                copiedFeedback = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                    copiedFeedback = false
                    onDismiss()
                }
            }

            // 3. 朗读 (Speak selected text)
            PillBarButton(
                icon: "speaker.wave.2",
                title: L10n.string("朗读")
            ) {
                SystemDictionaryService.shared.speak(vm.inputText)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(SnapLexTheme.toolbarBackground(for: colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(SnapLexTheme.toolbarBorder(for: colorScheme), lineWidth: 0.8)
        )
        .padding(14)
        .snapLexAppearance()
    }
}

private struct PillBarButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    @State private var isHovered: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if icon == "wechat:translate" {
                    WeChatTranslateTinyIcon()
                        .foregroundStyle(SnapLexTheme.toolbarForeground(for: colorScheme).opacity(isHovered ? 1.0 : 0.84))
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(SnapLexTheme.toolbarForeground(for: colorScheme).opacity(isHovered ? 1.0 : 0.84))
                }
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SnapLexTheme.toolbarForeground(for: colorScheme).opacity(isHovered ? 1.0 : 0.90))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? SnapLexTheme.toolbarHover(for: colorScheme) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct WeChatTranslateTinyIcon: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2.2, style: .continuous)
                .stroke(lineWidth: 1.15)
                .frame(width: 10.5, height: 10.5)
                .offset(x: -2.2, y: -2.2)
            Text("文")
                .font(.system(size: 6.8, weight: .bold))
                .offset(x: -2.2, y: -2.2)

            RoundedRectangle(cornerRadius: 2.0, style: .continuous)
                .fill(SnapLexTheme.toolbarForeground(for: colorScheme))
                .frame(width: 9.0, height: 9.0)
                .offset(x: 2.6, y: 2.6)
            RoundedRectangle(cornerRadius: 2.0, style: .continuous)
                .stroke(lineWidth: 1.05)
                .frame(width: 9.0, height: 9.0)
                .offset(x: 2.6, y: 2.6)
            Text("A")
                .font(.system(size: 6.2, weight: .bold, design: .rounded))
                .foregroundStyle(SnapLexTheme.toolbarBackground(for: colorScheme))
                .offset(x: 2.6, y: 2.6)
        }
        .frame(width: 15, height: 15)
    }
}
