//
//  AppDefaults.swift
//  WriterTex
//

import Foundation
import SwiftUI

/// The factory values for every user setting backed by a `DefaultKey`.
///
/// The typed `@AppStorage(.key)` initializers read their default from the
/// registration domain, so these must be registered before any view that uses
/// them is created — `WriterTexApp.init` does that.
enum AppDefaults {

    static func register(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            // Theme overrides are deliberately unregistered: an absent value
            // is what makes a slot fall back to the built-in color.
            DefaultKeys.gradientBackground.rawValue: false,
            DefaultKeys.displayMode.rawValue: DisplayMode.dark.rawValue,

            // Find
            DefaultKeys.findUsesRegularExpression.rawValue: false,
            DefaultKeys.findIgnoresCase.rawValue: true,
            DefaultKeys.findMatchesFullWord.rawValue: false,
        ])
    }
}


// MARK: - Keys

/// A user-defaults key, typed by the value it stores, so `@AppStorage(.key)`
/// and `UserDefaults.standard[.key]` can't read it as the wrong type.
class DefaultKeys: @unchecked Sendable {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

final class DefaultKey<Value>: DefaultKeys, @unchecked Sendable { }

extension DefaultKeys {
    // Theme overrides, stored as sRGB `#RRGGBBAA` codes. Unset (nil) means the
    // slot uses the built-in color. The keys predate WriterTex; renaming them
    // would drop users' picks.
    static let textColor = DefaultKey<String?>("editor.textView.theme.text")
    static let backgroundColor = DefaultKey<String?>("editor.textView.theme.background")
    static let accentColor = DefaultKey<String?>("app.theme.accent")
    static let secondaryColor = DefaultKey<String?>("app.theme.secondary")
    // Diff pane colors: the gutter marker, and the wash behind changed rows.
    static let diffAddedColor = DefaultKey<String?>("app.theme.diffAdded")
    static let diffRemovedColor = DefaultKey<String?>("app.theme.diffRemoved")
    /// The preset the overrides were last set from, so resets restore its
    /// colors even after the user edits some. Unset means WriterTex's own.
    static let themePreset = DefaultKey<String?>("app.theme.preset")
    /// Paints the whole window with a card-to-foreground gradient instead of the flat card.
    static let gradientBackground = DefaultKey<Bool>("app.theme.gradientBackground")
    /// Light, dark, or following the system; applied to every window.
    static let displayMode = DefaultKey<DisplayMode>("app.theme.displayMode")

    // Find, shared by every editor's find bar
    static let findUsesRegularExpression = DefaultKey<Bool>("findUsesRegularExpression")
    static let findIgnoresCase = DefaultKey<Bool>("findIgnoresCase")
    static let findMatchesFullWord = DefaultKey<Bool>("findMatchesFullWord")
}


// MARK: - Access

extension UserDefaults {

    subscript(key: DefaultKey<Bool>) -> Bool {
        get { bool(forKey: key.rawValue) }
        set { set(newValue, forKey: key.rawValue) }
    }

    subscript(key: DefaultKey<String?>) -> String? {
        get { string(forKey: key.rawValue) }
        set { set(newValue, forKey: key.rawValue) }
    }

    /// An unreadable stored value falls back to the case whose raw value is 0.
    subscript<T>(key: DefaultKey<T>) -> T where T: RawRepresentable, T.RawValue == Int {
        get { T(rawValue: integer(forKey: key.rawValue)) ?? T(rawValue: 0)! }
        set { set(newValue.rawValue, forKey: key.rawValue) }
    }

    /// The value `AppDefaults.register` gave `key`.
    fileprivate func registered<T>(_ key: DefaultKey<T>) -> Any? {
        volatileDomain(forName: UserDefaults.registrationDomain)[key.rawValue]
    }
}

extension AppStorage {

    init(_ key: DefaultKey<Value>, store: UserDefaults? = nil) where Value == Bool {
        let initial = (store ?? .standard).registered(key) as? Bool ?? false
        self.init(wrappedValue: initial, key.rawValue, store: store)
    }

    init(_ key: DefaultKey<Value>, store: UserDefaults? = nil) where Value == String? {
        self.init(key.rawValue, store: store)
    }

    init(_ key: DefaultKey<Value>, store: UserDefaults? = nil) where Value: RawRepresentable, Value.RawValue == Int {
        let raw = (store ?? .standard).registered(key) as? Int ?? 0
        self.init(wrappedValue: Value(rawValue: raw) ?? Value(rawValue: 0)!, key.rawValue, store: store)
    }
}
