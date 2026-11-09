import SwiftUI

struct BibliographyInspector: View {
    @ObservedObject var library: BibLibrary
    let onChooseFile: () -> Void
    let onCreateFile: () -> Void
    @State private var browser = BibliographyBrowserModel()
    @State private var showsCrossrefSearch = false
    @State private var sheetIsPresented = false
    @State private var editTarget: BibEntry?

    var body: some View {
        List(selection: $browser.selection) {
            ForEach(browser.entries(in: library)) { entry in
                BibliographyEntryRow(entry: entry)
                    .tag(entry.id)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .contextMenu {
                        actions(for: entry)
                    }
                    .onTapGesture(count: 2) {
                        browser.copy(ids: [entry.id], in: library)
                    }
                    .onTapGesture {
                        editTarget = entry
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .softScrollEdge(for: .bottom)
        .safeAreaBarOrInset(edge: .bottom) {
            searchfooter
        }
        .paneBar(.top, bar: {
            PaneBar(edge: .top, showsDivider: false) {
                header
            } accessory: {
                PaneBar(edge: .top, showsDivider: true) {
                    Text(browser.selection.isEmpty ? "\(library.entries.count) References" : "\(browser.selection.count) Selected")
                    Spacer(minLength: 0)
                    if let message = library.lastMessage {
                        Text(message)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        })
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if library.fileURL == nil {
                placeholder("Choose a bibliography", detail: "Choose or create the .bib file this manuscript cites from.")
            } else if library.document == nil {
                placeholder(library.lastMessage == nil ? "Loading bibliography…" : "Bibliography unavailable",
                            detail: "")
            } else if library.entries.isEmpty {
                placeholder("No citations yet", detail: "Save a citation from Safari with CiteTex, or add one in the editor.")
            } else if browser.entries(in: library).isEmpty {
                placeholder("No matches", detail: "Try another author, title, or citation key.")
            }
        }
        .onCopyCommand {
            guard let text = browser.citation(ids: browser.selection, in: library) else { return [] }
            return [NSItemProvider(object: text as NSString)]
        }
        .sheet(item: $editTarget) { entry in
            if let entry = library.entries.first(where: { $0.id == entry.id }) {
                ReferenceDetailSheet(entry: entry, library: library)
            }
        }
        .confirmationDialog("Remove \(browser.pendingRemoval.count) citations?", isPresented: Binding(
            get: { !browser.pendingRemoval.isEmpty },
            set: { if !$0 { browser.pendingRemoval.removeAll() } }
        ), titleVisibility: .visible) {
            Button("Remove", role: .destructive) { browser.remove(from: library) }
            Button("Cancel", role: .cancel) { browser.pendingRemoval.removeAll() }
        } message: {
            Text("This removes the entries from the bibliography file. Citations using these keys will no longer resolve.")
        }
        .onChange(of: library.fileURL) { browser.reset() }
        .onChange(of: library.entries) {
            browser.selection.formIntersection(Set(library.entries.map(\.id)))
        }
        .onChange(of: browser.search) {
            browser.selection.formIntersection(Set(browser.entries(in: library).map(\.id)))
        }
    }

    private func showsEditSheet(for entry: BibEntry) -> Bool {
        if entry == editTarget {
            return true
        } else {
            return false
        }
    }

    private var searchfooter: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .font(.body)
            TextField(
                "Search author, title, key",
                text: $browser.search,
                axis: .horizontal
            )
            .fixedSize(horizontal: false, vertical: true)
            .textFieldStyle(.plain)
            .lineLimit(1)
            .focusEffectDisabled()
            Spacer()
            if !browser.search.isEmpty {
                Button("clear", systemImage: "xmark.circle.fill", action: {
                    browser.search.removeAll()
                })
                .labelStyle(.iconOnly)
                .foregroundStyle(Color.secondary)
                .buttonStyle(.plain)
                .font(.system(size: 10))
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .glassOrMaterial()
        .safeAreaPadding(.vertical, 10)
        .safeAreaPadding(.horizontal, 10)
    }

    private var header: some View {
        Group {
            Menu {
                Button("New Bibliography…", action: onCreateFile)
                Button("Choose Existing File…", action: onChooseFile)
                if library.fileURL != nil {
                    Button("Reveal in Finder") { library.revealInFinder() }
                    Button("Stop Using This File") { library.select(nil) }
                }
            } label: {
                HStack {
                    Image(systemName: "books.vertical")
                    Text(library.fileURL?.lastPathComponent ?? "Choose Bibliography…")
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                }
                .padding(.horizontal)
            }
            .menuStyle(.button)
            .buttonStyle(.glassTitleButton)
            .help(library.fileURL.map(library.displayPath) ?? "Choose or create a bibliography")
            Menu("Citation Actions", systemImage: "ellipsis") {
                Button("Select All Matches") { browser.selection = Set(browser.entries(in: library).map(\.id)) }
                Button("Deselect All") { browser.selection.removeAll() }
                Divider()
                Button("Copy BibTeX") { browser.copy(ids: browser.selection, in: library, source: true) }
                    .disabled(browser.selection.isEmpty)
                Button("Remove Selected…", role: .destructive) { browser.pendingRemoval = browser.selection }
            }
            .disabled(browser.selection.isEmpty)
            .labelStyle(.iconOnly)
            .menuIndicator(.hidden)
            .menuStyle(.button)
            .buttonStyle(.glassButton)
        }
    }

    @ViewBuilder private func actions(for entry: BibEntry) -> some View {
        let ids = browser.selection.contains(entry.id) ? browser.selection : [entry.id]
        Button("Copy Citation") { browser.copy(ids: ids, in: library) }
        Button("Copy BibTeX") { browser.copy(ids: ids, in: library, source: true) }
        if let doi = entry.citation.doi, let url = URL(string: "https://doi.org/\(doi)") {
            Link("Open DOI", destination: url)
        } else if let address = entry.citation.url, let url = URL(string: address) {
            Link("Open URL", destination: url)
        }
        Divider()
        Button("Remove…", role: .destructive) { browser.pendingRemoval = ids }
    }

    private func placeholder(_ title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.callout)
            if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .multilineTextAlignment(.center)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct BibliographyEntryRow: View {
    let entry: BibEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.citation.title.isEmpty ? entry.key : entry.citation.title)
                .font(.callout)
                .lineLimit(2)
            Text(entry.citation.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(entry.key)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if entry.isDuplicateKey {
                Label("Duplicate key", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .contentShape(Rectangle())

        .help("\(entry.citation.title)\n\(entry.key)\nDouble-click to copy citation. Command-click to select several.")
    }
}
