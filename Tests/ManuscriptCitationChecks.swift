import AppKit
import SwiftUI
@testable import WriterTex

@main struct ManuscriptCitationChecks {
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
        let model = FileBrowserModel(), session = EditorSession()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 550),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: RichMarkdownEditor(
            richData: manuscriptData("Text 😀 [@smith2020; @jones2021, p. 4] and `[@code]`."), model: model,
            editorIsFocused: .constant(true), session: session))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        let view = session.findTextView as! MarkdownRichTextView
        let storage = view.textStorage!
        let coordinator = view.delegate as! RichMarkdownEditor.Coordinator
        func range(_ text: String) -> NSRange { (view.string as NSString).range(of: text) }
        func link(_ text: String) -> Any? { storage.attribute(.link, at: range(text).location, effectiveRange: nil) }
        let marker = "[@smith2020; @jones2021, p. 4]"
        precondition(ManuscriptCitations.isLink(link(marker)))
        precondition(link("[@code]") == nil)
        precondition(view.undoManager?.canUndo != true && !coordinator.hasEdits)
        let saved = try ManuscriptDocument.encode(storage)
        let reopened = try ManuscriptDocument.decode(saved, using: view.document)
        precondition(ManuscriptCitations.isLink(reopened.attribute(.link, at: range(marker).location, effectiveRange: nil)))
        precondition(storage.string.contains(marker) && !storage.string.contains("writertex-citation:"))
        let printed = ManuscriptPDF.manuscriptText(storage, baseURL: nil,
            style: MarkdownStyleSheet(theme: .print, manuscript: .manuscript),
            settings: ManuscriptExportSettings(), citations: nil).text
        precondition(printed.attribute(.link, at: range(marker).location, effectiveRange: nil) == nil)
        print("PASS: Citation clusters load as native links, survive RTFD, and stay ordinary citation text in export")

        let linked = NSMutableAttributedString(string: "See the doi and [@smith2020].", attributes: view.document.style.bodyAttributes)
        let doi = URL(string: "https://doi.org/10.1/x")!
        let doiRange = (linked.string as NSString).range(of: "doi")
        linked.addAttribute(.link, value: doi, range: doiRange)
        ManuscriptCitations.updateLinks(in: linked, editedRange: NSRange(location: 0, length: linked.length))
        func hasHyperlinkField(_ rtfd: Data) -> Bool { rtfd.range(of: Data("HYPERLINK".utf8)) != nil }
        precondition(hasHyperlinkField(linked.rtfd(from: NSRange(location: 0, length: linked.length))!),
                     "Plain RTFD writes links as fields, which the RTF reader resolves through data detectors")
        let linkedFile = try ManuscriptDocument.encode(linked)
        let storedRTFD = try PropertyListDecoder().decode(ManuscriptDocument.self, from: linkedFile).rtfd
        precondition(!hasHyperlinkField(storedRTFD),
                     "No link reaches the stored RTFD")
        let relinked = try ManuscriptDocument.decode(linkedFile, using: view.document)
        precondition(relinked.attribute(.link, at: doiRange.location, effectiveRange: nil) as? URL == doi)
        precondition(ManuscriptCitations.isLink(relinked.attribute(.link, at: (relinked.string as NSString).range(of: "[@smith2020]").location, effectiveRange: nil)))
        print("PASS: Links are stored beside the RTFD and restored on opening, so reading it never waits on data detectors")

        let selected = view.selectedRange()
        var palette = view.document.style.theme
        palette.bodyText = .brown
        palette.link = .magenta
        view.updatePalette(palette)
        precondition(ManuscriptCitations.isLink(link(marker)))
        precondition(view.linkTextAttributes?[.foregroundColor] as? NSColor == .magenta)
        precondition(view.selectedRange() == selected && !coordinator.hasEdits && view.undoManager?.canUndo != true)
        print("PASS: Appearance foreground updates preserve citation links and native accent styling without edits or Undo")
        let visible = view.visibleRect
        let bitmap = view.bitmapImageRepForCachingDisplay(in: visible)!
        view.cacheDisplay(in: visible, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/writertex-citation-theme.png"))
        var coloredPixels = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.alphaComponent > 0.5, color.redComponent > 0.6,
                   color.blueComponent > 0.6, color.greenComponent < 0.4 { coloredPixels += 1 }
            }
        }
        precondition(coloredPixels > 10, "Native rendering must actually draw citations in the accent color")
        print("PASS: Native NSTextView rendering draws the citation accent color")

        let nativeMenu = NSMenu()
        nativeMenu.addItem(withTitle: "Native Item", action: nil, keyEquivalent: "")
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let menu = coordinator.textView(view, menu: nativeMenu, for: event, at: range(marker).location)!
        precondition(menu.items.map(\.title).contains("Select Citation") && menu.items.map(\.title).contains("Native Item"))
        let copy = menu.items.first { $0.title == "Copy Citation" }!
        precondition(copy.representedObject as? String == marker)
        let select = menu.items.first { $0.title == "Select Citation" }!
        NSApp.sendAction(select.action!, to: select.target, from: select)
        precondition(view.selectedRange() == range(marker))
        precondition(coordinator.textView(view, clickedOnLink: link(marker)!, at: range(marker).location))
        precondition(!coordinator.textView(view, clickedOnLink: URL(string: "https://example.com")!, at: 0))
        print("PASS: Native citation menu selects/copies the marker, retains standard items, and consumes internal link clicks")

        func waitUntil(line: Int = #line, _ condition: () -> Bool) async throws {
            for _ in 0..<300 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            preconditionFailure("Timed out waiting at line \(line)")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bib = root.appendingPathComponent("refs.bib")
        try """
        @article{smith2020, author = {Smith, Ada}, title = {First Smith}, journal = {Journal}, year = {2020}, doi = {10.1/x}}
        @article{jones2021, author = {Jones, Bo}, title = {Jones Paper}, year = {2021}}
        @article{smith2020, author = {Smith, Ada}, title = {Second Smith}, year = {2020}}
        """.write(to: bib, atomically: true, encoding: .utf8)
        let library = BibLibrary(projectID: UUID(), root: root, inbox: nil)
        library.select(bib)
        session.bibliography = library
        try await waitUntil { !session.entries(cited: marker).isEmpty }
        let cited = session.entries(cited: marker)
        precondition(cited.map(\.key) == ["smith2020", "jones2021"])
        precondition(cited[0].citation.title == "First Smith", "A repeated key resolves to its first entry, as BibTeX does")
        precondition(session.entries(cited: "[@missing; @jones2021]").map(\.key) == ["jones2021"])

        /// A new popover each time: `close()` animates, so `isShown` lags.
        func opensPopover(_ action: () -> Void) -> Bool {
            let before = coordinator.citationPopover
            action()
            return coordinator.citationPopover !== before && coordinator.citationPopover?.isShown == true
        }
        let resolvedMenu = coordinator.textView(view, menu: NSMenu(), for: event, at: range(marker).location)!
        let open = resolvedMenu.items.first { $0.title == "Go to Citation" }!
        precondition(opensPopover { NSApp.sendAction(open.action!, to: open.target, from: open) })
        precondition(coordinator.citationPopover?.contentViewController is NSHostingController<CitationPopover>)

        precondition(view.gestureRecognizers.allSatisfy { NSStringFromClass(type(of: $0)).hasPrefix("NS") || NSStringFromClass(type(of: $0)).hasPrefix("_NS") },
                     "Force click stays the system's: Look Up and definitions work on citations too")

        try "@article{smith2020, title = {Revised Smith}, year = {2020}}".write(to: bib, atomically: true, encoding: .utf8)
        library.reload()
        try await waitUntil { session.entries(cited: marker).first?.citation.title == "Revised Smith" }
        precondition(session.entries(cited: marker).map(\.key) == ["smith2020"])
        library.select(nil)
        try await waitUntil { session.entries(cited: marker).isEmpty }
        precondition(!coordinator.textView(view, menu: NSMenu(), for: event, at: range(marker).location)!.items.contains { $0.title == "Go to Citation" },
                     "An unresolved citation offers nothing to open")
        print("PASS: Citations resolve through a key index that follows the .bib, and Go to Citation opens a popover")

        storage.setAttributedString(NSAttributedString(string: "😀 [@smith2020", attributes: view.document.style.bodyAttributes))
        view.setSelectedRange(NSRange(location: storage.length, length: 0))
        view.typingAttributes = view.document.style.bodyAttributes
        view.insertText("]", replacementRange: view.selectedRange())
        precondition(ManuscriptCitations.isLink(link("[@smith2020]")))
        try await Task.sleep(for: .milliseconds(20))
        view.undoManager!.undo()
        precondition(view.string == "😀 [@smith2020" && link("[@smith2020") == nil)
        view.undoManager!.redo()
        precondition(ManuscriptCitations.isLink(link("[@smith2020]")))
        view.insertText(" suffix", replacementRange: view.selectedRange())
        precondition(link(" suffix") == nil && ManuscriptCitations.isLink(link("[@smith2020]")))
        view.insertText("", replacementRange: range("]"))
        precondition(link("[@smith2020") == nil)
        view.insertText("]", replacementRange: NSRange(location: range(" suffix").location, length: 0))
        precondition(ManuscriptCitations.isLink(link("[@smith2020]")))
        storage.addAttribute(.markdownInline, value: MarkdownInlineStyle.code.rawValue, range: range("[@smith2020]"))
        precondition(link("[@smith2020]") == nil)
        storage.removeAttribute(.markdownInline, range: range("[@smith2020]"))
        precondition(ManuscriptCitations.isLink(link("[@smith2020]")))
        let external = URL(string: "https://example.com")!
        storage.addAttribute(.link, value: external, range: range("[@smith2020]"))
        precondition(link("[@smith2020]") as? URL == external)
        print("PASS: Typing, Undo/Redo, deletion and formatting update citation links locally without coloring following prose or replacing external links")
    }
}
