import AppKit
import SwiftUI

/// The UI bridge belongs to one editor, so toolbar actions never reach
/// another window through the application-wide responder chain.
@Observable final class EditorSession {
    @ObservationIgnored weak var csvGrid: CSVGridBodyView?
    /// The open manuscript's finder; nil while a table or preview is showing.
    var finder: TextFinder?
    var findTextView: NSTextView? { finder?.textView }
    var hasPendingCSVEdit = false
    /// The grid's selected cell, pushed in by the grid: an AppKit view's
    /// state can't be observed, so reading `csvGrid` would never re-render.
    var selectedCell = ""
    var selectedInlineStyle: MarkdownInlineStyle = []
    var selectedHeadingLevel: Int? = 0
    var canSetHeadingLevel = false
    var isBlockQuote = false
    var canSetBlockQuote = false
    var selectedListKind: MarkdownListKind?
    var selectionContainsList = false
    var canSetListKind = false
    var canInsertTable = false
    var selectionInTable = false
    var selectedColumnAlignment: MarkdownRichText.TableAlignment?
    /// The project's bibliography, so the editor can resolve the citations it
    /// shows. Weak: the window's session control owns it.
    @ObservationIgnored weak var bibliography: BibLibrary?
    /// Entries by key, and the .bib text they were parsed from. Rebuilt on the
    /// first lookup after a reparse: an unchanged document shares its text's
    /// storage, so checking it is a pointer comparison, not a scan.
    @ObservationIgnored private var index: (text: String, entries: [String: BibEntry])?

    private var entriesByKey: [String: BibEntry] {
        guard let document = bibliography?.document else { return [:] }
        if let index, index.text == document.text { return index.entries }
        // The first entry for each key wins, as BibTeX resolves a repeated key.
        let entries = Dictionary(document.entries.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        index = (document.text, entries)
        return entries
    }

    var selectedTableCell: String {
        if let table = csvGrid {
            let cor = table.selectedCell
            return cor
        }
        return ""
    }

    /// The entries a marker such as `[@smith2020, p. 3; @doe99]` cites, in its
    /// order. Keys the bibliography doesn't hold are left out.
    func entries(cited marker: String) -> [BibEntry] {
        guard marker.hasPrefix("["), marker.hasSuffix("]"),
              let citation = PandocCitations.parse(cluster: String(marker.dropFirst().dropLast())) else { return [] }
        let entries = entriesByKey
        return citation.cites.compactMap { entries[$0.id] }
    }

    /// Runs on every keystroke and caret move. Observation invalidates on any
    /// write, so only values that changed are written: re-rendering the toolbar
    /// for each key resets the pointer over the text.
    func updateFormattingState(from view: MarkdownRichTextView) {
        update(\.selectedInlineStyle, view.selectedInlineStyle)
        let heading = view.headingSelection
        update(\.selectedHeadingLevel, heading.level)
        update(\.canSetHeadingLevel, heading.canApply)
        let quote = view.quoteSelection
        update(\.isBlockQuote, quote.isQuoted)
        update(\.canSetBlockQuote, quote.canApply)
        let list = view.listSelection
        update(\.selectedListKind, list.kind)
        update(\.selectionContainsList, list.containsList)
        update(\.canSetListKind, list.canApply)
        update(\.canInsertTable, view.canInsertTable)
        update(\.selectionInTable, view.selectionInTable)
        update(\.selectedColumnAlignment, view.selectedColumnAlignment)
    }

    private func update<Value: Equatable>(_ property: ReferenceWritableKeyPath<EditorSession, Value>, _ value: Value) {
        if self[keyPath: property] != value { self[keyPath: property] = value }
    }

    func alignColumn(_ alignment: MarkdownRichText.TableAlignment) {
        guard let view = finder?.textView as? MarkdownRichTextView, let window = view.window else { return }
        window.makeFirstResponder(view)
        view.alignColumn(alignment)
        updateFormattingState(from: view)
    }

    func insertTable() {
        guard let view = finder?.textView as? MarkdownRichTextView, let window = view.window else { return }
        window.makeFirstResponder(view)
        view.insertTable()
        updateFormattingState(from: view)
    }

    func editTable(_ edit: MarkdownTableEdit) {
        guard let view = finder?.textView as? MarkdownRichTextView, let window = view.window else { return }
        window.makeFirstResponder(view)
        view.editTable(edit)
        updateFormattingState(from: view)
    }

    func setListKind(_ kind: MarkdownListKind) {
        guard let view = finder?.textView as? MarkdownRichTextView, let window = view.window else { return }
        window.makeFirstResponder(view)
        view.setListKind(kind)
        updateFormattingState(from: view)
    }

    func setBodyStyle() {
        guard let view = finder?.textView as? MarkdownRichTextView, let window = view.window else { return }
        window.makeFirstResponder(view)
        view.setBodyStyle()
        updateFormattingState(from: view)
    }

    func setBlockQuote(_ enabled: Bool) {
        guard let view = finder?.textView as? MarkdownRichTextView, let window = view.window else { return }
        window.makeFirstResponder(view)
        view.setBlockQuote(enabled)
        updateFormattingState(from: view)
    }

    func setInlineStyle(_ inline: MarkdownInlineStyle, enabled: Bool) {
        guard let view = finder?.textView as? MarkdownRichTextView, let window = view.window else { return }
        window.makeFirstResponder(view)
        view.setInlineStyle(inline, enabled: enabled)
        updateFormattingState(from: view)
    }

    /// Whether a manuscript editor is showing, for commands that need one.
    var hasManuscriptEditor: Bool {
        (finder?.textView as? MarkdownRichTextView)?.onInsertCitation != nil
    }

    func insertCitation() {
        guard let view = finder?.textView as? MarkdownRichTextView, let window = view.window else { return }
        window.makeFirstResponder(view)
        view.onInsertCitation?()
    }

    func setHeadingLevel(_ level: Int) {
        guard let view = finder?.textView as? MarkdownRichTextView, let window = view.window else { return }
        window.makeFirstResponder(view)
        view.setHeadingLevel(level)
        updateFormattingState(from: view)
    }

    /// Whether this editor's inline Find & Replace bar is showing.
    var isFindBarPresented = false
    /// The last find command's outcome: "3 of 12", "Not found", or an error.
    var findMessage: String?

    /// Bumped every time the find field should take focus, so pressing ⌘F again
    /// while the bar is already open still moves the caret back into it.
    private(set) var findFocusRequest = 0

    func csvAnalysisSnapshot(scope: CSVAnalysisSnapshot.Scope = .allRows) throws -> CSVAnalysisSnapshot {
        guard let csvGrid else { throw CSVAnalysisError.noTable }
        return try csvGrid.analysisSnapshot(scope: scope)
    }

    func csvSelection() -> (row: Int?, column: Int)? { csvGrid?.committedSelection() }

    /// Reveals the find bar and puts focus in its search field.
    func find() {
        guard let textView = findTextView else { return }

        // Seed the field from the selection, the way ⌘F does elsewhere on the
        // platform — but only on the way in, so re-invoking it does not discard
        // a search the user has already typed. Regex is switched off with it
        // because literal selections routinely contain metacharacters.
        if !self.isFindBarPresented {
            let selection = (textView.string as NSString).substring(with: textView.selectedRange())
            if !selection.isEmpty, !selection.contains(where: \.isNewline) {
                FindStrings.shared.findString = selection
                UserDefaults.standard[.findUsesRegularExpression] = false
            }
        }

        self.isFindBarPresented = true
        self.findFocusRequest += 1
    }

    /// Hides the find bar and hands focus back to the text view.
    func dismissFind() {
        self.isFindBarPresented = false
        self.findMessage = nil
        guard let textView = findTextView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    /// Runs a find action against this editor and no other.
    func performFind(_ action: FindAction) {
        finder?.perform(action)
    }

    /// Runs the search-as-you-type pass for this editor.
    func incrementalSearch() {
        finder?.incrementalSearch()
    }
}

extension FocusedValues {
    /// The key window's editor, so menu-bar commands act on that window only.
    @Entry var editorSession: EditorSession?
}
