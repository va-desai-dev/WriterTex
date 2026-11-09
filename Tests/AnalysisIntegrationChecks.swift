import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
@testable import WriterTex

/// Checks the notebook's statistics against values a user would get from R, and
/// the step/document values against round-tripping and validation.
@main
struct AnalysisIntegrationChecks {
    @MainActor static func main() async throws {
        AppDefaults.register()

        // MARK: Descriptives

        let sequence = snapshot(columns: ["x"], rows: (1...10).map { [String($0)] })
        let describeStep = AnalysisStep(operation: .describe(columns: [ColumnReference(index: 0, name: "x")]))
        let described = try AnalysisKernel.run(describeStep, on: sequence)
        let summary = described.tables[0].rows[0]
        check(summary[1] == .count(10), "Descriptives count every usable row")
        check(near(summary[4], 5.5), "Mean of 1...10 is 5.5")
        check(near(summary[5], 3.0276503541), "Sample SD uses n-1, matching R's sd()")
        check(near(summary[7], 3.25) && near(summary[8], 5.5) && near(summary[9], 7.75),
              "Quartiles interpolate like R's default quantile type 7")

        // MARK: Missing versus unusable

        let mixed = snapshot(columns: ["v"], rows: [["1"], [""], ["NA"], ["12kg"], ["4"]])
        let mixedStep = AnalysisStep(operation: .describe(columns: [ColumnReference(index: 0, name: "v")]))
        let untyped = try AnalysisKernel.run(mixedStep, on: mixed, missingCodes: []).tables[0].rows[0]
        check(untyped[2] == .count(1) && untyped[3] == .count(2),
              "Without a declared code, only blanks are missing and NA counts as unusable")
        let declared = try AnalysisKernel.run(mixedStep, on: mixed, missingCodes: ["NA"]).tables[0].rows[0]
        check(declared[2] == .count(2) && declared[3] == .count(1),
              "A declared NA code moves those cells from unusable to missing")
        check(near(declared[4], 2.5), "The mean ignores both missing and unusable cells")

        // MARK: Missing policy

        let paired = snapshot(columns: ["a", "b"], rows: [["1", "1"], ["2", "2"], ["", "3"], ["4", "4"]])
        let references = [ColumnReference(index: 0, name: "a"), ColumnReference(index: 1, name: "b")]
        let pairwise = try AnalysisKernel.run(
            AnalysisStep(missing: .pairwise, operation: .describe(columns: references)), on: paired)
        check(pairwise.tables[0].rows[0][1] == .count(3) && pairwise.tables[0].rows[1][1] == .count(4),
              "Pairwise lets each column keep the rows it has")
        let listwise = try AnalysisKernel.run(
            AnalysisStep(missing: .listwise, operation: .describe(columns: references)), on: paired)
        check(listwise.tables[0].rows[0][1] == .count(3) && listwise.tables[0].rows[1][1] == .count(3),
              "Listwise drops the incomplete row from every column in the step")
        check(listwise.notes.contains { $0.contains("1 of 4 rows dropped") },
              "Listwise reports how many rows it dropped")
        var failed = false
        do { _ = try AnalysisKernel.run(
            AnalysisStep(missing: .fail, operation: .describe(columns: references)), on: paired) }
        catch { failed = true }
        check(failed, "The fail policy refuses a step rather than dropping a row")

        // MARK: Correlation

        let bivariate = snapshot(columns: ["x", "y"],
                                 rows: [["1", "2"], ["2", "4"], ["3", "5"], ["4", "4"], ["5", "5"]])
        let pearson = try AnalysisKernel.run(
            AnalysisStep(operation: .correlation(columns: references, method: .pearson)), on: bivariate)
        check(near(pearson.tables[0].rows[0][1], 0.7745966692), "Pearson r matches R's cor()")
        check(pearson.tables[0].columns == ["", "a"] && pearson.tables[0].rows.count == 1,
              "The matrix keeps only its lower triangle, with no diagonal of ones")
        check(pearson.tables[1].rows[0][2] == .count(5), "The tests table reports complete pairs")
        let spearman = try AnalysisKernel.run(
            AnalysisStep(operation: .correlation(columns: references, method: .spearman)), on: bivariate)
        check(near(spearman.tables[0].rows[0][1], 0.7378647874),
              "Spearman averages tied ranks, matching R's cor(method = \"spearman\")")

        let constant = snapshot(columns: ["x", "y"], rows: [["1", "3"], ["2", "3"], ["3", "3"]])
        let flat = try AnalysisKernel.run(
            AnalysisStep(operation: .correlation(columns: references, method: .pearson)), on: constant)
        check(flat.tables[0].rows[0][1] == .missing, "A variable with no spread gives no coefficient")
        check(flat.notes.contains { $0.contains("no spread") }, "And says why")

        // MARK: Frequencies and cross-tabulation

        let factor = snapshot(columns: ["g", "h"],
                              rows: [["a", "x"], ["a", "y"], ["b", "x"], ["", "x"], ["b", "y"]])
        let frequency = try AnalysisKernel.run(
            AnalysisStep(operation: .frequency(column: ColumnReference(index: 0, name: "g"))), on: factor)
        check(frequency.tables[0].rows.count == 2, "Frequencies list the levels present, not the blanks")
        check(frequency.tables[0].rows[0][1] == .count(2) && near(frequency.tables[0].rows[0][2], 50),
              "Percentages are of the non-missing rows")
        check(frequency.tables[0].rows.last.map { near($0[3], 100) } == true, "Cumulative percent reaches 100")

        let crossTab = try AnalysisKernel.run(
            AnalysisStep(operation: .crossTabulation(rows: ColumnReference(index: 0, name: "g"),
                                                     columns: ColumnReference(index: 1, name: "h"))), on: factor)
        let body = crossTab.tables[0].rows
        check(body.count == 3 && body[2][0] == .text("Total"), "A cross-tab ends in a totals row")
        check(body[0][1] == .count(1) && body[0][3] == .count(2), "Cell and row totals count correctly")
        check(body[2][3] == .count(4), "The grand total excludes the row missing a variable")
        check(crossTab.notes.contains { $0.contains("1 of 5") }, "And that exclusion is reported")

        // MARK: Provenance and drift

        let renamed = snapshot(columns: ["years"], rows: [["1"], ["2"]])
        let agedStep = AnalysisStep(operation: .describe(columns: [ColumnReference(index: 0, name: "age")]))
        let drifted = try AnalysisKernel.run(agedStep, on: renamed)
        check(drifted.notes.contains { $0.contains("years") && $0.contains("age") },
              "A step reports a header that moved instead of quietly using the new column")
        var absent = false
        do { _ = try AnalysisKernel.run(
            AnalysisStep(operation: .describe(columns: [ColumnReference(index: 4, name: "gone")])), on: renamed) }
        catch { absent = true }
        check(absent, "A step whose column no longer exists fails loudly")

        check(sequence.fingerprint == snapshot(columns: ["x"], rows: (1...10).map { [String($0)] }).fingerprint,
              "Identical tables fingerprint identically")
        check(sequence.fingerprint != mixed.fingerprint, "Different tables do not")
        check(described.input.rowCount == 10 && described.input.scope == .allRows,
              "A result carries the shape of the table it was computed from")

        // MARK: The notebook document

        let notebook = AnalysisNotebookFile(missingCodes: ["NA"], steps: [describeStep, agedStep])
        let encoded = try JSONEncoder().encode(notebook)
        let decoded = try JSONDecoder().decode(AnalysisNotebookFile.self, from: encoded)
        check(decoded == notebook, "Steps and missing codes round-trip through notebook.json")
        try decoded.validate()
        var rejected = 0
        for bad in [AnalysisNotebookFile(version: 2),
                    AnalysisNotebookFile(steps: [AnalysisStep(dataset: "../secrets.csv", operation: .describe(columns: []))]),
                    AnalysisNotebookFile(steps: [AnalysisStep(dataset: "Datasets/x.csv", operation: .describe(columns: []))]),
                    AnalysisNotebookFile(steps: [AnalysisStep(operation: .describe(columns: [ColumnReference(index: -1, name: "x")]))])] {
            do { try bad.validate() } catch { rejected += 1 }
        }
        check(rejected == 4, "A future version, a path out of the datasets folder and a negative column are all refused")

        // MARK: The report

        let report = NotebookReport.markdown(steps: [describeStep], results: [describeStep.id: described],
                                             failures: [:], missingCodes: ["NA"])
        check(report.contains("| Variable | N |"), "The export writes result tables as Markdown")
        check(report.contains(described.input.fingerprint), "And records which capture produced them")
        check(NotebookReport.text(.missing) == "—" && NotebookReport.text(.count(1000)) == "1,000",
              "Cells format the same on screen and in the export")

        // MARK: The pane, end to end

        NSApplication.shared.setActivationPolicy(.accessory)
        var package = NotebookPackage()
        package.notebook = notebook
        package.datasets["sample.csv"] = Data("g,v\na,1\nb,2\na,3\n".utf8)
        let file = NotebookFile()
        file.package = package
        let model = NotebookModel(file: file)
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        let host = NSHostingView(rootView: NotebookView(model: model).frame(width: 900, height: 600))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        check(model.availableDatasets == ["sample.csv"], "The notebook's packaged CSVs are offered as datasets")
        check(model.steps.count == 2, "The notebook opens with its saved steps")
        check(await model.headers(for: "sample.csv") == ["g", "v"],
              "Headers for a packaged dataset are read for the step composer")

        check(AnalysisNotebookFile().missingCodes == ["NA"],
              "A new notebook treats NA as missing, and not N/A")

        undo.beginUndoGrouping()
        model.setMissingCodes([])
        undo.endUndoGrouping()
        let fileStep = AnalysisStep(dataset: "sample.csv",
                                    operation: .frequency(column: ColumnReference(index: 0, name: "g")))
        await model.run(fileStep)
        check(model.failures[fileStep.id] == nil, "A step against a packaged dataset runs")
        check(model.results[fileStep.id]?.tables[0].rows.count == 2, "And produces its frequency table")
        check(model.results[fileStep.id]?.input.dataset == "sample.csv", "Recording which dataset it read")

        let openStep = AnalysisStep(operation: .describe(columns: [ColumnReference(index: 1, name: "v")]))
        await model.run(openStep)
        check(model.failures[openStep.id]?.contains("Choose a table") == true,
              "A step without a dataset asks for one instead of failing silently")

        // MARK: Results to a new manuscript

        let unrunStep = AnalysisStep(dataset: "sample.csv", operation: .describe(columns: [ColumnReference(index: 1, name: "v")]))
        let exported = NotebookManuscript.document(title: "Sample Results", steps: [fileStep, openStep, unrunStep],
                                                   results: model.results, failures: model.failures, missingCodes: [])
        let manuscriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wrtx")
        defer { try? FileManager.default.removeItem(at: manuscriptURL) }
        check(await model.writeManuscript(titled: "Sample Results", to: manuscriptURL), "Results write out as a manuscript")
        let reader = MarkdownRichText(baseURL: nil, style: MarkdownStyleSheet(theme: .screen, manuscript: .screen))
        let reopenedManuscript = try ManuscriptDocument.decode(Data(contentsOf: manuscriptURL), using: reader)
        let shown = exported.string as NSString
        check(reopenedManuscript.attribute(.markdownHeading, at: 0, effectiveRange: nil) as? Int == 1
              && shown.hasPrefix("Sample Results\n"), "The manuscript opens with its title as a heading")
        let stepHeading = shown.range(of: "1. \(fileStep.title)")
        check(exported.attribute(.markdownHeading, at: stepHeading.location, effectiveRange: nil) as? Int == 2,
              "Each step is a second-level heading")
        let frequencies = model.results[fileStep.id]!.tables[0]
        let headerCell = shown.range(of: frequencies.columns.joined(separator: "\n") + "\n")
        let grid = reader.tableGrid(at: headerCell.location, in: exported)
        check(grid?.cells.count == frequencies.rows.count + 1 && grid?.cells.first?.count == frequencies.columns.count,
              "A result table becomes a native manuscript table with its header row")
        check(grid?.cells[1].map(\.string) == frequencies.rows[0].map(NotebookReport.text),
              "Its cells read exactly as on screen")
        check(grid?.alignments.first == .left && grid?.alignments.last == .right,
              "Text columns align left and number columns right")
        check(shown.contains("Did not run: ") && shown.contains("Not run.") && !shown.contains("|"),
              "Failed and unrun steps say so, and no Markdown table syntax leaks in")
        let reopenedText = reopenedManuscript.string as NSString
        let firstSaved = reopenedText.range(of: "1. \(model.steps[0].title)\n")
        check(firstSaved.location != NSNotFound
              && reopenedManuscript.attribute(.markdownHeading, at: firstSaved.location, effectiveRange: nil) as? Int == 2,
              "The saved manuscript reopens with the notebook's own steps as headings")

        // A private pasteboard, so the check never replaces what the user copied.
        let board = NSPasteboard(name: NSPasteboard.Name("writertex-check-\(UUID())"))
        defer { board.releaseGlobally() }
        try NotebookManuscript.copy(fileStep, number: 1, result: model.results[fileStep.id]!, to: board)
        check(board.types?.starts(with: [ManuscriptDocument.pasteboardType]) == true && board.data(forType: .rtf) != nil,
              "Copy Result offers WriterTex rich text first, then RTF")
        check(board.string(forType: .string)?.contains(frequencies.columns.joined(separator: "\t")) == true,
              "And tab-separated rows for a spreadsheet")
        let pastedInto = MarkdownRichTextView(usingTextLayoutManager: false)
        pastedInto.document = reader
        check(pastedInto.readSelection(from: board, type: ManuscriptDocument.pasteboardType),
              "A manuscript editor reads the copied result")
        let pasted = pastedInto.textStorage!
        let pastedHeader = (pasted.string as NSString).range(of: frequencies.columns.joined(separator: "\n") + "\n")
        check(pasted.attribute(.markdownHeading, at: 0, effectiveRange: nil) as? Int == 2
              && reader.tableGrid(at: pastedHeader.location, in: pasted)?.cells.count == frequencies.rows.count + 1,
              "Pasting it gives the step heading and a native table")

        undo.beginUndoGrouping()
        model.remove(describeStep.id)
        undo.endUndoGrouping()
        check(model.steps.map(\.id) == [agedStep.id] && file.package.notebook.steps.map(\.id) == [agedStep.id],
              "Removing a step writes through to the document")
        undo.undo()
        check(model.steps.map(\.id) == [describeStep.id, agedStep.id] && file.package.notebook.steps.count == 2,
              "Undo puts the step back where it was")
        undo.undo()
        check(model.missingCodes == ["NA"] && file.package.notebook.missingCodes == ["NA"],
              "Undo restores the missing codes too")
        host.layoutSubtreeIfNeeded()

        // MARK: Datasets come in as copies, and go out undoably

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let incoming = [folder.appendingPathComponent("sample.csv"), folder.appendingPathComponent("codes.csv"),
                        folder.appendingPathComponent("empty.csv")]
        try Data("x\n9\n".utf8).write(to: incoming[0])
        try Data("v\na\n1\nNA\n2\n".utf8).write(to: incoming[1])
        try Data().write(to: incoming[2])
        undo.beginUndoGrouping()
        let problems = await model.importDatasets(incoming)
        undo.endUndoGrouping()
        check(Set(model.availableDatasets) == ["codes.csv", "sample.csv", "sample 2.csv"],
              "Imports are copied in, and a taken name gets a number rather than replacing a table")
        check(problems?.contains("empty.csv") == true, "A file with no header row is refused, and says which")
        check(file.package.datasets["sample.csv"] == Data("g,v\na,1\nb,2\na,3\n".utf8),
              "The table already in the notebook is untouched")
        try FileManager.default.removeItem(at: incoming[1])
        check(model.availableDatasets.contains("codes.csv"), "A copy outlives the file it came from")
        undo.undo()
        check(model.availableDatasets == ["sample.csv"], "Undo takes the whole import back out")
        undo.redo()
        check(model.availableDatasets.count == 3, "Redo brings it back")

        // MARK: Rows and columns are added and deleted, and steps follow their columns

        let readsB = AnalysisStep(dataset: "shape.csv", operation: .describe(columns: [ColumnReference(index: 1, name: "b")]))
        let readsC = AnalysisStep(dataset: "shape.csv", operation: .frequency(column: ColumnReference(index: 2, name: "c")))
        let elsewhere = AnalysisStep(dataset: "sample.csv", operation: .frequency(column: ColumnReference(index: 1, name: "v")))
        var shapePackage = NotebookPackage()
        shapePackage.notebook = AnalysisNotebookFile(missingCodes: [], steps: [readsB, readsC, elsewhere])
        shapePackage.datasets = ["shape.csv": Data("a,b,c\n1,2,3\n4,5,6\n".utf8), "sample.csv": Data("g,v\na,1\n".utf8)]
        let shapeFile = NotebookFile()
        shapeFile.package = shapePackage
        let shaped = NotebookModel(file: shapeFile)
        let shapeUndo = UndoManager()
        shapeUndo.groupsByEvent = false
        shaped.undoManager = shapeUndo
        func shapeText() -> String { String(decoding: shapeFile.package.datasets["shape.csv"] ?? Data(), as: UTF8.self) }
        func columns(of step: AnalysisStep) -> [ColumnReference] { shaped.steps.first { $0.id == step.id }?.columns ?? [] }
        func edit(_ change: () -> Void) {
            shapeUndo.beginUndoGrouping()
            change()
            shapeUndo.endUndoGrouping()
        }

        let revision = shaped.datasetRevision
        edit { shaped.insertColumn(at: 1, in: "shape.csv") }
        check(shapeText() == "a,Untitled,b,c\n1,,2,3\n4,,5,6\n", "A new column is blank, named Untitled, where it was asked for")
        check(columns(of: readsB) == [ColumnReference(index: 2, name: "b")] && columns(of: readsC) == [ColumnReference(index: 3, name: "c")],
              "Steps reading the columns after it follow them")
        check(columns(of: elsewhere) == elsewhere.columns, "Steps on other datasets are left alone")
        check(shaped.datasetRevision > revision && shapeUndo.undoActionName == "Add Column",
              "The grid and inspector reload, and the edit is named for Undo")
        shapeUndo.undo()
        check(shapeText() == "a,b,c\n1,2,3\n4,5,6\n" && columns(of: readsB) == readsB.columns,
              "Undo takes the column back out and the steps back with it")
        shapeUndo.redo()
        check(shapeText().hasPrefix("a,Untitled,b,c\n") && columns(of: readsB) == [ColumnReference(index: 2, name: "b")],
              "Redo puts both back")
        edit { shaped.insertColumn(at: 99, in: "shape.csv") }
        check(shapeText().hasPrefix("a,Untitled,b,c,Untitled 2\n"), "A second new column takes the next free name, at the end")

        edit { shaped.renameColumn(3, to: "score", in: "shape.csv") }
        check(shapeText().hasPrefix("a,Untitled,b,score,") && columns(of: readsC) == [ColumnReference(index: 3, name: "score")],
              "Renaming a column renames it in the steps that read it")
        await shaped.run(shaped.steps.first { $0.id == readsC.id }!)
        check(shaped.failures[readsC.id] == nil && shaped.results[readsC.id]?.notes.contains { $0.contains("now reads") } == false,
              "So a renamed column runs without being reported as drift")

        edit { shaped.setColumnType(.numeric, column: 3, in: "shape.csv") }
        edit { shaped.setColumnType(.factor, column: 2, in: "shape.csv") }
        shaped.setRules(column: 3, direction: .descending, filter: CSVArrangement.Filter(condition: .isNotEmpty), in: "shape.csv")
        shaped.setRules(column: 2, direction: nil, filter: CSVArrangement.Filter(condition: .isEmpty), in: "shape.csv")
        check(shaped.columnTypes["shape.csv"] == [3: .numeric, 2: .factor] && shapeUndo.undoActionName == "Change Variable Type",
              "Variable types are kept by the notebook and named for Undo")
        shapeUndo.undo()
        check(shaped.columnTypes["shape.csv"] == [3: .numeric], "Undo takes a variable type back")
        shapeUndo.redo()

        edit { shaped.deleteColumn(2, in: "shape.csv") }
        check(shapeText() == "a,Untitled,score,Untitled 2\n1,,3,\n4,,6,\n", "Deleting a column takes its cells with it")
        check(columns(of: readsC) == [ColumnReference(index: 2, name: "score")], "Columns after it move up in the steps")
        check(shaped.columnTypes["shape.csv"] == [2: .numeric], "And its type goes with it, while the types after it move up")
        check(shaped.arrangements["shape.csv"]?.sortColumn == 2 && shaped.arrangements["shape.csv"]?.filters.keys.sorted() == [2],
              "Sort and filters follow their column, and a deleted column's go with it")
        shapeUndo.undo()
        check(shaped.columnTypes["shape.csv"] == [3: .numeric, 2: .factor], "Undoing the deletion brings its type back")
        check(shaped.arrangements["shape.csv"]?.sortColumn == 3 && shaped.arrangements["shape.csv"]?.filters.keys.sorted() == [2, 3],
              "And puts each rule back on its column")
        shapeUndo.redo()
        await shaped.run(shaped.steps.first { $0.id == readsB.id }!)
        check(shaped.failures[readsB.id]?.contains("“b”") == true,
              "A step reading the deleted column names it as missing instead of reading its neighbour")
        for column in [3, 1, 0] { edit { shaped.deleteColumn(column, in: "shape.csv") } }
        let lastColumn = shapeText()
        edit { shaped.deleteColumn(0, in: "shape.csv") }
        check(lastColumn == "score\n3\n6\n" && shapeText() == lastColumn, "The last column can't be deleted, so the table keeps a header")

        edit { shaped.insertRow(at: 1, in: "shape.csv") }
        check(shapeText() == "score\n3\n\n6\n" && shapeUndo.undoActionName == "Add Row", "A blank row goes in where it was asked for")
        edit { shaped.deleteRow(0, in: "shape.csv") }
        check(shapeText() == "score\n\n6\n", "Deleting a row removes that case")
        edit { shaped.deleteRow(9, in: "shape.csv") }
        check(shapeText() == "score\n\n6\n", "A row that isn't there changes nothing")
        let reshapedPackage = try NotebookPackage(shapeFile.package.fileWrapper(reusing: nil))
        check(reshapedPackage == shapeFile.package && reshapedPackage.notebook.columnTypes["shape.csv"] == [0: .numeric],
              "The reshaped dataset, its steps and its variable types save and reopen")
        let preTypes = try JSONDecoder().decode(AnalysisNotebookFile.self, from: Data(#"{"version":1,"missingCodes":["NA"],"steps":[]}"#.utf8))
        check(preTypes.columnTypes.isEmpty, "Notebooks saved before variable types still open")

        // The grid's selection, with a cell edit still open, is what the edit menu acts on.
        let shapeSession = EditorSession()
        let gridHost = NSHostingView(rootView: CSVPreviewView(table: CSVEngine.parse(shapeText()), session: shapeSession) {
            shaped.updateDataset("shape.csv", to: $0)
        }.frame(width: 400, height: 300))
        let gridWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                  styleMask: [.titled], backing: .buffered, defer: false)
        gridWindow.isReleasedWhenClosed = false
        gridWindow.contentView = gridHost
        gridWindow.makeKeyAndOrderFront(nil)
        defer { gridWindow.close() }
        gridHost.layoutSubtreeIfNeeded()
        let typed = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: gridWindow.windowNumber, context: nil,
                                     characters: "7", charactersIgnoringModifiers: "7", isARepeat: false, keyCode: 26)!
        shapeSession.csvGrid?.keyDown(with: typed)
        var selection: (row: Int?, column: Int)?
        edit { selection = shapeSession.csvSelection() }
        check(selection?.row == 0 && selection?.column == 0, "The selected cell is read in file rows and columns")
        check(shapeText() == "score\n7\n6\n", "Reading it commits the cell being typed, so a reshape keeps the edit")
        edit { shaped.insertRow(at: (selection?.row ?? 0) + 1, in: "shape.csv") }
        check(shapeText() == "score\n7\n\n6\n", "Insert Row Below lands under the selected case")

        // MARK: Variable types are read from the cells

        typealias Flag = CSVArrangement.VariableFlag
        func reads(_ cells: [String], _ codes: Set<String> = ["NA"]) -> Flag { .inferred(from: cells, missingCodes: codes) }
        check(reads([]) == .character && reads(["", " ", "NA"]) == .character, "A column with nothing to read is character")
        check(reads(["1", "0", "1"]) == .logical && reads(["Yes", "no", "YES", "NA"]) == .logical && reads(["TRUE", "false"]) == .logical,
              "Only 0/1, yes/no or true/false, in any case, is logical")
        check(reads(["1", "2", "-3", " 4 ", ""]) == .integer, "Whole numbers are integers, around blanks and spaces")
        check(reads(["1.5", "2", "NA"]) == .numeric && reads(["1e3", "-0.25"]) == .numeric, "Any other numbers are numeric")
        check(reads(["1.5", "inf"]) != .numeric && reads(["12kg", "3"]) != .numeric, "Infinity and units are not numbers")
        check(reads(["1", "2", "3", "1", "2", "3"]) == .integer, "Numeric codes stay numbers rather than becoming factors")
        check(reads(["2026-11-05", "1999-01-31"]) == .date, "ISO dates are dates")
        check(reads(["14:30", "09:05:59.25"]) == .time, "ISO times are times")
        check(reads(["2026-11-05T14:30:00Z", "2026-11-05 08:00+05:30", "2026-11-05T08:00:00.5-0400"]) == .datetime,
              "ISO date-times are date-times, with or without a zone")
        check(reads(["2026-13-01"]) == .character && reads(["11/05/2026"]) == .character && reads(["2026-11-05", "14:30"]) == .character,
              "Impossible dates, other formats and mixed kinds stay character")
        check(reads(["a", "b", "a", "b", "c", "a"]) == .factor, "Text repeating a few levels is a factor")
        check(reads(["alice", "bob", "carol"]) == .character, "Text that doesn't repeat is character")
        check(reads((0..<200).map { "level \($0 % 60)" }) == .character, "Too many levels for a factor is character")

        var typedPackage = NotebookPackage()
        typedPackage.datasets["typed.csv"] = Data("id,score,group,when,flag\n1,2.5,a,2026-01-01,yes\n2,NA,b,2026-01-02,no\n3,3,a,2026-01-03,yes\n4,4,b,2026-01-04,no\n".utf8)
        let typedFile = NotebookFile()
        typedFile.package = typedPackage
        let typedModel = NotebookModel(file: typedFile)
        let typedUndo = UndoManager()
        typedUndo.groupsByEvent = false
        typedModel.undoManager = typedUndo
        func typedEdit(_ change: () -> Void) {
            typedUndo.beginUndoGrouping()
            change()
            typedUndo.endUndoGrouping()
        }
        await typedModel.typesInferred()
        check(typedModel.inferredTypes["typed.csv"] == [0: .integer, 1: .numeric, 2: .factor, 3: .date, 4: .logical],
              "Each column's type is read when the notebook opens")
        check(typedModel.columnTypes.isEmpty && typedFile.package.notebook.columnTypes.isEmpty,
              "Read types aren't saved, so they follow the cells")
        typedEdit { typedModel.setColumnType(.factor, column: 1, in: "typed.csv") }
        check(typedModel.type(of: 1, in: "typed.csv") == .factor && typedModel.inferredTypes["typed.csv"]?[1] == .numeric,
              "A type the user sets wins over the one read")
        typedEdit { typedModel.setColumnType(nil, column: 1, in: "typed.csv") }
        check(typedModel.type(of: 1, in: "typed.csv") == .numeric, "Setting Automatic goes back to the read type")

        var flagTable = try await typedModel.table(for: "typed.csv")
        flagTable.rows[0][4] = "maybe"
        typedEdit { typedModel.updateDataset("typed.csv", to: flagTable) }
        await typedModel.typesInferred()
        check(typedModel.inferredTypes["typed.csv"]?[4] == .character, "Editing a cell reads its column again")
        typedUndo.undo()
        await typedModel.typesInferred()
        check(typedModel.inferredTypes["typed.csv"]?[4] == .logical, "And so does undoing the edit")
        typedEdit { typedModel.setMissingCodes([]) }
        await typedModel.typesInferred()
        check(typedModel.inferredTypes["typed.csv"]?[1] == .character, "Once NA isn't missing, it is text in a number column")
        typedEdit { typedModel.removeDatasets(["typed.csv"]) }
        await typedModel.typesInferred()
        check(typedModel.inferredTypes["typed.csv"] == nil, "A removed dataset's read types go with it")

        // MARK: Compute and recode write new values into a dataset

        let people = CSVTable(columns: ["id", "score", "First Name", "group", "weight"],
                              rows: [["1", "40", "Ana", "a", "12kg"], ["2", "NA", "", "b", "60"],
                                     ["3", "75.5", "Raj", "a", "70"], ["4", "", "Li", "c", "0"]])
        func computed(_ formula: String) throws -> [String] {
            try DataTransform.compute(formula, in: people, missingCodes: ["NA"]).cells
        }
        check(try computed("=score * 2 + 1") == ["81", "", "152", ""], "Arithmetic follows precedence, and a missing input gives a blank")
        check(try computed("ROUND((score - 50) / 10, 1)") == ["-1", "", "2.6", ""], "Functions, brackets and rounding away from zero")
        check(try computed("-2^2") == ["-4", "-4", "-4", "-4"] && (try computed("2^-1")) == ["0.5", "0.5", "0.5", "0.5"],
              "Powers bind tighter than a leading minus, as in SPSS and R")
        check(try computed("0.1 + 0.2") == ["0.3", "0.3", "0.3", "0.3"], "Results are written to 15 significant digits")
        check(try computed("MEAN(score, id)") == ["20.5", "2", "39.25", "4"] && (try computed("SUM(score)")) == ["40", "", "75.5", ""],
              "MEAN and SUM skip missing values, and are blank only when all are")
        check(try computed("IF(score >= 50, \"pass\", \"fail\")") == ["fail", "", "pass", ""], "IF picks a branch; a missing test gives a blank")
        check(try computed("IF(ISBLANK([First Name]), \"?\", [First Name] & \" \" & id)") == ["Ana 1", "?", "Raj 3", "Li 4"],
              "Bracketed headers, ISBLANK, text literals and & join text")
        check(try computed("group = \"A\"") == ["1", "0", "1", "0"] && (try computed("AND(id > 1, id <> 4)")) == ["0", "1", "1", "0"],
              "Comparisons are 1 or 0, and text compares without case")
        check(try computed("SCORE / Id") == ["40", "", "25.1666666666667", ""], "Names match headers without case")
        let weights = try DataTransform.compute("weight / 2", in: people, missingCodes: ["NA"])
        check(weights.cells == ["", "30", "35", "0"] && weights.summary == DataTransform.Summary(cases: 4, blank: 1, notNumbers: 1),
              "A cell that isn't a number is blank in the result, and counted apart from missing")
        check(try computed("id / (id - id)") == ["", "", "", ""], "Dividing by zero is missing, not infinity")
        for (formula, message) in [("", "Type a formula"), ("score +", "ends too soon"), ("height * 2", "No column is named “height”"),
                                   ("SQRT(1, 2)", "SQRT takes 1 argument"), ("FOO(1)", "no function FOO"),
                                   ("(1 + 2", "Expected “)”"), ("\"open", "closing quote"), ("1 2", "Unexpected “2”")] {
            do {
                _ = try computed(formula)
                check(false, "“\(formula)” is refused")
            } catch {
                check(error.localizedDescription.contains(message), "“\(formula)” is refused: \(error.localizedDescription)")
            }
        }

        let ages = ["17", "18", "64", "65", "NA", "", "unknown", "30.0"]
        let bands = [RecodeRule(match: .range(low: nil, high: 17), output: .value("minor")),
                     RecodeRule(match: .range(low: 18, high: 64), output: .value("adult")),
                     RecodeRule(match: .range(low: 65, high: nil), output: .value("senior")),
                     RecodeRule(match: .missing, output: .value("not asked"))]
        check(DataTransform.recode(ages, rules: bands, missingCodes: ["NA"], keepsUnmatched: false)
              == ["minor", "adult", "adult", "senior", "not asked", "not asked", "", "adult"],
              "Ranges, lowest and highest, and missing recode; an unmatched value goes blank in a new variable")
        check(DataTransform.recode(ages, rules: bands, missingCodes: ["NA"], keepsUnmatched: true)[6] == "unknown",
              "And keeps its value when recoding the same variable")
        let flags = [RecodeRule(match: .value("3"), output: .value("three")),
                     RecodeRule(match: .value("unknown"), output: .blank),
                     RecodeRule(match: .other, output: .copy)]
        check(DataTransform.recode(["3.0", "unknown", "x", "3"], rules: flags, missingCodes: [], keepsUnmatched: false)
              == ["three", "", "x", "three"], "A value matches its number written another way; the first rule wins; ELSE copies")

        var computePackage = NotebookPackage()
        computePackage.datasets["people.csv"] = Data(CSVEngine.generate(from: people).utf8)
        computePackage.notebook.steps = [AnalysisStep(dataset: "people.csv", operation: .describe(columns: [ColumnReference(index: 1, name: "score")]))]
        let computeFile = NotebookFile()
        computeFile.package = computePackage
        let computeModel = NotebookModel(file: computeFile)
        let computeUndo = UndoManager()
        computeUndo.groupsByEvent = false
        computeModel.undoManager = computeUndo
        func peopleTable() async throws -> CSVTable { try await computeModel.table(for: "people.csv") }
        func mutate(_ change: () throws -> Void) rethrows {
            computeUndo.beginUndoGrouping()
            defer { computeUndo.endUndoGrouping() }
            try change()
        }
        let original = computeFile.package.datasets["people.csv"]
        let revisionBefore = computeModel.datasetRevision
        var computeSummary = DataTransform.Summary()
        try mutate { computeSummary = try computeModel.compute("score / 10", into: "tenths", in: "people.csv") }
        var written = try await peopleTable()
        check(written.columns.last == "tenths" && written.rows.map { $0[5] } == ["4", "", "7.55", ""],
              "Compute writes a new column at the end")
        check(computeSummary == DataTransform.Summary(cases: 4, blank: 2, notNumbers: 0) && computeUndo.undoActionName == "Compute Variable",
              "It reports what it did, and is one step to undo")
        check(computeModel.datasetRevision > revisionBefore && computeModel.steps[0].columns == [ColumnReference(index: 1, name: "score")],
              "The grid reloads, and steps keep reading their columns")
        await computeModel.typesInferred()
        check(computeModel.inferredTypes["people.csv"]?[5] == .numeric, "The new column's type is read like any other")
        try mutate { try computeModel.compute("score * 10", into: "tenths", in: "people.csv") }
        written = try await peopleTable()
        check(written.columns.count == 6 && written.rows.map { $0[5] } == ["400", "", "755", ""], "Naming an existing column replaces its values")
        do {
            try computeModel.compute("nope + 1", into: "x", in: "people.csv")
            check(false, "A bad formula is refused")
        } catch {
            check(try await peopleTable().columns.count == 6, "A bad formula changes nothing")
        }
        do {
            try computeModel.compute("1", into: "  ", in: "people.csv")
            check(false, "A blank target is refused")
        } catch {
            check(error.localizedDescription.contains("Name the variable"), "A blank target is refused")
        }

        let grades = [RecodeRule(match: .value("a"), output: .value("1")), RecodeRule(match: .value("b"), output: .value("2"))]
        try mutate { try computeModel.recode(3, rules: grades, into: "group code", in: "people.csv") }
        written = try await peopleTable()
        check(written.columns.last == "group code" && written.rows.map { $0[6] } == ["1", "2", "1", ""]
              && written.rows.map { $0[3] } == ["a", "b", "a", "c"], "Recode into a different variable leaves the source alone")
        try mutate { try computeModel.recode(3, rules: grades, into: nil, in: "people.csv") }
        written = try await peopleTable()
        check(written.rows.map { $0[3] } == ["1", "2", "1", "c"] && computeUndo.undoActionName == "Recode Variable",
              "Recode into the same variable keeps what no rule matches")
        computeUndo.undo()
        computeUndo.undo()
        computeUndo.undo()
        computeUndo.undo()
        check(computeFile.package.datasets["people.csv"] == original, "Undo takes every compute and recode back out")
        computeUndo.redo()
        check(try await peopleTable().columns.last == "tenths", "And redo puts them back")

        let sheetHost = NSHostingView(rootView: DataMutationSheet(model: computeModel, kind: .compute))
        sheetHost.layoutSubtreeIfNeeded()
        check(sheetHost.fittingSize.width > 0, "The compute sheet mounts against a notebook")
        for kind in AnalysisOperationKind.allCases {
            let composer = NSHostingView(rootView: NotebookStepComposer(model: computeModel, kind: kind) { _ in })
            composer.layoutSubtreeIfNeeded()
            check(composer.fittingSize.width > 0, "The \(kind.rawValue) composer mounts in the same layout")
        }

        // MARK: A step's roles take variables in order

        var pairRoles = StepRoleAssignment(AnalysisOperationKind.pairedT.roles)
        check(!pairRoles.isComplete && pairRoles.active == 0, "A step starts with every role empty, filling the first")
        pairRoles.pick(2)
        check(pairRoles.columns == [[2], []] && pairRoles.active == 1, "A click fills the active role and moves on to the next")
        pairRoles.pick(5)
        check(pairRoles.columns == [[2], [5]] && pairRoles.isComplete, "Two picks fill a two-role step")
        pairRoles.pick(7)
        check(pairRoles.columns == [[2], [7]], "A click into a full one-variable role replaces what is there")
        pairRoles.place(2, in: 1)
        check(pairRoles.columns == [[7], [2]], "Moving a variable into a full role trades it with the one there")
        pairRoles.pick(7)
        check(pairRoles.columns == [[], [2]] && pairRoles.active == 0, "Clicking a picked variable takes it out and makes its role active")

        var listRoles = StepRoleAssignment(AnalysisOperationKind.describe.roles)
        for column in [4, 1, 3] { listRoles.pick(column) }
        check(listRoles.columns == [[4, 1, 3]] && listRoles.active == 0, "A list role keeps variables in the order they were picked")
        listRoles.move(in: 0, fromOffsets: [2], toOffset: 0)
        check(listRoles.columns == [[3, 4, 1]], "A variable moves up within its role")
        listRoles.move(in: 0, fromOffsets: [0], toOffset: 3)
        check(listRoles.columns == [[4, 1, 3]], "And down to the end")
        listRoles.place(1, in: 0, at: 0)
        check(listRoles.columns == [[1, 4, 3]], "A drop inside the same role reorders it")

        var regressionRoles = StepRoleAssignment(AnalysisOperationKind.linearRegression.roles)
        for column in [0, 2, 3] { regressionRoles.pick(column) }
        check(regressionRoles.columns == [[0], [2, 3]] && regressionRoles.active == 1,
              "Regression fills its outcome, then keeps adding predictors")
        regressionRoles.place(3, in: 0)
        check(regressionRoles.columns == [[3], [2, 0]], "A predictor dropped on the outcome sends the old outcome back to the predictors")
        regressionRoles.place(5, in: 1, at: 0)
        check(regressionRoles.columns == [[3], [5, 2, 0]], "A variable dropped from the list lands where it was dropped")

        var correlationRoles = StepRoleAssignment(AnalysisOperationKind.correlation.roles)
        correlationRoles.pick(0)
        check(!correlationRoles.isComplete, "A correlation needs at least two variables")
        correlationRoles.pick(1)
        check(correlationRoles.isComplete, "And is complete with two")

        // MARK: The package on disk

        let saved = try file.package.fileWrapper(reusing: nil)
        let reread = try NotebookPackage(saved)
        check(reread == file.package, "A notebook and all its datasets round-trip through the package")
        check(saved.fileWrappers?[NotebookPackage.datasetsName]?.fileWrappers?.count == 3,
              "Each dataset is its own CSV inside the package")
        let packageURL = folder.appendingPathComponent("Round Trip.wrstatx")
        try saved.write(to: packageURL, options: .atomic, originalContentsURL: nil)
        let fromDisk = try FileWrapper(url: packageURL)
        check(try NotebookPackage(fromDisk) == file.package, "And through a real .wrstatx folder")
        let rewritten = try file.package.fileWrapper(reusing: fromDisk)
        let kept = rewritten.fileWrappers?[NotebookPackage.datasetsName]?.fileWrappers?["sample.csv"]
        check(kept === fromDisk.fileWrappers?[NotebookPackage.datasetsName]?.fileWrappers?["sample.csv"],
              "An unchanged dataset is reused rather than written again")
        let hostile = FileWrapper(directoryWithFileWrappers: [
            NotebookPackage.datasetsName: FileWrapper(directoryWithFileWrappers: [
                ".hidden.csv": FileWrapper(regularFileWithContents: Data("a\n1\n".utf8)),
                "notes.txt": FileWrapper(regularFileWithContents: Data("x".utf8)),
            ])])
        check(try NotebookPackage(hostile).datasets.isEmpty, "Only plain .csv files in the package are datasets")
        check(UTType.writerTexNotebook.conforms(to: .package), "A notebook is a package Finder shows as one file")

        // MARK: Changing the vocabulary re-runs what has already run

        let codesStep = AnalysisStep(dataset: "codes.csv",
                                     operation: .describe(columns: [ColumnReference(index: 0, name: "v")]))
        let neverRun = AnalysisStep(dataset: "codes.csv",
                                    operation: .frequency(column: ColumnReference(index: 0, name: "v")))
        var vocabulary = file.package
        vocabulary.notebook = AnalysisNotebookFile(missingCodes: [], steps: [codesStep, neverRun])
        let reopenedFile = NotebookFile()
        reopenedFile.package = try NotebookPackage(vocabulary.fileWrapper(reusing: nil))
        let reopened = NotebookModel(file: reopenedFile)
        check(reopened.steps.count == 2 && reopened.missingCodes.isEmpty,
              "A saved notebook reopens with its own vocabulary, not the default")

        await reopened.run(codesStep)
        let before = reopened.results[codesStep.id]?.tables[0].rows[0]
        check(before?[2] == .count(0) && before?[3] == .count(2),
              "With no codes declared, the NA row is unusable and nothing is missing")

        reopened.setMissingCodes(["NA"])
        for _ in 0..<100 where reopened.results[codesStep.id]?.tables[0].rows[0][2] == .count(0) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let after = reopened.results[codesStep.id]?.tables[0].rows[0]
        check(after?[2] == .count(1) && after?[3] == .count(1),
              "Declaring NA re-runs the step and moves that row from unusable to missing")
        check(reopened.results[neverRun.id] == nil && reopened.failures[neverRun.id] == nil,
              "A step that has never run is not started by a vocabulary change")

        // MARK: Significance
        //
        // Expected values are R's, via:
        //   pt / pchisq / pf, cor.test(x, y), chisq.test(m, correct = FALSE),
        //   p.adjust(p, "holm") and p.adjust(p, "BH").

        for (name, got, want) in [
            ("pnorm(1.96)", Distributions.normal(1.96), 0.97500210485177963),
            ("pnorm(-2.5)", Distributions.normal(-2.5), 0.0062096653257761349),
            ("pt(2, 10)", Distributions.studentT(2, df: 10), 0.96330598261462974),
            ("2*pt(-2, 10)", Distributions.twoTailedT(2, df: 10), 0.073388034770740393),
            ("2*pt(-3, 48)", Distributions.twoTailedT(3, df: 48), 0.0042716622441844616),
            ("2*pt(-12, 200)", Distributions.twoTailedT(12, df: 200), 2.4221360052465909e-25),
            ("pchisq(3.8414588, 1)", Distributions.chiSquare(3.841458820694124, df: 1), 0.95000000000000007),
            ("pchisq(18.31, 4, upper)", Distributions.upperChiSquare(18.31, df: 4), 0.0010732822472379843),
            ("pchisq(100, 10, upper)", Distributions.upperChiSquare(100, df: 10), 5.4497019829205302e-17),
            ("pf(4, 3, 20)", Distributions.fDistribution(4, 3, 20), 0.97792300033763757),
            ("pf(4, 3, 20, upper)", Distributions.upperF(4, 3, 20), 0.022076999662362429),
        ] {
            check(abs(got - want) <= abs(want) * 1e-12, "\(name) matches R to 12 significant digits")
        }
        check(Distributions.twoTailedT(12, df: 200) > 0,
              "A far-tail p keeps its digits instead of rounding to zero against 1")

        let holm = PValueAdjustment.holm.adjusted([0.004, 0.041, 0.13, 0.009])
        let hochberg = PValueAdjustment.benjaminiHochberg.adjusted([0.004, 0.041, 0.13, 0.009])
        check(zip(holm, [0.016, 0.082, 0.13, 0.027]).allSatisfy { abs($0 - $1) < 1e-12 },
              "Holm adjustment matches p.adjust(method = \"holm\")")
        check(zip(hochberg, [0.016, 0.0546666666666667, 0.13, 0.018]).allSatisfy { abs($0 - $1) < 1e-12 },
              "Benjamini–Hochberg matches p.adjust(method = \"BH\")")
        check(PValueAdjustment.none.adjusted([0.004, 0.041]) == [0.004, 0.041],
              "No adjustment leaves the raw values alone")

        let tested = try AnalysisKernel.run(
            AnalysisStep(adjustment: .none, operation: .correlation(columns: references, method: .pearson)),
            on: bivariate)
        let row = tested.tables[1].rows[0]
        check(row[4] == .count(3), "Correlation reports n - 2 degrees of freedom")
        check(near(row[5], 2.1213203435596428), "And the t statistic R's cor.test gives")
        guard case .probability(let correlationP, _) = row[6] else { fatalError("no p-value") }
        check(abs(correlationP - 0.12402706265755449) < 1e-12, "And its two-sided p-value")
        check(near(row[7], -0.34008203518750996) && near(row[8], 0.9842357551507267),
              "And the Fisher z interval cor.test reports")
        check(tested.tables[1].columns.count == 9, "With no adjustment there is no adjusted column")

        let adjustedRun = try AnalysisKernel.run(
            AnalysisStep(adjustment: .holm, operation: .correlation(
                columns: references + [ColumnReference(index: 0, name: "x")], method: .pearson)),
            on: bivariate)
        check(adjustedRun.tables[1].columns.contains("p (Holm)"),
              "A family of tests gains an adjusted column")
        check(adjustedRun.notes.contains { $0.contains("simultaneous tests") },
              "And says how many tests it adjusted for")
        check(adjustedRun.tables[1].rows.allSatisfy { row in
                  guard case .probability(_, let starred) = row[6] else { return true }
                  return !starred
              }, "Once adjusted, the raw p no longer carries stars")
        check(adjustedRun.tables[0].rows.count == 2 && adjustedRun.tables[0].rows[0][2] == .text(""),
              "A three-variable matrix is two rows by two columns, blank above the diagonal")

        let squared = try AnalysisKernel.run(
            AnalysisStep(operation: .crossTabulation(rows: ColumnReference(index: 0, name: "g"),
                                                     columns: ColumnReference(index: 1, name: "h"))),
            on: factor)
        check(squared.tables.count == 1,
              "A cross-tabulation describes the table and runs no test of its own")

        // Counts [[1, 1], [1, 2]], i.e. chisq.test(matrix(c(1,1,1,2), 2, byrow = TRUE)).
        let skewed = snapshot(columns: ["g", "h"],
                              rows: [["a", "x"], ["a", "y"], ["b", "x"], ["b", "y"], ["b", "y"]])
        let chiSquareStep = AnalysisStep(operation: .chiSquareIndependence(
            rows: ColumnReference(index: 0, name: "g"), columns: ColumnReference(index: 1, name: "h")))
        let chiSquareResult = try AnalysisKernel.run(chiSquareStep, on: skewed)
        let independence = chiSquareResult.tables[0].rows[0]
        check(chiSquareResult.tables.count == 2
              && chiSquareResult.tables[1].caption?.contains("Expected") == true,
              "The test is its own step, and reports the expected counts behind it")
        check(near(independence[0], 0.13888888888888881) && independence[1] == .count(1)
              && independence[2] == .count(5),
              "Chi-square, df and N match chisq.test(correct = FALSE)")
        guard case .probability(let independenceP, _) = independence[3] else { fatalError("no p-value") }
        check(abs(independenceP - 0.70938811501422649) < 1e-12, "As does its p-value")
        check(near(independence[4], 0.16666666666666663), "And Cramér's V follows from it")
        check(try AnalysisKernel.run(chiSquareStep, on: skewed).notes.contains { $0.contains("fewer than 5") },
              "A sparse table says the approximation is unreliable")
        var oneLevel = false
        do {
            _ = try AnalysisKernel.run(AnalysisStep(operation: .chiSquareIndependence(
                rows: ColumnReference(index: 0, name: "x"), columns: ColumnReference(index: 1, name: "y"))),
                on: snapshot(columns: ["x", "y"], rows: [["a", "p"], ["a", "p"]]))
        } catch { oneLevel = true }
        check(oneLevel, "A single-level variable fails rather than returning a degenerate test")

        // MARK: Comparing means
        //
        // Expected values are R's, via t.test(...) and summary(aov(y ~ f)).

        let scores = snapshot(columns: ["x", "g"], rows: [
            ["5", "a"], ["7", "a"], ["8", "a"], ["6", "a"],
            ["9", "b"], ["7", "b"], ["8", "b"], ["10", "b"],
        ])
        let outcome = ColumnReference(index: 0, name: "x")
        let grouping = ColumnReference(index: 1, name: "g")

        let oneSample = try AnalysisKernel.run(
            AnalysisStep(operation: .oneSampleT(column: outcome, testValue: 7)), on: scores).tables[0].rows[0]
        check(oneSample[0] == .count(8) && near(oneSample[4], 0.88191710368819687)
              && oneSample[5] == .count(7),
              "One-sample t matches t.test(x, mu = 7)")
        guard case .probability(let oneSampleP, _) = oneSample[6] else { fatalError("no p") }
        check(abs(oneSampleP - 0.40708382206558869) < 1e-10, "As does its p-value")
        check(near(oneSample[7], 6.159384061322843 - 7) && near(oneSample[8], 8.840615938677157 - 7),
              "And its interval, expressed around the tested value")

        let pairedTest = try AnalysisKernel.run(
            AnalysisStep(operation: .pairedT(first: ColumnReference(index: 0, name: "a"),
                                             second: ColumnReference(index: 1, name: "b"))),
            on: snapshot(columns: ["a", "b"], rows: [["5", "9"], ["7", "7"], ["8", "8"], ["6", "10"]])
        ).tables[0].rows[0]
        check(pairedTest[0] == .count(4) && near(pairedTest[4], -1.7320508075688774)
              && pairedTest[5] == .count(3),
              "Paired t matches t.test(a, b, paired = TRUE)")
        check(near(pairedTest[7], -5.6747724620741566) && near(pairedTest[8], 1.6747724620741571),
              "As does its interval")

        // Unequal n and spread, so Welch and pooled genuinely differ.
        let uneven = snapshot(columns: ["x", "g"], rows: [
            ["5", "a"], ["7", "a"], ["8", "a"], ["6", "a"], ["7", "a"],
            ["9", "b"], ["2", "b"], ["18", "b"], ["10", "b"], ["14", "b"], ["3", "b"],
        ])
        let welch = try AnalysisKernel.run(
            AnalysisStep(operation: .independentT(outcome: outcome, group: grouping, variance: .welch)),
            on: uneven)
        let welchRow = welch.tables[1].rows[0]
        check(near(welchRow[2], -1.0609165962055893) && near(welchRow[3], 5.4047472978668401),
              "Welch matches t.test(var.equal = FALSE), fractional df included")
        check(near(welchRow[5], -9.2097198094024115) && near(welchRow[6], 3.7430531427357443),
              "As does its interval")
        let pooled = try AnalysisKernel.run(
            AnalysisStep(operation: .independentT(outcome: outcome, group: grouping, variance: .pooled)),
            on: uneven).tables[1].rows[0]
        check(near(pooled[2], -0.96596196678643031) && near(pooled[3], 9),
              "Pooled matches t.test(var.equal = TRUE) and differs from Welch")
        check(welch.tables[0].rows[0][1] == .count(5) && welch.tables[0].rows[1][1] == .count(6),
              "Group descriptives report each group's n")
        let levene = welch.tables[2].rows[0]
        check(near(levene[0], 5.6771569792904995) && levene[1] == .count(1) && levene[2] == .count(9),
              "Levene's test matches an ANOVA on absolute deviations from the group means")
        check(welch.tables[2].caption?.contains("does not decide the test for you") == true,
              "And is offered as evidence, not as a rule")

        var wrongLevels = false
        do {
            _ = try AnalysisKernel.run(
                AnalysisStep(operation: .independentT(outcome: ColumnReference(index: 0, name: "y"),
                                                      group: ColumnReference(index: 1, name: "f"),
                                                      variance: .welch)),
                on: snapshot(columns: ["y", "f"], rows: [["1", "a"], ["2", "b"], ["3", "c"], ["4", "c"]]))
        } catch let error as CSVAnalysisError {
            wrongLevels = error.localizedDescription.contains("One-Way ANOVA")
        }
        check(wrongLevels, "Three groups refuses a t test and names the test that fits, rather than switching")

        let anova = try AnalysisKernel.run(
            AnalysisStep(operation: .oneWayANOVA(outcome: ColumnReference(index: 0, name: "y"),
                                                 factor: ColumnReference(index: 1, name: "f"))),
            on: snapshot(columns: ["y", "f"], rows: [
                ["5", "a"], ["7", "a"], ["8", "a"], ["6", "a"],
                ["9", "b"], ["7", "b"], ["8", "b"], ["10", "b"],
                ["12", "c"], ["11", "c"], ["13", "c"], ["12", "c"],
            ]))
        let between = anova.tables[1].rows[0]
        check(near(between[1], 61.999999999999936) && between[2] == .count(2)
              && near(between[4], 23.250000000000028),
              "One-way ANOVA matches summary(aov(y ~ f))")
        guard case .probability(let anovaP, _) = between[5] else { fatalError("no p") }
        check(abs(anovaP - 0.00027846644366968628) < 1e-10, "As does its p-value")
        check(near(anova.tables[1].rows[1][1], 11.999999999999973) && anova.tables[1].rows[1][2] == .count(9),
              "And its within-groups sum of squares and df")
        check(near(between[6], 61.999999999999936 / 73.99999999999991), "η² is the between share of total")
        // R: anova(lm(abs(y - ave(y, f)) ~ f)), Levene centred on the group means.
        let oneWayLevene = anova.tables[2]
        check(oneWayLevene.columns == ["F", "df1", "df2", "p"] && near(oneWayLevene.rows[0][0], 1.0000000000000009)
              && oneWayLevene.rows[0][1] == .count(2) && oneWayLevene.rows[0][2] == .count(9),
              "One-way ANOVA reports Levene's test across its groups")
        guard case .probability(let oneWayLeveneP, _) = oneWayLevene.rows[0][3] else { fatalError("no p") }
        check(abs(oneWayLeveneP - 0.4053444297059024) < 1e-10, "With R's p-value")

        // Unbalanced on purpose: Type III and sequential sums differ here, so a
        // kernel that reported anova()'s Type I would fail. Expected values are
        // R's drop1(lm(y ~ a * b, contrasts = contr.sum), . ~ ., test = "F").
        let twoWayRows: [[String]] = zip(
            [5, 7, 8, 6, 9, 7, 8, 10, 12, 11, 13, 12, 14, 6, 9, 4, 8, 11, 10, 13],
            ["lo", "lo", "lo", "lo", "lo", "lo", "lo", "lo", "mid", "mid", "mid", "mid", "mid",
             "hi", "hi", "hi", "hi", "hi", "hi", "hi"]
        ).enumerated().map { row, pair in
            [String(pair.0), pair.1, [0, 1, 2, 3, 4, 8, 9, 10, 13, 14, 15].contains(row) ? "p" : "q"]
        }
        let twoWayColumns = (y: ColumnReference(index: 0, name: "y"), a: ColumnReference(index: 1, name: "a"),
                             b: ColumnReference(index: 2, name: "b"))
        let twoWay = try AnalysisKernel.run(
            AnalysisStep(operation: .factorialANOVA(outcome: twoWayColumns.y, factors: [twoWayColumns.a, twoWayColumns.b])),
            on: snapshot(columns: ["y", "a", "b"], rows: twoWayRows))
        check(twoWay.title == "Two-way ANOVA — y by a × b", "A two-factor ANOVA is titled two-way")
        let twoWayCells = twoWay.tables[0]
        check(twoWayCells.columns == ["a", "b", "N", "Mean", "SD"] && twoWayCells.rows.count == 6
              && twoWayCells.rows[0][0] == .text("hi") && twoWayCells.rows[0][1] == .text("p")
              && twoWayCells.rows[0][2] == .count(3),
              "Every cell is described, in level order with the last factor fastest")
        let effects = twoWay.tables[1].rows
        check(effects.map { $0[0] } == [.text("a"), .text("b"), .text("a × b"), .text("Residual"), .text("Corrected total")],
              "The table lists both main effects, their interaction, the residual and the total")
        check(near(effects[0][1], 74.0574198359433069) && effects[0][2] == .count(2)
              && near(effects[0][4], 11.6932768162015677),
              "The first main effect matches R's Type III sum of squares and F")
        check(near(effects[1][1], 21.6666666666666643) && effects[1][2] == .count(1)
              && near(effects[1][4], 6.8421052631578894),
              "As does the second")
        check(near(effects[2][1], 9.7472035794183327) && effects[2][2] == .count(2)
              && near(effects[2][4], 1.5390321441186832),
              "And the interaction")
        let effectPs = effects.prefix(3).compactMap { row -> Double? in
            if case .probability(let p, _) = row[5] { return p } else { return nil }
        }
        check(effectPs.count == 3 && abs(effectPs[0] - 0.0010324956241000551) < 1e-10
              && abs(effectPs[1] - 0.0203440607394364051) < 1e-10 && abs(effectPs[2] - 0.2487858875565837624) < 1e-10,
              "With R's p-values")
        check(near(effects[3][1], 44.333333333333364) && effects[3][2] == .count(14)
              && near(effects[4][1], 154.54999999999995) && effects[4][2] == .count(19),
              "The residual and corrected total match too")
        check(near(effects[0][6], 74.0574198359433069 / (74.0574198359433069 + 44.333333333333364)),
              "Partial η² is the effect over the effect plus the residual")
        check(near(twoWay.tables[2].rows[0][0], 0.55357142857142738),
              "Levene's test runs across the cells")
        check(twoWay.notes.contains { $0.contains("Type III") }, "Unequal cells say why the sums do not add up")

        var emptyCell = false
        do {
            _ = try AnalysisKernel.run(
                AnalysisStep(operation: .factorialANOVA(outcome: twoWayColumns.y, factors: [twoWayColumns.a, twoWayColumns.b])),
                on: snapshot(columns: ["y", "a", "b"], rows: twoWayRows.filter { !($0[1] == "mid" && $0[2] == "q") }))
        } catch let error as CSVAnalysisError {
            emptyCell = error.localizedDescription.contains("mid × q")
        }
        check(emptyCell, "A combination with no cases refuses the test and names it")
        var oneFactor = false
        do {
            _ = try AnalysisKernel.run(
                AnalysisStep(operation: .factorialANOVA(outcome: twoWayColumns.y, factors: [twoWayColumns.a])),
                on: snapshot(columns: ["y", "a", "b"], rows: twoWayRows))
        } catch let error as CSVAnalysisError {
            oneFactor = error.localizedDescription.contains("One-Way ANOVA")
        }
        check(oneFactor, "One factor is refused, naming the test that fits")
        let movedTwoWay = AnalysisStep(operation: .factorialANOVA(outcome: twoWayColumns.y, factors: [twoWayColumns.a, twoWayColumns.b]))
            .mappingColumns { ColumnReference(index: $0.index + 1, name: $0.name) }
        check(movedTwoWay.columns.map(\.index) == [1, 2, 3], "A two-way step follows its columns when they move")

        check(Distributions.inverseT(0.975, df: 10) - 2.2281388519862735 < 1e-10
              && abs(Distributions.inverseT(0.975, df: 1) - 12.706204736174692) < 1e-9
              && abs(Distributions.inverseT(0.975, df: 3.7) - 2.8675207071911917) < 1e-9,
              "The inverse t matches qt(), fractional df included")

        check(NotebookReport.text(.probability(0.0004, starred: false)) == "< .001"
              && NotebookReport.text(.probability(0.0426, starred: false)) == ".043"
              && NotebookReport.text(.probability(1)) == "1.000",
              "p-values print to APA convention")
        check(NotebookReport.text(.probability(0.0426)) == ".043*"
              && NotebookReport.text(.probability(0.009)) == ".009**"
              && NotebookReport.text(.probability(0.0004)) == "< .001***"
              && NotebookReport.text(.probability(0.0426, starred: false)) == ".043"
              && NotebookReport.text(.estimate(0.5, p: 0.2)) == "0.5000",
              "p-values carry significance stars, unless another column is the p to judge by")

        // A notebook written before significance testing must still open.
        let legacy = Data(#"{"version":1,"missingCodes":["NA"],"steps":[{"id":"\#(UUID())","operation":{"frequency":{"column":{"index":0,"name":"g"}}}}]}"#.utf8)
        let opened = try JSONDecoder().decode(AnalysisNotebookFile.self, from: legacy)
        check(opened.steps.first?.adjustment == .holm && opened.steps.first?.missing == .pairwise
              && opened.steps.first?.scope == .allRows,
              "A step saved before these fields existed adopts the current defaults")

        // MARK: Regression
        //
        // Expected values are R's, via summary(lm(y ~ x1 + x2)), confint(),
        // anova(), and diag(solve(cor(cbind(x1, x2)))) for the inflations.

        let regressionData = snapshot(columns: ["y", "x1", "x2"], rows: [
            ["52", "3", "11"], ["61", "5", "14"], ["48", "2", "9"], ["70", "8", "17"],
            ["66", "7", "16"], ["55", "4", "12"], ["73", "9", "19"], ["59", "5", "13"],
            ["64", "6", "15"], ["68", "7", "16"], ["57", "4", "12"], ["72", "8", "18"],
        ])
        let regressionStep = AnalysisStep(operation: .linearRegression(
            outcome: ColumnReference(index: 0, name: "y"),
            predictors: [RegressionPredictor(column: ColumnReference(index: 1, name: "x1")),
                         RegressionPredictor(column: ColumnReference(index: 2, name: "x2"))]))
        let fitted = try AnalysisKernel.run(regressionStep, on: regressionData)

        let modelSummary = fitted.tables[0].rows[0]
        check(modelSummary[0] == .count(12) && near(modelSummary[2], 0.9892464792354676)
              && near(modelSummary[3], 0.9868568079544604)
              && near(modelSummary[4], 0.92810394200563007),
              "Model summary matches summary(lm(y ~ x1 + x2))")

        let variance = fitted.tables[1].rows
        check(near(variance[0][1], 713.16427432216722) && variance[0][2] == .count(2)
              && near(variance[1][1], 7.75239234449751) && variance[1][2] == .count(9),
              "The regression ANOVA matches anova(lm(...))")
        check(near(variance[0][4], 413.96759759296918), "As does the model F")
        guard case .probability(let modelP, _) = variance[0][5] else { fatalError("no model p") }
        check(abs(modelP - 1.3866857454165045e-09) < 1e-20, "And its p-value, far into the tail")

        let coefficients = fitted.tables[2].rows
        check(coefficients[0][0] == .text("(Intercept)") && coefficients[1][0] == .text("x1"),
              "Coefficients are named, with the intercept first")
        check(near(coefficients[0][1], 30.6877990430621566) && near(coefficients[1][1], 1.4497607655502180)
              && near(coefficients[2][1], 1.6172248803827878),
              "Estimates match lm() to the digits R prints")
        check(near(coefficients[0][2], 5.3422661877737729) && near(coefficients[1][2], 1.1156473693116087)
              && near(coefficients[2][2], 0.8069600183745006),
              "As do the standard errors, taken from a QR rather than from XᵀX")
        check(near(coefficients[1][4], 1.2994793923502623), "As does t")
        guard case .probability(let slopeP, _) = coefficients[1][5] else { fatalError("no p") }
        check(abs(slopeP - 0.22607732413998454) < 1e-12, "As does its p-value")
        check(near(coefficients[1][6], -1.07400892209501131) && near(coefficients[1][7], 3.9735304531954476),
              "And the interval confint() gives")
        check(near(coefficients[1][3], 0.39185169123257912) && near(coefficients[2][3], 0.60432522901829733),
              "Standardized β is the coefficient in standard deviations")
        check(coefficients[0][3] == .missing, "The intercept has no standardized coefficient")
        check(near(coefficients[1][8], 76.102073365233792) && near(coefficients[2][8], 76.102073365233792),
              "VIF matches diag(solve(cor(predictors)))")
        check(fitted.notes.contains { $0.contains("variance inflation") },
              "And a high one is called out rather than left to be noticed")

        // Rank deficiency has to surface as rank deficiency.
        var collinear = false
        do {
            _ = try AnalysisKernel.run(AnalysisStep(operation: .linearRegression(
                outcome: ColumnReference(index: 0, name: "y"),
                predictors: [RegressionPredictor(column: ColumnReference(index: 1, name: "x1")),
                             RegressionPredictor(column: ColumnReference(index: 1, name: "x1"))])),
                on: regressionData)
        } catch let error as CSVAnalysisError {
            collinear = error.localizedDescription.contains("collinear")
        }
        check(collinear, "A duplicated predictor is refused rather than fitted")

        var selfPredicted = false
        do {
            _ = try AnalysisKernel.run(AnalysisStep(operation: .linearRegression(
                outcome: ColumnReference(index: 0, name: "y"),
                predictors: [RegressionPredictor(column: ColumnReference(index: 0, name: "y"))])),
                on: regressionData)
        } catch { selfPredicted = true }
        check(selfPredicted, "An outcome cannot also be its own predictor")

        // One predictor: the slope's t test is the correlation's, and no VIF exists.
        let simple = try AnalysisKernel.run(AnalysisStep(operation: .linearRegression(
            outcome: ColumnReference(index: 0, name: "y"),
            predictors: [RegressionPredictor(column: ColumnReference(index: 1, name: "x1"))])),
            on: regressionData)
        check(simple.tables[2].columns.count == 8,
              "A single predictor reports no variance inflation, having nothing to be inflated by")
        let simpleRow = simple.tables[2].rows[1]
        let correlated = try AnalysisKernel.run(AnalysisStep(adjustment: .none, operation: .correlation(
            columns: [ColumnReference(index: 0, name: "y"), ColumnReference(index: 1, name: "x1")],
            method: .pearson)), on: regressionData).tables[1].rows[0]
        guard case .probability(let regressionP, _) = simpleRow[5],
              case .probability(let correlationTestP, _) = correlated[6] else { fatalError("no p") }
        check(abs(regressionP - correlationTestP) < 1e-9,
              "A simple regression's slope test and the correlation's test are the same test")

        // Incomplete rows are dropped for the whole model, not per column.
        let gappy = snapshot(columns: ["y", "x1", "x2"], rows: [
            ["52", "3", "11"], ["61", "5", "14"], ["48", "", "9"], ["70", "8", "17"],
            ["66", "7", "16"], ["55", "4", "12"], ["73", "9", "19"], ["59", "5", "13"],
        ])
        let dropped = try AnalysisKernel.run(regressionStep, on: gappy)
        check(dropped.tables[0].rows[0][0] == .count(7)
              && dropped.notes.contains { $0.contains("incomplete across the outcome and predictors") },
              "A row missing any term leaves the model, and the count is reported")

        // MARK: Categorical predictors
        //
        // Expected values are R's, via summary(lm(y ~ x1 + f)) with f a factor,
        // confint(), anova(), and relevel(f, ref = "c").

        let withFactor = snapshot(columns: ["y", "x1", "f"], rows: [
            ["52", "3", "a"], ["61", "5", "b"], ["48", "2", "a"], ["70", "8", "c"],
            ["66", "7", "c"], ["55", "4", "b"], ["73", "9", "c"], ["59", "5", "a"],
            ["64", "6", "b"], ["68", "7", "c"], ["57", "4", "b"], ["72", "8", "c"],
        ])
        let scale = RegressionPredictor(column: ColumnReference(index: 1, name: "x1"))
        let factorColumn = ColumnReference(index: 2, name: "f")
        let dummied = try AnalysisKernel.run(AnalysisStep(operation: .linearRegression(
            outcome: ColumnReference(index: 0, name: "y"),
            predictors: [scale, RegressionPredictor(column: factorColumn, isCategorical: true)])),
            on: withFactor)

        let dummyTerms = dummied.tables[2].rows
        check(dummyTerms.count == 4,
              "A three-level factor contributes two indicators, not three")
        check(dummyTerms[2][0] == .text("f = b") && dummyTerms[3][0] == .text("f = c"),
              "Indicators are named for the level they carry")
        check(near(dummyTerms[0][1], 40.91190864600329746) && near(dummyTerms[1][1], 3.62642740619901938)
              && near(dummyTerms[2][1], 1.11256117455136616) && near(dummyTerms[3][1], 0.60195758564435808),
              "Estimates match lm(y ~ x1 + f) with a as the baseline")
        check(near(dummyTerms[2][2], 0.94649189990708116) && near(dummyTerms[3][2], 1.69003398054689846),
              "As do the indicator standard errors")
        check(near(dummyTerms[2][6], -1.0700530605716101) && near(dummyTerms[2][7], 3.2951754096743424),
              "And the intervals confint() gives")
        check(near(dummied.tables[0].rows[0][2], 0.987251141462962)
              && near(dummied.tables[0].rows[0][4], 1.0718479719814684),
              "As do R² and the residual standard error")
        check(near(dummied.tables[1].rows[0][1], 711.72580206633836) && dummied.tables[1].rows[0][2] == .count(3)
              && near(dummied.tables[1].rows[1][1], 9.190864600326293),
              "And the regression ANOVA, with the factor costing two degrees of freedom")
        check(dummied.notes.contains { $0.contains("dummy coded against “a”") },
              "The result names the baseline every coefficient is measured from")

        let relevelled = try AnalysisKernel.run(AnalysisStep(operation: .linearRegression(
            outcome: ColumnReference(index: 0, name: "y"),
            predictors: [scale, RegressionPredictor(column: factorColumn, isCategorical: true,
                                                    referenceLevel: "c")])), on: withFactor)
        check(near(relevelled.tables[2].rows[0][1], 41.513866231647661)
              && near(relevelled.tables[2].rows[2][1], -0.60195758564435697)
              && near(relevelled.tables[2].rows[3][1], 0.51060358890700897),
              "Choosing a different baseline matches relevel(f, ref = \"c\")")
        check(near(relevelled.tables[0].rows[0][2], 0.987251141462962),
              "The fit itself does not depend on which level is held out")
        check(relevelled.notes.contains { $0.contains("per indicator") },
              "Multi-level inflation factors are flagged as per indicator, not per variable")

        // The same column read as a number rather than as a factor is a different model.
        let asNumbers = snapshot(columns: ["y", "x1", "code"], rows: [
            ["52", "3", "1"], ["61", "5", "2"], ["48", "2", "1"], ["70", "8", "3"],
            ["66", "7", "3"], ["55", "4", "2"], ["73", "9", "3"], ["59", "5", "1"],
            ["64", "6", "2"], ["68", "7", "3"], ["57", "4", "2"], ["72", "8", "3"],
        ])
        let codeColumn = ColumnReference(index: 2, name: "code")
        let asScale = try AnalysisKernel.run(AnalysisStep(operation: .linearRegression(
            outcome: ColumnReference(index: 0, name: "y"),
            predictors: [scale, RegressionPredictor(column: codeColumn)])), on: asNumbers)
        let asFactor = try AnalysisKernel.run(AnalysisStep(operation: .linearRegression(
            outcome: ColumnReference(index: 0, name: "y"),
            predictors: [scale, RegressionPredictor(column: codeColumn, isCategorical: true)])),
            on: asNumbers)
        check(asScale.tables[2].rows.count == 3 && asFactor.tables[2].rows.count == 4,
              "A numeric-looking code entered as a factor is a different model than entered as a scale")

        var oneLevelFactor = false
        do {
            _ = try AnalysisKernel.run(AnalysisStep(operation: .linearRegression(
                outcome: ColumnReference(index: 0, name: "y"),
                predictors: [RegressionPredictor(column: ColumnReference(index: 1, name: "g"),
                                                 isCategorical: true)])),
                on: snapshot(columns: ["y", "g"], rows: [["1", "a"], ["2", "a"], ["3", "a"], ["4", "a"]]))
        } catch { oneLevelFactor = true }
        check(oneLevelFactor, "A factor with one level is refused rather than coded into nothing")

        var absentBaseline = false
        do {
            _ = try AnalysisKernel.run(AnalysisStep(operation: .linearRegression(
                outcome: ColumnReference(index: 0, name: "y"),
                predictors: [scale, RegressionPredictor(column: factorColumn, isCategorical: true,
                                                        referenceLevel: "z")])), on: withFactor)
        } catch let error as CSVAnalysisError {
            absentBaseline = error.localizedDescription.contains("a, b, c")
        }
        check(absentBaseline, "A baseline that is not a level fails and lists the ones that are")

        // MARK: The R script
        //
        // The emitted script is checked by running it. Structure assertions can
        // pass on code R would reject, so the real test is Rscript's exit status.

        let y = ColumnReference(index: 0, name: "y")
        let x = ColumnReference(index: 1, name: "x 1 (raw)")
        let fColumn = ColumnReference(index: 2, name: "f")
        let gColumn = ColumnReference(index: 3, name: "g")
        let scriptSteps: [AnalysisStep] = [
            AnalysisStep(operation: .describe(columns: [y, x])),
            AnalysisStep(operation: .frequency(column: fColumn)),
            AnalysisStep(operation: .crossTabulation(rows: fColumn, columns: gColumn)),
            AnalysisStep(operation: .chiSquareIndependence(rows: fColumn, columns: gColumn)),
            AnalysisStep(adjustment: .holm, operation: .correlation(columns: [y, x], method: .pearson)),
            AnalysisStep(missing: .listwise,
                         operation: .correlation(columns: [y, x], method: .spearman)),
            AnalysisStep(operation: .oneSampleT(column: y, testValue: 7)),
            AnalysisStep(operation: .independentT(outcome: y, group: gColumn, variance: .welch)),
            AnalysisStep(operation: .pairedT(first: y, second: x)),
            AnalysisStep(operation: .oneWayANOVA(outcome: y, factor: fColumn)),
            AnalysisStep(operation: .factorialANOVA(outcome: y, factors: [fColumn, gColumn])),
            AnalysisStep(operation: .linearRegression(outcome: y, predictors: [
                RegressionPredictor(column: x),
                RegressionPredictor(column: fColumn, isCategorical: true, referenceLevel: "b"),
            ])),
        ]
        let script = NotebookScript.r(
            steps: scriptSteps, missingCodes: ["NA"],
            sources: ["": NotebookScript.Source(frame: "data1", path: "data.csv")])

        check(script.hasPrefix("# %% Setup"), "The script opens with a setup cell")
        // Counted the way the editor parses them: a delimiter is a line that
        // starts with the marker, not any mention of it.
        let cells = script.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix(NotebookScript.cellMarker) }
        check(cells.count == scriptSteps.count + 1, "Every step becomes one cell, plus setup")
        check(script.contains("x_1_raw = as.numeric(data1[[2]])"),
              "A header that is not a valid identifier is read by position and renamed")
        check(script.contains("as.character(data1[[3]])"),
              "A column used as a factor is read as character, not coerced to a number")
        check(script.contains("relevel(factor(d$f), ref = \"b\")"),
              "The chosen baseline carries into the script")
        check(script.contains("lm(y ~ x_1_raw + f, data = d)"),
              "The model formula uses the renamed identifiers")
        check(script.contains("var.equal = FALSE"), "Welch carries into t.test")
        check(script.contains("p.adjust(raw, \"holm\")"), "So does the multiplicity adjustment")
        check(script.contains("use = \"complete.obs\"") && script.contains("use = \"pairwise.complete.obs\""),
              "And the missing policy, per step")
        check(script.contains("car::vif(model)"),
              "The regression cell points at the diagnostics the notebook does not do")
        check(script.contains("na.strings = missing"), "Declared missing codes reach read.csv")
        check(script.contains("lm(y ~ f * g, data = d,") && script.contains("contrasts = list(f = \"contr.sum\", g = \"contr.sum\")")
              && script.contains("drop1(model, . ~ ., test = \"F\")"),
              "A two-way ANOVA is written as R's Type III, matching the notebook")

        // A notebook with no steps still writes a usable script.
        let starter = NotebookScript.r(
            steps: [], missingCodes: [],
            sources: ["": NotebookScript.Source(frame: "data1", path: "data.csv")])
        check(starter.contains("read.csv(\"data.csv\"") && starter.contains("str(data1"),
              "An empty notebook still writes a script that loads the table")
        let starterCells = starter.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix(NotebookScript.cellMarker) }
        check(starterCells.count == 2, "With a setup cell and somewhere to start writing")

        let scriptRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scriptRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scriptRoot) }
        try Data("""
        y,x 1 (raw),f,g
        52,3,a,p
        61,5,b,q
        48,2,a,p
        70,8,c,q
        66,7,c,q
        55,4,b,p
        73,9,c,q
        59,5,a,q
        64,6,b,q
        68,7,c,p
        57,4,b,p
        72,8,c,q
        """.utf8).write(to: scriptRoot.appendingPathComponent("data.csv"))
        try Data(script.utf8).write(to: scriptRoot.appendingPathComponent("analysis.R"))

        if let rscript = locate("Rscript") {
            let run = Process()
            run.executableURL = rscript
            run.arguments = ["analysis.R"]
            run.currentDirectoryURL = scriptRoot
            let output = Pipe()
            run.standardOutput = output
            run.standardError = output
            try run.run()
            let produced = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            run.waitUntilExit()
            check(run.terminationStatus == 0,
                  "The generated script runs under Rscript without error")
            if run.terminationStatus != 0 { print(produced) }
            check(produced.contains("Pearson's Chi-squared test") && produced.contains("Welch")
                  && produced.contains("Coefficients") && produced.contains("Single term deletions"),
                  "And produces the analyses it was generated from")

            try Data(starter.utf8).write(to: scriptRoot.appendingPathComponent("starter.R"))
            let starterRun = Process()
            starterRun.executableURL = rscript
            starterRun.arguments = ["starter.R"]
            starterRun.currentDirectoryURL = scriptRoot
            starterRun.standardOutput = Pipe()
            starterRun.standardError = Pipe()
            try starterRun.run()
            starterRun.waitUntilExit()
            check(starterRun.terminationStatus == 0, "The empty-notebook script runs too")
        } else {
            print("SKIP: Rscript is not installed; the emitted script was not executed")
        }

        print(failures == 0 ? "All analysis checks passed" : "\(failures) analysis checks FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Harness

    /// Nil when the tool is absent, so the script check degrades to a skip on a
    /// machine without R rather than failing.
    nonisolated static func locate(_ tool: String) -> URL? {
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = [tool]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = Pipe()
        guard (try? which.run()) != nil else { return nil }
        let found = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        which.waitUntilExit()
        guard which.terminationStatus == 0, !found.isEmpty else { return nil }
        return URL(fileURLWithPath: found)
    }

    nonisolated static func snapshot(columns: [String], rows: [[String]]) -> CSVAnalysisSnapshot {
        CSVAnalysisSnapshot(table: CSVTable(columns: columns, rows: rows),
                            sourceRows: Array(rows.indices), columnTypes: [:])
    }

    nonisolated static func near(_ cell: AnalysisCell, _ expected: Double) -> Bool {
        switch cell {
        case .number(let value), .estimate(let value, _): return abs(value - expected) < 1e-9
        default: return false
        }
    }

    nonisolated(unsafe) static var failures = 0

    static func check(_ value: Bool, _ description: String) {
        if !value { failures += 1 }
        print("\(value ? "PASS" : "FAIL"): \(description)")
    }
}
