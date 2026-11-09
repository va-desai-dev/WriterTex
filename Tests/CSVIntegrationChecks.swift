import AppKit
import SwiftUI
@testable import WriterTex

@main
struct CSVIntegrationChecks {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        AppDefaults.register()
        let original = CSVTable(columns: ["Name", "Notes"], rows: [
            ["quoted \"name\"", "comma, newline\nnext"], ["", "line\r\nbreak"], ["", ""]
        ])
        let roundTrip = CSVEngine.parse(CSVEngine.generate(from: original))
        check(roundTrip.columns == original.columns && roundTrip.rows == original.rows,
              "CSV serialization preserves quotes, delimiters, newlines and empty cells")
        check(CSVEngine.parse("A\n\"\"").rows == [[""]], "Quoted empty final records survive parsing")

        let session = EditorSession()
        var published: CSVTable?
        let host = NSHostingView(rootView: CSVPreviewView(
            table: CSVTable(columns: ["Name", "Value"], rows: [["old", "1"], ["next", "2"]]),
            session: session
        ) { published = $0 }.frame(width: 800, height: 400))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        for _ in 0..<20 {
            host.layoutSubtreeIfNeeded()
            if session.csvGrid != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let grid = session.csvGrid else { fatalError("Grid did not mount") }
        doubleClick(grid, window: window, row: 0, col: 0)
        try await Task.sleep(for: .milliseconds(50))
        guard let editor = window.firstResponder as? NSTextView else { fatalError("Double click lost the cell editor") }
        editor.insertText("edited \"name\"", replacementRange: editor.selectedRange())
        check(session.hasPendingCSVEdit && published == nil, "Typing marks a pending edit before the cell is committed")
        _ = grid.control(NSControl(), textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        check(published?.rows[0][0] == "edited \"name\"" && !session.hasPendingCSVEdit,
              "Return commits the field editor and publishes its latest text")
        published = nil
        doubleClick(grid, window: window, row: 0, col: 0)
        let cancelEditor = window.firstResponder as! NSTextView
        cancelEditor.insertText("discard", replacementRange: cancelEditor.selectedRange())
        _ = grid.control(NSControl(), textView: cancelEditor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        check(!session.hasPendingCSVEdit && published == nil,
              "Escape discards the draft without publishing it")
        doubleClick(grid, window: window, row: 0, col: 0)
        let tabEditor = window.firstResponder as! NSTextView
        tabEditor.insertText("tabbed", replacementRange: tabEditor.selectedRange())
        _ = grid.control(NSControl(), textView: tabEditor, doCommandBy: #selector(NSResponder.insertTab(_:)))
        check(window.firstResponder is NSTextView, "Tab commits and opens the next cell")
        check(published?.rows[0][0] == "tabbed", "Tab publishes the edited table to the model")
        grid.cancelEditing()
        doubleClick(grid, window: window, row: 0, col: 0)
        let pending = window.firstResponder as! NSTextView
        pending.insertText("analysis edit", replacementRange: pending.selectedRange())
        let live = try session.csvAnalysisSnapshot()
        check(live.table.rows[0][0] == "analysis edit" && !session.hasPendingCSVEdit,
              "Analysis snapshot commits the active cell before reading data")

        let analysisSession = EditorSession()
        let container = CSVTableContainerView()
        container.session = analysisSession
        container.storage = CSVStorage(CSVTable(columns: ["value", "value"], rows: [
            ["1", "10"], ["", "20"], ["bad", "30"], ["Inf"], ["5", "50"]
        ]))
        container.columnTypes[0] = .numeric
        container.setUp()
        container.setRules(column: 0, direction: nil,
                           filter: CSVArrangement.Filter(condition: .doesNotContain, value: "bad"))
        let all = try analysisSession.csvAnalysisSnapshot()
        let visible = try analysisSession.csvAnalysisSnapshot(scope: .visibleRows)
        check(all.sourceRows == [0, 1, 2, 3, 4] && visible.sourceRows == [0, 1, 3, 4],
              "All-row snapshots preserve file order; filtered snapshots preserve record identity")
        let numeric = try visible.numericColumn(at: 0)
        check(numeric.values == [1, nil, nil, 5] && numeric.missingRows == [1] && numeric.invalidRows == [3],
              "Numeric inputs retain row alignment and distinguish blanks from non-finite values")
        let second = try visible.numericColumn(at: 1)
        check(second.values == [10, 20, nil, 50] && second.missingRows == [3],
              "Duplicate headers use column indices and short rows become missing values")
        check(visible.columnTypes[0] == .numeric, "Column type hints reach analysis snapshots")
        container.storage.rows[0][0] = "999"
        check(visible.table.rows[0][0] == "1", "Later edits do not mutate an analysis snapshot")
        container.setRules(column: 1, direction: .descending, filter: CSVArrangement.Filter())
        let sorted = try analysisSession.csvAnalysisSnapshot(scope: .visibleRows)
        check(sorted.sourceRows == [4, 1, 0, 3], "Analysis follows sorted display order without losing original row indices")
        let exported = CSVEngine.parse(visible.csvText)
        check(exported.rows == visible.table.rows, "Analysis CSV serializes exactly the captured rows")
        do {
            _ = try visible.numericColumn(at: 99)
            preconditionFailure("Invalid column should fail")
        } catch CSVAnalysisError.invalidColumn { }
        container.endPreview()
        do {
            _ = try analysisSession.csvAnalysisSnapshot()
            preconditionFailure("Closed CSV should not remain available for analysis")
        } catch CSVAnalysisError.noTable { }
        print("All CSV integration checks passed")
    }

    @MainActor static func doubleClick(_ grid: CSVGridBodyView, window: NSWindow, row: Int, col: Int) {
        let point = grid.convert(NSPoint(x: CGFloat(col) * 150 + 20, y: CGFloat(row) * 22 + 11), to: nil)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                      clickCount: 2, pressure: 1)!
        grid.mouseDown(with: event)
    }

    static func check(_ value: Bool, _ description: String) {
        precondition(value, description)
        print("PASS: \(description)")
    }
}
