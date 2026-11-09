import SwiftUI
import UniformTypeIdentifiers

/// The installed citation styles and every style in the Citation Style
/// Language repository, searchable, with one-click downloads.
struct CitationStyleBrowser: View {
    @Environment(\.dismiss) private var dismiss
    let library: CitationStyleLibrary
    @Binding var selection: String

    @State private var search = ""
    @State private var isLoading = false
    @State private var downloading: String?
    @State private var error: String?
    @State private var importsFile = false

    /// Rows past this are left out until the search narrows them.
    private static let shownLimit = 200

    private var matches: [CitationStyleLibrary.CatalogEntry] {
        let words = search.lowercased().split(separator: " ").map(String.init)
        guard let catalog = library.catalog else { return [] }
        let available = catalog.filter { !library.contains($0.id) }
        guard !words.isEmpty else { return available }
        return available.filter { entry in
            let haystack = entry.name.lowercased() + " " + entry.id
            return words.allSatisfy(haystack.contains)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section("Installed") {
                    ForEach(library.styles) { style in
                        installedRow(style)
                    }
                }
                Section {
                    if let catalog = library.catalog {
                        let matches = matches
                        ForEach(matches.prefix(Self.shownLimit)) { entry in
                            availableRow(entry)
                        }
                        if matches.count > Self.shownLimit {
                            Text("\(matches.count - Self.shownLimit) more — narrow the search to see them.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if matches.isEmpty, !catalog.isEmpty {
                            Text("No styles match “\(search)”.").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if isLoading {
                        HStack { ProgressView().controlSize(.small); Text("Loading the style list…").foregroundStyle(.secondary) }
                    }
                } header: {
                    HStack {
                        Text(library.catalog.map { "Available (\($0.count))" } ?? "Available")
                        Spacer()
                        Group {
                            if library.catalog == nil, !isLoading {
                                Button{Task{await loadCatalog(refresh: true) } } label: { HStack { Text("Retry")}.padding(.horizontal, 12)}
                            } else {
                                Button{importsFile = true } label: { HStack { Text("Import CSL File")}.padding(.horizontal, 12)}
                            }
                        }
                        .buttonStyle(.glassTitleButton)
                    }
                } footer: {
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
            }
            .safeAreaBarOrInset(edge: .bottom) {
                HStack {
                    TextField("Search", text: $search, prompt: Text("Search journals and styles"))
                        .fixedSize(horizontal: false, vertical: true)
                        .textFieldStyle(.plain)
                        .lineLimit(1)
                        .focusEffectDisabled()
                    Spacer()
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .glassOrMaterial()
                .safeAreaPadding(.vertical, 10)
                .safeAreaPadding(.horizontal, 10)
            }
            .paneBar(.top) {
                PaneBar {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Citation Styles").font(.headline)
                        Text("From the Citation Style Language repository, used by Zotero, Mendeley and Pandoc.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Done", systemImage: "xmark") { dismiss() }
                        .buttonStyle(.glassButton)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .frame(width: 560, height: 620)
        .background(AppTheme.shared.windowBackground)
        .task { await loadCatalog(refresh: false) }
        .fileImporter(isPresented: $importsFile, allowedContentTypes: [UTType(filenameExtension: "csl") ?? .xml, .xml]) { result in
            guard case .success(let url) = result else { return }
            Task {
                do { selection = try await library.install(contentsOf: url).id } catch { self.error = error.localizedDescription }
            }
        }
    }

    private func installedRow(_ style: CitationStyleLibrary.Style) -> some View {
        Button {
            selection = style.id
        } label: {
            HStack {
                Image(systemName: selection == style.id ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selection == style.id ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(style.title)
                    Text(style.isBundled ? "Built in" : style.parentID.map { "Based on \($0)" } ?? style.id)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !style.isBundled {
                Button("Remove", role: .destructive) {
                    library.remove(style.id)
                    if selection == style.id { selection = "apa" }
                }
            }
        }
    }

    private func availableRow(_ entry: CitationStyleLibrary.CatalogEntry) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                Text(entry.isDependent ? "\(entry.id) · journal" : entry.id)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if downloading == entry.id {
                ProgressView().controlSize(.small)
            } else {
                Button("Get", systemImage: "arrow.down") { download(entry) }
                    .buttonStyle(.glassButton)
                    .disabled(downloading != nil)
            }
        }
    }

    private func download(_ entry: CitationStyleLibrary.CatalogEntry) {
        downloading = entry.id
        error = nil
        Task {
            do { selection = try await library.download(entry).id } catch { self.error = error.localizedDescription }
            downloading = nil
        }
    }

    private func loadCatalog(refresh: Bool) async {
        guard library.catalog == nil || refresh else { return }
        isLoading = true
        error = nil
        do { try await library.loadCatalog(refresh: refresh) } catch { self.error = error.localizedDescription }
        isLoading = false
    }
}
