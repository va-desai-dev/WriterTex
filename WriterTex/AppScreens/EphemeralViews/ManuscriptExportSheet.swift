import AppKit
import SwiftUI

/// Asks how the manuscript should look, then exports the open WriterTex document
/// as a PDF or Word file. The look lives only here, never in the editor.
struct ManuscriptExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: FileBrowserModel


    /// The project's .bib, whose records citations are formatted from.
    let bibliography: BibLibrary?
    /// The project's output folder; nil exports beside the document.
    let outputDirectory: (@MainActor @Sendable () async throws -> URL)?

    @State private var settings = ManuscriptExportSettings.saved
    @AppStorage("ManuscriptExportFormat") private var format = ManuscriptFormat.pdf
    @State private var isBusy = false
    @State private var error: String?
    @State private var exported: URL?
    /// Cited keys the .bib didn't have in the last export.
    @State private var missing: [String] = []
    @State private var showsStyles = false
    private let styles = CitationStyleLibrary.shared
    private let styleSelection = CitationStyleLibrary.Style?(nilLiteral: ())

    @State private var isFormatSec = false

    private static let families = NSFontManager.shared.availableFontFamilies

    // Keep the callback's Sendable qualification at the initializer boundary.
    init(model: FileBrowserModel, bibliography: BibLibrary?,
         outputDirectory: (@MainActor @Sendable () async throws -> URL)?) {
        self.model = model
        self.bibliography = bibliography
        self.outputDirectory = outputDirectory
    }

    var linespacinglabel: String {
        if settings.style.lineSpacing == CGFloat(1) { return "Single" }
        if settings.style.lineSpacing == CGFloat(2) { return "Double" }
        else {
            return settings.style.lineSpacing.formatted()
        }
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Style Manual")
                        .font(.system(size: 14))
                    Spacer()
                    Menu {
                        ForEach(ManuscriptManual.allCases) { manual in
                            Button(manual.title) { apply(manual) }
                        }
                    } label: {
                        HStack {
                            Text(ManuscriptManual.matching(settings)?.title ?? "Custom")
                                .font(.headline)
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8))
                                .foregroundStyle(Color.secondary)
                        }
                        .padding(.horizontal)
                        .frame(width: 240, alignment: .leading)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glassTitleButton)
                    .disabled(isBusy)
                }
            } header: {
                Text("Publication Manual")
                    .font(.headline)
                    .bold()
            } footer: {
                Text("Sets type, heading levels, indents, page numbers and citation style to the manual’s rules; everything below can still be adjusted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Text("Font")
                        .font(.system(size: 14))
                    Spacer()
                    Menu {
                        Picker("Font", selection: $settings.style.fontFamily) {
                            Text("System").tag(String?.none)
                            Divider()
                            ForEach(Self.families, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } label: {
                        HStack {
                            Text(settings.style.fontFamily ?? "System")
                                .font(.headline)
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8))
                                .foregroundStyle(Color.secondary)
                        }
                        .padding(.horizontal)
                        .frame(width: 200, alignment: .leading)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glassTitleButton)
                }
                linespacingPicker
                ForEach(0...6, id: \.self) { level in
                    LevelRow(title: level == 0 ? "P" : "H\(level)", level: binding(for: level))
                }
            } header: {
                Text("Text Formatting")
                    .font(.headline)
                    .bold()
            }
            Section {
                // List IDs are shared across sections, so these can't reuse the Levels rows' 0...6.
                ForEach((0...6).map { (id: "spacing-\($0)", level: $0) }, id: \.id) { row in
                    SpacingRow(title: row.level == 0 ? "P" : "H\(row.level)", level: binding(for: row.level))
                }
                HStack(spacing: 4) {
                    Text("First-Line Indent")
                    Spacer(minLength: 0)
                    PointsField(title: "First-Line Indent", value: $settings.style.firstLineIndent)
                }
                HStack(spacing: 4) {
                    Text("Reference Hanging Indent")
                    Spacer(minLength: 0)
                    PointsField(title: "Reference Hanging Indent", value: $settings.style.referencesHanging)
                }
            } header: {
                Text("Spacing")
                    .font(.headline)
                    .bold()
            } footer: {
                Text("Points of space before and after each paragraph, on top of line spacing. Indents are in points too: 36 is half an inch. The hanging indent applies when the citation style hangs its references.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Text("Citation Format").font(.system(size: 14))
                    Spacer()
                    Menu{
                        Picker("Citation Format",selection: $settings.citationStyle) {
                            ForEach(styles.styles){style in Text(style.title).tag(style.id)}}.pickerStyle(.inline).labelsHidden()}
                        label:{
                        HStack{
                            Text(styles.styles.first { $0.id == settings.citationStyle }?.title ?? "Import or Download CSL Style");Spacer();Image(
                                systemName: "chevron.down"
                            )
                            .font(.system(size: 8))
                            .foregroundStyle(Color.secondary)
                        }
                        .padding(.horizontal)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glassTitleButton)
                    Button{showsStyles = true}label:{HStack{Text("Get Styles…")}.padding(.horizontal)}.buttonStyle(.glassTitleButton)
                }
                HStack {
                    Text("Reference List Header:")
                    TextField("Reference List", text: $settings.referencesTitle, prompt: Text("References"))
                        .textFieldStyle(.roundedBorder)
                        .focusEffectDisabled()
                }
            } header: {
                Text("Citation Styles")
                    .font(.headline)
                    .bold()
            } footer: {
                Text(bibliography?.fileURL == nil
                     ? "Choose the project’s .bib to format [@key] citations; until then they export as typed."
                     : "[@key] citations are formatted from \(bibliography?.fileURL?.lastPathComponent ?? "the project’s .bib"), with the reference list at the end or under an empty References heading.")
                .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                FurnitureRow(furniture: $settings.header)
            } header: {
                Text("Header")
                    .font(.headline)
                    .bold()
            }
            Section {
                FurnitureRow(furniture: $settings.footer)
            } header: {
                Text("Footer")
                    .font(.headline)
                    .bold()
            } footer: {
                Text("{page}, {pages} and {title} fill in on every page.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            if !missing.isEmpty {
                Section {
                    Label("Not in the .bib: " + missing.joined(separator: ", "), systemImage: "questionmark.circle.fill")
                        .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
            }

            if let exported {
                Section {
                    HStack {
                        Label(exported.lastPathComponent, systemImage: "checkmark.circle.fill")
                            .textSelection(.enabled)
                        Spacer()
                        if exported.isFileURL {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([exported]) }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .paneBar(.top) {
            PaneBar {
                Text("Setup & Export Manuscript").font(.headline)
                Spacer()
                Button(role: .cancel) { dismiss() }label:{Label(exported == nil ? "Cancel" : "Done", systemImage: "xmark")}
                    .buttonStyle(.glassButton)
            }
        }
        .paneBar(.bottom) {
            PaneBar(edge: .bottom) {
                FillingTabStrip(
                    accessibilityLabel: "Exported file format",
                    tabs: ManuscriptFormat.allCases,
                    selection: $format) {
                        $0.title
                    } content: {
                        .title($0.title)
                    }
                Spacer(minLength: 70)
                Button{ settings = ManuscriptExportSettings() }label:{HStack{Text("Defaults")}.padding(.horizontal)}
                    .buttonStyle(.glassTitleButton)
                Button(action: export) { HStack(alignment: .center){Label("Export", systemImage: "square.and.arrow.up") }.padding(.horizontal)}
                    .buttonStyle(.glassTitleButton)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBusy)
                if isBusy { ProgressView().controlSize(.small) }
            }
        }
        .background(AppTheme.shared.windowBackground)
        .foregroundStyle(Color.foreground)
        .sheet(isPresented: $showsStyles) {
            CitationStyleBrowser(library: styles, selection: $settings.citationStyle)
                .background(AppTheme.shared.windowBackground)
                .foregroundStyle(Color.foreground)
        }
        .onAppear {
            // A removed style falls back to APA.
            if !styles.contains(settings.citationStyle) { settings.citationStyle = "apa" }
        }
        .presentationSizing(.form)
        .frame(minHeight: 720)
    }

    private func binding(for level: Int) -> Binding<ManuscriptStyle.Level> {
        Binding(get: { settings.style.level(level) }, set: {
            if level == 0 { settings.style.body = $0 } else { settings.style.headings[level - 1] = $0 }
        })
    }

    /// Takes on a manual's settings, first downloading its citation style if it
    /// isn't installed. Without the style, the layout still changes.
    private func apply(_ manual: ManuscriptManual) {
        error = nil
        guard !styles.contains(manual.citationStyle) else {
            settings = manual.settings
            return
        }
        isBusy = true
        Task {
            do {
                try await styles.download(.init(id: manual.citationStyle, isDependent: false,
                                                name: CitationStyleLibrary.displayName(manual.citationStyle)))
                settings = manual.settings
            } catch {
                var layout = manual.settings
                layout.citationStyle = settings.citationStyle
                settings = layout
                self.error = "The \(manual.title) citation style couldn’t be downloaded: \(error.localizedDescription)"
            }
            isBusy = false
        }
    }

    private var linespacingPicker: some View {
        HStack(spacing: 4) {
            Text("Line Spacing")
                .font(.system(size: 14))
            Spacer()
            Menu {
                Button("Single") { settings.style.lineSpacing = CGFloat(1) }
                Button("1.15") { settings.style.lineSpacing = CGFloat(1.15) }
                Button("1.5") { settings.style.lineSpacing = CGFloat(1.5) }
                Button("Double") { settings.style.lineSpacing = CGFloat(2) }
            } label : {
                HStack {
                    Text(linespacinglabel)
                        .font(.headline)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.secondary)
                }
                .padding(.horizontal)
                .frame(width: 200, alignment: .leading)
            }
            .menuStyle(.button)
            .buttonStyle(.glassTitleButton)
        }
    }

    private func export() {
        settings.save()
        isBusy = true
        error = nil
        exported = nil
        missing = []
        Task {
            do {
                var citations: ManuscriptCitationSource?
                if let bibliography, !bibliography.entries.isEmpty {
                    citations = ManuscriptCitationSource(style: try styles.style(settings.citationStyle),
                                                         items: bibliography.entries.map(\.citation),
                                                         referencesTitle: settings.referencesTitle.isEmpty ? "References" : settings.referencesTitle)
                }
                let result = try await model.exportManuscript(settings, as: format, into: try await outputDirectory?(), citations: citations)
                exported = result.url
                missing = result.missing
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            isBusy = false
        }
    }
}

private struct LevelRow: View {
    let title: String
    @Binding var level: ManuscriptStyle.Level

    private var size: Binding<Double> {
        Binding(get: { Double(level.size) }, set: { level.size = CGFloat($0) })
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 14))
            Spacer(minLength: 0)
            TextField("Size", value: size, format: .number)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .focusEffectDisabled()
                .frame(width: 48)
                .multilineTextAlignment(.trailing)
            Stepper("Size", value: size, in: 6...72).labelsHidden()
            DynamicLiquidGlassStrip {
                TraitToggle(isOn: $level.bold, symbol: "bold", help: "Bold")
                TraitToggle(isOn: $level.italic, symbol: "italic", help: "Italic")
                TraitToggle(isOn: $level.underline, symbol: "underline", help: "Underline")
                Menu {
                    Button("As Typed") { level.capitalization = .asTyped }
                    Button("UPPERCASE") { level.capitalization = .upper }
                    Button("lowercase") { level.capitalization = .lower }
                    Button("Title Case") { level.capitalization = .title }
                } label: {
                    Image(systemName: "textformat")
                }
                .menuIndicator(.hidden)
                .menuStyle(.button)
                .buttonStyle(.glassSegment)
                Menu {
                    Picker("Alignment", selection: $level.alignment) {
                        ForEach(ManuscriptStyle.TextAlignment.allCases, id: \.self) { alignment in
                            Label(alignment.title, systemImage: alignment.symbol).tag(alignment)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Image(systemName: level.alignment.symbol)
                }
                .menuIndicator(.hidden)
                .menuStyle(.button)
                .buttonStyle(.glassSegment)
                .help("Alignment")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SpacingRow: View {
    let title: String
    @Binding var level: ManuscriptStyle.Level

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            Spacer(minLength: 0)
            PointsField(title: "Before", value: $level.spaceBefore)
            PointsField(title: "After", value: $level.spaceAfter)
        }
    }
}

private struct PointsField: View {
    let title: String
    @Binding var value: CGFloat

    private var points: Binding<Double> {
        Binding(get: { Double(value) }, set: { value = CGFloat(max(0, $0)) })
    }

    var body: some View {
        HStack(spacing: 1) {
            TextField(title, value: points, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 48)
                .labelsHidden()
                .lineLimit(1)
                .focusEffectDisabled()
            Stepper(title, value: points, in: 0...72)
                .labelsHidden()
        }
    }
}

/// Shows its state the way the editor's formatting toggles do.
private struct TraitToggle: View {
    @Binding var isOn: Bool
    let symbol: String
    let help: String

    var body: some View {
        Toggle(isOn: $isOn) {
            Label(help, systemImage: symbol)
                .labelStyle(.iconOnly)
                .fontWeight(isOn ? .bold : .regular)
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
        }
        .toggleStyle(.button)
        .buttonStyle(.glassSegment)
        .help(help)
    }
}

private struct FurnitureRow: View {
    @Binding var furniture: ManuscriptExportSettings.Furniture

    var body: some View {
        HStack {
            TextField("Left", text: $furniture.left, prompt: Text("Left"))
            TextField("Center", text: $furniture.center, prompt: Text("Center")).multilineTextAlignment(.center)
            TextField("Right", text: $furniture.right, prompt: Text("Right")).multilineTextAlignment(.trailing)
        }
        .textFieldStyle(.roundedBorder)
        .focusEffectDisabled()
        .labelsHidden()
    }
}
