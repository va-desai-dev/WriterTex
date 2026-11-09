import AppKit
import SwiftUI
@testable import WriterTex

@main struct ManuscriptTableChecks {
    @MainActor final class RejectEdits: NSObject, NSTextViewDelegate {
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool { false }
    }

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
        func check(_ passed: Bool, _ label: String) {
            print("\(passed ? "PASS" : "FAIL"): \(label)")
            if !passed { failures += 1 }
        }
        let model = FileBrowserModel(), session = EditorSession()
        let window = NSWindow(contentRect: NSRect(x: 70, y: 70, width: 850, height: 550),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: FileViewer(model: model, session: session))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        let view = session.findTextView as! MarkdownRichTextView
        let storage = view.textStorage!, layout = view.layoutManager!, container = view.textContainer!
        window.makeFirstResponder(view)
        let body = view.document.style.bodyAttributes
        let before = NSAttributedString(string: "Before the table\n", attributes: body)
        let empty = NSAttributedString()
        func reset(_ following: NSAttributedString = NSAttributedString(), rows: Int = 2) {
            let headers = ["Name", "Value", "Detail"].map { NSAttributedString(string: $0, attributes: body) }
            let cells = [headers] + Array(repeating: Array(repeating: empty, count: 3), count: rows - 1)
            let table = view.document.table(cells, alignments: [.left, .center, .right])
            let text = NSMutableAttributedString(attributedString: before)
            text.append(table.text)
            text.append(following)
            view.setSelectedRange(NSRange(location: 0, length: 0))
            storage.setAttributedString(text)
            view.setSelectedRange(NSRange(location: before.length + table.starts[rows - 1][1], length: 0))
            view.typingAttributes = storage.attributes(at: view.selectedRange().location, effectiveRange: nil)
            view.undoManager?.removeAllActions()
        }
        func tableBottom() -> CGFloat {
            layout.ensureLayout(for: container)
            let grid = view.document.tableGrid(at: before.length, in: storage)!
            let index = NSMaxRange(grid.range) - 1
            let cell = (storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as! NSParagraphStyle).textBlocks.last!
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
            return layout.boundsRect(for: cell, glyphRange: glyphs).maxY
        }

        let followingBody = NSAttributedString(string: "Following body\n", attributes: body)
        let followingHeading = view.document.applyingHeading(2, to: NSAttributedString(string: "Following heading\n", attributes: body))
        for (name, following) in [("EOF", empty), ("empty trailer", NSAttributedString(string: "\n", attributes: body)),
                                  ("body below", followingBody), ("heading below", followingHeading)] {
            reset(following)
            let original = NSAttributedString(attributedString: storage)
            let originalGrid = view.document.tableGrid(at: before.length, in: storage)!
            let tableEnd = NSMaxRange(originalGrid.range)
            let originalCells = storage.attributedSubstring(from: originalGrid.range)
            view.insertNewline(nil)
            let added = view.document.tableGrid(at: view.selectedRange().location, in: storage)!
            check(added.cells.count == 3 && added.row == 2 && added.column == 1,
                  "\(name): Return in the empty bottom row adds one row in the same column")
            check(storage.attributedSubstring(from: originalGrid.range).isEqual(to: originalCells)
                  && (view.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.alignment == .center,
                  "\(name): appending preserves existing cells and column alignment")
            view.insertNewline(nil)
            check(storage.firstTable?.rows == 2 && !view.selectionInTable && view.selectedRange().location == tableEnd,
                  "\(name): second Return removes only the added row and exits to body")
            check(storage.attributedSubstring(from: originalGrid.range).isEqual(to: originalCells),
                  "\(name): exiting preserves the original table exactly")
            if following.length > 0 {
                check(storage.attributedSubstring(from: NSRange(location: storage.length - following.length, length: following.length)).isEqual(to: following),
                      "\(name): following content and its style remain intact")
            }
            if name == "empty trailer" { check(storage.string == original.string, "Existing empty body trailer is reused") }
            let bottom = tableBottom()
            view.insertText("Outside", replacementRange: view.selectedRange())
            for _ in 0..<3 { view.insertNewline(nil) }
            check(!view.selectionInTable && storage.firstTable?.rows == 2 && abs(tableBottom() - bottom) < 0.01,
                  "\(name): typing and Return outside never stretch the table")
            let outside = (view.string as NSString).range(of: "Outside")
            check((storage.attribute(.paragraphStyle, at: outside.location, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.isEmpty == true,
                  "\(name): body text has no inherited table block")
            let reopened = try ManuscriptDocument.decode(ManuscriptDocument.encode(storage), using: view.document)
            check(reopened.string == storage.string && reopened.firstTable?.rows == 2,
                  "\(name): table and body paragraph survive saving and reopening")
            let word = String(decoding: ManuscriptDOCX.render(reopened, baseURL: nil, title: "Tables", settings: ManuscriptExportSettings(), citations: nil).data, as: UTF8.self)
            check(word.components(separatedBy: "<w:tr>").count - 1 == 2
                  && word.range(of: "</w:tbl>")!.upperBound < word.range(of: "Outside")!.lowerBound,
                  "\(name): Word contains two rows followed by body text outside the table")
        }

        for (name, following) in [("EOF", empty), ("empty trailer", NSAttributedString(string: "\n", attributes: body)),
                                  ("body below", followingBody), ("heading below", followingHeading)] {
            reset(following)
            let end = NSMaxRange(view.document.tableGrid(at: before.length, in: storage)!.range)
            view.setSelectedRange(NSRange(location: end, length: 0))
            let original = NSAttributedString(attributedString: storage)
            let expected = NSMutableAttributedString(attributedString: before)
            expected.append(following)
            let originalDelegate = view.delegate
            let rejected = RejectEdits()
            view.delegate = rejected
            view.deleteBackward(nil)
            check(storage.isEqual(to: original) && view.selectedRange() == NSRange(location: end, length: 0),
                  "\(name): rejected table deletion preserves content and caret")
            view.delegate = originalDelegate
            view.undoManager?.removeAllActions()
            view.deleteBackward(nil)
            check(storage.isEqual(to: expected) && storage.firstTable == nil && view.selectedRange().location == before.length,
                  "\(name): Backspace after the table deletes the whole table and preserves surrounding paragraphs")
            check(!view.selectionInTable
                  && (view.typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.headerLevel == (name == "heading below" ? 2 : 0),
                  "\(name): typing keeps the following paragraph's style instead of a cell style")
            view.undoManager?.undo()
            check(storage.isEqual(to: original), "\(name): one Undo restores the complete table and formatting")
            view.undoManager?.redo()
            check(storage.isEqual(to: expected), "\(name): Redo deletes the complete table again")
            let reopened = try ManuscriptDocument.decode(ManuscriptDocument.encode(storage), using: view.document)
            check(reopened.string == expected.string && reopened.firstTable == nil,
                  "\(name): no table cells remain after saving and reopening")
        }
        reset(NSAttributedString(string: "\n", attributes: body))
        let firstTable = NSAttributedString(attributedString: storage)
        let secondTable = view.document.table([[NSAttributedString(string: "Second table", attributes: body)]], alignments: [.left]).text
        storage.append(secondTable)
        let secondEnd = storage.length
        storage.append(NSAttributedString(string: "\n", attributes: body))
        view.setSelectedRange(NSRange(location: secondEnd, length: 0))
        view.deleteBackward(nil)
        check(storage.string == firstTable.string + "\n"
              && storage.attributedSubstring(from: NSRange(location: 0, length: firstTable.length)).isEqual(to: firstTable),
              "Backspace deletes only the adjacent table, leaving an earlier table intact")

        reset(followingBody)
        let untouched = NSAttributedString(attributedString: storage)
        let cellCaret = view.selectedRange()
        view.deleteBackward(nil)
        check(storage.isEqual(to: untouched) && view.selectedRange() == cellCaret,
              "Backspace between cells still protects the table")
        view.insertText("AB", replacementRange: view.selectedRange())
        view.deleteBackward(nil)
        check(view.document.tableGrid(at: view.selectedRange().location, in: storage)?.cells[1][1].string == "A",
              "Backspace inside cell text still deletes one character")
        let end = NSMaxRange(view.document.tableGrid(at: before.length, in: storage)!.range)
        view.setSelectedRange(NSRange(location: end, length: "Following".utf16.count))
        view.deleteBackward(nil)
        check(storage.firstTable?.rows == 2 && view.string.hasSuffix(" body\n"),
              "Deleting selected body text after a table leaves the table intact")
        reset(NSAttributedString(string: "\n", attributes: body))
        let tableEnd = NSMaxRange(view.document.tableGrid(at: before.length, in: storage)!.range)
        view.setSelectedRange(NSRange(location: tableEnd - 1, length: 0))
        let beforeForwardDelete = NSAttributedString(attributedString: storage)
        view.deleteForward(nil)
        check(storage.isEqual(to: beforeForwardDelete), "Forward Delete in the last cell cannot merge the body trailer into the table")

        reset()
        let beforeReturn = NSAttributedString(attributedString: storage)
        view.insertNewline(nil)
        let afterReturn = NSAttributedString(attributedString: storage)
        view.undoManager?.undo()
        check(storage.isEqual(to: beforeReturn), "Undo removes the added row and restores the exact document")
        view.undoManager?.redo()
        check(storage.isEqual(to: afterReturn), "Redo restores the added row and body trailer")
        reset()
        view.insertNewline(nil)
        let beforeExit = NSAttributedString(attributedString: storage)
        view.undoManager?.removeAllActions()
        view.insertNewline(nil)
        let afterExit = NSAttributedString(attributedString: storage)
        view.undoManager?.undo()
        check(storage.isEqual(to: beforeExit), "Undo exit restores the empty row")
        view.undoManager?.redo()
        check(storage.isEqual(to: afterExit), "Redo exit restores the separate body paragraph")

        reset()
        let delegate = view.delegate
        let rejection = RejectEdits()
        let rejectedText = NSAttributedString(attributedString: storage), rejectedCaret = view.selectedRange()
        view.delegate = rejection
        view.insertNewline(nil)
        view.insertNewline(nil)
        check(storage.isEqual(to: rejectedText) && view.selectedRange() == rejectedCaret && view.selectionInTable,
              "Rejected row insertion never removes an original row or changes the caret")
        view.delegate = delegate
        view.insertNewline(nil)
        let rejectedExitText = NSAttributedString(attributedString: storage), rejectedExitCaret = view.selectedRange()
        view.delegate = rejection
        view.insertNewline(nil)
        check(storage.isEqual(to: rejectedExitText) && view.selectedRange() == rejectedExitCaret && view.selectionInTable,
              "Rejected exit preserves the new row, caret and cell typing style")
        view.delegate = delegate

        reset()
        let rtf = storage.rtf(from: NSRange(location: 0, length: storage.length), documentAttributes: [:])!
        let imported = view.document.importing(try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil))
        view.setSelectedRange(NSRange(location: 0, length: 0))
        storage.setAttributedString(imported)
        let importedGrid = view.document.tableGrid(at: before.length, in: storage)!
        view.setSelectedRange(NSRange(location: NSMaxRange(importedGrid.range) - 2, length: 0))
        view.typingAttributes = storage.attributes(at: view.selectedRange().location, effectiveRange: nil)
        let importedCaret = view.selectedRange()
        view.delegate = rejection
        view.insertNewline(nil)
        check(storage.isEqual(to: imported) && view.selectedRange() == importedCaret,
              "Rejected edits to an external RTF table leave its content and caret intact")
        view.delegate = delegate
        view.insertNewline(nil)
        check(storage.firstTable?.rows == 3 && view.selectionInTable, "Return also appends to an external RTF table")
        view.insertNewline(nil)
        check(storage.firstTable?.rows == 2 && !view.selectionInTable, "Double Return exits an external RTF table")

        reset()
        view.insertText("Cell value", replacementRange: view.selectedRange())
        view.insertNewline(nil)
        let filled = view.document.tableGrid(at: view.selectedRange().location, in: storage)!
        check(filled.cells.count == 3 && filled.cells[1][1].string == "Cell value" && filled.cells[2][1].length == 0,
              "Return after cell text adds a row without inserting a line break inside the cell")

        reset()
        view.insertNewline(nil)
        view.insertText("x", replacementRange: view.selectedRange())
        view.deleteBackward(nil)
        view.insertNewline(nil)
        check(storage.firstTable?.rows == 4 && view.selectionInTable,
              "Typing cancels double-Return exit even if that text is deleted again")
        reset()
        view.insertNewline(nil)
        let newCell = view.selectedRange()
        view.setSelectedRange(NSRange(location: before.length, length: 0))
        view.setSelectedRange(newCell)
        view.insertNewline(nil)
        check(storage.firstTable?.rows == 4 && view.selectionInTable,
              "Moving away and back cancels double-Return exit")
        reset()
        view.insertNewline(nil)
        view.insertTab(nil)
        view.insertNewline(nil)
        check(storage.firstTable?.rows == 4 && view.selectionInTable, "Tab cancels double-Return exit")

        reset()
        view.setSelectedRange(NSRange(location: before.length, length: 0))
        let beforeMove = NSAttributedString(attributedString: storage)
        view.insertNewline(nil)
        let moved = view.document.tableGrid(at: view.selectedRange().location, in: storage)!
        check(moved.row == 1 && moved.column == 0 && storage.isEqual(to: beforeMove),
              "Return above the bottom navigates down without editing cell text")
        reset(rows: 200)
        view.insertNewline(nil)
        check(storage.firstTable?.rows == 201 && view.visibleRect.intersects(
            layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: view.selectedRange(), actualCharacterRange: nil), in: container)
                .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)),
              "Appending to a long table reveals the new row")
        view.insertNewline(nil)
        check(storage.firstTable?.rows == 200 && !view.selectionInTable, "Double Return exits a long table")
        precondition(failures == 0, "\(failures) table checks failed")
    }
}
