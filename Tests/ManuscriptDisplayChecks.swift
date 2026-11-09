import AppKit
import SwiftUI
@testable import WriterTex

@main struct ManuscriptDisplayChecks {
    final class FixtureWindow: NSWindow {
        override var isKeyWindow: Bool { true }
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

    /// Read the current backing layer, without asking NSTextView to redraw it.
    @MainActor static func selectionPixels(in view: NSTextView) -> Int {
        let scale = view.window!.backingScaleFactor
        let width = Int(ceil(view.bounds.width * scale)), height = Int(ceil(view.bounds.height * scale))
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.scaleBy(x: scale, y: scale)
        view.layer!.render(in: context)
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        return stride(from: 0, to: width * height * 4, by: 4).reduce(0) { count, offset in
            count + (bytes[offset] > 170 && bytes[offset + 1] < 80 && bytes[offset + 2] > 170 ? 1 : 0)
        }
    }

    @MainActor static func backingPixels(_ view: NSView) -> (Data, CGImage) {
        let scale = view.window!.backingScaleFactor
        let width = Int(ceil(view.bounds.width * scale)), height = Int(ceil(view.bounds.height * scale))
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.scaleBy(x: scale, y: scale)
        view.layer!.render(in: context)
        return (Data(bytes: context.data!, count: width * height * 4), context.makeImage()!)
    }

    @MainActor static func run() async {
        let paragraph = "A manuscript should scroll smoothly while the author reads and revises each paragraph. Native text layout wraps these lines and positions every glyph on the page."
        let prose = (0..<4).map { "Paragraph \($0 + 1). \(paragraph)" }.joined(separator: "\n\n")
        // Native WriterTex data, with body-styled paragraph terminators as found
        // in documents copied between projects. No Markdown import is involved.
        let model = FileBrowserModel(), session = EditorSession()
        let window = FixtureWindow(contentRect: NSRect(x: 50, y: 50, width: 850, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let document = MarkdownRichText(baseURL: nil, style: MarkdownStyleSheet(theme: .screen, manuscript: .screen))
        let native = NSMutableAttributedString()
        for (level, text) in [(1, "Research Notes"), (2, "Video Reaction"), (3, "Working Questions"), (0, "A short body paragraph.")] {
            native.append(document.applyingHeading(level, to: NSAttributedString(string: text, attributes: document.style.bodyAttributes)))
            native.append(NSAttributedString(string: "\n", attributes: document.style.bodyAttributes))
        }
        let data = try! ManuscriptDocument.encode(native)
        let host = NSHostingView(rootView: RichMarkdownEditor(richData: data, model: model,
            editorIsFocused: .constant(false), session: session).background(Color.black))
        window.contentView = host
        window.orderFront(nil)
        try? await Task.sleep(for: .milliseconds(150))
        let view = session.findTextView as! MarkdownRichTextView
        window.makeFirstResponder(view)
        // Exercise focused editing while excluding caret blink from pixel comparisons.
        view.insertionPointColor = .clear
        for width in [850.0, 600, 1600] {
            window.setContentSize(NSSize(width: width, height: 600))
            try? await Task.sleep(for: .milliseconds(100))
            let heading = (view.string as NSString).range(of: "Video Reaction")
            view.setSelectedRange(NSRange(location: NSMaxRange(heading), length: 0))
            for step in 0..<4 {
                if step.isMultiple(of: 2) { view.insertNewline(nil) }
                else { view.deleteBackward(nil) }
                try? await Task.sleep(for: .milliseconds(100))
                let before = backingPixels(view)
                view.needsDisplay = true
                view.displayIfNeeded()
                let after = backingPixels(view)
                let changed = zip(before.0, after.0).filter { $0 != $1 }.count
                print("REPAINT width=\(width) edit=\(step): \(changed) differing bytes")
                if changed > 64 {
                    for (name, snapshot) in [("incremental", before), ("redrawn", after)] {
                        let bitmap = NSBitmapImageRep(cgImage: snapshot.1)
                        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/writertex-middle-\(name).png"))
                    }
                }
                precondition(changed <= 64, "Middle edits must paint identically to a fresh redraw, without clipped or overlapping text")
            }
        }
        window.close()
        print("PASS: Middle paragraph edits repaint correctly across narrow and wide window sizes")

        for source in [prose, "| One | Two |\n| --- | --- |\n| Cell | Cell |\n\n\(paragraph)\n\n## A heading that wraps across several lines in a narrow editor\n\n\(paragraph)"] {
            let model = FileBrowserModel(), session = EditorSession()
            let window = FixtureWindow(contentRect: NSRect(x: 50, y: 50, width: 800, height: 500),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: RichMarkdownEditor(richData: manuscriptData(source), model: model,
                editorIsFocused: .constant(true), session: session)
                .padding(.top, 0.25)
                .background(LinearGradient(colors: [.black, .gray], startPoint: .bottomLeading, endPoint: .topTrailing)))
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(200))
            let view = session.findTextView as! MarkdownRichTextView
            precondition(view.wantsLayer && view.layer != nil && !view.drawsBackground,
                         "Native text rendering must own its backing surface while retaining transparency")
            window.makeFirstResponder(view)
            view.selectedTextAttributes = [.backgroundColor: NSColor.magenta, .foregroundColor: NSColor.white]
            let original = NSAttributedString(attributedString: view.textStorage!)
            for width in [800.0, 575.25] {
                window.setContentSize(NSSize(width: width, height: 500))
                host.layoutSubtreeIfNeeded()
                // A drag repeatedly shrinks and grows an existing highlight;
                // selection-to-caret alone does not exercise those dirty regions.
                view.insertionPointColor = .clear
                for length in [200, 80, 250, 120, 30, 0] {
                    view.setSelectedRange(NSRange(location: 10, length: min(length, original.length - 10)),
                                          affinity: .downstream, stillSelecting: true)
                    try? await Task.sleep(for: .milliseconds(60))
                    let incremental = backingPixels(view).0
                    view.needsDisplay = true
                    view.displayIfNeeded()
                    let redrawn = backingPixels(view).0
                    let changed = zip(incremental, redrawn).filter { $0 != $1 }.count
                    precondition(changed <= 64,
                                 "Changing a selection must match a fresh redraw: \(changed) differing bytes")
                }
                view.setSelectedRange(NSRange(location: 10, length: 0), affinity: .downstream, stillSelecting: false)
                for index in 0..<5 {
                    view.setSelectedRange(NSRange(location: index + 10, length: min(200, view.textStorage!.length - index - 10)))
                    try? await Task.sleep(for: .milliseconds(60))
                    let selected = selectionPixels(in: view)
                    precondition(selected > 100, "Backing-layer capture must contain the selected highlight: \(selected)")
                    view.setSelectedRange(NSRange(location: 10, length: 0))
                    try? await Task.sleep(for: .milliseconds(60))
                    let cleared = selectionPixels(in: view)
                    precondition(cleared == 0, "Clearing selection left \(cleared) highlight pixels in the native backing layer")
                }
            }
            precondition(view.textStorage!.isEqual(to: original) && view.undoManager?.canUndo != true,
                         "Display changes must preserve content, paragraph styles and Undo")
            print("PASS: Native selection clears without residual pixels at both widths, including fractional positioning")
            window.close()
        }

    }
}
