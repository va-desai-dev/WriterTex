//
//  SidebarView.swift
//  WriterTex
//
//  Created by Vedant A. Desai on 10/24/26.
//
import SwiftUI
import UniformTypeIdentifiers


struct TableOfContentsSidebar: View {
    // Pass the extracted dynamic headings array into this view
    let headings: [DecodedHeading]
    var body: some View {
        List(headings) { heading in
            HStack(alignment: .top, spacing: 4) {
                    Text(heading.text)
                        .font(fontForLevel(heading.level))
                        .lineLimit(1)
            }
            .padding(.leading, CGFloat(heading.level - 1) * 6)
            .padding(.vertical, 2)
        }
    }

    // Optional helper to adjust font weight/size depending on heading level
    private func fontForLevel(_ level: Int) -> Font {
        switch level {
            case 1:  return .system(.title2).bold()
            case 2:  return .system(.title3).weight(.semibold)
            case 3: return .system(.headline).weight(.medium)
            case 4: return .system(.headline).italic()
            default: return .system(.body).italic()
        }
    }
}

enum SidebarTabs: String, CaseIterable, Identifiable {
    case file, outline
    var id: String { rawValue }
    var title: String {
        switch self {
            case .file: return "File"
            case .outline: return "Outline"
        }
    }
    var icon: String {
        switch self {
            case .file: return "wrtxfile.svg"
            case .outline: return "list.bullet"
        }
    }
    var nsImage: NSImage? {
        switch self {
            case .file: NSImage(resource: .wrtxfile)
            case .outline: NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        }
    }
}


/// A manuscript window's sidebar: the manuscript and the one .bib it cites.
struct ManuscriptSidebar: View {
    let session: ManuscriptSession

    let headings: [DecodedHeading]



    @State private var selectedTab: SidebarTabs = .file


    var body: some View {
        Group {
            switch selectedTab {
                case .file:
                    List {
                        Section("Manuscript") {
                            DocumentRow(title: session.title,
                                        detail: session.editor.selectedFile?.deletingLastPathComponent().path ?? "Not saved yet",
                                        icon: AppModes.files.fileIcon, url: session.editor.selectedFile)
                        }
                        Section("Bibliography") {
                            ManuscriptBibliographyRow(library: session.bibliography, file: session.file)
                        }
                    }
                case .outline:
                    TableOfContentsSidebar(headings: headings)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .paneBar(.top) {
            PaneBar {
                FillingTabStrip(
                    accessibilityLabel: "Writing Sidebar Tabs",
                    tabs: SidebarTabs.allCases,
                    selection: $selectedTab) { tab in
                        tab.rawValue
                    } content: { tab in
                            .label(tab.nsImage, tab.title)
                    }
            }
        }
    }
}

private struct ManuscriptBibliographyRow: View {
    @ObservedObject var library: BibLibrary
    @ObservedObject var file: ManuscriptFile

    var body: some View {
        if let url = library.fileURL {
            DocumentRow(title: url.lastPathComponent, detail: "\(library.entries.count) citations",
                        icon: Image(systemName: "books.vertical"), url: url)
                .contextMenu {
                    Button("Choose Another File…", action: library.chooseOtherFile)
                    Button("Stop Using This File") { library.select(nil) }
                }
        } else if let missing = file.unreachableBibliography {
            DocumentRow(title: missing, detail: "Not available on this Mac", icon: Image(systemName: "exclamationmark.triangle"), url: nil)
            Button("Locate…", action: library.chooseOtherFile)
        } else {
            Button("Choose Bibliography…", systemImage: "plus", action: library.chooseOtherFile)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
    }
}

/// One file: its name, a line of detail, and Reveal in Finder when it has a place on disk.
struct DocumentRow: View {
    let title: String
    let detail: String
    let icon: Image
    let url: URL?

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
        } icon: {
            icon
        }
        .help(url?.path ?? title)
        .contextMenu {
            if let url {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }
}

/// A notebook window's sidebar: the datasets packaged in the notebook.
struct NotebookSidebar: View {
    let model: NotebookModel
    @Binding var selection: String?
    @Binding var showsNotebook: Bool
    @State private var isImporting = false
    @State private var importFailure: String?
    @State private var pendingRemoval: String?

    var body: some View {
        List(selection: $selection) {
            Section("Datasets") {
                ForEach(model.availableDatasets, id: \.self) { name in
                    Label(name, systemImage: "tablecells")
                        .tag(name)
                        .contextMenu {
                            Button("Remove from Notebook…", role: .destructive) { pendingRemoval = name }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .overlay {
            if model.availableDatasets.isEmpty {
                ContentUnavailableView {
                    Label("No Datasets", systemImage: "tablecells")
                } description: {
                    Text("Import CSV files. They’re copied into the notebook, so it opens the same anywhere.")
                } actions: {
                    Button("Import CSV…") { isImporting = true }
                }
            }
        }
        // Picking a dataset shows its table; the toggle goes back to the steps.
        .onChange(of: selection) { if selection != nil { showsNotebook = false } }
        .onChange(of: model.availableDatasets) {
            if let selection, !model.availableDatasets.contains(selection) { self.selection = nil }
        }
        .paneBar(.top) {
            PaneBar {
                Spacer()
                DynamicLiquidGlassStrip {
                    Toggle(isOn: $showsNotebook) {
                        Label(showsNotebook ? "Analyses" : "Dataset",
                              systemImage: showsNotebook ? "graph.2d" : "tablecells.fill.badge.ellipsis")
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.glassSegment)
                    .disabled(selection == nil)
                    .help(showsNotebook ? "Show the selected dataset" : "Show the analysis steps")
                    Button("Import CSV", systemImage: "plus") { isImporting = true }
                        .buttonStyle(.glassSegment)
                        .help("Copy CSV files into this notebook")
                }
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.commaSeparatedText], allowsMultipleSelection: true) { result in
            switch result {
                case .success(let urls): Task { importFailure = await model.importDatasets(urls) }
                case .failure(let error): importFailure = error.localizedDescription
            }
        }
        .alert("Couldn’t Import Everything", isPresented: Binding(
            get: { importFailure != nil }, set: { if !$0 { importFailure = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: { Text(importFailure ?? "") }
        .confirmationDialog("Remove “\(pendingRemoval ?? "")” from the notebook?", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let pendingRemoval { model.removeDatasets([pendingRemoval]) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Steps that read it stay and report it missing. Edit ▸ Undo brings it back.")
        }
    }
}
