import AppKit
import SwiftUI

/// The native editor keeps edits in NSTextStorage. Encoding to RTFD happens
/// only when a save or view handoff needs it.
struct RichMarkdownEditor: NSViewRepresentable {
    let richData: Data
    let model: FileBrowserModel
    @Binding var editorIsFocused: Bool
    let session: EditorSession
    var fileURL: URL?
    /// Read here, so the view that makes the editor follows Appearance changes.
    var palette = ManuscriptPalette.screen
    /// A document window's, so typing marks the document edited and Edit ▸ Undo
    /// reaches it. Without one the editor keeps its own.
    var undoManager: UndoManager?
    /// Room left under the text for a bar floating over the editor's bottom edge.
    var bottomInset: CGFloat = 0

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = MarkdownRichTextView(usingTextLayoutManager: false)
        let scrollView = NSScrollView()
        textView.document = MarkdownRichText(baseURL: fileURL?.deletingLastPathComponent(),
                                             style: MarkdownStyleSheet(theme: .screen, manuscript: .screen))
        textView.isRichText = true
        textView.allowsUndo = true
        textView.usesFontPanel = false
        textView.drawsBackground = false
        // Keep transparent text/selection repainting on an AppKit-owned surface.
        textView.wantsLayer = true

        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = true

        textView.allowsDocumentBackgroundColorChange = true

        textView.textContainerInset = NSSize(width: 60, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 10_000_000)
        // AppKit owns wrapping and vertical growth as the scroll view resizes.
        textView.textContainer?.containerSize = NSSize(width: 0, height: 10_000_000)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        // Native contiguous layout keeps document height stable while scrolling.
        textView.layoutManager?.allowsNonContiguousLayout = false


        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.scrollsDynamically = true
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        // SwiftUI's safe area doesn't reach AppKit; insets come from `bottomInset`.
        scrollView.automaticallyAdjustsContentInsets = false
        applyInsets(to: scrollView)

        context.coordinator.textView = textView
        textView.onInsertCitation = { [weak coordinator = context.coordinator] in coordinator?.showInsertionPanel() }
        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator
        context.coordinator.load(richData)
        textView.updatePalette(palette)
        model.attachPendingMarkdown(context.coordinator)
        let finder = context.coordinator.finder
        DispatchQueue.main.async {
            finder.attach(to: textView, session: session)
            context.coordinator.updateFormattingState()
            if editorIsFocused { textView.window?.makeFirstResponder(textView) }
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if richData != context.coordinator.richData || model.hostRevision != context.coordinator.hostRevision {
            context.coordinator.load(richData)
        }
        context.coordinator.textView?.updatePalette(palette)
        applyInsets(to: nsView)
        // A re-hosted document detaches the editor until it loads the new one.
        model.attachPendingMarkdown(context.coordinator)
    }

    /// Scroll room past the last line, so text typed at the end of the
    /// manuscript sits clear of the bar instead of flush against it.
    private static let overscroll: CGFloat = 96

    /// Text and scroller both stop above the bar, but the clip view still
    /// spans it, so lines scroll underneath. The text also gets `overscroll`
    /// beyond the bar; the scroller doesn't need it.
    private func applyInsets(to scrollView: NSScrollView) {
        let textInset = bottomInset + Self.overscroll
        guard scrollView.contentInsets.bottom != textInset else { return }
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: textInset, right: 0)
        scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        // Hands over edits when the view goes.
        coordinator.parent.model.commitPendingMarkdown()
        coordinator.parent.model.detachPendingMarkdown(coordinator)
        coordinator.finder.detach()
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate, PendingMarkdownSource {
        var parent: RichMarkdownEditor
        weak var textView: MarkdownRichTextView?
        let finder = TextFinder()
        /// The document last loaded or written, so the model's echo doesn't reload.
        private(set) var richData: Data?
        /// The model's `hostRevision` when this last loaded.
        private(set) var hostRevision: Int?
        /// Edits the rich text holds that `richData` doesn't have yet.
        private var isEdited = false
        private var isLoading = false
        private var isUpdatingCitationLinks = false
        private var formattingUpdateScheduled = false
        private let editorUndoManager = UndoManager()

        init(_ parent: RichMarkdownEditor) { self.parent = parent }

        func undoManager(for view: NSTextView) -> UndoManager? { parent.undoManager ?? editorUndoManager }

        func load(_ richData: Data) {
            guard let textView, let storage = textView.textStorage else { return }
            let loaded: NSAttributedString
            do {
                loaded = try ManuscriptDocument.decode(richData, using: textView.document)
            } catch {
                parent.model.reportDocumentError(error)
                textView.isEditable = false
                return
            }
            textView.isEditable = true
            self.richData = richData
            hostRevision = parent.model.hostRevision
            isEdited = false
            isLoading = true
            storage.setAttributedString(loaded)
            isLoading = false
            (parent.undoManager ?? editorUndoManager).removeAllActions()
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.typingAttributes = storage.length > 0
                ? storage.attributes(at: 0, effectiveRange: nil) : textView.document.style.bodyAttributes
            updateFormattingState()
        }

        func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            guard !isUpdatingCitationLinks else { return }
            isUpdatingCitationLinks = true
            ManuscriptCitations.updateLinks(in: textStorage, editedRange: editedRange)
            isUpdatingCitationLinks = false
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard ManuscriptCitations.isLink(link) else { return false }
            if let storage = textView.textStorage,
               let range = ManuscriptCitations.linkRange(in: storage, at: charIndex) {
                textView.setSelectedRange(range)
            }
            return true
        }

        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            guard let storage = view.textStorage,
                  let range = ManuscriptCitations.linkRange(in: storage, at: charIndex) else { return menu }
            let select = NSMenuItem(title: "Select Citation", action: #selector(selectCitation(_:)), keyEquivalent: "")
            select.target = self
            select.representedObject = NSValue(range: range)
            let copy = NSMenuItem(title: "Copy Citation", action: #selector(copyCitation(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = (storage.string as NSString).substring(with: range)
            menu.insertItem(.separator(), at: 0)
            menu.removeAllItems()
            // Offered only when the marker resolves, so the item never opens on nothing.
            let entries = parent.session.entries(cited: copy.representedObject as? String ?? "")
            if !entries.isEmpty {
                let open = NSMenuItem(title: "Inspect Citation", action: #selector(openCitation(_:)), keyEquivalent: "")
                open.target = self
                open.representedObject = CitedEntries(range: range, entries: entries)
                menu.insertItem(open, at: 0)
            }
            menu.insertItem(copy, at: 1)
            menu.insertItem(select, at: 2)
            return menu
        }

        /// What "Go to Citation" carries: the marker's range, to anchor a
        /// popover on, and the entries it cites, resolved when the menu opened.
        struct CitedEntries {
            let range: NSRange
            let entries: [BibEntry]
        }

        @objc private func openCitation(_ sender: NSMenuItem) {
            guard let cited = sender.representedObject as? CitedEntries,
                  let textView, NSMaxRange(cited.range) <= (textView.textStorage?.length ?? 0) else { return }
            showCitation(cited.entries, at: cited.range, in: textView)
        }

        /// The cite-while-you-write picker; held strongly until dismissed.
        private(set) var citationInsert: NSPopover?

        /// Opens the citation picker at the caret. The chosen marker replaces the
        /// selection as it was when the picker opened, as one undoable edit.
        func showInsertionPanel() {
            guard let textView, let window = textView.window, let library = parent.session.bibliography else {
                NSSound.beep()
                return
            }
            citationInsert?.close()
            let insertion = textView.selectedRange()
            // The caret's rect, from screen to view coordinates; widened so an
            // empty caret still gives the popover something to point at.
            let caret = textView.firstRect(forCharacterRange: NSRange(location: insertion.location, length: 0), actualRange: nil)
            var anchor = textView.convert(window.convertFromScreen(caret), from: nil)
            anchor.size.width = max(anchor.width, 1)

            let card = CitationInsertionCard(library: library) { [weak self] marker in
                self?.insertCitation(marker, at: insertion)
            } onCancel: { [weak self] in
                self?.citationInsert?.close()
                textView.window?.makeFirstResponder(textView)
            }
            let host = NSHostingController(rootView: card)
            host.sizingOptions = .preferredContentSize
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = host
            popover.show(relativeTo: anchor, of: textView, preferredEdge: .maxY)
            citationInsert = popover
        }

        private func insertCitation(_ marker: String, at range: NSRange) {
            citationInsert?.close()
            guard let textView, NSMaxRange(range) <= (textView.textStorage?.length ?? 0) else { return }
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(range)
            textView.insertText(marker, replacementRange: range)
        }

        /// Held strongly so it survives until dismissed.
        private(set) var citationPopover: NSPopover?

        private func showCitation(_ entries: [BibEntry], at range: NSRange, in textView: NSTextView) {
            guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
            citationPopover?.close()
            // Anchored on the marker's first line, so a wrapped citation
            // doesn't point the arrow at the space between its lines.
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var anchor = NSRect.zero
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs,
                                                  withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                                  in: container) { rect, stop in
                anchor = rect
                stop.pointee = true
            }
            anchor = anchor.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)

            let host = NSHostingController(rootView: CitationPopover(entries: entries))
            host.sizingOptions = .preferredContentSize
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = host
            popover.show(relativeTo: anchor, of: textView, preferredEdge: .maxY)
            citationPopover = popover
        }

        @objc private func selectCitation(_ sender: NSMenuItem) {
            guard let range = (sender.representedObject as? NSValue)?.rangeValue,
                  let textView, NSMaxRange(range) <= (textView.textStorage?.length ?? 0) else { return }
            textView.setSelectedRange(range)
            textView.window?.makeFirstResponder(textView)
        }

        @objc private func copyCitation(_ sender: NSMenuItem) {
            guard let text = sender.representedObject as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        func textDidChange(_ notification: Notification) {
            if !isEdited {
                isEdited = true
                parent.model.markPendingMarkdownEdited()
            }
            updateFormattingState()
        }

        func takeRichText() throws -> Data? {
            guard isEdited, let storage = textView?.textStorage else { return nil }
            let data = try ManuscriptDocument.encode(storage)
            richData = data
            isEdited = false
            return data
        }

        var richTextSnapshot: NSAttributedString? {
            guard let textView, textView.isEditable else { return nil }
            return textView.textStorage.map { NSAttributedString(attributedString: $0) }
        }

        var hasEdits: Bool { isEdited }

        var readableText: String {
            // Rich text separates paragraphs with one newline; counting expects a blank line.
            (textView?.string ?? "").replacingOccurrences(of: "\n", with: "\n\n")
        }

        func textViewDidChangeSelection(_ notification: Notification) { updateFormattingState() }

        func textViewDidChangeTypingAttributes(_ notification: Notification) { updateFormattingState() }

        func updateFormattingState() {
            // Selection can change during a SwiftUI document reload. Publish the latest
            // native state afterwards, without sending a formatting command back.
            guard !formattingUpdateScheduled else { return }
            formattingUpdateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                formattingUpdateScheduled = false
                guard let textView,
                      parent.session.finder?.textView === textView else { return }
                parent.session.updateFormattingState(from: textView)
            }
        }
    }
}
