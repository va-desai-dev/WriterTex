import AppKit
import Observation



/// Presentation state and citation actions; BibLibrary owns file access and captures.
@MainActor @Observable
final class BibliographyBrowserModel {
    var search = ""
    var selection = Set<String>()
    var pendingRemoval = Set<String>()

    enum Column: Int, CaseIterable {
        case authors, year, title, venue, key

        var title: String {
            switch self {
            case .authors: "Author(s)"
            case .year: "Year"
            case .title: "Title"
            case .venue: "Journal/Publisher"
            case .key: "Key"
            }
        }
    }

    /// One entry's display strings, indexed by `Column.rawValue`.
    struct Row: Equatable, Identifiable {
        let id: String
        let line: Int
        let cells: [String]
    }

    /// Derived once per document, not per cell: `Citation`'s accessors rebuild
    /// names and dates from its JSON fields on every read.
    private(set) var rows: [Row] = []
    private var sortColumn: Column?
    private var sortAscending = true

    func load(_ document: BibDocument?) {
        rows = (document?.entries ?? []).map { entry in
            let citation = entry.citation
            return Row(id: entry.id, line: entry.line,
                       cells: [citation.nameClean, citation.year ?? "n.d.", citation.title,
                               citation.publisher ?? citation.containerTitle ?? "", entry.key])
        }
        sortRows()
    }

    func sort(by column: Column, ascending: Bool) {
        sortColumn = column
        sortAscending = ascending
        sortRows()
    }

    private func sortRows() {
        guard let column = sortColumn?.rawValue else { return }
        let ascending = sortAscending
        rows.sort { lhs, rhs in
            let order = lhs.cells[column].localizedStandardCompare(rhs.cells[column])
            // Ties keep file order, in either direction.
            if order == .orderedSame { return lhs.line < rhs.line }
            return ascending == (order == .orderedAscending)
        }
    }

    func entries(in library: BibLibrary) -> [BibEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return library.entries }
        return library.entries.filter { entry in
            let citation = entry.citation
            return ([entry.key, citation.title, citation.containerTitle ?? ""]
                    + citation.authors.map(\.display) + citation.editors.map(\.display))
                .contains { $0.localizedStandardContains(query) }
        }
    }

    func citation(ids: Set<String>, in library: BibLibrary) -> String? {
        var seen = Set<String>()
        let keys = library.entries.filter { ids.contains($0.id) }
            .map(\.key).filter { seen.insert($0).inserted }
        return keys.isEmpty ? nil : "[" + keys.map { "@\($0)" }.joined(separator: "; ") + "]"
    }

    func copy(ids: Set<String>, in library: BibLibrary, source: Bool = false) {
        let text: String?
        if source, let document = library.document {
            let entries = document.entries.filter { ids.contains($0.id) }
            text = entries.isEmpty ? nil : entries.map { document.source(of: $0) }.joined(separator: "\n\n") + "\n"
        } else {
            text = citation(ids: ids, in: library)
        }
        guard let text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func remove(from library: BibLibrary) {
        library.delete(ids: pendingRemoval)
        selection.subtract(pendingRemoval)
        pendingRemoval.removeAll()
    }

    func reset() {
        search = ""
        selection.removeAll()
        pendingRemoval.removeAll()
    }
}
