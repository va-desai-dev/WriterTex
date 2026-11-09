import AppKit
import SwiftUI
@testable import WriterTex

@main
struct BibliographyInspectorChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("A very long bibliography filename that must fit the narrow inspector.bib")
        let source = """
        @article{aVeryLongCitationKeyThatMustNeverExpandTheInspectorWidth,
          title = {A very long paper title about scientific writing and the behavior of compact bibliography inspectors},
          author = {Doe, Jane and Smith, Alex}, year = {2026}, journal = {Journal of Research}}
        @book{second, title = {Another reference}, author = {Jones, Sam}, year = {2025}}
        @book{second, title = {A duplicate key reference}, author = {Smith, Alex}, year = {2024}}
        """
        try source.write(to: url, atomically: true, encoding: .utf8)
        let domain = "BibliographyChecks.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let library = BibLibrary(projectID: UUID(), root: root,
                                 selections: BibSelectionStore(defaults: defaults), inbox: nil)
        library.select(url)
        for _ in 0..<200 {
            if library.entries.count == 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(library.entries.count == 3)
        let browser = BibliographyBrowserModel()
        browser.search = "  jane  "
        precondition(browser.entries(in: library).count == 1)
        browser.search = "Journal of Research"
        precondition(browser.entries(in: library).count == 1)
        browser.search = "no matching paper"
        precondition(browser.entries(in: library).isEmpty)
        precondition(browser.citation(ids: Set(library.entries.map(\.id)), in: library)
                     == "[@aVeryLongCitationKeyThatMustNeverExpandTheInspectorWidth; @second]")
        browser.selection = ["second"]
        browser.pendingRemoval = ["second"]
        browser.reset()
        precondition(browser.search.isEmpty && browser.selection.isEmpty && browser.pendingRemoval.isEmpty)

        browser.load(library.document)
        precondition(browser.rows.map(\.cells)[1] == ["Jones, Sam", "2025", "Another reference", "", "second"],
                     "Table rows carry each entry's display strings")
        browser.sort(by: .year, ascending: true)
        precondition(browser.rows.map(\.id) == ["second#2", "second", "aVeryLongCitationKeyThatMustNeverExpandTheInspectorWidth"],
                     "Rows sort by a column")
        browser.load(library.document)
        precondition(browser.rows.first?.id == "second#2", "A reloaded document keeps the current sort")

        let canvas = NSHostingView(rootView: BibliographyCanvas(library: library, onOpenFile: { _ in },
                                                                onChooseFile: {}, onCreateFile: {}))
        let canvasWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
        canvasWindow.isReleasedWhenClosed = false
        canvasWindow.contentView = canvas
        canvasWindow.orderFront(nil)
        try await Task.sleep(for: .milliseconds(250))
        func tables(in view: NSView) -> [NSTableView] {
            view.subviews.flatMap { ($0 as? NSTableView).map { [$0] } ?? tables(in: $0) }
        }
        let table = tables(in: canvas).first!
        func cell(_ row: Int, _ column: Int) -> String {
            (table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTextField)?.stringValue ?? ""
        }
        precondition(table.numberOfRows == 3 && table.numberOfColumns == 5, "The canvas lists every entry")
        precondition(table.tableColumns.allSatisfy { $0.resizingMask.contains(.userResizingMask) }, "Columns resize")
        table.selectRowIndexes([1], byExtendingSelection: false)
        let selectedKey = cell(1, 4)
        table.sortDescriptors = [NSSortDescriptor(key: "1", ascending: false)]
        try await Task.sleep(for: .milliseconds(100))
        precondition(cell(0, 1) == "2026" && cell(2, 1) == "2024", "Header sort reorders the table")
        precondition(table.selectedRowIndexes.count == 1 && cell(table.selectedRow, 4) == selectedKey,
                     "Selection follows its entry through a sort")
        canvasWindow.close()

        for width in [260.0, 300.0] {
            // Rendered in dark mode, the harder case for contrast.
            let view = BibliographyInspector(library: library, onChooseFile: {}, onCreateFile: {})
                .environment(\.colorScheme, .dark)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 650),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(250))
            host.layoutSubtreeIfNeeded()
            precondition(host.frame.width == width, "Inspector stays within its allocated width")
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let output = URL(fileURLWithPath: "/tmp/centcom-bibliography-\(Int(width))-dark.png")
                try bitmap.representation(using: .png, properties: [:])!.write(to: output)
            }
            window.close()
        }
        print("Bibliography checks passed: search, citation ordering and duplicate keys, state reset, and 260/300-point layouts in the app’s dark scheme.")
    }
}
