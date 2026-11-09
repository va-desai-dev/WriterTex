import AppKit
import Observation

@Observable
@MainActor
final class CrossrefSearchModel {
    enum SortKey: String, CaseIterable, Identifiable {
        case relevance = "Relevance"
        case title = "Title"
        case year = "Year"
        var id: Self { self }
    }

    enum DateFilter: String, CaseIterable, Identifiable {
        case allTime, sinceYear, since4Years, since8Years, custom
        var id: Self { self }

        var title: String {
            switch self {
            case .allTime: "All Time"
            case .sinceYear: "Since \(CrossrefSearchModel.currentYear)"
            case .since4Years: "Since \(CrossrefSearchModel.currentYear - 4)"
            case .since8Years: "Since \(CrossrefSearchModel.currentYear - 8)"
            case .custom: "Custom Range"
            }
        }
    }

    static var currentYear: Int { Calendar.current.component(.year, from: .now) }

    var query = ""
    var sortKey: SortKey = .relevance
    var sortOrder: SortOrder = .forward
    var dateFilter: DateFilter = .allTime { didSet { yearRangeChanged() } }
    var authorFilters: [String] = [] { didSet { authorFilterChanged() } }
    /// Crossref type identifiers to include; empty means every type.
    var typeFilters: Set<String> = [] { didSet { typeFilterChanged() } }

    /// Free-text bounds for `.custom`; a blank or non-numeric field leaves that side open.
    var fromYear = "" { didSet { yearRangeChanged() } }
    var toYear = "" { didSet { yearRangeChanged() } }

    private var fetched: [AcademicSource] = []
    /// The submitted query, year range, authors, and types behind `fetched`, so filter changes re-run that search
    /// rather than whatever is half-typed in the search field.
    private var searchedQuery: String?
    private var searchedRange: (lower: Int?, upper: Int?) = (nil, nil)
    private var searchedAuthors: [String] = []
    private var searchedTypes: Set<String> = []

    /// Author filters with blank rows dropped, so adding an empty field doesn't trigger a search.
    private var cleanedAuthors: [String] {
        authorFilters
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
    private(set) var isSearching = false
    private(set) var message: String?
    private var task: Task<Void, Never>?
    private var requestID = UUID()
    private let service: CrossrefService

    /// Default arguments are evaluated in a nonisolated context, so the main-actor `CrossrefService()`
    /// is built in the body instead.
    init(service: CrossrefService? = nil) { self.service = service ?? CrossrefService() }

    var canSearch: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func search() {
        guard canSearch else { cancel(); fetched = []; searchedQuery = nil; message = nil; return }
        fetched = []
        run(query: query)
    }

    /// Re-runs the last submitted search with the new year range. Debounced so typing a custom
    /// year doesn't fire a request per keystroke; until it lands, `results` filters what's on hand.
    private func yearRangeChanged() {
        guard let searchedQuery, yearRange != searchedRange else { return }
        run(query: searchedQuery, after: .milliseconds(600))
    }

    /// Re-runs the last submitted search when the effective author list changes, including
    /// when the last author is removed, so the results stop being filtered.
    private func authorFilterChanged() {
        guard let searchedQuery, cleanedAuthors != searchedAuthors else { return }
        run(query: searchedQuery, after: .milliseconds(600))
    }

    /// Re-runs the last submitted search with the new type selection. Debounced so ticking several
    /// types in a row sends one request.
    private func typeFilterChanged() {
        guard let searchedQuery, typeFilters != searchedTypes else { return }
        run(query: searchedQuery, after: .milliseconds(600))
    }

    private func run(query: String, after delay: Duration = .zero) {
        cancel()
        let id = UUID()
        requestID = id
        let range = yearRange
        let currentAuthors = cleanedAuthors
        let currentTypes = typeFilters
        searchedQuery = query
        searchedRange = range
        searchedAuthors = currentAuthors
        searchedTypes = currentTypes
        isSearching = true
        message = nil
        task = Task {
            defer { if requestID == id { isSearching = false } }
            do {
                if delay > .zero { try await Task.sleep(for: delay) }

                // Call service.searchSources directly with your array variable
                let sources = try await service.searchSources(
                    query: query,
                    authors: currentAuthors, // Perfectly passes [String] to [String]
                    fromYear: range.lower,
                    untilYear: range.upper,
                    types: currentTypes
                )

                guard !Task.isCancelled, requestID == id else { return }

                var seen = Set<String>()
                let fetched = sources.filter { seen.insert($0.id).inserted }

                if fetched.isEmpty {
                    message = range == (nil, nil) && currentTypes.isEmpty
                        ? "No matches. Try another title, author, or DOI."
                        : "No matches for the selected years or types. Try widening them."
                } else {
                    message = nil
                    self.fetched = fetched // Assign clean data back to UI pipeline array
                }

            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, requestID == id else { return }
                message = error.localizedDescription
            }
        }
    }

    /// Inclusive publication-year bounds for the current date filter; `nil` leaves that side open.
    var yearRange: (lower: Int?, upper: Int?) {
        switch dateFilter {
        case .allTime: return (nil, nil)
        case .sinceYear: return (Self.currentYear, nil)
        case .since4Years: return (Self.currentYear - 4, nil)
        case .since8Years: return (Self.currentYear - 8, nil)
        case .custom:
            let from = Int(fromYear.trimmingCharacters(in: .whitespaces))
            let to = Int(toYear.trimmingCharacters(in: .whitespaces))
            // Tolerate a backwards range rather than showing nothing.
            if let from, let to, from > to { return (to, from) }
            return (from, to)
        }
    }

    /// True when sources were fetched but the date, author, or type filters hide every one of them.
    var isFilteredEmpty: Bool { !fetched.isEmpty && results.isEmpty }

    /// Whether any author filter is in effect, so the empty state can name the right cause.
    var hasAuthorFilter: Bool { !cleanedAuthors.isEmpty }

    /// Lowercased, accent-free words, so "Müller" matches "muller" and "Smith, J." splits into ["smith", "j"].
    private static func nameTokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// Every author filter must match one of the source's authors (editors when it has none).
    /// A filter matches a name when each of its words starts a word of that name, so
    /// "smith j" matches "John Smith" and "J. Smith" but not "Smithson, Ann".
    private func matchesAuthors(_ source: AcademicSource) -> Bool {
        let filters = cleanedAuthors.map( CrossrefSearchModel.nameTokens).filter { !$0.isEmpty }
        guard !filters.isEmpty else { return true }
        let citation = source.citation
        let names = (citation.authors.isEmpty ? citation.editors : citation.authors)
            .map { Self.nameTokens($0.display) }
        return filters.allSatisfy { filter in
            names.contains { name in
                filter.allSatisfy { word in name.contains { $0.hasPrefix(word) } }
            }
        }
    }

    private func matchesYearRange(_ source: AcademicSource) -> Bool {
        let (lower, upper) = yearRange
        guard lower != nil || upper != nil else { return true }
        // Undated sources can't be placed in a range, so any active filter hides them.
        guard let year = source.citation.year.flatMap(Int.init) else { return false }
        return year >= (lower ?? .min) && year <= (upper ?? .max)
    }

    /// Results in the order the user picked, limited to the chosen year range, authors, and types;
    /// `.relevance` keeps Crossref's own ranking.
    var results: [AcademicSource] {
        let fetched = fetched.filter {
            matchesYearRange($0) && matchesAuthors($0) && (typeFilters.isEmpty || typeFilters.contains($0.type))
        }
        switch sortKey {
        case .relevance:
            return fetched
        case .title:
            return fetched.sorted {
                let order = $0.citation.title.localizedStandardCompare($1.citation.title)
                return sortOrder == .forward ? order == .orderedAscending : order == .orderedDescending
            }
        case .year:
            // Undated sources always sink to the bottom, whichever direction is chosen.
            return fetched.sorted {
                switch ($0.citation.year.flatMap(Int.init), $1.citation.year.flatMap(Int.init)) {
                case let (lhs?, rhs?): sortOrder == .forward ? lhs < rhs : lhs > rhs
                case (_?, nil): true
                default: false
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        requestID = UUID()
        isSearching = false
    }
    func add(_ source: AcademicSource, to destination: URL) {

        let entryText = BibTeX.entry(for: source.citation)

        // 2. Set pasteboard contents for standard user convenience
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entryText, forType: .string)
        
        // 3. Resolve the target file path from your library model
        // Assuming destination has a URL property referencing the local .bib file
        let fileURL = destination

        // 4. Safely append the entry block to the end of the file
        // Wrapping in a new line prevents broken formatting if the file doesn't end in a trailing break
        let formattedText = "\n\(entryText)"
        guard let data = formattedText.data(using: .utf8) else { return }

        do {
            if FileManager.default.fileExists(atPath: fileURL.path()) {
                let fileHandle = try FileHandle(forWritingTo: fileURL)
                try fileHandle.seekToEnd() // Advance the stream marker to the absolute end of file
                try fileHandle.write(contentsOf: data) // Commit the byte stream
                try fileHandle.close() // Release file system resource hold

                message = "Appended new entry to bibliography file."
            } else {
                // Fallback: Create the file if it does not exist yet
                try data.write(to: fileURL, options: .atomic)
                message = "Created bibliography file and added entry."
            }
        } catch {
            message = "File Write Error: \(error.localizedDescription)"
        }
    }


    func copy(_ source: AcademicSource) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(BibTeX.entry(for: source.citation), forType: .string)
        message = "Copied BibTeX. Paste it into your bibliography file."
    }

    func dismissMessage() {
        message = nil
    }
}
