//
//  EditorOptionsControls.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 10/27/26.
//

import AppKit
import SwiftUI

// MARK: - Theme Slots

/// One user-overridable color in the app theme.
enum EditorThemeSlot: CaseIterable, Identifiable {
    case text, background, accentColor, secondaryForeground
    case diffAdded, diffRemoved

    var id: Self { self }

    /// The chrome's colors: `background` is `Color.card`, `text` is `Color.foreground`.
    static let appSlots: [Self] = [.background, .text, .accentColor, .secondaryForeground]
    static let diffSlots: [Self] = [.diffAdded, .diffRemoved]

    var label: String {
        switch self {
        case .text: "Text"
        case .background: "Background"
        case .accentColor: "Accent"
        case .secondaryForeground: "Muted Labels"
        case .diffAdded: "Confirmation Labels"
        case .diffRemoved: "Destructive Labels"
        }
    }

    /// Where Settings stores the slot's override; `AppTheme` reads it back.
    var defaultsKey: DefaultKey<String?> {
        switch self {
        case .text: DefaultKeys.textColor
        case .background: DefaultKeys.backgroundColor
        case .accentColor: DefaultKeys.accentColor
        case .secondaryForeground: DefaultKeys.secondaryColor
        case .diffAdded: DefaultKeys.diffAddedColor
        case .diffRemoved: DefaultKeys.diffRemovedColor
        }
    }

    /// Whether the picker offers opacity. The card sits on an opaque window,
    /// and the diff colors are washed to a fixed strength, so a translucent
    /// pick would only wash them out further.
    var supportsOpacity: Bool {
        switch self {
        case .background, .diffAdded, .diffRemoved: false
        default: false
        }
    }

    /// The slot's built-in color, before any override.
    var defaultColor: NSColor {
        switch self {
        case .text: NSColor(AppTheme.defaultForeground)
        case .background: NSColor(AppTheme.defaultCard)
        case .accentColor: NSColor(AppTheme.defaultAccent)
        case .secondaryForeground: NSColor(AppTheme.defaultSecondary)
        case .diffAdded: AppTheme.defaultDiffAdded
        case .diffRemoved: AppTheme.defaultDiffRemoved
        }
    }
}


// MARK: - Overrides

/// The Settings window's bindings to the stored theme overrides. Nothing
/// paints from these: `AppTheme` reads the same defaults and is what the
/// chrome and diff views draw with. A slot with no stored code (or an
/// unparsable one) keeps the TypeNBash color.
struct EditorThemeOverrides: DynamicProperty {
    @AppStorage(.textColor) private var text: String?
    @AppStorage(.backgroundColor) private var background: String?
    @AppStorage(.accentColor) private var accent: String?
    @AppStorage(.secondaryColor) private var secondary: String?
    @AppStorage(.diffAddedColor) private var diffAdded: String?
    @AppStorage(.diffRemovedColor) private var diffRemoved: String?
    @AppStorage(.themePreset) private var presetID: String?

    /// The stored `#RRGGBBAA` code for `slot`; nil means "not overridden".
    func colorCode(for slot: EditorThemeSlot) -> Binding<String?> {
        switch slot {
        case .text: $text
        case .background: $background
        case .accentColor: $accent
        case .secondaryForeground: $secondary
        case .diffAdded: $diffAdded
        case .diffRemoved: $diffRemoved
        }
    }

    /// The user's color for `slot`, or nil when it follows the base theme.
    func color(for slot: EditorThemeSlot) -> NSColor? {
        colorCode(for: slot).wrappedValue.flatMap { NSColor.sRGB(colorCode: $0) }
    }

    /// The preset the colors were last set from, among `presets` (those drawn
    /// for the current mode). A stored partner from the other mode counts, in
    /// case the appearance flipped before `follow(appearance:)` caught up.
    /// Without a stored base, an exact match is the only record of it; failing
    /// that, WriterTex's own for the mode.
    func basePreset(in presets: [EditorThemePreset]) -> EditorThemePreset? {
        guard let presetID else { return matchingPreset(in: presets) ?? presets.first }
        return presets.first { $0.id == presetID || $0.partner(in: EditorThemePreset.all)?.id == presetID }
            ?? presets.first
    }

    /// Whether `slot` differs from `preset`'s color.
    func isEdited(_ slot: EditorThemeSlot, from preset: EditorThemePreset) -> Bool {
        colorCode(for: slot).wrappedValue != preset.code(for: slot)
    }
}


// MARK: - Presets

/// A named palette from `appThemeConcepts.json`, applied by writing its
/// colors as overrides — so the chrome and diff views follow it the same
/// way they follow a hand-picked color.
struct EditorThemePreset: Identifiable {
    /// The JSON key of the palette that matches the built-in TypeNBash theme.
    static let defaultID = "default"

    let id: String
    /// Each slot's color as a normalized `#RRGGBBAA` code.
    let colorCodes: [EditorThemeSlot: String]

    
    var isDefault: Bool { id == Self.defaultID }

    /// The mode the palette was drawn for, judged by its background. Nil for
    /// TypeNBash, which has both.
    var displayMode: DisplayMode? {
        if id == "azuredark" || id == "default" {
            return .dark
        }
        if id == "light" || id == "azurelight" {
            return .light
        } else { return nil }
    }

    /// Each palette's equivalent for the other mode.
    private static let partnerIDs = [
        "default": "light", "light": "default",
        "azuredark": "azurelight", "azurelight": "azuredark",
    ]

    func partner(in presets: [Self]) -> Self? {
        Self.partnerIDs[id].flatMap { partnerID in presets.first { $0.id == partnerID } }
    }

    /// The override code this preset stores for `slot`. Nil for TypeNBash,
    /// whose colors are the built-in defaults.
    func code(for slot: EditorThemeSlot) -> String? {
        isDefault ? nil : colorCodes[slot]
    }

    /// "tokyoNightInspired" → "Tokyo Night".
    var label: String {
        if isDefault { return "WriterTex Dark" }
        if id == "azuredark" { return "Azure Dark" }
        if id == "azurelight" { return "Azure Light" }
        if id == "light" { return "WriterTex Light" }
        return id
    }

    /// The JSON field name for `slot`.
    private static func key(for slot: EditorThemeSlot) -> String {
        switch slot {
        case .text: "foreground"
        case .background: "background"
        case .accentColor: "accentControls"
        case .secondaryForeground: "muted"
        case .diffAdded: "diffAdded"
        case .diffRemoved: "diffRemoved"
        }
    }

    /// Every palette in the bundled JSON: TypeNBash first, the rest by name.
    static let all: [Self] = {
        guard
            let url = Bundle.main.url(forResource: "appThemeConcepts", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let palettes = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else { return [] }

        return palettes
            .map { id, fields in
                // Normalize through NSColor so codes compare equal to the
                // ones the color pickers store.
                let codes = EditorThemeSlot.allCases.reduce(into: [EditorThemeSlot: String]()) { codes, slot in
                    if let hex = fields[key(for: slot)],
                       let code = NSColor.sRGB(colorCode: hex)?.sRGBColorCode {
                        codes[slot] = code
                    }
                }
                return Self(id: id, colorCodes: codes)
            }
            .sorted { lhs, rhs in
                // WriterTex's own pair leads in both modes.
                let lhsBuiltIn = lhs.isDefault || lhs.id == "light"
                let rhsBuiltIn = rhs.isDefault || rhs.id == "light"
                if lhsBuiltIn != rhsBuiltIn { return lhsBuiltIn }
                return lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
            }
    }()
}

extension EditorThemeOverrides {
    /// Replaces every override with `preset`'s colors. The TypeNBash preset
    /// clears the overrides instead, so the built-in light/dark theme applies.
    /// The display mode is left alone: the picker only offers presets drawn
    /// for the current appearance, and `follow(appearance:)` swaps to the
    /// partner when it flips.
    func apply(_ preset: EditorThemePreset) {
        for slot in EditorThemeSlot.allCases {
            colorCode(for: slot).wrappedValue = preset.code(for: slot)
        }
        presetID = preset.id
    }

    /// Swaps the base preset for its partner when the app's appearance flips,
    /// whether from the mode picker or the system setting under System. Slots
    /// still on the base's color follow the partner; hand-picked ones stay.
    /// Unlike `apply`, this never writes the display mode, so System stays
    /// System.
    static func follow(appearance: DisplayMode) {
        let defaults = UserDefaults.standard
        let presets = EditorThemePreset.all
        // Before the base was stored, an exact match was the only record of it.
        let matching = presets.first { preset in
            EditorThemeSlot.allCases.allSatisfy { defaults[$0.defaultsKey] == preset.code(for: $0) }
        }
        let baseID = defaults[.themePreset] ?? matching?.id ?? EditorThemePreset.defaultID
        guard
            let base = presets.first(where: { $0.id == baseID }),
            base.displayMode != appearance,
            let partner = base.partner(in: presets),
            partner.displayMode == appearance
        else { return }

        for slot in EditorThemeSlot.allCases where defaults[slot.defaultsKey] == base.code(for: slot) {
            defaults[slot.defaultsKey] = partner.code(for: slot)
        }
        defaults[.themePreset] = partner.id
    }

    /// The preset the stored overrides match exactly, or nil once the user
    /// has customized any color.
    func matchingPreset(in presets: [EditorThemePreset]) -> EditorThemePreset? {
        presets.first { preset in
            EditorThemeSlot.allCases.allSatisfy { !isEdited($0, from: preset) }
        }
    }
}

// MARK: - Controls

/// The Theme pane of the Settings window.
struct EditorThemeControls: View {
    private var overrides = EditorThemeOverrides()
    @AppStorage(.gradientBackground) private var gradientBackground: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Form {
            Section("Preferred Mode") {
                VisualAppearancePicker()
            }
            Section {
                ForEach(EditorThemeSlot.appSlots) { row(for: $0) }
                ForEach(EditorThemeSlot.diffSlots) { row(for: $0) }
                Toggle("Gradient Background", isOn: $gradientBackground)
            } header: {
                HStack {
                    Text("App Theme")
                    Spacer()
                    presetPicker
                }
            }
            Button {
                if let base { overrides.apply(base) }
            } label: {
                HStack {
                    Text("Restore Preset Colors")
                }
                .padding(.horizontal)
            }
            .buttonStyle(.glassTitleButton)
            .disabled(base.map { overrides.matchingPreset(in: [$0]) != nil } ?? true)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// The bundled palettes drawn for the current appearance, so only one
    /// half of each pair is offered.
    private var presets: [EditorThemePreset] {
        let mode: DisplayMode = colorScheme == .dark ? .dark : .light
        return EditorThemePreset.all.filter { $0.displayMode == mode }
    }

    /// The preset the resets restore, edited or not.
    private var base: EditorThemePreset? {
        overrides.basePreset(in: presets)
    }

    /// Picks a bundled palette. Shows "Custom" once any color is edited by hand.
    private var presetPicker: some View {
        let presets = presets
        let current = overrides.matchingPreset(in: presets)
        let selection = Binding<String?>(
            get: { current?.id },
            set: { id in
                if let preset = presets.first(where: { $0.id == id }) {
                    overrides.apply(preset)
                }
            }
        )

        return Menu {
            Picker("Preset", selection: selection) {
                if current == nil {
                    Text("Custom").tag(String?.none)
                }
                ForEach(presets) { preset in
                    Text(preset.label).tag(Optional(preset.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.inline)
        } label: {
            HStack {
                if let current {
                    Text(current.label).tag(current.id)
                } else {
                    Text("Custom").tag(String?.none)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(Color.secondary)
            }
            .padding(.horizontal)
        }
        .buttonStyle(.glassTitleButton)
    }

    /// A picker that shows the override when set, otherwise the TypeNBash
    /// color; picking a color stores it as an override. Reset restores the
    /// base preset's color, not the built-in one.
    private func row(for slot: EditorThemeSlot) -> some View {
        let code = overrides.colorCode(for: slot)
        let fallback = slot.defaultColor
        let selection = Binding<Color>(
            get: { Color(nsColor: overrides.color(for: slot) ?? fallback) },
            set: { code.wrappedValue = NSColor($0).sRGBColorCode }
        )

        return HStack {
            ColorPicker(slot.label, selection: selection, supportsOpacity: slot.supportsOpacity)
            if let base, overrides.isEdited(slot, from: base) {
                Button("Reset", systemImage: "arrow.uturn.backward") {
                    code.wrappedValue = base.code(for: slot)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Use the \(base.label) Color")
            }
        }
    }
}
