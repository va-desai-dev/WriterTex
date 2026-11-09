import AppKit
import SwiftUI
@testable import WriterTex

/// The workspace window's split view, clicked with real mouse events at widths
/// up to full screen. With /tmp/writertex-fullscreen present it also goes into
/// full screen, which takes over the screen for a few seconds.
@Observable final class Columns {
    var sidebar = true
    var inspector = true
}

struct FullScreenCanvas: View {
    @Bindable var columns: Columns
    let model: FileBrowserModel
    let session: EditorSession
    let data: Data

    var body: some View {
        CanvasSplitView(showsSidebar: $columns.sidebar, showsInspector: $columns.inspector) {
            Color.gray.opacity(0.2)
        } content: {
            RichMarkdownEditor(richData: data, model: model, editorIsFocused: .constant(true), session: session,
                               fileURL: URL(fileURLWithPath: "/tmp/FullScreen.wrtx"))
        } inspector: {
            Color.gray.opacity(0.2)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) { Button("Sidebar") { columns.sidebar.toggle() } }
            ToolbarItem { Button("Inspector") { columns.inspector.toggle() } }
        }
        .toolbar(removing: .title)
    }
}

/// Key whichever app is frontmost, so the checks don't depend on what the user is doing.
final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@main struct ManuscriptClickChecks {
    @MainActor static func main() {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.regular)
        AppDefaults.register()
        Task { @MainActor in await run(); exit(0) }
        NSApp.run()
    }

    /// Clicks the middle of the character at `index` and reports where the
    /// selection and the drawn caret land.
    @MainActor static func click(_ view: NSTextView, at index: Int) -> (selection: Int, caretX: CGFloat, glyphX: CGFloat, point: NSPoint) {
        let layout = view.layoutManager!, glyph = layout.glyphIndexForCharacter(at: index)
        var rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: view.textContainer!)
        rect = rect.offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        let local = NSPoint(x: rect.minX + 1, y: rect.midY)
        let point = view.convert(local, to: nil)
        let window = view.window!
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        NSApp.postEvent(event(.leftMouseUp), atStart: false)
        // Deliver to the text view so an unrelated frontmost app cannot consume
        // the synthetic down event as window activation instead of text input.
        view.mouseDown(with: event(.leftMouseDown))
        view.displayIfNeeded()
        let indicator = view.subviews.first { $0 is NSTextInsertionIndicator }
        return (view.selectedRange().location, indicator?.frame.midX ?? -1, local.x, point)
    }

    @MainActor static func run() async {
        let paragraph = "Research on adolescence also suggests that chronotype development is associated with executive function, emotional control, and flexibility [@diss34; @diss105]. Moreover, recent studies also report a bidirectional correlation."
        let source = (0..<40).map { $0 % 8 == 0 ? "## Section \($0)\n\n\(paragraph)" : paragraph }.joined(separator: "\n\n")
        let document = MarkdownRichText(baseURL: nil, style: MarkdownStyleSheet(theme: .screen, manuscript: .screen))
        let data = try! ManuscriptDocument.encode(document.load(source))

        let model = FileBrowserModel(), session = EditorSession(), columns = Columns()
        let controller = NSHostingController(rootView: FullScreenCanvas(columns: columns, model: model, session: session, data: data))
        controller.sceneBridgingOptions = [.toolbars]
        let window = KeyWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.collectionBehavior = [.fullScreenPrimary]
        window.setContentSize(NSSize(width: 1100, height: 720))
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        try? await Task.sleep(for: .milliseconds(500))
        let view = session.findTextView as! MarkdownRichTextView
        window.makeFirstResponder(view)

        func probe(_ label: String) async {
            try? await Task.sleep(for: .milliseconds(1200))
            var misses = 0
            for index in [40, 400, 900, 1500] {
                try? await Task.sleep(for: .milliseconds(600))
                let result = click(view, at: index)
                let missed = abs(result.selection - index) > 1 || abs(result.caretX - result.glyphX) > 4
                if missed { misses += 1; print("    click on character \(index) at \(result.point) selected \(result.selection), caret x \(result.caretX) for x \(result.glyphX)") }
            }
            print("  \(label): \(4 - misses) of 4 clicks landed")
            precondition(misses == 0, "\(label): \(misses) of 4 clicks missed")
        }

        columns.sidebar = false; columns.inspector = false
        for width in [1360.0, 1700, 1828, 600] {
            window.setContentSize(NSSize(width: width, height: 720))
            await probe("\(Int(view.frame.width)) points, both columns hidden")
        }
        precondition(view.textContainerOrigin.x == 60, "Native margins stay fixed in wide windows")
        print("PASS: Clicks land on the intended character in wide and narrow editors")
        if FileManager.default.fileExists(atPath: "/tmp/writertex-fullscreen") {
            columns.sidebar = true; columns.inspector = true
            await probe("windowed, both columns")
            window.toggleFullScreen(nil)
            try? await Task.sleep(for: .milliseconds(1500))
            columns.sidebar = false
            columns.inspector = false
            await probe("full screen, both hidden")
            print("PASS: Clicks land on the character they point at in full screen with both columns hidden")
        }
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            try? await Task.sleep(for: .milliseconds(1500))
        }
        window.close()
    }
}
