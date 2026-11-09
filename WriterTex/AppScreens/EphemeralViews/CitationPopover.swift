import SwiftUI

/// Cite-while-you-write: the picker the editor's insert-citation shortcut opens
/// at the caret. Typing filters, ↑/↓ move, Return inserts, Escape dismisses;
/// ⌘-click picks several for one `[@a; @b]` marker.
struct CitationInsertionCard: View {
    @ObservedObject var library: BibLibrary
    let onInsert: (String) -> Void
    let onCancel: () -> Void
    @State private var browser = BibliographyBrowserModel()
    @FocusState private var searchIsFocused: Bool

    var body: some View {
        let matches = browser.entries(in: library)
        ScrollViewReader { proxy in
            List(selection: $browser.selection) {
                ForEach(matches) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.key)
                            .monospaced()
                            .foregroundStyle(.foreground)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(entry.citation.title.isEmpty ? entry.key : entry.citation.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(entry.citation.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .tag(entry.id)
                    .id(entry.id)
                    .onTapGesture(count: 2) { insert([entry.id]) }
                }
            }
            .scrollContentBackground(.hidden)
            .overlay {
                if matches.isEmpty {
                    Text(library.entries.isEmpty ? "No references in this bibliography" : "No matches")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .safeAreaBarOrInset(edge: .bottom) {
                searchBar(matches: matches, proxy: proxy)
            }
        }
        .frame(width: 360, height: 320)
        .onAppear {
            browser.selection = matches.first.map { [$0.id] } ?? []
            searchIsFocused = true
        }
        // The best match stays picked as the search narrows, so Return always cites something.
        .onChange(of: browser.search) {
            browser.selection = browser.entries(in: library).first.map { [$0.id] } ?? []
        }
        .onExitCommand(perform: onCancel)
    }

    private func searchBar(matches: [BibEntry], proxy: ScrollViewProxy) -> some View {
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
            .focused($searchIsFocused)
            .onSubmit { insert(browser.selection) }
            // Focus stays in the field; the arrows walk the list from here.
            .onKeyPress(.downArrow) { move(by: 1, in: matches, proxy: proxy) }
            .onKeyPress(.upArrow) { move(by: -1, in: matches, proxy: proxy) }
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

    private func move(by step: Int, in matches: [BibEntry], proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !matches.isEmpty else { return .handled }
        let current = matches.firstIndex { browser.selection.contains($0.id) }
        let next = current.map { min(max($0 + step, 0), matches.count - 1) } ?? 0
        browser.selection = [matches[next].id]
        proxy.scrollTo(matches[next].id)
        return .handled
    }

    private func insert(_ ids: Set<String>) {
        guard let marker = browser.citation(ids: ids, in: library) else { return }
        onInsert(marker)
    }
}

/// The read-only card a citation in the manuscript opens: one block per
/// reference the marker cites, in its order.
struct CitationPopover: View {
    let entries: [BibEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                if index > 0 { Divider() }
                Reference(entry: entry)
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
    }

    private struct Reference: View {
        let entry: BibEntry

        var body: some View {
            let citation = entry.citation
            VStack(alignment: .leading, spacing: 4) {
                Text(citation.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if let names = Self.names(citation) {
                    Text(names)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let source = Self.source(citation) {
                    Text(source)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let link = Self.link(citation) {
                    Link(link.label, destination: link.url)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                HStack(spacing: 6) {
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
                .padding(.top, 2)
            }
            .textSelection(.enabled)
        }

        /// Every author, or the editors when there are none.
        static func names(_ citation: Citation) -> String? {
            if !citation.authors.isEmpty { return citation.authors.map(\.display).joined(separator: ", ") }
            guard !citation.editors.isEmpty else { return nil }
            let editors = citation.editors.map(\.display).joined(separator: ", ")
            return editors + (citation.editors.count == 1 ? " (Ed.)" : " (Eds.)")
        }

        /// "Journal, 12(3), 45–67 · 2020": the venue, then where in it, then when.
        static func source(_ citation: Citation) -> String? {
            var location = citation.volume ?? ""
            if let issue = citation.issue { location += "(\(issue))" }
            let venue = [citation.containerTitle ?? citation.publisher, location, citation.page]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
            let parts = [venue, citation.year ?? "n.d."].filter { !$0.isEmpty }
            return parts.joined(separator: " · ")
        }

        static func link(_ citation: Citation) -> (label: String, url: URL)? {
            if let doi = citation.doi, let url = URL(string: "https://doi.org/\(doi)") { return ("doi:\(doi)", url) }
            if let string = citation.url, let url = URL(string: string) { return (string, url) }
            return nil
        }
    }
}
