import AppKit
import SwiftUI
@testable import WriterTex

@main
struct MarkdownFormattingIntegrationChecks {
    final class FixtureWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }
    /// The open document, held by the same model the app's editor writes into.
    @MainActor @Observable final class Document {
        let browser = FileBrowserModel()
        var focused = false
        let session = EditorSession()
        private let url = URL(fileURLWithPath: "/tmp/fixture-\(UUID()).wrtx")

        init() { browser.openFixture("plain, **bold**, *italic*.", at: url) }

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
            RichMarkdownEditor(richData: document.loaded, model: document.browser,
                               editorIsFocused: $document.focused, session: document.session)
        }
    }
    @MainActor static func main() {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.accessory)
        AppDefaults.register()
        Task { @MainActor in
            await run()
            exit(0)
        }
        NSApp.run()
    }
    @MainActor static func run() async {
        let first = Document(), second = Document()
        let original = first.outline
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 400))
        let toolbar = NSHostingView(rootView: RTFTools(session: first.session).fixedSize().frame(maxWidth: .infinity, alignment: .leading))
        toolbar.frame = NSRect(x: 0, y: 374, width: 180, height: 26)
        host.addSubview(toolbar)
        for (index, document) in [first, second].enumerated() {
            let editor = NSHostingView(rootView: Fixture(document: document))
            editor.frame = NSRect(x: index * 500, y: 0, width: 500, height: 374)
            host.addSubview(editor)
        }
        let window = FixtureWindow(contentRect: NSRect(x: 80, y: 80, width: 1000, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        await settle()
        guard let view = first.session.findTextView as? MarkdownRichTextView,
              let other = second.session.findTextView else { fatalError("Editors did not mount") }
        window.makeFirstResponder(view)
        func select(_ word: String) { view.setSelectedRange((view.string as NSString).range(of: word)) }
        /// Flips a header toggle the way clicking it does: through the first
        /// editor's session, whichever editor has focus.
        func press(_ label: String) {
            let style: MarkdownInlineStyle = label == "Bold" ? .strong : .emphasis
            first.session.setInlineStyle(style, enabled: !first.session.selectedInlineStyle.contains(style))
        }

        select("bold")
        await settle()
        precondition(first.session.selectedInlineStyle.contains(.strong))
        precondition(!first.session.selectedInlineStyle.contains(.emphasis))
        select("italic")
        await settle()
        precondition(first.session.selectedInlineStyle.contains(.emphasis))
        precondition(!first.session.selectedInlineStyle.contains(.strong))
        precondition(first.outline == original && view.undoManager?.canUndo != true,
                     "Selection feedback must never format text or create undo actions")
        view.setSelectedRange(NSRange(location: 0, length: NSMaxRange((view.string as NSString).range(of: "bold"))))
        await settle()
        precondition(!first.session.selectedInlineStyle.contains(.strong), "Mixed selection must show bold off")
        print("PASS: toolbar state follows bold, italic and mixed selections without editing")

        select("plain")
        await settle()
        window.makeFirstResponder(other)
        press("Bold")
        await settle()
        precondition(first.outline.contains("**plain**") && second.outline == original,
                     "Actual header toggle must format only its own editor: \(first.outline)")
        precondition(window.firstResponder === view && first.session.selectedInlineStyle.contains(.strong))
        view.undoManager?.undo()
        await settle()
        precondition(first.outline == original && !first.session.selectedInlineStyle.contains(.strong))
        view.undoManager?.redo()
        await settle()
        precondition(first.outline.contains("**plain**") && first.session.selectedInlineStyle.contains(.strong))
        print("PASS: native header Press preserves selection, targets its pane, updates the document and supports undo/redo")

        press("Italics")
        await settle()
        precondition(first.outline.contains("***plain***") && first.session.selectedInlineStyle.contains([.strong, .emphasis]))
        press("Bold")
        await settle()
        precondition(first.outline.contains("*plain*") && !first.session.selectedInlineStyle.contains(.strong)
                     && first.session.selectedInlineStyle.contains(.emphasis))
        print("PASS: bold and italic toggle independently while preserving the other trait")

        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        await settle()
        let beforeTyping = first.outline
        press("Bold")
        await settle()
        precondition(first.outline == beforeTyping && first.session.selectedInlineStyle.contains(.strong),
                     "Caret formatting changes typing attributes without changing the document")
        view.insertText("X", replacementRange: view.selectedRange())
        await settle()
        precondition(first.outline.contains("**X**"), "New text must use the toolbar's typing format: \(first.outline)")
        let italicShortcut = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                              timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                              characters: "i", charactersIgnoringModifiers: "i", isARepeat: false, keyCode: 34)!
        precondition(view.performKeyEquivalent(with: italicShortcut))
        await settle()
        precondition(first.session.selectedInlineStyle.contains([.strong, .emphasis]),
                     "Keyboard shortcuts must update header state at the caret")
        print("PASS: caret formatting affects subsequent typing, and keyboard shortcuts update the header")

        let headingSource = "Title with **bold**, *italic*, [link](https://example.com), and `code`.\n\nUntouched __source__.\n"
        first.load(headingSource)
        await settle()
        select("Title")
        let headingSelection = view.selectedRange()
        window.makeFirstResponder(other)
        first.session.setHeadingLevel(1)
        await settle()
        precondition(first.outline == outline("# " + headingSource), "Heading 1 applies to the whole paragraph: \(first.outline)")
        precondition(view.selectedRange() == headingSelection && window.firstResponder === view)
        precondition(!view.string.contains("#") && first.session.selectedHeadingLevel == 1)
        precondition(second.outline == original, "Heading commands must stay in their editor pane")
        view.undoManager?.undo()
        await settle()
        precondition(first.outline == outline(headingSource) && first.session.selectedHeadingLevel == 0)
        view.undoManager?.redo()
        await settle()
        precondition(first.outline == outline("# " + headingSource) && first.session.selectedHeadingLevel == 1,
                     "Heading redo: \(first.outline.debugDescription), level \(String(describing: first.session.selectedHeadingLevel)), selection \(view.selectedRange())")
        for level in 2...6 {
            first.session.setHeadingLevel(level)
            await settle()
            precondition(first.outline == outline(String(repeating: "#", count: level) + " " + headingSource),
                         "Heading \(level) must preserve inline formatting and other paragraphs: \(first.outline)")
            precondition(first.session.selectedHeadingLevel == level)
        }
        first.session.setHeadingLevel(0)
        await settle()
        precondition(first.outline == outline(headingSource), "Body removes the heading without leaving inherited bold")
        print("PASS: Heading 1–6 and Body preserve inline content, other paragraphs, selection, pane isolation and undo/redo")

        first.load("First paragraph.\n\nSecond paragraph.\n\nThird paragraph.")
        await settle()
        let end = NSMaxRange((view.string as NSString).range(of: "Second paragraph."))
        view.setSelectedRange(NSRange(location: 2, length: end - 2))
        first.session.setHeadingLevel(2)
        await settle()
        precondition(first.outline == outline("## First paragraph.\n\n## Second paragraph.\n\nThird paragraph."),
                     "Partial selection must format complete paragraphs: \(first.outline)")
        view.undoManager?.undo()
        await settle()
        precondition(first.outline == outline("First paragraph.\n\nSecond paragraph.\n\nThird paragraph."), "Multi-paragraph formatting must undo together")
        first.load("# Loaded heading\n\nBody")
        await settle()
        precondition(first.session.selectedHeadingLevel == 1, "Loaded heading state: \(String(describing: first.session.selectedHeadingLevel))")
        first.session.setHeadingLevel(0)
        await settle()
        precondition(first.outline == outline("Loaded heading\n\nBody"), "A parsed heading's implicit bold must not become emphasis")
        print("PASS: multiple paragraphs format in one undo step, and imported headings map back to Body")

        first.load("")
        await settle()
        first.session.setHeadingLevel(3)
        precondition(first.outline.isEmpty && first.session.selectedHeadingLevel == 3)
        view.insertText("New heading", replacementRange: view.selectedRange())
        view.insertNewline(nil)
        view.insertText("Body text", replacementRange: view.selectedRange())
        await settle()
        precondition(first.outline.contains("### New heading\nBody text") && first.session.selectedHeadingLevel == 0,
                     "Empty-caret heading must apply to typing, with Return restoring Body: \(first.outline)")
        first.load("")
        await settle()
        for character in "## Typed heading" { view.insertText(String(character), replacementRange: view.selectedRange()) }
        await settle()
        precondition(first.session.selectedHeadingLevel == 2 && first.browser.reopened.shownText == "Typed heading",
                     "Typed `## ` applies Heading 2: \(first.outline.debugDescription)")
        print("PASS: empty paragraphs and Return stay synchronized with heading controls; typed `## ` applies Heading 2")

        first.load("> Quoted *text*.")
        await settle()
        first.session.setHeadingLevel(2)
        await settle()
        precondition(first.outline == outline("> ## Quoted *text*."), "Heading formatting must preserve quote structure")
        for source in ["- List item", "```\nliteral\n```", "| A | B |\n| --- | --- |\n| 1 | 2 |"] {
            first.load(source)
            await settle()
            precondition(!first.session.canSetHeadingLevel)
            first.session.setHeadingLevel(1)
            precondition(first.outline == outline(source), "Unsupported block structures must remain intact")
        }
        print("PASS: quotes retain structure; tables, lists and code blocks reject unsupported heading changes")

        // Imported markers pick the list style.
        let mixedLists = "- dash one\n- dash two\n\n* bullet\n\n1. first"
        first.load(mixedLists)
        await settle()
        let paragraphs = view.string.components(separatedBy: "\n")
        precondition(paragraphs[0].hasPrefix("\t–\t") && paragraphs[2].hasPrefix("\t•\t") && paragraphs[3].hasPrefix("\t1.\t"),
                     "List markers: \(paragraphs.map(\.debugDescription))")
        select("dash one")
        await settle()
        precondition(first.session.selectedListKind == .dashed)
        select("bullet")
        await settle()
        precondition(first.session.selectedListKind == .bulleted)
        print("PASS: `-` imports as a dashed list, `*` as bulleted")

        func expect(_ kind: MarkdownListKind?, _ markdown: String, _ step: String) async {
            if let kind { first.session.setListKind(kind) } else { first.session.setBodyStyle() }
            await settle()
            precondition(first.outline == outline(markdown), "\(step): \(first.outline.debugDescription)")
            precondition(window.firstResponder === view)
        }
        first.load("alpha **bold**\n\nbeta")
        await settle()
        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
        await expect(.numbered, "1. alpha **bold**\n2. beta", "Numbered")
        precondition(first.session.selectedListKind == .numbered)
        await expect(.dashed, "- alpha **bold**\n- beta", "Dashed")
        await expect(.bulleted, "* alpha **bold**\n* beta", "Bulleted")
        await expect(.bulleted, "alpha **bold**\n\nbeta", "Choosing the current list style again")
        await expect(.dashed, "- alpha **bold**\n- beta", "Dashed again")
        await expect(nil, "alpha **bold**\n\nbeta", "Body")
        // Without real events every step since loading shares one undo group, so undo a single step.
        first.load("- alpha **bold**\n- beta")
        await settle()
        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
        await expect(nil, "alpha **bold**\n\nbeta", "Body from a loaded list")
        view.undoManager?.undo()
        await settle()
        precondition(first.outline == outline("- alpha **bold**\n- beta"), "Undo list removal: \(first.outline.debugDescription)")
        print("PASS: Paragraph Style lists convert, toggle back to body, keep inline formatting, and undo")

        first.load("# Title")
        await settle()
        view.setSelectedRange(NSRange(location: 2, length: 0))
        await expect(.dashed, "- Title", "Heading to list")
        precondition(view.selectedRange().location == (view.string as NSString).range(of: "Title").location + 2,
                     "Caret must stay on the same text: \(view.selectedRange())")
        first.load("> quoted")
        await settle()
        select("quoted")
        await expect(.bulleted, "> * quoted", "Quoted list")
        first.load("```\ncode\n```")
        await settle()
        select("code")
        await settle()
        precondition(!first.session.canSetListKind)
        first.session.setListKind(.dashed)
        precondition(first.outline == outline("```\ncode\n```"), "Code blocks reject list styles")
        print("PASS: headings become list items, quotes keep their structure, code blocks are left alone")

        first.load("")
        await settle()
        view.setSelectedRange(NSRange(location: 0, length: 0))
        first.session.setListKind(.numbered)
        await settle()
        view.insertText("x", replacementRange: view.selectedRange())
        await settle()
        precondition(first.outline == outline("1. x"), "List in an empty document: \(first.outline.debugDescription)")
        for typed in ["* ", "- "] {
            first.load("")
            await settle()
            view.setSelectedRange(NSRange(location: 0, length: 0))
            for character in typed + "item" { view.insertText(String(character), replacementRange: view.selectedRange()) }
            await settle()
            let reopened = first.browser.reopened
            precondition(reopened.containsList && reopened.shownText.hasSuffix("item"),
                         "Typed \(typed.debugDescription) creates a native list: \(first.outline.debugDescription)")
        }
        print("PASS: lists start in an empty document from Paragraph Style, and typed `* `/`- ` create lists")

        func type(_ text: String) {
            for character in text { view.insertText(String(character), replacementRange: view.selectedRange()) }
        }
        first.load("")
        await settle()
        type("> Literal")
        precondition(view.string == "> Literal" && !view.quoteSelection.containsQuote,
                     "Typing > must remain literal rather than enter a quote")
        first.load("")
        await settle()
        first.session.setBlockQuote(true)
        precondition(view.string.isEmpty && first.session.isBlockQuote)
        type("First")
        view.insertNewline(nil)
        view.insertNewline(nil)
        type("Third")
        await settle()
        precondition(view.string == "First\n\nThird" && first.session.isBlockQuote
                     && view.document.quoteSelection(in: view.textStorage!).isQuoted,
                     "Return must continue the same quote, including empty paragraphs")
        let quoteBeforeDelete = NSAttributedString(attributedString: view.textStorage!)
        view.setSelectedRange(NSRange(location: (view.string as NSString).range(of: "Third").location, length: 0))
        view.undoManager?.removeAllActions()
        view.deleteBackward(nil)
        precondition(view.string == "First\nThird" && view.quoteSelection.isQuoted,
                     "Backspace must remove a blank quote line without leaving the quote")
        view.undoManager?.undo()
        precondition(view.textStorage!.isEqual(to: quoteBeforeDelete), "Undo restores the deleted quote line and its style")
        view.setSelectedRange(NSRange(location: (view.string as NSString).range(of: "Third").location, length: 0))
        view.deleteBackward(nil)
        view.deleteBackward(nil)
        precondition(view.string == "FirstThird" && view.quoteSelection.isQuoted,
                     "Backspace joins quoted paragraphs normally")
        view.setSelectedRange(NSRange(location: 5, length: 0))
        view.insertNewline(nil)
        view.setSelectedRange(NSRange(location: 5, length: 0))
        view.deleteForward(nil)
        precondition(view.string == "FirstThird" && view.quoteSelection.isQuoted,
                     "Forward Delete joins quoted paragraphs normally")
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        view.insertNewline(nil)
        let beforeExit = view.string
        first.session.setBlockQuote(false)
        precondition(view.string == beforeExit && !first.session.isBlockQuote,
                     "Turning off Quote on an empty line must not insert another line")
        type("Outside")
        precondition(first.outline == "> FirstThird\nOutside", "Only the explicitly styled paragraphs belong to the quote")
        let quoteSaved = first.browser.reopened
        precondition(quoteSaved.string == view.string && quoteSaved.outline == "> FirstThird\nOutside")
        let word = ManuscriptDOCX.render(quoteSaved, baseURL: nil, title: "Quote", settings: ManuscriptExportSettings(), citations: nil).data
        precondition(String(decoding: word, as: UTF8.self).contains("<w:pStyle w:val=\"Quote\"/>"),
                     "Block quotes export as Word Quote paragraphs")
        print("PASS: literal >, explicit quote entry/exit, blank lines, native deletion, Undo, save/reopen and Word quote style")

        first.load("alpha **bold** 😀\n\nbeta\n\nUntouched")
        await settle()
        let beforeQuote = first.outline
        let quotedRange = NSRange(location: 2, length: NSMaxRange((view.string as NSString).range(of: "beta")) - 2)
        view.setSelectedRange(quotedRange)
        window.makeFirstResponder(other)
        first.session.setBlockQuote(true)
        await settle()
        precondition(first.outline == "> alpha **bold** 😀\n> beta\nUntouched"
                     && view.selectedRange() == quotedRange && window.firstResponder === view
                     && second.outline == original && first.session.isBlockQuote,
                     "Quote styles selected paragraphs, preserving inline text, selection and pane ownership")
        view.undoManager?.undo()
        await settle()
        precondition(first.outline == beforeQuote && !first.session.isBlockQuote)
        view.undoManager?.redo()
        await settle()
        precondition(first.session.isBlockQuote && first.outline == "> alpha **bold** 😀\n> beta\nUntouched")
        first.session.setBodyStyle()
        precondition(first.outline == beforeQuote && !first.session.isBlockQuote,
                     "Body removes quote styling without altering text")
        let quoteShortcut = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
                                             timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                             characters: "(", charactersIgnoringModifiers: "(", isARepeat: false, keyCode: 25)!
        precondition(view.performKeyEquivalent(with: quoteShortcut) && view.quoteSelection.isQuoted,
                     "Command-Shift-9 applies Quote to the editor with focus")
        precondition(view.performKeyEquivalent(with: quoteShortcut) && !view.quoteSelection.containsQuote,
                     "Command-Shift-9 toggles Quote off")
        print("PASS: quote selection, inline formatting, pane ownership, Body, Undo/Redo and keyboard shortcut")

        first.load("# Heading")
        await settle()
        first.session.setBlockQuote(true)
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        view.insertNewline(nil)
        type("Continued")
        precondition(first.outline == "> # Heading\n> Continued",
                     "Return after a quoted heading continues the quote in body text")
        for source in ["```\ncode\n```", "| A | B |\n| --- | --- |\n| 1 | 2 |"] {
            first.load(source)
            await settle()
            precondition(!first.session.canSetBlockQuote)
            first.session.setBlockQuote(true)
            precondition(first.outline == outline(source), "Quote must leave code blocks and tables intact")
        }
        print("PASS: quote styling preserves heading transitions and refuses incompatible blocks")
    }
    static func settle() async { try? await Task.sleep(for: .milliseconds(300)) }
}
