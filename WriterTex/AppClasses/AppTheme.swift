//
//  AppTheme.swift
//  WriterTex
//
//  Created by Vedant A. Desai on 11/2/26.
//
import SwiftUI


/// The app chrome colors, with the user's overrides from Settings applied.
///
/// `@Observable`, so every view whose body reads one of the `Color` statics
/// below re-renders when the user picks a new color — no `.id()` reset that
/// would tear down open editors.
@Observable
final class AppTheme {
    static let shared = AppTheme()

    // Each default resolves per appearance, so Light mode gets a light card
    // rather than the dark one with system controls drawn over it.
    static let defaultCard = adaptive(dark: "#0B0A0A", light: "#FCFCFC")
    static let defaultAccent = adaptive(dark: "#B8975E", light: "#8C6B2F")
    static let defaultForeground = adaptive(dark: "#F0EAD6", light: "#242424")
    static let defaultSecondary = adaptive(dark: "#7E7A70", light: "#6E6A60")
    // AppKit colors, so the defaults keep following light and dark mode.
    static let defaultDiffAdded = NSColor.systemGreen
    static let defaultDiffRemoved = NSColor.systemRed


    // The stored `#RRGGBBAA` override codes; nil keeps the default color.
    private var cardCode: String?
    private var accentCode: String?
    private var foregroundCode: String?
    private var secondaryCode: String?
    private var diffAddedCode: String?
    private var diffRemovedCode: String?

    /// Whether the window is painted with `gradientCard` rather than the flat card.
    private(set) var gradientBackground = false
    /// Applied to `NSApp`, so every window and sheet follows it.
    private(set) var displayMode = DisplayMode.system {
        didSet { NSApplication.shared.appearance = displayMode.appearance }
    }
    var card: Color { Self.color(cardCode) ?? Self.defaultCard }
    var accent: Color { Self.color(accentCode) ?? Self.defaultAccent }
    var foreground: Color { Self.color(foregroundCode) ?? Self.defaultForeground }
    var secondary: Color { Self.color(secondaryCode) ?? Self.defaultSecondary }

    static let highlightColor = NSColor.systemYellow.withAlphaComponent(0.32)

    /// The diff palette for AppKit painters: the diff pane's gutter and row
    /// washes. SwiftUI reads `Color.diffAdded`/`diffRemoved`.
    var diffColors: GitDiffColors {
        GitDiffColors(added: Self.nsColor(diffAddedCode) ?? Self.defaultDiffAdded,
                      removed: Self.nsColor(diffRemovedCode) ?? Self.defaultDiffRemoved)
    }
    var diffAdded: Color { Color(nsColor: diffColors.added) }
    var diffRemoved: Color { Color(nsColor: diffColors.removed) }

    @ObservationIgnored private var observer: (any NSObjectProtocol)?
    @ObservationIgnored private var appearanceObserver: NSKeyValueObservation?

    private init() {
        reload()
        NSApplication.shared.appearance = displayMode.appearance
        // Settings writes the overrides through `@AppStorage`; follow along.
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        // The effective appearance flips with the mode picker and, under
        // System, with the system setting. A paired preset swaps to its
        // partner so its colors match the controls drawn over them. `.initial`
        // catches a system change made while the app was closed.
        appearanceObserver = NSApplication.shared.observe(\.effectiveAppearance, options: [.initial, .new]) { app, _ in
            MainActor.assumeIsolated {
                let isDark = app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                EditorThemeOverrides.follow(appearance: isDark ? .dark : .light)
            }
        }
    }

    /// Re-reads the overrides, assigning only what changed so an unrelated
    /// defaults write doesn't invalidate every themed view.
    private func reload() {
        let defaults = UserDefaults.standard
        let card = defaults.string(forKey: DefaultKeys.backgroundColor.rawValue)
        let accent = defaults.string(forKey: DefaultKeys.accentColor.rawValue)
        let foreground = defaults.string(forKey: DefaultKeys.textColor.rawValue)
        let secondary = defaults.string(forKey: DefaultKeys.secondaryColor.rawValue)
        let diffAdded = defaults.string(forKey: DefaultKeys.diffAddedColor.rawValue)
        let diffRemoved = defaults.string(forKey: DefaultKeys.diffRemovedColor.rawValue)
        if cardCode != card { cardCode = card }
        if accentCode != accent { accentCode = accent }
        if foregroundCode != foreground { foregroundCode = foreground }
        if secondaryCode != secondary { secondaryCode = secondary }
        if diffAddedCode != diffAdded { diffAddedCode = diffAdded }
        if diffRemovedCode != diffRemoved { diffRemovedCode = diffRemoved }
        let gradient = defaults.bool(forKey: DefaultKeys.gradientBackground.rawValue)
        if gradientBackground != gradient { gradientBackground = gradient }
        let mode = defaults[.displayMode]
        if displayMode != mode { displayMode = mode }
    }

    var gradientCard: LinearGradient {
        .init(colors: [card, card.mix(with: foreground, by: 0.134)],
              startPoint: .bottomLeading,
              endPoint: .topTrailing)
    }

    /// The window's backdrop: one gradient spanning every column, or the flat card.
    var windowBackground: AnyShapeStyle {
        gradientBackground ? AnyShapeStyle(gradientCard) : AnyShapeStyle(card)
    }

    /// Fill for the panes and toolbar. Clear while the gradient is on, so the
    /// single window-wide gradient shows through instead of one per pane.
    var paneBackground: Color {
        gradientBackground ? .clear : .card
    }

    private static func color(_ code: String?) -> Color? {
        nsColor(code).map { Color(nsColor: $0) }
    }

    private static func nsColor(_ code: String?) -> NSColor? {
        code.flatMap { NSColor.sRGB(colorCode: $0) }
    }

    /// AppKit may resolve the color off the main thread, so the closure only
    /// picks between two colors made up front.
    private static func adaptive(dark: String, light: String) -> Color {
        let dark = NSColor.hex(dark), light = NSColor.hex(light)
        return Color(nsColor: NSColor(name: nil) { @Sendable appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

/// The diff palette as AppKit colors, handed to views that paint it. Only
/// `AppTheme.diffColors` makes one. The gutter marker uses each color as
/// picked; the row behind it takes a light wash of the same hue.
struct GitDiffColors: Equatable {
    var added: NSColor
    var removed: NSColor
}

extension Color {
    static var card: Color { AppTheme.shared.card }
    static var accentColor: Color { AppTheme.shared.accent }
    static var foreground: Color { AppTheme.shared.foreground }
    static var secondary: Color { AppTheme.shared.secondary }
    static var diffAdded: Color { AppTheme.shared.diffAdded }
    static var diffRemoved: Color { AppTheme.shared.diffRemoved }
}

