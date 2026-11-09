//
//  BibView.swift
//  WriterTex
//
//  Created by Vedant A. Desai on 11/3/26.
//

import SwiftUI
import AppKit
import Foundation

struct BibliographyCanvas: View {
    @ObservedObject var library: BibLibrary
    let onOpenFile: (URL) -> Void
    let onChooseFile: () -> Void
    let onCreateFile: () -> Void
    @State private var browser = BibliographyBrowserModel()

    /// Tracked by id, not index: a header sort moves rows under an index.
    @State private var focusedRowID: String?
    /// Non-nil while the edit sheet is up; `.sheet(item:)` keys it to the entry.
    @State private var editingRow: BibliographyBrowserModel.Row?

    var body: some View {
        BibliographyTable(rows: browser.rows) { browser.sort(by: $0, ascending: $1)
        } onSelect: { selectedRow in
            editingRow = selectedRow // Opens sheet exclusively on double-click
        }
        onContext: { contextRow in
            focusedRowID = contextRow?.id
        }
        .contextMenu {
            if let row = browser.rows.first(where: { $0.id == focusedRowID }) {
                Button("Edit Citation") {
                    editingRow = row
                }
                Divider()
                Button("Delete Citation", role: .destructive) {
                    print("Deleting \(row)")
                }
            }
        }
        .onReceive(library.$document) { browser.load($0) }
        .sheet(item: $editingRow) { row in
            if let entry = library.entries.first(where: { $0.id == row.id }) {
                ReferenceDetailSheet(entry: entry, library: library)
            }
        }
    }
}

/// Edits one entry's raw BibTeX fields. The values are the LaTeX as written,
/// not `Citation`'s decoded display strings, so saving rewrites only what the
/// user changed and every other field survives byte-for-byte.
struct ReferenceDetailSheet: View {
    struct Field: Identifiable {
        let id = UUID()
        let name: String
        var value: String
    }

    let library: BibLibrary
    private let entryID: String
    /// The entry's source when the sheet opened. Saving is refused if the file
    /// no longer holds it, rather than overwriting a change made elsewhere.
    private let original: String
    /// Not editable yet: renaming a key would break every manuscript citing it.
    private let key: String
    /// The parser's known types, plus the entry's own when it is one the parser
    /// doesn't map (a biblatex `@dataset`, say), so opening the sheet never
    /// silently changes it.
    private let types: [String]
    @State private var type: String
    @State private var fields: [Field]

    @Environment(\.dismiss) private var dismiss

    init(entry: BibEntry, library: BibLibrary) {
        self.library = library
        entryID = entry.id
        key = entry.key
        original = library.document?.source(of: entry) ?? ""
        let raw = library.document?.rawEntry(entry)
        let type = (raw?.type ?? entry.entryType).lowercased()
        types = BibTeXParser.entryTypes.contains(type)
            ? BibTeXParser.entryTypes
        : (BibTeXParser.entryTypes + [type]).sorted()
        _type = State(initialValue: type)
        _fields = State(initialValue: (raw?.fieldOrder ?? []).map {
            Field(name: $0, value: raw?.fields[$0] ?? "")
        })
    }

    var body: some View {
        Form {
            Section {
                Picker("Type", selection: $type) {
                    ForEach(types, id: \.self) { Text($0).tag($0) }
                }
            }
            Section("Fields") {
                ForEach($fields) { $field in
                    TextField(field.name, text: $field.value, axis: .vertical)
                        .lineLimit(1...6)
                        .focusEffectDisabled()
                        .foregroundStyle(Self.isBalanced(field.value) ? .primary : Color.red)
                }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    library.replace(id: entryID, original: original,
                                    with: BibDocument.source(type: type, key: key,
                                                             fields: fields.map { ($0.name, $0.value) }))
                    dismiss()
                }
                .disabled(!canSave)
            }
        }
        .frame(minWidth: 480, minHeight: 420)
    }

    private var canSave: Bool {
        fields.allSatisfy { Self.isBalanced($0.value) }
    }

    /// Values are written inside `{…}`; an unbalanced brace would swallow the
    /// rest of the file. `\{` and `\}` are literal and don't count.
    static func isBalanced(_ value: String) -> Bool {
        var depth = 0
        var escaped = false
        for character in value {
            if escaped { escaped = false; continue }
            switch character {
            case "\\": escaped = true
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth < 0 { return false }
            default: break
            }
        }
        return depth == 0
    }
}


/// An `NSTableView` rather than SwiftUI's `Table`: rows are reused label views
/// over precomputed strings, and column resizing, reordering, header sorting
/// and remembered widths are native.
struct BibliographyTable: NSViewRepresentable {
    typealias Column = BibliographyBrowserModel.Column
    typealias Row = BibliographyBrowserModel.Row

    let rows: [Row]
    let onSort: (Column, Bool) -> Void

    let onSelect: (Row?) -> Void

    let onContext: (Row?) -> Void


    func makeCoordinator() -> Coordinator {
        Coordinator(onSort: onSort, onSelect: onSelect, onContext: onContext)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()

        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true

        // 1. Tell AppKit to resize the LAST column or spread space naturally
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.rowSizeStyle = .default
        table.style = .inset

        for column in Column.allCases {
            let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(column.rawValue)))
            tableColumn.title = column.title
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(key: String(column.rawValue), ascending: true)

            // 2. THIS IS THE CRITICAL LINE: Enable auto-resizing on EVERY individual column
            tableColumn.resizingMask = [.autoresizingMask, .userResizingMask]

            table.addTableColumn(tableColumn)
        }
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        // MARK: - THE HARDWARE INPUT FIX
        table.target = context.coordinator

        // 1. Single-clicks track highlight selections safely without triggering closures
        table.action = #selector(Coordinator.handleNativeRowSelection(_:))

        // 2. Double-clicks route straight to your onSelect sheet presentation pipeline
        table.doubleAction = #selector(Coordinator.handleNativeDoubleTap(_:))
        table.autosaveName = "BibliographyTable"
        table.autosaveTableColumns = true


        // 3. Force AppKit to calculate the natural boundaries across all flexible column masks
        table.sizeToFit()

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        return scrollView
    }



    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSort = onSort
        guard let table = scrollView.documentView as? NSTableView else { return }
        table.backgroundColor = NSColor(AppTheme.shared.paneBackground)
        // Array == short-circuits on shared storage, so an update that didn't
        // touch the rows costs nothing here.
        guard coordinator.rows != rows else { return }
        // Keep the selection on the same entries when a sort moves them.
        let selected = Set(table.selectedRowIndexes.map { coordinator.rows[$0].id })
        coordinator.rows = rows
        table.reloadData()
        table.selectRowIndexes(IndexSet(rows.indices.filter { selected.contains(rows[$0].id) }),
                               byExtendingSelection: false)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var rows: [Row] = []
        var onSort: (Column, Bool) -> Void
        let onSelect: (BibliographyBrowserModel.Row?) -> Void
        let onContext: (BibliographyBrowserModel.Row?) -> Void
        private static let cellID = NSUserInterfaceItemIdentifier("BibliographyCell")


        init(onSort: @escaping (BibliographyBrowserModel.Column, Bool) -> Void,
             onSelect: @escaping (BibliographyBrowserModel.Row?) -> Void, onContext: @escaping (
                BibliographyBrowserModel.Row?
             ) -> Void) {
                 self.onSort = onSort
                 self.onSelect = onSelect
                 self.onContext = onContext
                 super.init()
             }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let index = tableColumn.flatMap({ Int($0.identifier.rawValue) }) else { return nil }
            // The table stretches the returned view to the full row height and a
            // bare text field draws its text at the top, so the label sits in a
            // cell view that centers it vertically.
            let cell = tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? NSTableCellView ?? {
                let cell = NSTableCellView()
                cell.identifier = Self.cellID

                let label = NSTextField(labelWithString: "")
                label.usesSingleLineMode = true
                label.font = .systemFont(ofSize: 13)
                label.lineBreakMode = .byTruncatingTail
                label.translatesAutoresizingMaskIntoConstraints = false
                label.focusRingType = .none

                // Hovering a truncated title shows it in full.
                label.allowsExpansionToolTips = true

                cell.addSubview(label)
                cell.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                    label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
                return cell
            }()
            cell.textField?.stringValue = rows[row].cells[index]
            cell.textField?.focusRingType = .none
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table = notification.object as? NSTableView else { return }
            let selectedIndex = table.selectedRow

            if selectedIndex >= 0 && selectedIndex < rows.count {
                // Fires your context selection index mapping cleanly
                onContext(rows[selectedIndex])
            }
        }

        // MARK: - Action Interface Routers

        @objc func handleNativeRowSelection(_ sender: NSTableView) {
            // Keeps cell selection highlights responsive during single-clicks
            let clickedRow = sender.clickedRow
            if clickedRow >= 0 && clickedRow < rows.count {
                onContext(rows[clickedRow])
            }
        }

        @objc func handleNativeDoubleTap(_ sender: NSTableView) {
            let clickedRow = sender.clickedRow
            if clickedRow >= 0 && clickedRow < rows.count {
                // 🚀 EXCLUSIVE DOUBLE-CLICK TRIGGER: Launches your sheet view instantly
                onSelect(rows[clickedRow])
            }
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first,
                  let column = descriptor.key.flatMap(Int.init).flatMap(Column.init) else { return }
            onSort(column, descriptor.ascending)
        }
    }
}
