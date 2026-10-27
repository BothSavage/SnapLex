import SwiftUI
import AppKit

/// A short visual response without delaying the button's action or changing layout.
struct SnapLexPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.84 : 1)
            .contentShape(Rectangle())
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

public enum SnapLexTheme {
    public static func resolvedColorScheme(for mode: SnapLexAppearanceMode, system: ColorScheme) -> ColorScheme {
        switch mode {
        case .system: system
        case .light: .light
        case .dark: .dark
        }
    }

    public static func resolvedColorScheme(for appearance: NSAppearance) -> ColorScheme {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    public static func appKitToolbarBackground(for appearance: NSAppearance) -> NSColor {
        resolvedColorScheme(for: appearance) == .dark
            ? NSColor(calibratedWhite: 0.105, alpha: 0.97)
            : NSColor.white.withAlphaComponent(0.98)
    }

    public static func appKitToolbarForeground(for appearance: NSAppearance) -> NSColor {
        resolvedColorScheme(for: appearance) == .dark
            ? NSColor.white.withAlphaComponent(0.94)
            : NSColor.black.withAlphaComponent(0.90)
    }

    public static func appKitToolbarBorder(for appearance: NSAppearance) -> NSColor {
        resolvedColorScheme(for: appearance) == .dark
            ? NSColor.white.withAlphaComponent(0.15)
            : NSColor.black.withAlphaComponent(0.14)
    }

    public static func appKitAppearance(for mode: SnapLexAppearanceMode) -> NSAppearance? {
        switch mode {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    public static func toolbarBackground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.105).opacity(0.97) : Color.white.opacity(0.98)
    }

    public static func toolbarForeground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.94) : Color.black.opacity(0.90)
    }

    public static func toolbarBorder(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.15) : Color.black.opacity(0.14)
    }

    public static func toolbarHover(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.13) : Color.black.opacity(0.075)
    }

    public static func toolbarSelection(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.23) : Color.black.opacity(0.13)
    }

    public static func tooltipBackground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.95) : Color(white: 0.08)
    }

    public static func tooltipForeground(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.92) : Color.white
    }
}

private struct SnapLexAppearanceModifier: ViewModifier {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var systemColorScheme

    private var resolvedColorScheme: ColorScheme {
        SnapLexTheme.resolvedColorScheme(for: settings.appearanceMode, system: systemColorScheme)
    }

    func body(content: Content) -> some View {
        content
            .environment(\.colorScheme, resolvedColorScheme)
            .environment(\.locale, L10n.locale)
            // L10n.string returns plain strings rather than LocalizedStringKey.
            // Refresh the whole view subtree when the app language changes so
            // existing cards, tooltips, and native panels update immediately.
            .id(settings.appLanguage.rawValue)
    }
}

public extension View {
    func snapLexAppearance() -> some View {
        modifier(SnapLexAppearanceModifier())
    }
}
