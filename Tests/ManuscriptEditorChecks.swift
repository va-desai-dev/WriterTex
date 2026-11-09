import AppKit
import SwiftUI
import PDFKit
@testable import WriterTex

@main struct ManuscriptEditorChecks {
    @MainActor static func main() {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.accessory)
        AppDefaults.register()
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { print("FAIL: \(error)"); exit(1) }
        }
        NSApp.run()
    }

    @MainActor static func run() async throws {
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        let model = FileBrowserModel(), session = EditorSession()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Manuscript \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 550), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: FileViewer(model: model, session: session))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(250))
        var view = session.findTextView as! MarkdownRichTextView
        window.makeFirstResponder(view)
        func reset(_ text: NSAttributedString = NSAttributedString()) {
            view.textStorage!.setAttributedString(text)
            view.typingAttributes = view.document.style.bodyAttributes
            view.setSelectedRange(NSRange(location: 0, length: 0))
            view.undoManager?.removeAllActions()
        }
        func type(_ string: String) {
            for char in string { view.insertText(String(char), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        }
        reset(NSAttributedString(string: "Theme", attributes: view.document.style.bodyAttributes))
        let selectionBeforeTheme = view.selectedRange()
        let fontBeforeTheme = view.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let defaults = UserDefaults.standard
        let originalForeground = defaults.object(forKey: DefaultKeys.textColor.rawValue)
        defaults.set("#208060FF", forKey: DefaultKeys.textColor.rawValue)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        try await Task.sleep(for: .milliseconds(150))
        let foreground = NSColor(AppTheme.shared.foreground)
        check(view.textColor == foreground && view.insertionPointColor == foreground,
              "Appearance foreground reaches the mounted NSTextView and caret")
        check(view.typingAttributes[.foregroundColor] as? NSColor == foreground
              && view.textStorage!.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == foreground,
              "Native text and typing attributes receive the foreground")
        check(view.string == "Theme" && view.selectedRange() == selectionBeforeTheme && view.undoManager?.canUndo != true
              && view.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == fontBeforeTheme,
              "Theme updates preserve text, font, selection and undo")
        reset(); type("## Heading"); view.insertNewline(nil); type("Body")
        check(view.typingAttributes[.foregroundColor] as? NSColor == foreground,
              "New body paragraphs keep the chosen display foreground")
        if let originalForeground { defaults.set(originalForeground, forKey: DefaultKeys.textColor.rawValue) }
        else { defaults.removeObject(forKey: DefaultKeys.textColor.rawValue) }
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)

        reset(); type("$$ x + y $$")
        check(view.string == "$$ x + y $$" && view.textStorage!.attribute(.markdownSpan, at: 0, effectiveRange: nil) == nil,
              "Dollar delimiters remain ordinary editable text")
        let importedDollars = view.document.load("$$ x + y $$")
        check(importedDollars.attribute(.markdownSpan, at: 0, effectiveRange: nil) == nil, "Markdown import has no LaTeX atomic spans")
        for level in 1...6 {
            reset()
            type(String(repeating: "#", count: level) + " Heading")
            check(view.string == "Heading" && view.textStorage!.attribute(.markdownHeading, at: 0, effectiveRange: nil) as? Int == level, "H\(level) typing shortcut")
            view.insertNewline(nil)
            type("Body")
            check(view.textStorage!.attribute(.markdownHeading, at: view.string.utf16.count - 1, effectiveRange: nil) == nil, "Return leaves H\(level)")
        }
        for (source, expected, style) in [("**bold**", "bold", MarkdownInlineStyle.strong), ("*italic*", "italic", .emphasis), ("~~strike~~", "strike", .strikethrough), ("`code`", "code", .code)] {
            reset(); type(String(source.dropLast()))
            try await Task.sleep(for: .milliseconds(20))
            type(String(source.suffix(1)))
            try await Task.sleep(for: .milliseconds(20))
            check(view.string == expected && view.selectedRange().location == expected.utf16.count && MarkdownInlineStyle(view.textStorage!.attributes(at: 0, effectiveRange: nil)).contains(style), "Inline shortcut \(source)")
            view.undoManager?.undo()
            check(view.string == source, "Undo restores delimiters \(source): \(view.string.debugDescription)")
            view.undoManager?.redo()
            check(view.string == expected, "Redo restores formatting \(source)")
        }
        reset(); type("snake_case_name and \\*literal*")
        check(view.string == "snake_case_name and \\*literal*", "Literal punctuation stays literal")
        reset(); view.insertText("## Pasted **literal**", replacementRange: view.selectedRange())
        check(view.string == "## Pasted **literal**", "Multi-character insertion never parses shortcuts")
        for marker in ["- ", "* ", "1. "] {
            reset(); type(marker + "Item")
            check(view.listSelection.containsList && view.string.contains("Item"), "Native list shortcut \(marker)")
        }
        for useToolbar in [false, true] {
            reset()
            let path = useToolbar ? "toolbar" : "typing shortcut"
            if useToolbar { view.setListKind(.numbered) } else { type("1. ") }
            type("First")
            // Isolate Return from the synthetic typing's event-level undo group.
            view.breakUndoCoalescing()
            try await Task.sleep(for: .milliseconds(20))
            view.undoManager?.removeAllActions()
            view.insertNewline(nil)
            check(view.string == "\t1.\tFirst\n\t2.\t\n", "\(path): Return immediately inserts item 2")
            let afterReturn = view.string
            try await Task.sleep(for: .milliseconds(20))
            check(view.string == afterReturn, "\(path): numbering stays unchanged after the edit settles")
            view.undoManager?.undo()
            check(view.string == "\t1.\tFirst", "\(path): Undo removes the new item: \(view.string.debugDescription)")
            view.undoManager?.redo()
            check(view.string == afterReturn, "\(path): Redo restores item 2")
            type("Second"); view.insertNewline(nil); type("Third")
            let expected = "\t1.\tFirst\n\t2.\tSecond\n\t3.\tThird\n"
            check(view.string == expected, "\(path): native continuation numbers three items in order")
            let reopenedList = try ManuscriptDocument.decode(ManuscriptDocument.encode(view.textStorage!), using: view.document)
            reset(reopenedList)
            view.setSelectedRange(NSRange(location: NSMaxRange((view.string as NSString).range(of: "Third")), length: 0))
            view.insertNewline(nil)
            check(view.string == expected + "\t4.\t\n", "\(path): reopened list continues at item 4")
            view.insertNewline(nil)
            check((view.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.textLists.isEmpty == true
                  && !view.string.contains("\t4.\t"), "\(path): Return on an empty item leaves the list")
        }
        reset(NSAttributedString(string: "\nBody below", attributes: view.document.style.bodyAttributes))
        type("1. First"); view.insertNewline(nil); type("Second")
        check(view.string == "\t1.\tFirst\n\t2.\tSecond\nBody below",
              "Typed list continues before an existing body paragraph")
        let bodyBelow = (view.string as NSString).range(of: "Body below")
        check((view.textStorage!.attribute(.paragraphStyle, at: bodyBelow.location, effectiveRange: nil) as? NSParagraphStyle)?.textLists.isEmpty == true,
              "Starting a list preserves the body paragraph below")
        reset(NSAttributedString(string: "\nNext", attributes: view.document.style.bodyAttributes))
        type("## "); type("Middle")
        check(view.string == "Middle\nNext" && view.textStorage!.attribute(.markdownHeading, at: 0, effectiveRange: nil) as? Int == 2, "Heading shortcut in empty middle paragraph")

        let source = view.document.load("# Title\n\nA **bold** and *italic* manuscript 😀. [@smith2020]\n\n> Quoted text\n\n```swift\nlet x = 1\n```\n\n1. First\n2. Second\n\n| Name | Value |\n| --- | ---: |\n| One | 1 |")
        let encoded = try ManuscriptDocument.encode(source)
        let restored = try ManuscriptDocument.decode(encoded, using: view.document)
        check(encoded.starts(with: Data("bplist00".utf8)), "WriterTex stores a rich-text container")
        check(restored.string == source.string, "Native RTFD preserves exact text and table/list markers")
        check(restored.attribute(.markdownHeading, at: 0, effectiveRange: nil) as? Int == 1, "Heading semantics reopen")
        let boldRange = (restored.string as NSString).range(of: "bold")
        check(MarkdownInlineStyle(restored.attributes(at: boldRange.location, effectiveRange: nil)).contains(.strong), "Bold reopens")
        let quoted = (restored.string as NSString).range(of: "Quoted")
        check((restored.attribute(.paragraphStyle, at: quoted.location, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.last is MarkdownQuoteBlock, "Quote reopens")
        let cell = (restored.string as NSString).range(of: "One")
        check(view.document.tableGrid(at: cell.location, in: restored)?.cells.count == 2, "Table structure reopens")
        reset(restored); view.didChangeText()
        let savedURL = root.appendingPathComponent("Manuscript.wrtx")
        let saved = try model.documentContents()
        try saved.write(to: savedURL)
        check(!model.hasUnsavedChanges, "Saving clears unsaved changes")
        check(try ManuscriptDocument.decode(saved, using: view.document).string == restored.string, "Saved manuscript opens without Markdown parsing")
        defaults.set("#208060FF", forKey: DefaultKeys.textColor.rawValue)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        try await Task.sleep(for: .milliseconds(150))
        check(try !model.hasUnsavedChanges && Data(contentsOf: savedURL) == saved,
              "Changing display foreground leaves the saved manuscript clean")
        model.hostDocument(saved, at: savedURL)
        try await Task.sleep(for: .milliseconds(150))
        let reopenedView = session.findTextView!
        let shown = { (color: Any?) -> NSColor? in
            var resolved: NSColor?
            reopenedView.effectiveAppearance.performAsCurrentDrawingAppearance { resolved = (color as? NSColor)?.usingColorSpace(.sRGB) }
            return resolved
        }
        check(shown(reopenedView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil)) == shown(NSColor(AppTheme.shared.foreground)),
              "Reopening applies the current display foreground")
        if let originalForeground { defaults.set(originalForeground, forKey: DefaultKeys.textColor.rawValue) }
        else { defaults.removeObject(forKey: DefaultKeys.textColor.rawValue) }
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)

        let citation = Citation(fields: ["id": .string("smith2020"), "type": .string("article-journal"), "title": .string("A robust editor"), "container-title": .string("Journal of Writing"), "author": .array([.object(["family": .string("Smith"), "given": .string("Jane")])]), "issued": .object(["date-parts": .array([.array([.number(2020)])])])])
        let citations = ManuscriptCitationSource(style: try CitationStyleLibrary.shared.style("apa"), items: [citation], referencesTitle: "References")
        let result = try await model.exportManuscript(ManuscriptExportSettings(), as: .docx, into: root, citations: citations)
        let docx = try Data(contentsOf: result.url)
        try docx.write(to: URL(fileURLWithPath: "/tmp/writertex-manuscript-check.docx"))
        let xml = String(decoding: docx, as: UTF8.self)
        check(result.missing.isEmpty && xml.contains("Smith") && xml.contains("2020") && !xml.contains("[@smith2020]"), "Word resolves CSL citations")
        check(xml.contains("A robust editor") && xml.contains("Bibliography") && xml.contains("References"), "Word includes CSL bibliography")
        check(xml.contains("<w:tbl>") && xml.contains("Heading1") && xml.contains("<w:numPr>"), "Word contains real headings, table and list numbering")
        check((try model.manuscriptSnapshot()).string == source.string, "Export leaves editable source intact")
        let pdf = ManuscriptPDF.render(restored, baseURL: root, title: "Manuscript", settings: ManuscriptExportSettings(), citations: citations)
        let pdfDocument = PDFDocument(data: pdf.data)
        check((pdfDocument?.pageCount ?? 0) > 0 && pdfDocument?.string?.contains("Smith") == true,
              "PDF export still paginates rich text and formatted CSL citations")

        let legacyText = NSAttributedString(string: "Legacy text")
        let legacy = try legacyText.data(from: NSRange(location: 0, length: legacyText.length),
                                         documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        model.hostDocument(legacy, at: root.appendingPathComponent("Legacy.wrtx"))
        try await Task.sleep(for: .milliseconds(150))
        check(try model.manuscriptSnapshot().string == "Legacy text", "Plain-RTF manuscripts open as rich text")
        check(try model.documentContents().starts(with: Data("bplist".utf8)), "Saving upgrades plain-RTF manuscripts")

        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { bounds in
            NSColor.blue.setFill(); bounds.fill(); return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: 0, width: 24, height: 24)
        let figure = NSAttributedString(attachment: attachment)
        let roundTripFigure = try ManuscriptDocument.decode(ManuscriptDocument.encode(figure), using: view.document)
        let restoredAttachment = roundTripFigure.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
        check(restoredAttachment?.image?.isValid == true && restoredAttachment?.bounds.size == NSSize(width: 24, height: 24),
              "Embedded image pixels and size survive native storage")
        let imageWord = ManuscriptDOCX.render(roundTripFigure, baseURL: nil, title: "Figure", settings: ManuscriptExportSettings(), citations: nil).data
        check(String(decoding: imageWord, as: UTF8.self).contains("word/media/image1.png"), "Reopened images embed in Word exports")
        let empty = try ManuscriptDocument.decode(ManuscriptDocument.encode(NSAttributedString()), using: view.document)
        check(empty.length == 0, "Empty manuscripts round-trip")
        do {
            _ = try ManuscriptDocument.decode(Data("bplist00broken".utf8), using: view.document)
            check(false, "Corrupt files are rejected")
        } catch { check(true, "Corrupt files are rejected") }

        // Compare per-keystroke work on a short and a long manuscript. This is a
        // diagnostic, not a machine-dependent pass/fail wall-clock threshold.
        view = session.findTextView as! MarkdownRichTextView
        for count in [100, 100_000] {
            reset(NSAttributedString(string: String(repeating: "word ", count: count), attributes: view.document.style.bodyAttributes))
            view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
            let started = ContinuousClock.now
            for _ in 0..<100 { type("x"); session.updateFormattingState(from: view) }
            print("TIMING: \(count) words, 100 edits + toolbar updates: \(started.duration(to: .now))")
        }
        precondition(failures == 0, "\(failures) manuscript checks failed")
    }
}
