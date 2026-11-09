import SwiftUI

/// The two ways a notebook writes new values into a dataset.
enum DataMutation: String, Identifiable, CaseIterable {
    case compute = "Compute Variable"
    case recode = "Recode Variable"
    var id: String { self.rawValue }
}

/// Compute or Recode, against one of the notebook's datasets. The variables are
/// listed on the left; clicking one puts it in the formula, or picks it to
/// recode. The first rows preview the result before anything is written.
struct DataMutationSheet: View {
    let model: NotebookModel
    let kind: DataMutation

    @Environment(\.dismiss) private var dismiss
    @State private var dataset = ""
    @State private var table: CSVTable?
    @State private var target = ""
    @State private var formula = ""
    @State private var source: Int?
    @State private var intoSame = false
    @State private var rules = [RecodeDraft()]
    @State private var error: String?

    /// Enough rows to show what the result looks like, without evaluating a
    /// large table on every keystroke.
    private var sample: CSVTable? {
        table.map { CSVTable(columns: $0.columns, rows: Array($0.rows.prefix(50))) }
    }

    var body: some View {
        VStack(alignment: .leading) {
            HStack(alignment: .center) {
                List(Array((table?.columns ?? []).enumerated()), id: \.offset) { index, header in
                    NotebookVariableButton(model: model, dataset: dataset, index: index, icon: "checkmark", header: header,
                                           isPicked: kind == .recode && source == index) { pick(index, header) }
                    .help(kind == .compute ? "Insert into the formula" : "Recode this variable")
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)

                VStack(alignment: .leading, spacing: 10) {
                    switch kind {
                    case .compute: computeForm
                    case .recode: recodeForm
                    }
                }
                .padding(.vertical, 8)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .focusEffectDisabled()
        .paneBar(.bottom) {
            PaneBar(edge: .bottom) {
                Button("Cancel", role: .cancel) { dismiss() }
                    .glassButtonStyle()
                Spacer()

                Button(kind == .compute ? "Compute" : "Recode") { apply() }
                    .glassButtonStyle(prominent: true)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canApply)
            }
        }
        .paneBar(.top) {
            PaneBar {
                Text(kind.rawValue).font(.title3).bold()
                Spacer()
                NotebookDatasetMenu(model: model, dataset: $dataset)
            }
        }
        .presentationSizing(.page)
        .padding()
        .presentationBackground(AppTheme.shared.windowBackground)
        .onAppear { if dataset.isEmpty, let first = model.availableDatasets.first { dataset = first } }
        .task(id: "\(dataset)#\(model.datasetRevision)") {
            table = try? await model.table(for: dataset)
        }
        .onChange(of: dataset) { source = nil; error = nil }
    }

    // MARK: Compute

    @ViewBuilder private var computeForm: some View {
        TextField("Target variable", text: $target, prompt: Text("Add New or Overwrite Existing Variable…"))
            .focusEffectDisabled()
        TextEditor(text: $formula)
            .font(.body.monospaced())
            .textEditorStyle(.automatic)
            .focusEffectDisabled()
        Menu {
            ForEach(DataTransform.Function.allCases, id: \.self) { function in
                Button(function.rawValue) { formula += function.rawValue + "("  } }
        } label: {
            Text("Add Operator")
        }
        .menuStyle(.borderedButton)
        Text("Bare names read one-word headers; [brackets] read any header. Arithmetic on a missing value is missing; SUM, MEAN, MIN and MAX skip it.")
            .font(.caption).foregroundStyle(.secondary)
        if let sample, !formula.isEmpty {
            switch Result(catching: { try DataTransform.compute(formula, in: sample, missingCodes: Set(model.missingCodes)) }) {
            case .success(let result): preview(result.cells.prefix(8).map { $0.isEmpty ? "blank" : $0 })
            case .failure(let failure): Text(failure.localizedDescription).foregroundStyle(.secondary).font(.callout)
            }
        }
    }

    // MARK: Recode

    @ViewBuilder private var recodeForm: some View {
        if let source, let columns = table?.columns, columns.indices.contains(source) {
            Picker("As", selection: $intoSame) {
                Text("Same Variable").tag(true)
                Text("New Variable").tag(false)
            }
            .pickerStyle(.segmented)
            if !intoSame {
                TextField("Target variable", text: $target, prompt: Text("\(columns[source])_recoded"))
                    .focusEffectDisabled()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach($rules) { $rule in
                        RecodeRuleRow(rule: $rule) { rules.removeAll { $0.id == rule.id } }
                    }
                    Button("Add Rule", systemImage: "plus") { rules.append(RecodeDraft()) }
                }
                .padding(.vertical, 10)
            }
            Text(intoSame ? "Values no rule matches stay as they are." : "Values no rule matches are left blank.")
                .font(.caption).foregroundStyle(.secondary)
            if let sample, let recode = self.recodeRules {
                let cells = sample.rows.map { source < $0.count ? $0[source] : "" }
                let recoded = DataTransform.recode(cells, rules: recode, missingCodes: Set(model.missingCodes), keepsUnmatched: intoSame)
                var seen = Set<String>()
                let pairs = zip(cells, recoded).filter { seen.insert($0.0).inserted }.prefix(8)
                preview(pairs.map { "\($0.0.isEmpty ? "blank" : $0.0) → \($0.1.isEmpty ? "blank" : $0.1)" })
            }
        } else {
            ContentUnavailableView("Pick a Variable", systemImage: "arrow.left",
                                   description: Text("Choose the variable to recode from the list."))
        }
    }

    /// The rules as the model takes them, or nil while one is half filled in.
    private var recodeRules: [RecodeRule]? {
        let built = rules.compactMap(\.rule)
        return built.count == rules.count && !built.isEmpty ? built : nil
    }

    // MARK: Shared

    private func preview(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Preview").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(lines.enumerated()), id: \.offset) { Text($0.element).font(.callout.monospaced()) }
        }
    }

    private func pick(_ index: Int, _ header: String) {
        switch kind {
        case .compute:
            let isWord = !header.isEmpty && header.allSatisfy { $0.isLetter || $0.isNumber || "_.".contains($0) }
                && header.first.map { $0.isLetter || $0 == "_" } == true
            formula += isWord ? header : "[\(header)]"
        case .recode:
            source = index
        }
    }

    private var canApply: Bool {
        switch kind {
        case .compute: !target.trimmingCharacters(in: .whitespaces).isEmpty && !formula.isEmpty
        case .recode: source != nil && recodeRules != nil && (intoSame || !target.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func apply() {
        do {
            switch kind {
            case .compute:
                try model.compute(formula, into: target, in: dataset)
            case .recode:
                guard let source, let recodeRules else { return }
                try model.recode(source, rules: recodeRules, into: intoSame ? nil : target, in: dataset)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A recode rule as it is being filled in.
private struct RecodeDraft: Identifiable {
    enum Match: String, CaseIterable {
        case value = "Value", range = "Range", lowest = "Lowest through", highest = "Through highest"
        case missing = "Missing", other = "All other values"
    }
    enum Output: String, CaseIterable {
        case value = "Value", blank = "Blank", copy = "Copy old value"
    }

    let id = UUID()
    var match = Match.value
    var low = ""
    var high = ""
    var output = Output.value
    var new = ""

    /// Nil until the numbers a range needs are filled in.
    var rule: RecodeRule? {
        let matched: RecodeRule.Match? = switch match {
        case .value: .value(low)
        case .range: Double(low).flatMap { low in Double(high).map { .range(low: low, high: $0) } }
        case .lowest: Double(low).map { .range(low: nil, high: $0) }
        case .highest: Double(low).map { .range(low: $0, high: nil) }
        case .missing: .missing
        case .other: .other
        }
        let written: RecodeRule.Output = switch output {
        case .value: .value(new)
        case .blank: .blank
        case .copy: .copy
        }
        return matched.map { RecodeRule(id: id, match: $0, output: written) }
    }
}

private struct RecodeRuleRow: View {
    @Binding var rule: RecodeDraft
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Picker("Old", selection: $rule.match) {
                ForEach(RecodeDraft.Match.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            switch rule.match {
                case .value, .lowest, .highest: TextField("Old", text: $rule.low).frame(width: 60).focusEffectDisabled()
            case .range:
                TextField("From", text: $rule.low).frame(width: 50).focusEffectDisabled()
                TextField("To", text: $rule.high).frame(width: 50).focusEffectDisabled()

            case .missing, .other: EmptyView()
            }
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            Picker("New", selection: $rule.output) {
                ForEach(RecodeDraft.Output.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            if rule.output == .value { TextField("New", text: $rule.new).frame(width: 60).focusEffectDisabled() }
            Spacer(minLength: 0)
            Button("Remove Rule", systemImage: "minus.circle", action: onRemove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .textFieldStyle(.roundedBorder)
    }
}
