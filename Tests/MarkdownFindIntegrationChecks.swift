import AppKit
import SwiftUI
@testable import WriterTex

@main
struct MarkdownFindIntegrationChecks {
    // Keep the query guard deterministic if the desktop user activates another
    // app during the fixture. AppKit still owns the real first-responder chain.
    final class FixtureWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    /// The open document, held by the same model the app's editor writes into.
    @MainActor @Observable final class Document {
        let browser = FileBrowserModel()
        var identity = UUID()
        var focused = true
        let session = EditorSession()
        private let url = URL(fileURLWithPath: "/tmp/fixture-\(UUID()).wrtx")
        static let fixture = "# Search fixture\n\nBarrett met BARRETT and café.\n\n==Keep this highlight== and **bold** with `code`.\n\n| Name | Score |\n| --- | ---: |\n| Barrett | 1 |\n\n- one\n- two\n\n> Quoted with emoji 😀\n\nBarrett again.\n"

        init() { browser.openFixture(Self.fixture, at: url) }

        /// What the editor was loaded with.
        var loaded: Data {
            browser.richData
        }

        /// The document as saving and reopening it shows it, with the editor's edits committed.
        var outline: String { browser.reopened.outline }

        /// Opens a document written in Markdown shorthand, as opening a file does.
        func load(_ markdown: String) { browser.openFixture(markdown, at: url) }
    }

    struct Fixture: View {
        @Bindable var document: Document
        var body: some View {
            VStack(spacing: 0) {
                EditorFindBar(session: document.session)
                RichMarkdownEditor(richData: document.loaded, model: document.browser,
                                   editorIsFocused: $document.focused, session: document.session)
                    .id(document.identity)
            }
        }
    }

    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.regular)
        AppDefaults.register()
        Task { @MainActor in
            do { try await run() } catch { fatalError("Markdown find checks: \(error)") }
            exit(0)
        }
        NSApp.run()
    }

    /// The match total in a find bar message such as "2 of 5".
    @MainActor static func count(_ session: EditorSession) -> Int? {
        session.findMessage?.components(separatedBy: " of ").last.flatMap { Int($0) }
    }

    @MainActor static func run() async throws {
        // The runner gives each check its own home folder, so these never reach the user's.
        UserDefaults.standard[.findIgnoresCase] = true
        UserDefaults.standard[.findUsesRegularExpression] = false
        UserDefaults.standard[.findMatchesFullWord] = false
        let first = Document()
        let second = Document()
        let original = first.outline
        let host = NSHostingView(rootView: HStack {
            Fixture(document: first)
            Fixture(document: second)
        })
        let window = FixtureWindow(contentRect: NSRect(x: 80, y: 80, width: 1300, height: 650),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        try await settle()
        guard let finder = first.session.finder, let document = finder.textView,
              let otherView = second.session.findTextView else {
            fatalError("Both Markdown editors must attach")
        }
        precondition(document !== otherView && first.session.findTextView === document)

        // Rich text: no syntax on screen, and an untouched document reopens unchanged.
        for syntax in ["#", "|", "**", "==", "`", "- "] {
            precondition(!document.string.contains(syntax), "Formatted view must not show \(syntax): \(document.string.debugDescription)")
        }
        precondition(first.outline == original && document.textLayoutManager == nil, "Loading must not change the document; tables need TextKit 1")
        // Edit a table cell: only that cell changes, and undo restores the document exactly.
        let text = document.string as NSString
        var scoreCell: NSRange?
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byParagraphs) { _, range, _, stop in
            guard range.location < text.length,
                  let block = (document.textStorage?.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.last as? NSTextTableBlock,
                  block.startingRow == 1, block.startingColumn == 0 else { return }
            scoreCell = range
            stop.pointee = true
        }
        guard let scoreCell else { fatalError("The table must render as text table cells") }
        window.makeFirstResponder(document)
        document.setSelectedRange(NSRange(location: scoreCell.location, length: 0))
        document.insertTab(nil)
        precondition(text.substring(with: document.selectedRange()) == "1", "Tab must select the next cell: \(text.substring(with: document.selectedRange()))")
        document.insertText("1X", replacementRange: document.selectedRange())
        try await settle()
        precondition(first.outline == original.replacingOccurrences(of: "| Barrett | 1 |", with: "| Barrett | 1X |"), "Only the table may change: \(first.outline)")
        document.undoManager?.undo()
        try await settle()
        precondition(first.outline == original, "Undo must restore the document exactly: \(first.outline)")
        // A quote is a full-width text block: one line, not one character per line.
        let quote = (document.string as NSString).range(of: "Quoted with emoji 😀")
        if let layout = document.layoutManager, let container = document.textContainer {
            layout.ensureLayout(for: container)
            var lines = 0
            layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(forCharacterRange: quote, actualCharacterRange: nil)) { _, _, _, _, _ in lines += 1 }
            precondition(lines == 1, "Quote must lay out at full width: \(lines) lines")
        }
        // Editing a paragraph that ends in an emoji (a surrogate pair) must save.
        document.setSelectedRange(NSRange(location: NSMaxRange(quote), length: 0))
        document.insertText("!", replacementRange: document.selectedRange())
        try await settle()
        precondition(first.outline.contains("> Quoted with emoji 😀!"), "Quote edit must save: \(first.outline)")
        document.undoManager?.undo()
        try await settle()
        precondition(first.outline == original, "Quote undo must restore the document")
        // Typed delimiters apply formatting, which survives saving and reopening.
        document.setSelectedRange(NSRange(location: (document.string as NSString).length, length: 0))
        document.insertNewline(nil)
        for key in "Typed **not bold** and `not code`" { document.insertText(String(key), replacementRange: document.selectedRange()) }
        try await settle()
        precondition(document.string.contains("Typed not bold and not code"), "Typing shortcuts must format the text: \(document.string.debugDescription)")
        let typedBack = first.browser.reopened
        precondition(typedBack.string.contains("Typed not bold and not code") && typedBack.has(.strong, on: "not bold") && typedBack.has(.code, on: "not code"),
                     "Shortcut formatting must survive reopening: \(first.outline.debugDescription)")
        first.load(Document.fixture)
        try await settle()
        precondition(!document.string.contains("Typed"), "Reloading the binding must replace the typed text")

        let matches = (document.string.lowercased().components(separatedBy: "barrett").count - 1)

        FindStrings.shared.findString = ""
        document.setSelectedRange(NSRange(location: 0, length: 0))
        window.makeFirstResponder(document)
        let commandF = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                       timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                       characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3)!
        NSApp.postEvent(commandF, atStart: false)
        try await settle()
        precondition(first.session.isFindBarPresented, "Command-F must open the shared bar")
        guard let input = window.firstResponder as? NSTextView, input !== document else {
            fatalError("Find field must take focus")
        }
        input.insertText("Bar", replacementRange: input.selectedRange())
        try await settle()
        precondition(count(first.session) == matches, "count=\(String(describing: first.session.findMessage)), query=\(FindStrings.shared.findString)")
        input.insertText("rett", replacementRange: input.selectedRange())
        try await settle()
        precondition(FindStrings.shared.findString == "Barrett" && count(first.session) == matches)
        precondition(first.outline == original && window.firstResponder === input)
        precondition(second.session.findMessage == nil && second.outline == original, "Search must stay in its own pane")

        let string = document.string as NSString
        first.session.performFind(.nextMatch)
        try await settle()
        precondition(document.selectedRange() == string.range(of: "BARRETT"),
                     "Next must select the next match: \(document.selectedRange())")
        first.session.performFind(.previousMatch)
        try await settle()
        precondition(document.selectedRange() == string.range(of: "Barrett") && first.session.findMessage == "1 of \(matches)")
        precondition(window.firstResponder === input, "Navigation must preserve field focus")

        FindStrings.shared.replacementString = "Replaced"
        first.session.performFind(.replaceAndFind)
        try await settle()
        precondition(first.outline.contains("Replaced") && second.outline == original, "Replacement must reach the binding: \(first.outline)")
        window.makeFirstResponder(document)
        document.undoManager?.undo()
        try await settle()
        precondition(first.outline == original, "Replacement must undo: text=\(first.outline)")
        document.undoManager?.redo()
        try await settle()
        precondition(first.outline.contains("Replaced"), "Redo must publish the replacement")
        document.undoManager?.undo()
        try await settle()
        first.session.performFind(.replaceAll)
        try await settle()
        precondition(first.outline.components(separatedBy: "Replaced").count == matches + 1 && second.outline == original, "Replace All: \(first.outline)")
        window.makeFirstResponder(document)
        document.undoManager?.undo()
        try await settle()
        precondition(first.outline == original, "Replace All must undo in one step")
        first.session.dismissFind()
        precondition(window.firstResponder === document)

        // Switch documents with the bar open.
        first.session.find()
        FindStrings.shared.findString = "Barrett"
        try await settle()
        first.load("# New document\n\nBarrett once.\n")
        first.identity = UUID()
        try await settle()
        guard let switched = first.session.findTextView, switched !== document, first.session.finder !== finder else {
            fatalError("New document must attach")
        }
        first.session.performFind(.replaceAll)
        try await settle()
        precondition(first.outline.contains("Replaced once") && second.outline == original)
        print("PASS: Formatted rich text without syntax, typing shortcuts, unchanged load and exact undo, table cell editing and Tab, full-width quotes, emoji-ending edits, native find, Command-F, incremental focus, navigation/counts, replacement and undo, pane isolation, document switching")
    }

    static func settle() async throws { try await Task.sleep(for: .milliseconds(1000)) }
}
