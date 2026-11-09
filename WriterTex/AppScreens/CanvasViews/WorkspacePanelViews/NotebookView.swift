import SwiftUI

/// The notebook pane. Presentation only: it builds `AnalysisStep` values and
/// renders `AnalysisResult` values, and never computes a statistic itself.
struct NotebookView: View {
    @Bindable var model: NotebookModel
    @State private var composing: AnalysisOperationKind?
    @State private var mutating: DataMutation?
    /// Where the notebook is saved; its R script reads the datasets there.
    var notebookURL: URL?

    var body: some View {
        Group {
            if model.steps.isEmpty {
                ContentUnavailableView {
                    Label("No Analysis Steps", systemImage: "function")
                } description: {
                    Text("Add a step to summarize, tabulate or correlate one of this notebook’s datasets. Steps are saved in the notebook; results are recomputed.")
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(model.steps) { step in
                            NotebookStepCard(model: model, step: step)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .paneBar(.top) {
            PaneBar {
                NotebookTitle(model: model)
                Spacer()
                NotebookAddStepMenu(model: model, onMutate: { mutating = $0 }) { composing = $0 }
                NotebookActions(model: model, notebookURL: notebookURL)
            }
        }
        .sheet(item: $composing) { kind in
            NotebookStepComposer(model: model, kind: kind) { step in
                model.add(step)
                composing = nil
            }
        }
        .sheet(item: $mutating) { DataMutationSheet(model: model, kind: $0) }
        .alert("Notebook", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: { Text(model.errorMessage ?? "") }
    }
}

/// The title, or a note that there's nothing to analyze yet.
struct NotebookTitle: View {
    let model: NotebookModel

    var body: some View {
        Text("Notebook").font(.headline)
        if model.availableDatasets.isEmpty {
            Text("No Data Loaded")
                .foregroundStyle(Color.diffRemoved)
                .help("Import CSV files in the sidebar to analyze them here.")
        }
    }
}

/// Every operation, grouped by family. Picking one hands its kind to whoever
/// presents the composer.
struct NotebookAddStepMenu: View {
    let model: NotebookModel
    let onMutate: (DataMutation) -> Void
    let onPick: (AnalysisOperationKind) -> Void

    var body: some View {
        DynamicLiquidGlassStrip {
            Button { Task { await model.runAll() } } label: {
                Label("Run All", systemImage: "play.fill")
            }
            .buttonStyle(.glassSegment)
            .disabled(model.steps.isEmpty || !model.runningSteps.isEmpty)
            .help(model.steps.isEmpty
                  ? "Add a step to run"
                  : "Recompute every step against its table")
            Menu {
                Section("Transform") {
                    ForEach(DataMutation.allCases) { mutation in
                        Button(mutation.rawValue + "…") { onMutate(mutation) }
                    }
                }
                ForEach(AnalysisOperationKind.Family.allCases) { family in
                    Section(family.rawValue) {
                        ForEach(AnalysisOperationKind.allCases.filter { $0.family == family }) { kind in
                            Button(kind.title) { onPick(kind) }
                        }
                    }
                }
            } label: {
                Label("Add New", systemImage: "plus")
            }
            .menuIndicator(.hidden)
            .menuStyle(.button)
            .buttonStyle(.glassSegment)
            .disabled(model.availableDatasets.isEmpty)
        }
    }
}

/// Export the results, as a manuscript or a report, or the steps as a script.
/// Saving is the File menu's.
struct NotebookActions: View {
    let model: NotebookModel
    let notebookURL: URL?

    var body: some View {
        DynamicLiquidGlassStrip {
            Menu {
                Button("Export to New Manuscript…") { exportManuscript() }
                Button("Export as Markdown Report…") { export(model.report, as: "Results.md") }
            } label: {
                Label("Export Results", systemImage: "square.and.arrow.up")
            }
            .menuIndicator(.hidden)
            .menuStyle(.button)
            .buttonStyle(.glassSegment)
            .disabled(model.results.isEmpty)
            .help(model.results.isEmpty ? "Run a step to have results to export" : "Save these results as a manuscript or a Markdown report")
            Button {
                do { export(try model.rScript(notebookURL: notebookURL), as: "Analysis.R") }
                catch { model.errorMessage = error.localizedDescription }
            } label: {
                Label("Export R Script", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .buttonStyle(.glassSegment)
            .disabled(model.steps.isEmpty)
            .help("Save the steps as an R script that reads this notebook’s datasets")
        }
    }

    /// Saves the results as a `.wrtx` and opens it in its own manuscript window.
    private func exportManuscript() {
        let title = notebookURL.map { "\($0.deletingPathExtension().lastPathComponent) Results" } ?? "Analysis Results"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.writerTexManuscript]
        panel.nameFieldStringValue = "\(title).wrtx"
        panel.directoryURL = notebookURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard await model.writeManuscript(titled: title, to: url) else { return }
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { model.errorMessage = error.localizedDescription }
            }
        }
    }

    private func export(_ text: String, as name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.directoryURL = notebookURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.write(text, to: url) }
    }
}

/// The operations the composer can build, grouped the way a statistics package
/// groups them. Kept apart from `AnalysisOperation` because that one carries its
/// columns and this one is only a menu choice.
///
/// Each entry is one named test. Nothing here inspects the data and decides on
/// the user's behalf whether they meant a t-test, an ANOVA or a test of
/// independence — choosing that is the analysis.
enum AnalysisOperationKind: String, CaseIterable, Identifiable {
    case describe, frequency, crossTabulation
    case oneSampleT, independentT, pairedT, oneWayANOVA, twoWayANOVA
    case correlation
    case linearRegression
    case chiSquareIndependence

    var id: String { self.rawValue }

    enum Family: String, CaseIterable, Identifiable {
        case describe = "Descriptives"
        case compareMeans = "Compare Means"
        case correlate = "Correlate"
        case regression = "Regression"
        case categorical = "Categorical"

        var id: String { self.rawValue }
    }

    var family: Family {
        switch self {
            case .describe, .frequency, .crossTabulation: .describe
            case .oneSampleT, .independentT, .pairedT, .oneWayANOVA, .twoWayANOVA: .compareMeans
            case .correlation: .correlate
            case .linearRegression: .regression
            case .chiSquareIndependence: .categorical
        }
    }

    var title: String {
        switch self {
            case .describe: "Descriptive Statistics…"
            case .frequency: "Frequency Table…"
            case .crossTabulation: "Cross-Tabulation…"
            case .oneSampleT: "One-Sample T Test…"
            case .independentT: "Independent-Samples T Test…"
            case .pairedT: "Paired-Samples T Test…"
            case .oneWayANOVA: "One-Way ANOVA…"
            case .twoWayANOVA: "Two-Way ANOVA…"
            case .correlation: "Correlation Matrix…"
            case .linearRegression: "Linear Regression…"
            case .chiSquareIndependence: "Chi-Square Test of Independence…"
        }
    }

    /// What the step reads, in the order it reads them. The composer shows
    /// these as its right-hand side, whatever their number or size.
    var roles: [StepRole] {
        switch self {
            case .describe: [.many("Variables")]
            case .correlation: [.many("Variables", atLeast: 2)]
            case .frequency, .oneSampleT: [.one("Variable")]
            case .crossTabulation, .chiSquareIndependence: [.one("Rows"), .one("Columns")]
            case .independentT: [.one("Outcome"), .one("Groups")]
            case .pairedT: [.one("First"), .one("Second")]
            case .oneWayANOVA: [.one("Outcome"), .one("Factor")]
            case .twoWayANOVA: [.one("Outcome"), StepRole(label: "Factors", count: 2...2)]
            case .linearRegression: [.one("Outcome"), .many("Predictors", codesLevels: true)]
        }
    }

    var needsTestValue: Bool { self == .oneSampleT }
}

// MARK: - One step and its result

private struct NotebookStepCard: View {
    @Bindable var model: NotebookModel
    let step: AnalysisStep
    @State private var isCopied = false

    @State private var didDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(step.title).font(.headline)
                Spacer()
                if model.runningSteps.contains(step.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Run", systemImage: "play.fill") { Task { await model.run(step) } }
                        .buttonStyle(.glassButton)
                        .labelStyle(.iconOnly)
                }
                Button {
                    Task {
                        let success = await model.didCopy(of: step)
                        if success {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                isCopied = true
                            }
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            withAnimation {
                                isCopied = false
                            }
                        }
                    }
                } label: {
                    Label("Copy Step's Results", systemImage: isCopied ? "checkmark" : "document.on.document")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.glassButton)
                .labelStyle(.iconOnly)
                .disabled(model.results[step.id] == nil || model.failures[step.id] != nil)
                .help("Copy this result to paste into a manuscript, a document or a spreadsheet")

                Button {
                    model.remove(step.id)
                } label: {
                    Label("Remove", systemImage: didDelete ? "trash.fill" : "trash")
                }
                .buttonStyle(.glassButton)
                .labelStyle(.iconOnly)
            }
            if let failure = model.failures[step.id] {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.orange)
                    .font(.callout)
            } else if let result = model.results[step.id] {
                self.summary(result.input)
                ForEach(result.notes, id: \.self) { note in
                    Text(note).font(.callout).foregroundStyle(.secondary)
                }
                ForEach(result.tables) { table in
                    AnalysisTableView(table: table)
                }
            } else {
                Text("Not run yet.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.foreground.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    /// What the numbers were computed from, so a result stays readable after the
    /// table underneath it has moved on.
    private func summary(_ input: AnalysisInputSummary) -> some View {
        Text("\(input.datasetLabel) · \(input.scope.label) · \(input.rowCount) rows · \(step.missing.rawValue) · data \(input.fingerprint) read at \(input.capturedAt.formatted(date: .omitted, time: .standard))")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// A result table. Long tables are cut off on screen and complete in the export,
/// because 500 rows of frequencies is a file, not a pane.
private struct AnalysisTableView: View {
    static let displayLimit = 200
    let table: AnalysisResultTable

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let caption = table.caption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                    GridRow {
                        ForEach(Array(table.columns.enumerated()), id: \.offset) { _, column in
                            Text(column).bold()
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(table.rows.prefix(Self.displayLimit).enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(NotebookReport.text(cell))
                                    .monospacedDigit()
                                    .foregroundStyle(cell == .missing ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                            }
                        }
                    }
                }
                .font(.callout)
                .padding(.vertical, 4)
            }
            if let legend = NotebookReport.legend(for: table) {
                Text(legend).font(.caption).foregroundStyle(.secondary)
            }
            if table.rows.count > Self.displayLimit {
                Text("Showing \(Self.displayLimit) of \(table.rows.count) rows — export for the rest.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Which cell text counts as missing. Commits on Return or when focus leaves.
struct NotebookMissingCodesField: View {
    @Bindable var model: NotebookModel
    @State private var missingCodesField = ""
    @FocusState private var isEditingCodes: Bool

    var body: some View {
        Text("Missing Data Codes")
            .foregroundStyle(.secondary)
        TextField("NA", text: $missingCodesField)
            .focusEffectDisabled()
            .textFieldStyle(.plain)
            .foregroundStyle(Color.foreground)
            .frame(maxWidth: 260)
            .focused($isEditingCodes)
            .onSubmit { self.commitCodes() }
        // Clicking away is how a field in a status bar is usually
        // left, so losing focus commits rather than discarding.
            .onChange(of: isEditingCodes) { _, editing in if !editing { self.commitCodes() } }
            .help("Cell text that counts as missing rather than unusable. Blanks always count. N/A is not included by default, because it usually marks a meaningful skip rather than absent data. Changing this re-runs the steps that have already run.")
            .onChange(of: model.missingCodes, initial: true) {
                missingCodesField = model.missingCodes.joined(separator: ", ")
            }
    }

    private func commitCodes() {
        model.setMissingCodes(missingCodesField
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
    }
}

// MARK: - Composing a step

/// The table a sheet works on, as the glass menu in its top bar.
struct NotebookDatasetMenu: View {
    let model: NotebookModel
    @Binding var dataset: String

    var body: some View {
        Menu {
            Picker("Table", selection: $dataset) {
                ForEach(model.availableDatasets, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Text(dataset.isEmpty ? "Select Table" : dataset)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(Color.secondary)
            }
            .padding(.horizontal, 6)
        }
        .menuStyle(.button)
        .buttonStyle(.glassTitleButton)
    }
}

/// A variable by its header, with its type's glyph.
struct NotebookVariableLabel: View {
    let model: NotebookModel
    let dataset: String
    let index: Int
    let header: String

    var body: some View {
        Label(header.isEmpty ? "Column \(index + 1)" : header,
              systemImage: model.type(of: index, in: dataset)?.icon ?? "questionmark")
    }
}

/// A variable to pick: a checkmark and a light highlight once it is picked.
///
/// With a `dragPayload` the row can also be dragged out. It is then a tapped
/// view rather than a button, because a button takes the mouse-down and a drag
/// never starts.
struct NotebookVariableButton: View {
    let model: NotebookModel
    let dataset: String
    let index: Int
    let icon: String
    let header: String
    let isPicked: Bool
    var dragPayload: String? = nil
    let action: () -> Void

    var body: some View {
        if let dragPayload {
            self.row
                .onTapGesture(perform: action)
                .draggable(dragPayload)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(isPicked ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction(.default, action)
        } else {
            Button(action: action) { self.row }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isPicked ? .isSelected : [])
        }
    }

    private var row: some View {
        HStack {
            NotebookVariableLabel(model: model, dataset: dataset, index: index, header: header)
            Spacer()
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .opacity(isPicked ? 1 : 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .contentShape(.rect)
        .background(isPicked ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }
}

struct NotebookStepComposer: View {
    @Bindable var model: NotebookModel
    let kind: AnalysisOperationKind
    let onAdd: (AnalysisStep) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var dataset = ""
    @State private var missing = MissingPolicy.pairwise
    @State private var method = CorrelationMethod.pearson
    @State private var adjustment = PValueAdjustment.holm
    @State private var variance = VarianceAssumption.welch
    @State private var testValue = "0"
    @State private var headers: [String] = []
    /// The variables each of the step's roles reads, in order.
    @State private var assignment: StepRoleAssignment
    /// Variables the user declared categorical in a role that codes levels,
    /// and the baseline each is coded against.
    @State private var categorical: Set<Int> = []
    @State private var baselines: [Int: String] = [:]
    @State private var levels: [Int: [String]] = [:]
    /// The role a drag is over, for its highlight.
    @State private var dropTarget: Int?
    @State private var loadedDataset: String?

    /// `assignment` opens the sheet with its roles already filled, as editing
    /// a step would; it must be built from `kind.roles`.
    init(model: NotebookModel, kind: AnalysisOperationKind, assignment: StepRoleAssignment? = nil,
         onAdd: @escaping (AnalysisStep) -> Void) {
        self.model = model
        self.kind = kind
        self.onAdd = onAdd
        self._assignment = State(initialValue: assignment ?? StepRoleAssignment(kind.roles))
    }

    var body: some View {
        HStack(alignment: .top) {
            self.columnSelection
            VStack(alignment: .leading, spacing: 10) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(assignment.roles.enumerated()), id: \.offset) { role, _ in
                            self.roleSection(role)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                Text(self.hint).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .focusEffectDisabled()
        .paneBar(.bottom) {
            PaneBar(edge: .bottom) {
                Button("Cancel", role: .cancel) { dismiss() }
                    .glassButtonStyle()
                Spacer()
                Button("Add Step") { onAdd(self.makeStep()) }
                    .glassButtonStyle(prominent: true)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!self.isValid)
            }
        }
        .paneBar(.top) {
            PaneBar(showsDivider: false) {
                Text(kind.title.replacingOccurrences(of: "…", with: "")).font(.title3).bold()
                Spacer()
                NotebookDatasetMenu(model: model, dataset: $dataset)
            } accessory: {
                PaneBar(showsDivider: true) {
                    self.options
                }
            }
        }
        .presentationSizing(.page)
        .padding()
        .presentationBackground(AppTheme.shared.windowBackground)
        .onAppear {
            if dataset.isEmpty, let first = model.availableDatasets.first { dataset = first }
        }
        .task(id: dataset) {
            headers = await model.headers(for: dataset)
            // The roles the sheet opened with belong to its first table; a
            // different table's columns start them over.
            if let loadedDataset, !loadedDataset.isEmpty, loadedDataset != dataset {
                assignment = StepRoleAssignment(kind.roles)
                categorical = []
                baselines = [:]
                levels = [:]
            }
            loadedDataset = dataset
        }
    }

    /// The step's settings, each only where it applies.
    @ViewBuilder private var options: some View {
        Picker("Missing", selection: $missing) {
            ForEach(MissingPolicy.allCases) { Text($0.rawValue).tag($0) }
        }
        Spacer()
        if kind == .independentT {
            Picker("Variances", selection: $variance) {
                ForEach(VarianceAssumption.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Welch does not assume the groups share a variance and is the safer default. Levene's test is reported either way.")
        }
        if kind.needsTestValue {
            TextField("Test Value", text: $testValue, prompt: Text("0"))
                .focusEffectDisabled()
                .help("The value the mean is compared against, H₀: μ = this.")
        }
        if kind == .correlation {
            Picker("Method", selection: $method) {
                ForEach(CorrelationMethod.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            Picker("Adjust p", selection: $adjustment) {
                ForEach(PValueAdjustment.allCases) { Text($0.rawValue).tag($0) }
            }
            .help("Every pair of variables is a separate test. Holm controls the family-wise error rate; Benjamini–Hochberg controls the false discovery rate.")
        }
    }

    // MARK: Roles

    /// A variable's position in a role that reads a list, in the order the
    /// step reads them.
    @ViewBuilder private func positionLabel(_ position: Int) -> some View {
        Text("\(position + 1)")
            .font(.caption)
            .monospacedDigit()
            .frame(minWidth: 12)
            .padding(4)
            .foregroundStyle(.foreground)
            .background {
                Circle()
                    .stroke(Color.accentColor)
                    .fill(Color.accentColor.opacity(0.32))
            }
    }

    /// One role: its name, how many it takes, and the variables in it. The
    /// highlighted role is filled by the next click in the variable list, and
    /// any role takes a variable dropped on it.
    @ViewBuilder private func roleSection(_ role: Int) -> some View {
        let spec = assignment.roles[role]
        let columns = assignment.columns[role]
        let isActive = assignment.active == role
        VStack(alignment: .leading, spacing: 4) {
            Button { assignment.active = role } label: {
                HStack {
                    Text(spec.label).bold().foregroundStyle(Color.foreground)
                    Spacer()
                    Text(self.capacity(spec)).font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isActive ? .isSelected : [])

            if columns.isEmpty {
                Text(spec.takesSeveral ? "Click or drag variables here…" : "Click or drag a variable here…")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
            ForEach(Array(columns.enumerated()), id: \.element) { position, column in
                self.roleRow(column, at: position, in: role)
            }
        }
        .padding(8)
        .contentShape(.rect)
        .onTapGesture { assignment.active = role }
        .background(isActive || dropTarget == role ? Color.accentColor.opacity(0.15) : Color.foreground.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 8))
        .dropDestination(for: String.self) { items, _ in
            self.drop(items, in: role, at: nil)
        } isTargeted: { dropTarget = $0 ? role : (dropTarget == role ? nil : dropTarget) }
    }

    /// One variable in a role. It can be dragged to another position or role,
    /// moved from its menu, or taken out.
    @ViewBuilder private func roleRow(_ column: Int, at position: Int, in role: Int) -> some View {
        let spec = assignment.roles[role]
        let count = assignment.columns[role].count
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if spec.takesSeveral { self.positionLabel(position) }
                if headers.indices.contains(column) {
                    NotebookVariableLabel(model: model, dataset: dataset, index: column, header: headers[column])
                        .foregroundStyle(Color.foreground)
                }
                Spacer()
                if spec.codesLevels {
                    Toggle("Categorical", isOn: Binding(
                        get: { categorical.contains(column) },
                        set: { isOn in
                            if isOn { categorical.insert(column) } else { categorical.remove(column) }
                            if isOn, levels[column] == nil { self.loadLevels(column) }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .help("Enter this column as a set of indicators rather than as a number.")
                }
                Button("Remove", systemImage: "minus.circle") { assignment.remove(column) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Take this variable out of \(spec.label)")
            }
            if spec.codesLevels, categorical.contains(column) {
                self.baselinePicker(column)
            }
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
        .draggable(Self.payload(column))
        .dropDestination(for: String.self) { items, _ in
            return self.drop(items, in: role, at: position)
        }
        .contextMenu {
            if spec.takesSeveral {
                Button("Move Up") { assignment.move(in: role, fromOffsets: [position], toOffset: position - 1) }
                    .disabled(position == 0)
                Button("Move Down") { assignment.move(in: role, fromOffsets: [position], toOffset: position + 2) }
                    .disabled(position == count - 1)
            }
            ForEach(Array(assignment.roles.enumerated()), id: \.offset) { other, otherSpec in
                if other != role {
                    Button("Move to \(otherSpec.label)") { assignment.place(column, in: other) }
                }
            }
            Divider()
            Button("Remove") { assignment.remove(column) }
        }
    }

    @ViewBuilder private func baselinePicker(_ column: Int) -> some View {
        HStack(spacing: 6) {
            Text("Baseline").font(.caption).foregroundStyle(.secondary)
            Picker("Baseline", selection: Binding(
                get: { baselines[column] ?? levels[column]?.first ?? "" },
                set: { baselines[column] = $0 }
            )) {
                ForEach(levels[column] ?? [], id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .disabled((levels[column] ?? []).isEmpty)
            .help("Every coefficient for this variable is its difference from this level.")
        }
        .padding(.leading, 28)
    }

    private func capacity(_ role: StepRole) -> String {
        switch (role.count.lowerBound, role.isOpen) {
        case (_, false) where role.count.lowerBound == role.count.upperBound:
            role.count.lowerBound == 1 ? "One variable" : "\(role.count.lowerBound) variables"
        case (let fewest, true): fewest <= 1 ? "Any number" : "At least \(fewest)"
        case (let fewest, false): "\(fewest)–\(role.count.upperBound) variables"
        }
    }

    /// A column as a drag carries it. The prefix keeps text dragged in from
    /// elsewhere from being read as a column.
    private static let payloadPrefix = "writertex.column:"
    private static func payload(_ column: Int) -> String { payloadPrefix + String(column) }

    /// The table's columns a drag carries, ignoring anything else dropped.
    private func columns(in items: [String]) -> [Int] {
        items.compactMap { item -> Int? in
            guard item.hasPrefix(Self.payloadPrefix) else { return nil }
            return Int(item.dropFirst(Self.payloadPrefix.count)).flatMap { headers.indices.contains($0) ? $0 : nil }
        }
    }

    private func drop(_ items: [String], in role: Int, at position: Int?) -> Bool {
        let dropped = self.columns(in: items)
        guard !dropped.isEmpty else { return false }
        for (offset, column) in dropped.enumerated() {
            assignment.place(column, in: role, at: position.map { $0 + offset })
        }
        dropTarget = nil
        return true
    }

    private var hint: String {
        let active = assignment.active
        if assignment.roles.indices.contains(active), !assignment.isFull(active) {
            return "Click a variable to add it to \(assignment.roles[active].label), or drag it to any role."
        }
        if kind.roles.contains(where: \.codesLevels) {
            return "Mark a predictor categorical to compare its levels to a baseline. Drag to reorder."
        }
        return "Drag a variable to reorder it, move it to another role, or back to the list to take it out."
    }

    /// The table's variables. A click adds one to the highlighted role or takes
    /// it out of the role it is in; a drag puts it in any role.
    @ViewBuilder private var columnSelection: some View {
        if headers.isEmpty {
            ContentUnavailableView("No Variables", systemImage: "tablecells",
                                   description: Text("This table has no columns to analyze."))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                        let role = assignment.role(of: index)
                        NotebookVariableButton(model: model, dataset: dataset, index: index, icon: "checkmark", header: header,
                                               isPicked: role != nil, dragPayload: Self.payload(index)) { assignment.pick(index) }
                            .help(role.map { "In \(assignment.roles[$0].label). Click to take it out." }
                                  ?? "Click to add to \(self.activeLabel), or drag to any role")
                    }
                }
                .imageScale(.large)
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
            }
            .scrollContentBackground(.hidden)
            // A variable dragged back out of a role leaves it.
            .dropDestination(for: String.self) { items, _ in
                let columns = self.columns(in: items)
                columns.forEach { assignment.remove($0) }
                return !columns.isEmpty
            }
        }
    }

    private var activeLabel: String {
        assignment.roles.indices.contains(assignment.active) ? assignment.roles[assignment.active].label : "the step"
    }

    private func loadLevels(_ index: Int) {
        Task {
            let found = await model.levels(for: dataset, column: index)
            levels[index] = found
            if baselines[index] == nil { baselines[index] = found.first }
        }
    }

    private func reference(_ index: Int) -> ColumnReference {
        ColumnReference(index: index, name: headers.indices.contains(index) ? headers[index] : "")
    }

    private var isValid: Bool {
        guard !headers.isEmpty, assignment.isComplete else { return false }
        if kind.needsTestValue, Double(testValue.trimmingCharacters(in: .whitespaces)) == nil { return false }
        let coded = zip(assignment.roles, assignment.columns).filter(\.0.codesLevels).flatMap(\.1)
        return coded.filter { categorical.contains($0) }.allSatisfy { !(levels[$0] ?? []).isEmpty }
    }

    private func makeStep() -> AnalysisStep {
        let read = assignment.columns.map { $0.map(self.reference) }
        func one(_ role: Int) -> ColumnReference { read[role].first ?? self.reference(0) }
        let operation: AnalysisOperation = switch kind {
            case .describe: .describe(columns: read[0])
            case .correlation: .correlation(columns: read[0], method: method)
            case .frequency: .frequency(column: one(0))
            case .crossTabulation: .crossTabulation(rows: one(0), columns: one(1))
            case .chiSquareIndependence: .chiSquareIndependence(rows: one(0), columns: one(1))
            case .oneSampleT:
                .oneSampleT(column: one(0), testValue: Double(testValue.trimmingCharacters(in: .whitespaces)) ?? 0)
            case .independentT: .independentT(outcome: one(0), group: one(1), variance: variance)
            case .pairedT: .pairedT(first: one(0), second: one(1))
            case .oneWayANOVA: .oneWayANOVA(outcome: one(0), factor: one(1))
            case .twoWayANOVA: .factorialANOVA(outcome: one(0), factors: read[1])
            case .linearRegression:
                .linearRegression(outcome: one(0), predictors: assignment.columns[1].map { index in
                    RegressionPredictor(
                        column: self.reference(index),
                        isCategorical: categorical.contains(index),
                        referenceLevel: categorical.contains(index) ? baselines[index] : nil)
                })
        }
        return AnalysisStep(dataset: dataset, scope: .allRows,
                            missing: missing, adjustment: adjustment, operation: operation)
    }
}
