import Foundation

struct CrossrefResponse<Message: Decodable>: Decodable {
    let message: Message
}

struct CrossrefMessage: Decodable {
    let items: [AcademicSource]
}

/// Groups of Crossref work types offered by the search filter. `members` are Crossref's own type
/// identifiers, as sent in `filter=type:…` and returned in each work's `type` field.
enum CrossrefTypes: String, Sendable, CaseIterable, Identifiable {
    case journalart = "Articles & Papers"
    case books = "Books & Chapters"
    case institutional = "Institutional Material"
    var id: String { rawValue }

    var members: [String] {
        switch self {
        case .journalart:
            ["journal-article", "proceedings-article", "posted-content"]
        case .books:
            ["book", "book-chapter", "book-section", "book-part", "monograph", "edited-book", "reference-book"]
        case .institutional:
            ["dissertation", "report", "standard", "dataset", "grant", "peer-review", "component"]
        }
    }

    /// Readable name for a Crossref type identifier, e.g. "book-chapter" → "Book Chapter".
    static func title(for type: String) -> String {
        switch type {
        case "posted-content": "Preprint"
        case "proceedings-article": "Conference Paper"
        case "peer-review": "Peer Review Report"
        default: type.split(separator: "-").map(\.capitalized).joined(separator: " ")
        }
    }
}

/// Crossref work metadata adapted to the CSL records used by the bibliography.
struct AcademicSource: Decodable, Identifiable {
    let doi: String
    let citation: Citation
    /// Crossref's type identifier (e.g. "journal-article"), before mapping to a CSL type.
    let type: String
    var id: String { doi.lowercased() }
    var url: URL? {
        var components = URLComponents(string: "https://doi.org")!
        components.path = "/" + doi
        return components.url
    }

    init(from decoder: Decoder) throws {
        var fields = try [String: JSONValue](from: decoder)
        guard let doi = fields["DOI"]?.stringValue, !doi.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Missing DOI"))
        }
        self.doi = doi
        for key in ["title", "container-title", "ISBN", "ISSN"] {
            if let values = fields[key]?.arrayValue {
                fields[key] = values.first
            }
        }
        let types = ["journal-article": "article-journal",
                     "proceedings-article": "paper-conference",
                     "book-chapter": "chapter",
                     "book-part": "chapter",
                     "book-section": "chapter",
                     "monograph": "book",
                     "edited-book": "book",
                     "reference-book": "book",
                     "dissertation": "thesis",
                     "posted-content": "document"
        ]
        let type = fields["type"]?.stringValue ?? "document"
        fields["type"] = .string(types[type] ?? type)
        self.type = type
        if fields["issued"] == nil { fields["issued"] = fields["published"] }
        for key in ["author", "editor"] {
            if let names = fields[key]?.arrayValue {
                fields[key] = .array(names.map { value in
                    guard var name = value.objectValue else { return value }
                    if let literal = name["name"] { name["literal"] = literal }
                    return .object(name)
                })
            }
        }
        CitationNormalizer.repair(&fields)
        fields["id"] = .string(CitationNormalizer.mintKey(for: fields))
        citation = Citation(fields: fields)
    }
}

struct CrossrefService {
    var session: URLSession = .shared

    static func normalizedDOI(_ input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: value), let host = url.host?.lowercased(),
           ["doi.org", "dx.doi.org"].contains(host), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            value = String(url.path.dropFirst())
        } else if value.lowercased().hasPrefix("doi:") {
            value = String(value.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard value.range(of: #"^10\.\d{4,9}/\S+$"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    /// Searches works, optionally limited to an inclusive publication-year range (`nil` leaves that side open)
    /// and to Crossref work types (empty allows every type). Neither applies to exact DOI lookups.
    func searchSources(
        query: String,
        authors: [String] = [], // Fixed: Added missing authors array parameter
        fromYear: Int? = nil,
        untilYear: Int? = nil,
        types: Set<String> = [],
        maxRows: Int = 100
    ) async throws -> [AcademicSource] {

        let cleanedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedQuery.isEmpty else { return [] }

        // Check for exact DOI early execution exit
        if let doi = Self.normalizedDOI(cleanedQuery) {
            return [try await lookup(doi: doi)]
        }

        // 1. Initialize an empty dynamic array of query items
        var queryItems: [URLQueryItem] = []

        // 2. Add standard bibliographic text query
        queryItems.append(URLQueryItem(name: "query.bibliographic", value: cleanedQuery))
        queryItems.append(URLQueryItem(name: "rows", value: String(min(max(maxRows, 1), 1000))))

        // 3. Process and append multiple authors if present
        let filteredAuthors = authors.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !filteredAuthors.isEmpty {
            let combinedAuthors = filteredAuthors.joined(separator: " ")
            queryItems.append(URLQueryItem(name: "query.author", value: combinedAuthors))
        }

        // 4. Correctly build Crossref-style comma-separated filter strings
        var filters: [String] = []

        if let fromYear = fromYear {
            filters.append("from-pub-date:\(fromYear)")
        }
        if let untilYear = untilYear {
            filters.append("until-pub-date:\(untilYear)")
        }
        // Crossref ORs repeated values of the same filter, so this matches any selected type.
        filters += types.sorted().map { "type:\($0)" }

        if !filters.isEmpty {
            let combinedFilters = filters.joined(separator: ",")
            queryItems.append(URLQueryItem(name: "filter", value: combinedFilters))
        }

        // 5. Fire request
        let message: CrossrefMessage = try await fetch(path: "/works", query: queryItems)
        return message.items
    }

    func lookup(doi: String) async throws -> AcademicSource {
        guard let doi = Self.normalizedDOI(doi) else { throw CrossrefError.invalidDOI }
        return try await fetch(path: "/works/" + doi)
    }

    private func fetch<Message: Decodable>(path: String, query: [URLQueryItem] = []) async throws -> Message {
        var components = URLComponents(string: "https://api.crossref.org")!
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("TypeNBash/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard response.statusCode == 200 else { throw CrossrefError.http(response.statusCode) }
        return try JSONDecoder().decode(CrossrefResponse<Message>.self, from: data).message
    }
}

enum CrossrefError: LocalizedError {
    case invalidDOI, http(Int)
    var errorDescription: String? {
        switch self {
        case .invalidDOI: "Enter a DOI such as 10.1038/nphys1170 or a doi.org URL."
        case .http(404): "No Crossref record was found for this DOI."
        case .http(429): "Crossref is receiving too many requests. Please try again shortly."
        case .http(let status): "Crossref could not complete the request (HTTP \(status)). Try again."
        }
    }
}
