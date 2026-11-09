import AppKit
import SwiftUI
@testable import WriterTex

@main struct ManuscriptScrollChecks {
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

    @MainActor static func editor(in view: NSView) -> MarkdownRichTextView? {
        if let text = view as? MarkdownRichTextView { return text }
        return view.subviews.lazy.compactMap { editor(in: $0) }.first
    }

    @MainActor static func run() async {
        // Grow a short native manuscript through real edits. Cold-open checks
        // alone miss stale document frames after typing and paragraph formatting.
        let model = FileBrowserModel(), session = EditorSession()
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 850, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: RichMarkdownEditor(richData: Data(), model: model,
            editorIsFocused: .constant(true), session: session))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(100))
        let view = editor(in: host)!
        window.makeFirstResponder(view)
        for text in ["# Research Notes", "## Video Reaction", "### Working Questions"] {
            for character in text {
                view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            view.insertNewline(nil)
        }
        for index in 0..<20 {
            view.insertText("Paragraph \(index): " + String(repeating: "Body text wraps while typing. ", count: 8), replacementRange: view.selectedRange())
            view.insertNewline(nil)
            try? await Task.sleep(for: .milliseconds(20))
            let layout = view.layoutManager!, container = view.textContainer!
            let bottom = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
                + view.textContainerOrigin.y
            precondition(view.frame.height >= bottom, "Typing must grow the document view to contain every line and caret")
            if index == 2, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/writertex-rtf-typing.png"))
            }
        }
        view.scrollRangeToVisible(view.selectedRange())
        precondition(view.visibleRect.maxY >= view.layoutManager!.usedRect(for: view.textContainer!).maxY + view.textContainerOrigin.y,
                     "The final typed paragraph must be reachable by scrolling")
        print("PASS: Typed headings and paragraphs grow the native manuscript without clipping text or the caret")
        window.close()

        let paragraph = "A manuscript should scroll smoothly while the author reads and revises each paragraph. Native text layout already knows how to wrap these lines and position every glyph on the page. "
        let prose = (0..<32).map { "Paragraph \($0 + 1). " + paragraph }.joined(separator: "\n\n")
        let table = "| Name | Value | Detail |\n| --- | ---: | --- |\n" + (0..<200).map { "| Row \($0) | \($0) | Some longer cell text that wraps in a narrow window |\n" }.joined()
        let long = (0..<1600).map { "Paragraph \($0 + 1). " + paragraph }.joined(separator: "\n\n")
        for (name, text) in [("four-page prose", prose), ("200-row table", table), ("long prose", long)] {
            let model = FileBrowserModel(), session = EditorSession()
            let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 850, height: 500),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let data = manuscriptData(text)
            let started = ContinuousClock.now
            let host = NSHostingView(rootView: RichMarkdownEditor(richData: data, model: model,
                editorIsFocused: .constant(false), session: session))
            window.contentView = host
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            guard let view = editor(in: host), view.enclosingScrollView != nil,
                  let layout = view.layoutManager, let container = view.textContainer else { fatalError("Editor did not mount") }
            // Start with native deferred layout: revealing a target must lay it
            // out and make it reachable without an eager whole-document pass.
            let originalText = NSAttributedString(attributedString: view.textStorage!)
            let selection = view.selectedRange()
            print("LOAD \(name): \(started.duration(to: .now)); chars=\(view.string.utf16.count), height=\(view.frame.height)")

            func scrollBurst(_ phase: String) {
                let start = ContinuousClock.now
                var slowest = 0.0
                for step in 0..<48 {
                    let before = ContinuousClock.now
                    let index = Int(CGFloat(step % 12) / 11 * CGFloat(view.string.utf16.count - 1))
                    let target = NSRange(location: index, length: 1)
                    view.scrollRangeToVisible(target)
                    view.display(view.visibleRect)
                    let glyphs = layout.glyphRange(forCharacterRange: target, actualCharacterRange: nil)
                    let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                        .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
                    precondition(rect.minY >= view.visibleRect.minY - 1 && rect.maxY <= view.visibleRect.maxY + 1,
                                 "\(name): native scrolling must reveal character \(index) during \(phase)")
                    precondition(view.frame.height >= rect.maxY, "The scroll document must contain the revealed text")
                    let duration = before.duration(to: .now).components
                    slowest = max(slowest, Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
                }
                print("SCROLL \(name), \(phase): 48 reveals in \(start.duration(to: .now)); slowest=\(slowest)s")
            }
            scrollBurst("cold open")
            window.setContentSize(NSSize(width: 600, height: 500))
            host.layoutSubtreeIfNeeded()
            scrollBurst("narrow resize")
            precondition(view.textStorage!.isEqual(to: originalText) && view.selectedRange() == selection,
                         "Scrolling and resizing must preserve text attributes and selection")
            precondition(view.undoManager?.canUndo != true, "Layout must not create undo actions")
            window.close()
            try? await Task.sleep(for: .milliseconds(100))
        }
        print("PASS: Native scrolling reveals text throughout the document before and after resizing")
    }
}
