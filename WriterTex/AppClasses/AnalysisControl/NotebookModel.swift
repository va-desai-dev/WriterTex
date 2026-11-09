import Foundation
import Observation

/// Owns one notebook window's analysis: its steps, the datasets they read, and
/// the results they have produced so far.
///
/// Steps and datasets are document content: each change is written through to
/// the `.wrstatx` file and registered with Undo, which marks it edited.
/// Results are session values and are never saved, because a number saved
/// next to data that has since moved on is worse than no number at all.
@Observable
final class NotebookModel {


    private(set) var steps: [AnalysisStep] = []
    private(set) var results: [UUID: AnalysisResult] = [:]
    private(set) var failures: [UUID: String] = [:]
    private(set) var runningSteps: Set<UUID> = []
    /// File names of the datasets inside the notebook.
    private(set) var availableDatasets: [String] = []
    /// Bumped when a dataset's bytes change, so an open grid reloads.
    private(set) var datasetRevision = 0
    /// Variable types by dataset, then column, as the user set them. Saved with the notebook.
    private(set) var columnTypes: [String: [Int: CSVArrangement.VariableFlag]] = [:]
    /// The types the cells read as, for the columns the user hasn't typed.
    /// Never saved: they follow the cells and the missing codes.
    private(set) var inferredTypes: [String: [Int: CSVArrangement.VariableFlag]] = [:]
    /// Sort and filters by dataset. Session state like `results`: never saved
    /// and not undoable, because arranging a table doesn't edit it.
    private(set) var arrangements: [String: CSVArrangement.Rules] = [:]
    var errorMessage: String?

    /// Cell text that counts as missing rather than unusable, for every step.
    ///
    /// Every result in the notebook was computed under some vocabulary, so
    /// changing it invalidates all of them at once. Rather than leave stale
    /// numbers on screen labelled as current, the steps that have already run
    /// are run again.
    private(set) var missingCodes: [String] = ["NA"]

    func setMissingCodes(_ codes: [String]) {
        guard codes != self.missingCodes else { return }
        let previous = self.missingCodes
        self.change("Change Missing Values", undo: { $0.setMissingCodes(previous) }) {
            $0.notebook.missingCodes = codes
        }
    }

    private let file: NotebookFile
    /// The window's, so each change marks the notebook edited.
    @ObservationIgnored weak var undoManager: UndoManager?
    private var headerCache: [String: [String]] = [:]
    private var levelCache: [String: [String]] = [:]
    @ObservationIgnored private var rerun: Task<Void, Never>?
    @ObservationIgnored private var inference: [String: Task<Void, Never>] = [:]

    init(file: NotebookFile) {
        self.file = file
        self.sync()
        self.inferTypes(self.availableDatasets)
    }

    /// A column's type: the one the user set, or else the one its cells read as.
    func type(of column: Int, in dataset: String) -> CSVArrangement.VariableFlag? {
        self.columnTypes[dataset]?[column] ?? self.inferredTypes[dataset]?[column]
    }

    /// Reads the types of datasets whose cells may have changed, off the main
    /// actor. It reads them once the current edit is applied, and the old
    /// types show until it finishes, so nothing flickers to untyped.
    private func inferTypes(_ names: [String]) {
        for name in names {
            self.inference[name]?.cancel()
            self.inference[name] = Task {
                let data = self.file.package.datasets[name]
                let codes = Set(self.missingCodes)
                let types = await Task.detached(priority: .utility) {
                    data.flatMap { String(data: $0, encoding: .utf8) }.map { CSVEngine.parse($0).inferredTypes(missingCodes: codes) }
                }.value
                guard !Task.isCancelled else { return }
                self.inferredTypes[name] = types
                self.inference[name] = nil
            }
        }
    }

    /// Waits for type inference in flight, for callers that read types next.
    func typesInferred() async {
        while let task = self.inference.values.first { await task.value }
    }

    /// Writes one edit into the document and registers how to take it back.
    private func change(_ name: String, undo: @escaping (NotebookModel) -> Void,
                        _ edit: (inout NotebookPackage) -> Void) {
        let codes = self.file.package.notebook.missingCodes
        edit(&self.file.package)
        self.sync()
        self.undoManager?.registerUndo(withTarget: self, handler: undo)
        self.undoManager?.setActionName(name)
        if self.file.package.notebook.missingCodes != codes {
            self.inferTypes(self.availableDatasets)
            self.rerun?.cancel()
            self.rerun = Task { await self.rerunComputedSteps() }
        }
    }

    private func sync() {
        self.steps = self.file.package.notebook.steps
        self.missingCodes = self.file.package.notebook.missingCodes
        self.columnTypes = self.file.package.notebook.columnTypes
        self.availableDatasets = self.file.package.datasetNames
    }

    // MARK: Input

    /// The table a step reads: one of the notebook's datasets, picked in the composer.
    private func snapshot(for step: AnalysisStep) async throws -> CSVAnalysisSnapshot {
        guard !step.dataset.isEmpty else {
            throw CSVAnalysisError.datasetUnavailable("Choose a table for this step.")
        }
        return try await self.readDataset(step.dataset)
    }

    private func readDataset(_ name: String) async throws -> CSVAnalysisSnapshot {
        guard let data = self.file.package.datasets[name] else {
            throw CSVAnalysisError.datasetUnavailable("“\(name)” is no longer in this notebook.")
        }
        let table = try await Self.parse(data, named: name)
        return CSVAnalysisSnapshot(table: table, sourceRows: Array(table.rows.indices),
                                   columnTypes: (self.inferredTypes[name] ?? [:]).merging(self.columnTypes[name] ?? [:]) { $1 })
    }

    /// A dataset's table, for showing it in the grid.
    func table(for name: String) async throws -> CSVTable {
        guard let data = self.file.package.datasets[name] else {
            throw CSVAnalysisError.datasetUnavailable("“\(name)” is no longer in this notebook.")
        }
        return try await Self.parse(data, named: name)
    }

    private static func parse(_ data: Data, named name: String) async throws -> CSVTable {
        guard let text = String(data: data, encoding: .utf8) else {
            throw CSVAnalysisError.datasetUnavailable("“\(name)” is not UTF-8 text.")
        }
        let table = await Task.detached(priority: .userInitiated) { CSVEngine.parse(text) }.value
        guard !table.isEmpty else {
            throw CSVAnalysisError.datasetUnavailable("“\(name)” has no header row to read.")
        }
        return table
    }

    /// Column headers for the dataset picker, cached per dataset until it changes.
    func headers(for dataset: String) async -> [String] {
        if let cached = self.headerCache[dataset] { return cached }
        guard let snapshot = try? await self.readDataset(dataset) else { return [] }
        self.headerCache[dataset] = snapshot.table.columns
        return snapshot.table.columns
    }

    /// The distinct values of a column, for choosing a baseline level.
    ///
    /// Capped at the point where a column is plainly an identifier rather than a
    /// factor, so the composer never tries to list ten thousand of them.
    func levels(for dataset: String, column: Int) async -> [String] {
        let key = "\(dataset)#\(column)"
        if let cached = self.levelCache[key] { return cached }
        guard let snapshot = try? await self.readDataset(dataset),
              let values = try? snapshot.textColumn(at: column, missingCodes: Set(self.missingCodes))
        else { return [] }
        let levels = Set(values.values.compactMap { $0 })
        guard levels.count <= 200 else { return [] }
        let sorted = levels.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        self.levelCache[key] = sorted
        return sorted
    }

    // MARK: Datasets

    /// Copies CSV files into the notebook. A taken name gets a number, so an
    /// import never replaces a table. Returns what couldn't come in, and why.
    func importDatasets(_ urls: [URL]) async -> String? {
        var problems: [String] = []
        var added: [String: Data] = [:]
        for url in urls {
            let name = url.lastPathComponent
            let isScoped = url.startAccessingSecurityScopedResource()
            defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try await Task.detached { try Data(contentsOf: url, options: .mappedIfSafe) }.value
                guard data.count <= NotebookPackage.datasetByteLimit else {
                    throw CSVAnalysisError.datasetUnavailable("larger than the \(NotebookPackage.datasetByteLimit >> 20) MB limit")
                }
                _ = try await Self.parse(data, named: name)
                let taken = Set(self.availableDatasets).union(added.keys)
                guard taken.count < NotebookPackage.datasetLimit else {
                    throw CSVAnalysisError.datasetUnavailable("a notebook holds at most \(NotebookPackage.datasetLimit) datasets")
                }
                var fileName = Self.uniqueFileName(name, avoiding: taken)
                if !NotebookPackage.isDatasetName(fileName) { fileName = (fileName as NSString).deletingPathExtension + ".csv" }
                added[fileName] = data
            } catch {
                problems.append("“\(name)”: \(error.localizedDescription)")
            }
        }
        if !added.isEmpty { self.addDatasets(added) }
        return problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    /// `fileName`, or with a number before its extension when taken: "data.csv" → "data 2.csv".
    nonisolated static func uniqueFileName(_ fileName: String, avoiding taken: Set<String>) -> String {
        guard taken.contains(fileName) else { return fileName }
        let url = URL(fileURLWithPath: fileName)
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        func candidate(_ index: Int) -> String {
            ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
        }
        var index = 2
        while taken.contains(candidate(index)) { index += 1 }
        return candidate(index)
    }

    /// `types` puts back the variable types of datasets being restored by Undo.
    private func addDatasets(_ added: [String: Data],
                             types: [String: [Int: CSVArrangement.VariableFlag]] = [:]) {
        let names = Array(added.keys)
        self.change(added.count == 1 ? "Import Dataset" : "Import Datasets", undo: { $0.removeDatasets(names) }) {
            $0.datasets.merge(added) { _, new in new }
            $0.notebook.columnTypes.merge(types) { _, new in new }
        }
        self.inferTypes(names)
    }

    /// Steps that read a removed dataset stay, and report it when run. Its
    /// variable types go with it, so a later import under the same name starts clean.
    func removeDatasets(_ names: [String]) {
        let removed = self.file.package.datasets.filter { names.contains($0.key) }
        guard !removed.isEmpty else { return }
        let types = self.file.package.notebook.columnTypes.filter { names.contains($0.key) }
        self.forget(names)
        for name in names { self.arrangements[name] = nil }
        self.change(removed.count == 1 ? "Remove Dataset" : "Remove Datasets", undo: { $0.addDatasets(removed, types: types) }) {
            for name in names {
                $0.datasets[name] = nil
                $0.notebook.columnTypes[name] = nil
            }
        }
    }

    /// An analysis hint for one column; nil clears it. The CSV is untouched,
    /// so the grid doesn't reload and keeps its sort and filters.
    func setColumnType(_ type: CSVArrangement.VariableFlag?, column: Int, in name: String) {
        let previous = self.file.package.notebook.columnTypes[name]?[column]
        guard type != previous, column >= 0, self.file.package.datasets[name] != nil else { return }
        self.change("Change Variable Type", undo: { $0.setColumnType(previous, column: column, in: name) }) {
            $0.notebook.columnTypes[name, default: [:]][column] = type
            if $0.notebook.columnTypes[name]?.isEmpty == true { $0.notebook.columnTypes[name] = nil }
        }
    }

    /// One column's sort and filter, from either the grid's header or the inspector.
    func setRules(column: Int, direction: CSVArrangement.Direction?, filter: CSVArrangement.Filter, in name: String) {
        var rules = self.arrangements[name] ?? CSVArrangement.Rules()
        rules.set(column: column, direction: direction, filter: filter)
        self.arrangements[name] = rules == CSVArrangement.Rules() ? nil : rules
    }

    /// Edits made in the grid, written back as CSV.
    func updateDataset(_ name: String, to table: CSVTable) {
        guard let previous = self.file.package.datasets[name] else { return }
        let data = Data(CSVEngine.generate(from: table).utf8)
        guard data != previous else { return }
        self.setDataset(name, data)
    }

    /// A blank case at `row`, every cell empty.
    func insertRow(at row: Int, in name: String) {
        self.reshape(name, "Add Row") { table in
            table.rows.insert(Array(repeating: "", count: table.columns.count), at: min(max(row, 0), table.rows.count))
            return { $0 }
        }
    }

    func deleteRow(_ row: Int, in name: String) {
        self.reshape(name, "Delete Row") { table in
            guard table.rows.indices.contains(row) else { return nil }
            table.rows.remove(at: row)
            return { $0 }
        }
    }

    /// A blank variable at `column`, named "Untitled" or the next free number.
    /// Steps reading the columns after it follow them to their new place.
    func insertColumn(at column: Int, in name: String) {
        self.reshape(name, "Add Column") { table in
            let column = min(max(column, 0), table.columns.count)
            table.columns.insert(Self.uniqueFileName("Untitled", avoiding: Set(table.columns)), at: column)
            for row in table.rows.indices where table.rows[row].count >= column { table.rows[row].insert("", at: column) }
            return { $0.index >= column ? ColumnReference(index: $0.index + 1, name: $0.name) : $0 }
        }
    }

    /// Steps reading a deleted column are left pointing past the table, so
    /// running them names the missing variable instead of reading its neighbour.
    /// The last column stays: a CSV without a header row isn't a table.
    func deleteColumn(_ column: Int, in name: String) {
        self.reshape(name, "Delete Column") { table in
            guard table.columns.count > 1, table.columns.indices.contains(column) else { return nil }
            table.columns.remove(at: column)
            for row in table.rows.indices where table.rows[row].count > column { table.rows[row].remove(at: column) }
            let pastEnd = table.columns.count
            return { reference in
                switch reference.index {
                case column: ColumnReference(index: pastEnd, name: reference.name)
                case column...: ColumnReference(index: reference.index - 1, name: reference.name)
                default: reference
                }
            }
        }
    }

    /// Deletes several columns as one undoable edit, keeping at least one column.
    func deleteColumns(_ columns: Set<Int>, in name: String) {
        self.reshape(name, columns.count == 1 ? "Delete Column" : "Delete Columns") { table in
            let doomed = columns.filter { table.columns.indices.contains($0) }
            guard !doomed.isEmpty, doomed.count < table.columns.count else { return nil }
            // Highest first, so each removal leaves the remaining indexes in place.
            for column in doomed.sorted(by: >) {
                table.columns.remove(at: column)
                for row in table.rows.indices where table.rows[row].count > column { table.rows[row].remove(at: column) }
            }
            let pastEnd = table.columns.count
            return { reference in
                if doomed.contains(reference.index) { return ColumnReference(index: pastEnd, name: reference.name) }
                // Each deleted column before this one shifts it left by one.
                let shift = doomed.count { $0 < reference.index }
                return shift == 0 ? reference : ColumnReference(index: reference.index - shift, name: reference.name)
            }
        }
    }

    /// Steps reading the column take the new header, so it isn't reported as drift.
    func renameColumn(_ column: Int, to header: String, in name: String) {
        self.reshape(name, "Rename Column") { table in
            guard table.columns.indices.contains(column), table.columns[column] != header else { return nil }
            table.columns[column] = header
            return { $0.index == column ? ColumnReference(index: column, name: header) : $0 }
        }
    }

    // MARK: Compute and recode

    /// Writes `formula`'s value for every case into the column headed `target`,
    /// or a new one at the end. Throws when the formula can't be read, and
    /// changes nothing then.
    @discardableResult
    func compute(_ formula: String, into target: String, in name: String) throws -> DataTransform.Summary {
        var summary = DataTransform.Summary()
        try self.reshape(name, "Compute Variable") { table in
            let result = try DataTransform.compute(formula, in: table, missingCodes: Set(self.missingCodes))
            try DataTransform.write(result.cells, into: target, in: &table)
            summary = result.summary
            return { $0 }
        }
        return summary
    }

    /// Recodes `column` by `rules`. With no `target` the column itself changes
    /// and values no rule matches stay; otherwise they go blank in the column
    /// headed `target`, which is made at the end when there isn't one.
    func recode(_ column: Int, rules: [RecodeRule], into target: String?, in name: String) throws {
        try self.reshape(name, "Recode Variable") { table in
            guard table.columns.indices.contains(column) else { return nil }
            let cells = table.rows.map { column < $0.count ? $0[column] : "" }
            let recoded = DataTransform.recode(cells, rules: rules, missingCodes: Set(self.missingCodes), keepsUnmatched: target == nil)
            try DataTransform.write(recoded, into: target ?? table.columns[column], in: &table)
            return { $0 }
        }
    }

    /// Rewrites a dataset's shape, and the steps, variable types and rules that
    /// read it, as one undoable edit, then reloads the grid, which didn't make
    /// the change itself. `edit` returns how a column reference follows the
    /// change, or nil to change nothing.
    private func reshape(_ name: String, _ action: String,
                         _ edit: (inout CSVTable) throws -> ((ColumnReference) -> ColumnReference)?) rethrows {
        guard let text = self.file.package.datasets[name].flatMap({ String(data: $0, encoding: .utf8) }) else { return }
        var table = CSVEngine.parse(text)
        guard !table.isEmpty, let columns = try edit(&table) else { return }
        // A deleted column maps past the end of the table; its type and rules are dropped there.
        let position: (Int) -> Int? = { column in
            let index = columns(ColumnReference(index: column, name: "")).index
            return index < table.columns.count ? index : nil
        }
        var notebook = self.file.package.notebook
        notebook.steps = notebook.steps.map { $0.dataset == name ? $0.mappingColumns(columns) : $0 }
        if let types = notebook.columnTypes[name] {
            var moved: [Int: CSVArrangement.VariableFlag] = [:]
            for (column, type) in types {
                if let index = position(column) { moved[index] = type }
            }
            notebook.columnTypes[name] = moved.isEmpty ? nil : moved
        }
        let rules = self.arrangements[name]?.mappingColumns(position)
        self.setDataset(name, Data(CSVEngine.generate(from: table).utf8), notebook: notebook, rules: rules, action: action)
        self.datasetRevision += 1
    }

    /// `notebook` replaces the steps and variable types along with the bytes,
    /// and `rules` the arrangement, for edits that move columns out from under them.
    private func setDataset(_ name: String, _ data: Data, notebook: AnalysisNotebookFile? = nil,
                            rules: CSVArrangement.Rules? = nil, action: String = "Edit Dataset") {
        guard let previous = self.file.package.datasets[name] else { return }
        let previousNotebook = notebook.map { _ in self.file.package.notebook }
        let previousRules = self.arrangements[name]
        self.forget([name])
        self.change(action, undo: {
            $0.setDataset(name, previous, notebook: previousNotebook, rules: previousRules, action: action)
            $0.datasetRevision += 1
        }) {
            $0.datasets[name] = data
            if let notebook { $0.notebook = notebook }
        }
        // Rules aren't undoable on their own, but they ride along with a
        // reshape so undoing it puts each one back on its column.
        if notebook != nil { self.arrangements[name] = rules }
    }

    private func forget(_ names: [String]) {
        self.inferTypes(names)
        for name in names { self.headerCache[name] = nil }
        self.levelCache = self.levelCache.filter { key, _ in !names.contains { key.hasPrefix($0 + "#") } }
    }

    // MARK: Steps

    func add(_ step: AnalysisStep) {
        self.change("Add Step", undo: { $0.remove(step.id) }) { $0.notebook.steps.append(step) }
        Task { await self.run(step) }
    }

    func remove(_ id: UUID) {
        guard let index = self.steps.firstIndex(where: { $0.id == id }) else { return }
        let step = self.steps[index]
        self.results[id] = nil
        self.failures[id] = nil
        self.change("Remove Step", undo: { $0.insert(step, at: index) }) { $0.notebook.steps.remove(at: index) }
    }

    private func insert(_ step: AnalysisStep, at index: Int) {
        self.change("Add Step", undo: { $0.remove(step.id) }) {
            $0.notebook.steps.insert(step, at: min(index, $0.notebook.steps.count))
        }
    }

    // MARK: Running

    func run(_ step: AnalysisStep) async {
        self.runningSteps.insert(step.id)
        defer { self.runningSteps.remove(step.id) }
        self.failures[step.id] = nil
        do {
            let snapshot = try await self.snapshot(for: step)
            let codes = Set(self.missingCodes)
            let result = try await Task.detached(priority: .userInitiated) {
                try AnalysisKernel.run(step, on: snapshot, missingCodes: codes)
            }.value
            self.results[step.id] = result
        } catch is CancellationError {
        } catch {
            self.results[step.id] = nil
            self.failures[step.id] = error.localizedDescription
        }
    }

    func runAll() async {
        for step in self.steps { await self.run(step) }
    }

    /// Steps that have produced a result or an error already. A step never run
    /// stays that way — recomputing the vocabulary is not a reason to start it.
    private func rerunComputedSteps() async {
        for step in self.steps where self.results[step.id] != nil || self.failures[step.id] != nil {
            if Task.isCancelled { return }
            await self.run(step)
        }
    }

    var success: Bool {
        if failures.isEmpty {
            return true
        }
        return false
    }

    // MARK: Output

    /// The notebook's steps as an R script, reading each dataset where it sits
    /// inside the saved package at `notebookURL`.
    func rScript(notebookURL: URL?) throws -> String {
        guard let notebookURL else {
            throw CSVAnalysisError.datasetUnavailable("Save the notebook first, so the script has datasets to read.")
        }
        guard !self.steps.isEmpty else {
            throw CSVAnalysisError.datasetUnavailable("Add a step before writing a script.")
        }
        guard !self.steps.contains(where: \.dataset.isEmpty) else {
            throw CSVAnalysisError.datasetUnavailable("Choose a table for every step before writing a script.")
        }
        // Each distinct dataset becomes one data frame.
        var sources: [String: NotebookScript.Source] = [:]
        for (index, dataset) in Set(self.steps.map(\.dataset)).sorted().enumerated() {
            let path = notebookURL.appending(path: NotebookPackage.datasetsName).appending(path: dataset).path
            sources[dataset] = NotebookScript.Source(frame: "data\(index + 1)", path: path)
        }
        return NotebookScript.r(steps: self.steps, missingCodes: self.missingCodes, sources: sources)
    }

    /// The results as they stand, as a Markdown report.
    var report: String {
        NotebookReport.markdown(steps: self.steps, results: self.results,
                                failures: self.failures, missingCodes: self.missingCodes)
    }

    /// The results as they stand, as a new WriterTex manuscript titled `title`.
    func manuscript(titled title: String) throws -> Data {
        try ManuscriptDocument.encode(NotebookManuscript.document(
            title: title, steps: self.steps, results: self.results,
            failures: self.failures, missingCodes: self.missingCodes))
    }

    /// Puts a step's result on the pasteboard, ready to paste into a manuscript.
    func copyResult(of step: AnalysisStep) -> Bool {
        guard let result = self.results[step.id],
              let position = self.steps.firstIndex(where: { $0.id == step.id }) else {
            return false
        }

        do {
            try NotebookManuscript.copy(step, number: position + 1, result: result)
            return true // Success!
        } catch {
            self.errorMessage = error.localizedDescription
            return false // Failed
        }
    }

    // 2. Update didCopy to call it and return the result
    func didCopy(of step: AnalysisStep) async -> Bool {
        // Run the copy operation on the main actor if it modifies @Published properties
        return copyResult(of: step)
    }

    /// Writes `text` where the user chose in a save panel.
    func write(_ text: String, to url: URL) async {
        await self.write(Data(text.utf8), to: url)
    }

    /// Writes the results as a manuscript at `url`. False, with the reason in
    /// `errorMessage`, when nothing was written.
    func writeManuscript(titled title: String, to url: URL) async -> Bool {
        do { return await self.write(try self.manuscript(titled: title), to: url) }
        catch { self.errorMessage = error.localizedDescription; return false }
    }

    @discardableResult private func write(_ data: Data, to url: URL) async -> Bool {
        do {
            try await Task.detached { try data.write(to: url, options: .atomic) }.value
            return true
        } catch {
            self.errorMessage = error.localizedDescription
            return false
        }
    }
}
