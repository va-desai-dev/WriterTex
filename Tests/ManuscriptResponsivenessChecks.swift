import AppKit
import SwiftUI
@testable import WriterTex


/// Key whichever app is frontmost, so the checks don't depend on what the user is doing.
final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@main struct ManuscriptResponsivenessChecks {
    @MainActor static func main() {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.accessory)
        AppDefaults.register()
        Task { @MainActor in await run(); exit(0) }
        NSApp.run()
    }

    /// The longest the main thread goes without servicing its run loop after `edit`.
    @MainActor static func longestStall(after edit: () -> Void) -> Duration {
        edit()
        var worst = Duration.zero, last = ContinuousClock.now
        let end = last + .milliseconds(300)
        while ContinuousClock.now < end {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
            let now = ContinuousClock.now
            worst = max(worst, now - last)
            last = now
        }
        return worst
    }

    /// The leftmost drawn text in the view's current backing layer, without redrawing it.
    @MainActor static func leftmostInk(in view: NSView, excluding excluded: NSRect? = nil) -> CGFloat {
        let visible = view.visibleRect, scale = view.window!.backingScaleFactor
        let width = Int(visible.width * scale), height = Int(visible.height * scale)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -visible.minX, y: -visible.minY)
        view.layer!.render(in: context)
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        for x in 0..<width {
            let point = CGFloat(x) / scale
            if let excluded, point >= excluded.minX - 2, point <= excluded.maxX + 2 { continue }
            for y in stride(from: 0, to: height, by: 2) where bytes[(y * width + x) * 4 + 3] > 128 { return point }
        }
        return .infinity
    }

    @MainActor static func run() async {
        let paragraph = "Research on adolescence also suggests that chronotype development is associated with executive function, emotional control, and flexibility [@diss34; @diss105; @diss118]. Moreover, recent studies also report a bidirectional correlation between circadian entrainment and executive functions [@diss128]."
        let source = (0..<500).map { $0 % 12 == 0 ? "## Section \($0)\n\n\(paragraph)" : paragraph }.joined(separator: "\n\n")
        let document = MarkdownRichText(baseURL: nil, style: MarkdownStyleSheet(theme: .screen, manuscript: .screen))
        let data = try! ManuscriptDocument.encode(document.load(source))
        precondition(data.range(of: Data("writertex-citation".utf8)) == nil, "Citation links are not stored")
        let reopened = try! ManuscriptDocument.decode(data, using: document)
        let marker = (reopened.string as NSString).range(of: "[@diss128]")
        precondition(ManuscriptCitations.isLink(reopened.attribute(.link, at: marker.location, effectiveRange: nil)), "Opening rebuilds citation links")
        print("PASS: Citation links are rebuilt on opening instead of read back through AppKit's RTF link resolution")

        let model = FileBrowserModel(), session = EditorSession()
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let url = URL(fileURLWithPath: "/tmp/Responsiveness.wrtx")
        let start = ContinuousClock.now
        window.contentView = NSHostingView(rootView: RichMarkdownEditor(richData: data, model: model, editorIsFocused: .constant(true),
                                                                        session: session, fileURL: url))
        window.makeKeyAndOrderFront(nil)
        window.contentView!.layoutSubtreeIfNeeded()
        print("TIMING: first open of \(reopened.length) characters:", ContinuousClock.now - start)
        try? await Task.sleep(for: .milliseconds(200))
        let view = session.findTextView as! MarkdownRichTextView
        window.makeFirstResponder(view)
        precondition(view.layoutManager?.delegate == nil, "No layout delegate: it would cost TextKit its fast relayout below a new paragraph")

        view.setSelectedRange(NSRange(location: 2000, length: 0))
        let enters = (0..<5).map { _ in longestStall { view.insertNewline(nil) } }
        let typing = (0..<5).map { _ in longestStall { view.insertText("a", replacementRange: view.selectedRange()) } }
        print("TIMING: stalls after Enter \(enters.map { Int($0 / .milliseconds(1)) }) ms, after a character \(typing.map { Int($0 / .milliseconds(1)) }) ms")

        // Reflow must keep the drawn text, caret, and hit testing in agreement.
        for width in [1700.0, 900, 1300] {
            window.setContentSize(NSSize(width: width, height: 700))
            try? await Task.sleep(for: .milliseconds(150))
            let layout = view.layoutManager!, glyph = layout.glyphIndexForCharacter(at: view.selectedRange().location)
            let caretX = view.textContainerOrigin.x + layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX + layout.location(forGlyphAt: glyph).x
            let indicator = view.subviews.first { $0 is NSTextInsertionIndicator }
            precondition(indicator.map { abs($0.frame.midX - caretX) < 4 } ?? false,
                         "At \(width) points the caret is drawn at x=\(indicator?.frame.midX ?? -1) for text at x=\(caretX)")
            let ink = leftmostInk(in: view, excluding: indicator?.frame)
            precondition(abs(ink - view.textContainerOrigin.x) < 12, "At \(width) points text is drawn from x=\(ink) but clicks map from x=\(view.textContainerOrigin.x)")
        }
        print("PASS: Native reflow draws the text and caret where clicks land")

        window.close()

        // Width tracking remains AppKit's responsibility, including host collapse.
        let sized = MarkdownRichTextView(usingTextLayoutManager: false)
        sized.textContainerInset = NSSize(width: 60, height: 12)
        sized.textContainer!.widthTracksTextView = true
        for width in [900.0, 0, 1600, 500, 0, 1100, 2400] {
            sized.setFrameSize(NSSize(width: width, height: 38))
            if width > 120 {
                precondition(sized.textContainer!.size.width == width - 120,
                             "AppKit must wrap within the view's native insets")
                precondition(sized.textContainerOrigin.x == 60, "Margins remain native at every width")
            }
        }
        print("PASS: AppKit width tracking preserves native margins through host collapses and resizes")
    }
}
