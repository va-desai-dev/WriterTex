//
//  NoteBookWorkspaceView.swift
//  WriterTex
//
//  Created by Vedant A. Desai on 11/4/26.
//

import SwiftUI

//MARK: NOTEBOOKCANVAS
/// A notebook window. Its model is made once, when the window first appears,
/// so results survive the view being rebuilt.
struct NotebookWindow: View {
    let file: NotebookFile
    let fileURL: URL?
    @State private var model: NotebookModel?

    var body: some View {
        // One container, so it appears and disappears once with the window.
        // The placeholder is there to appear: an empty view never does, so
        // the model would never be made.
        ZStack {
            if let model { NoteBookWorkspaceView(model: model, fileURL: fileURL) } else { Color.clear }
        }
        .onAppear { if model == nil { model = NotebookModel(file: file) } }
    }
}

/// One `.wrstatx` notebook: its analysis steps, and the datasets packaged with it.
struct NoteBookWorkspaceView: View {
    let model: NotebookModel
    let fileURL: URL?
    @State private var editorSession = EditorSession()
    @State private var selectedDataset: String?
    @State private var showsNotebook = true
    @State private var showsInspector = false
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        CanvasView(showsInspector: $showsInspector) {
            VStack(spacing: 0) {
                Group {
                    if showsNotebook || selectedDataset == nil {
                        NotebookView(model: model, notebookURL: fileURL)
                    } else if let selectedDataset {
                        DatasetPane(model: model, name: selectedDataset, session: editorSession)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                PaneBar(edge: .bottom) {
                    NotebookMissingCodesField(model: model)
                    Spacer()
                    if selectedDataset != nil {
                        Text(editorSession.selectedCell)
                    }
                }
            }
        } sidebar: {
            NotebookSidebar(model: model, selection: $selectedDataset, showsNotebook: $showsNotebook)
        } inspector: {
            DatasetInspector(model: model, name: selectedDataset)
        }
        .onChange(of: undoManager.map(ObjectIdentifier.init), initial: true) {
            model.undoManager = undoManager
        }
    }
}

/// One packaged dataset in the grid. Cell edits are written back into the notebook.
private struct DatasetPane: View {
    let model: NotebookModel
    let name: String
    let session: EditorSession
    @State private var table: Result<CSVTable, Error>?

    var body: some View {
        Group {
            switch table {
                case .success(let table):
                    CSVPreviewView(table: table, session: session,
                                   columnTypes: model.columnTypes[name] ?? [:],
                                   inferredTypes: model.inferredTypes[name] ?? [:],
                                   onTypeChange: { model.setColumnType($1, column: $0, in: name) },
                                   rules: model.arrangements[name] ?? CSVArrangement.Rules(),
                                   onRulesChange: { model.setRules(column: $0, direction: $1, filter: $2, in: name) },
                                   onRename: { model.renameColumn($0, to: $1, in: name) }) { model.updateDataset(name, to: $0) }
                case .failure(let error):
                    ContentUnavailableView("Can’t Show This Table", systemImage: "tablecells",
                                           description: Text(error.localizedDescription))
                case nil:
                    ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Undo replaces the bytes under the grid, so it starts over from them.
        .id(DatasetIdentity(name: name, revision: model.datasetRevision))
        .task(id: DatasetIdentity(name: name, revision: model.datasetRevision)) {
            do { table = .success(try await model.table(for: name)) } catch { table = .failure(error) }
        }
        .paneBar(.top) {
            PaneBar {
                Text((name as NSString).deletingPathExtension).font(.headline).lineLimit(1)
                Spacer()
                TableDataMenu(session: session, style: .glassButton)
            }
        }
    }

    private struct DatasetIdentity: Hashable {
        let name: String
        let revision: Int
    }
}

//MARK: CURRENTLY TAKING THIS OUT OF UI. ONLY INSERTION/DELETION OF VARIABLES IS CURRENT GOAL. DELETION AND INSERTAION OF ROWS GOES AGAINST EVEN WHAT SPSS DOES. WE CAN ALWAYS ADD A SPECIAL "CASE SORTING/FILTERING" - OH WAIT WE ALREADY HAVE THAT. SO PERHAPS A FILTER-OUT CASES MAKES A NEW DECOY DATAFRAME CAN WORK BETTER INSTEAD.
// Adds rows and columns at the selected cell, and deletes the selected ones.
/// private struct DatasetEditMenu: View {
///    let model: NotebookModel
///    let name: String
///    let session: EditorSession
///    let table: CSVTable
///    @State private var deletion: DatasetDeletion?
///
///    var body: some View {
///        Menu {
///            Button("Insert Row Above") { if let cell = session.csvSelection() { model.insertRow(at: cell.row ?? table.rows.count, in: name) } }
///            Button("Insert Row Below") { if let cell = session.csvSelection() { model.insertRow(at: cell.row.map { $0 + 1 } ?? table.rows.count, in: name) } }
///           Button("Delete Row…", role: .destructive) { deletion = session.csvSelection()?.row.map(DatasetDeletion.row) }
///                .disabled(table.rows.isEmpty)
///            Divider()
///            Button("Insert New Variable") {
///                if let cell = session.csvSelection() {
///                    model.insertColumn(at: cell.column + 1, in: name)
///                }
///            }
///        } label: {
///            Label("Edit Table", systemImage: "tablecells.badge.ellipsis")
///                .labelStyle(.iconOnly)
///        }
///        .menuStyle(.button)
///        .buttonStyle(.glassButton)
///        .menuIndicator(.hidden)
///        .help("Add or delete rows and columns at the selected cell")
///        .datasetDeletion($deletion, model: model, name: name, table: table)
///    }
/// }
//MARK: -----END MARK----

/// A row or column waiting on the user to confirm its deletion.
private enum DatasetDeletion: Identifiable {
    case row(Int)
    case column(Set<Int>) // <-- Change from Int to Set<Int>

    var id: String {
        switch self {
        case .row(let row): return "row-\(row)"
        case .column(let columns): return "columns-\(columns.hashValue)"
        }
    }
}


private extension View {
    func datasetDeletion(_ deletion: Binding<DatasetDeletion?>, model: NotebookModel, name: String, table: CSVTable) -> some View {
        let title = switch deletion.wrappedValue {
        case .row(let row): "Delete row \(row + 1)?"
        case .column(let columns):
            columns.count == 1
                ? "Delete column \"\(table.columns[columns.first!])\"?"
                : "Delete \(columns.count) selected columns?"
        case nil: ""
        }

        return confirmationDialog(title, isPresented: Binding(get: { deletion.wrappedValue != nil }, set: { if !$0 { deletion.wrappedValue = nil } }), presenting: deletion.wrappedValue) { pending in
            switch pending {
            case .row(let row):
                Button("Delete Row", role: .destructive) { model.deleteRow(row, in: name) }
            case .column(let columns):
                Button(columns.count == 1 ? "Delete Column" : "Delete Columns", role: .destructive) {
                    model.deleteColumns(columns, in: name)
                }
            }
        } message: { pending in
            if case .column = pending {
                Text("Steps that read these columns will report them missing.")
            }
        }
    }
}


/// The selected dataset's shape, with its variables named, added and deleted here.
private struct DatasetInspector: View {
    let model: NotebookModel
    let name: String?
    @State private var table: CSVTable?
    @State private var deletion: DatasetDeletion?
    @State private var selectedColumnIndexes = Set<Int>()


    var body: some View {
        Group {
            if let name, let table {
                List(selection: $selectedColumnIndexes) {
                    Section("Dataframe") {
                        LabeledContent("Dataset", value: name)
                        LabeledContent("Rows", value: table.rows.count.formatted())
                        LabeledContent("Columns", value: table.columns.count.formatted())
                    }
                    .scrollContentBackground(.hidden)
                    Section("Variables") {
                        ForEach(Array(table.columns.enumerated()), id: \.offset) { index, header in
                            VariableRow(model: model, dataset: name, column: index, header: header)
                                .id(header)
                                .tag(index)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false, content: {
                                    // Swiping a selected row deletes the whole selection; any other row, just itself.
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        deletion = .column(selectedColumnIndexes.contains(index) ? selectedColumnIndexes : [index])
                                    }
                                    .labelsHidden()
                                    .buttonBorderShape(.circle)
                                    .font(.system(size: 14))
                                })
                        }
                        .listRowSeparator(.visible, edges: .bottom)
                        Button("Add Column", systemImage: "plus") { model.insertColumn(at: table.columns.count, in: name) }
                    }
                    .scrollContentBackground(.hidden)
                }
                // Right-clicking inside the selection hands over the whole selection;
                // right-clicking elsewhere hands over just that row.
                .contextMenu(forSelectionType: Int.self) { columns in
                    Button(columns.count > 1 ? "Delete \(columns.count) Columns" : "Delete Column", role: .destructive) {
                        deletion = .column(columns)
                    }
                    // A table keeps at least one column.
                    .disabled(columns.isEmpty || columns.count >= table.columns.count)
                }
                .dragContainerSelectionIfAvailable(table.columns)
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .datasetDeletion($deletion, model: model, name: name, table: table)
                // Indexes shift once columns go, so a stale selection would point at the wrong ones.
                .onChange(of: model.datasetRevision) { selectedColumnIndexes.removeAll() }
            } else {
                ContentUnavailableView("No Dataset Selected", systemImage: "tablecells",
                                       description: Text("Select a dataset in the sidebar."))
            }
        }
        .task(id: "\(name ?? "")#\(model.datasetRevision)") {
            table = if let name { try? await model.table(for: name) } else { nil }
        }
    }
}

/// One variable in the inspector, opening the same popover as its grid header.
/// Both read and write the model, so a change in either shows in the other.
private struct VariableRow: View {
    let model: NotebookModel
    let dataset: String
    let column: Int
    let header: String
    @State private var isPresented = false

    var body: some View {
        let rules = model.arrangements[dataset] ?? CSVArrangement.Rules()
        HStack {
            Text(header.isEmpty ? "Column \(column + 1)" : header)
            Spacer()
            Button("Column Options",
                systemImage: model.type(of: column, in: dataset)?.icon ?? "ellipsis"
            ) {
                isPresented = true
            }
                .help(model.type(of: column, in: dataset).map {
                    model.columnTypes[dataset]?[column] == nil ? "\($0.rawValue), read from the cells" : $0.rawValue
                } ?? "Column Options")
                .labelStyle(.iconOnly)
                .buttonStyle(.glassButton)
                .popover(isPresented: $isPresented) {
                    CSVColumnArrangementMenu(
                        columnName: header,
                        direction: rules.direction(for: column),
                        filter: rules.filter(for: column),
                        variableType: model.columnTypes[dataset]?[column],
                        inferredType: model.inferredTypes[dataset]?[column],
                        onTypeChange: {
                            model.setColumnType($0, column: column, in: dataset)
                        },
                        canRename: true,
                        onRename: { model.renameColumn(column, to: $0, in: dataset) }
                    ) { direction, filter in
                        model.setRules(column: column, direction: direction, filter: filter, in: dataset)
                    }
                }
        }
    }
}


