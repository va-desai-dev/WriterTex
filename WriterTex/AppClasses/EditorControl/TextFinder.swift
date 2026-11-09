//
//  TextFinder.swift
//  WriterTex
//
//  Find & Replace for the manuscript editor and project search: literal or
//  regular-expression matching, case and whole-word options, nothing more.
//

import AppKit
import SwiftUI

// MARK: - Options

/// The find options shared by the editor's find bar and project search.
nonisolated struct FindOptions: Equatable, Sendable {
    var regularExpression = false
    var ignoresCase = true
    var wholeWord = false

    /// The options last chosen in either find interface.
    @MainActor init(defaults: UserDefaults = .standard) {
        regularExpression = defaults[.findUsesRegularExpression]
        ignoresCase = defaults[.findIgnoresCase]
        wholeWord = defaults[.findMatchesFullWord]
    }
}


// MARK: - Pattern

/// A compiled search. Literal searches are escaped into a regular expression,
/// so both kinds match and replace the same way.
nonisolated struct FindPattern: @unchecked Sendable {
    let regex: NSRegularExpression
    let options: FindOptions

    enum Failure: LocalizedError {
        case emptyFindString
        case invalidRegularExpression(String)

        var errorDescription: String? {
            switch self {
            case .emptyFindString: "Enter text to find."
            case .invalidRegularExpression(let reason): "Invalid regular expression: \(reason)"
            }
        }
    }

    init(findString: String, options: FindOptions) throws(Failure) {
        guard !findString.isEmpty else { throw .emptyFindString }
        var pattern = options.regularExpression ? findString : NSRegularExpression.escapedPattern(for: findString)
        if options.wholeWord { pattern = "\\b(?:\(pattern))\\b" }
        var flags: NSRegularExpression.Options = [.anchorsMatchLines]
        if options.ignoresCase { flags.insert(.caseInsensitive) }
        do {
            regex = try NSRegularExpression(pattern: pattern, options: flags)
        } catch {
            throw .invalidRegularExpression(error.localizedDescription)
        }
        self.options = options
    }

    /// Every match in `text`, in order. `shouldStop` is polled between matches.
    func matches(in text: String, shouldStop: () -> Bool = { false }) -> [NSTextCheckingResult] {
        var results: [NSTextCheckingResult] = []
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) { result, _, stop in
            if shouldStop() { stop.pointee = true; return }
            if let result { results.append(result) }
        }
        return results
    }

    /// What `match` becomes. A regular expression expands `$1`-style
    /// references in `template`; a literal search inserts it as typed.
    func replacement(for match: NSTextCheckingResult, in text: String, template: String) -> String {
        let template = options.regularExpression ? template : NSRegularExpression.escapedTemplate(for: template)
        return regex.replacementString(for: match, in: text, offset: 0, template: template)
    }
}


// MARK: - Shared Strings

/// The find and replacement strings, shared by every window as the system's
/// find pasteboard is.
@MainActor @Observable final class FindStrings {
    static let shared = FindStrings()

    var findString = ""
    var replacementString = ""
}


// MARK: - Editor Finder

/// What a find-bar command does.
enum FindAction {
    case nextMatch, previousMatch, replaceAndFind, replaceAll
}

/// Runs the find bar's commands against one editor's text view, and owns the
/// ⌘F / ⌘G shortcuts while that view has focus.
@MainActor final class TextFinder {
    weak var textView: NSTextView?
    private weak var session: EditorSession?
    private var keyMonitor: Any?

    func attach(to textView: NSTextView, session: EditorSession) {
        guard self.textView !== textView else { return }
        detach()
        self.textView = textView
        self.session = session
        session.finder = self
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, let view = self.textView, event.window === view.window,
                      view.window?.firstResponder === view, !view.hasMarkedText() else { return false }
                let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
                let key = event.charactersIgnoringModifiers?.lowercased()
                if modifiers == .command, key == "f" { self.session?.find(); return true }
                if key == "g", modifiers == .command || modifiers == [.command, .shift] {
                    self.perform(modifiers.contains(.shift) ? .previousMatch : .nextMatch)
                    return true
                }
                return false
            }
            return handled ? nil : event
        }
        if session.isFindBarPresented { incrementalSearch() }
    }

    func detach() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if session?.finder === self { session?.finder = nil }
        textView = nil
        session = nil
    }

    /// The current find string compiled with the stored options; reports
    /// a bad regular expression to the find bar instead.
    private func pattern() -> FindPattern? {
        let findString = FindStrings.shared.findString
        guard !findString.isEmpty else {
            session?.findMessage = nil
            return nil
        }
        do {
            return try FindPattern(findString: findString, options: FindOptions())
        } catch {
            session?.findMessage = error.localizedDescription
            return nil
        }
    }

    func perform(_ action: FindAction) {
        guard let textView, let pattern = pattern() else { return }
        switch action {
        case .nextMatch: find(pattern, in: textView, forward: true, includingSelection: false)
        case .previousMatch: find(pattern, in: textView, forward: false, includingSelection: false)
        case .replaceAndFind: replace(pattern, in: textView)
        case .replaceAll: replaceAll(pattern, in: textView)
        }
    }

    /// Search-as-you-type: the first match at or after the caret.
    func incrementalSearch() {
        guard let textView, let pattern = pattern() else { return }
        find(pattern, in: textView, forward: true, includingSelection: true)
    }

    /// Selects the next or previous match, wrapping around the document.
    @discardableResult
    private func find(_ pattern: FindPattern, in textView: NSTextView, forward: Bool, includingSelection: Bool) -> NSRange? {
        let ranges = pattern.matches(in: textView.string).map(\.range)
        guard !ranges.isEmpty else {
            session?.findMessage = "Not found"
            return nil
        }
        let selection = textView.selectedRange()
        let index: Int
        if forward && includingSelection {
            index = ranges.firstIndex { $0.location >= selection.location } ?? 0
        } else if forward {
            index = ranges.firstIndex { $0.location >= NSMaxRange(selection) && $0 != selection } ?? 0
        } else {
            index = ranges.lastIndex { NSMaxRange($0) <= selection.location && $0 != selection } ?? ranges.count - 1
        }
        let range = ranges[index]
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.showFindIndicator(for: range)
        session?.findMessage = "\(index + 1) of \(ranges.count)"
        return range
    }

    /// Replaces the selected match, then moves to the next one. A selection
    /// that isn't a match only moves on, as in Xcode and Pages.
    private func replace(_ pattern: FindPattern, in textView: NSTextView) {
        let text = textView.string
        let selection = textView.selectedRange()
        if let match = pattern.matches(in: text).first(where: { $0.range == selection }) {
            let replacement = pattern.replacement(for: match, in: text, template: FindStrings.shared.replacementString)
            if textView.shouldChangeText(in: match.range, replacementString: replacement) {
                textView.textStorage?.replaceCharacters(in: match.range, with: replacement)
                textView.didChangeText()
                textView.undoManager?.setActionName("Replace")
                textView.setSelectedRange(NSRange(location: match.range.location + (replacement as NSString).length, length: 0))
            }
        }
        find(pattern, in: textView, forward: true, includingSelection: true)
    }

    /// Replaces every match as one undoable edit.
    private func replaceAll(_ pattern: FindPattern, in textView: NSTextView) {
        let text = textView.string
        let matches = pattern.matches(in: text)
        guard !matches.isEmpty else {
            session?.findMessage = "Not found"
            return
        }
        let template = FindStrings.shared.replacementString
        let replacements = matches.map { pattern.replacement(for: $0, in: text, template: template) }
        guard let storage = textView.textStorage,
              textView.shouldChangeText(inRanges: matches.map { NSValue(range: $0.range) }, replacementStrings: replacements)
        else { return }
        storage.beginEditing()
        // Back to front, so earlier ranges stay valid.
        for (match, replacement) in zip(matches, replacements).reversed() {
            storage.replaceCharacters(in: match.range, with: replacement)
        }
        storage.endEditing()
        textView.didChangeText()
        textView.undoManager?.setActionName("Replace All")
        session?.findMessage = matches.count == 1 ? "Replaced 1 match" : "Replaced \(matches.count) matches"
    }
}
