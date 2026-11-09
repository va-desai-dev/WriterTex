import Foundation
import Observation

/// The citation styles exports can use: APA, which ships inside CSLKit, and
/// whatever the user adds from the CSL project's style repository on GitHub
/// or from a .csl file. Styles are app-wide, kept in Application Support.
@MainActor @Observable
final class CitationStyleLibrary {
    static let shared = CitationStyleLibrary()

    struct Style: Identifiable, Hashable {
        let id: String
        let title: String
        let isBundled: Bool
        /// Journal styles that borrow another style's rules.
        let parentID: String?
    }

    /// A style the repository offers. Only its id is known until it's downloaded.
    struct CatalogEntry: Identifiable, Hashable {
        let id: String
        let isDependent: Bool
        let name: String
    }

    private(set) var styles: [Style] = []
    /// Every style in the repository, once fetched.
    private(set) var catalog: [CatalogEntry]?

    private let folder: URL
    private let session: URLSession

    /// Raw files in the official repository, and the listing of all of them.
    private static let repository = URL(string: "https://raw.githubusercontent.com/citation-style-language/styles/master/")!
    private static let listing = URL(string: "https://api.github.com/repos/citation-style-language/styles/git/trees/master?recursive=1")!
    /// The listing is 3 MB and GitHub limits anonymous requests, so it's kept a week.
    private static let catalogLifetime: TimeInterval = 7 * 24 * 3600

    init(folder: URL = .applicationSupportDirectory.appending(path: "Citation Styles", directoryHint: .isDirectory),
         session: URLSession = .shared) {
        self.folder = folder
        self.session = session
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        var found = CSLStyle.bundledIDs.compactMap { id in
            CSLStyle.bundledData(id).flatMap { try? CSLStyle(xml: $0) }.map { Style(id: id, title: $0.title, isBundled: true, parentID: nil) }
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "csl" {
            let id = file.deletingPathExtension().lastPathComponent
            guard !found.contains(where: { $0.id == id }),
                  let style = try? CSLStyle(xml: Data(contentsOf: file)) else { continue }
            found.append(Style(id: id, title: style.title, isBundled: false, parentID: style.parentID))
        }
        styles = found.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func contains(_ id: String) -> Bool { styles.contains { $0.id == id } }

    /// The style to format with: a journal style resolves to its parent's rules.
    func style(_ id: String) throws -> CSLStyle {
        let style = try load(id)
        guard style.isDependent, let parent = style.parentID else { return style }
        do { return try load(parent) } catch { throw CSLError.dependent(parent: parent) }
    }

    private func load(_ id: String) throws -> CSLStyle {
        if let data = CSLStyle.bundledData(id) { return try CSLStyle(xml: data) }
        return try CSLStyle(xml: Data(contentsOf: file(id)))
    }

    private func file(_ id: String) -> URL { folder.appending(path: id + ".csl", directoryHint: .notDirectory) }

    // MARK: Adding and removing

    /// Adds a .csl file the user chose.
    @discardableResult
    func install(contentsOf url: URL) async throws -> Style {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try await install(Data(contentsOf: url))
    }

    /// Downloads a style from the repository.
    @discardableResult
    func download(_ entry: CatalogEntry) async throws -> Style {
        try await install(fetch(Self.repository.appending(path: (entry.isDependent ? "dependent/" : "") + entry.id + ".csl")))
    }

    /// Saves a style, first fetching the parent a journal style depends on.
    private func install(_ data: Data) async throws -> Style {
        let style = try CSLStyle(xml: data)
        guard !style.id.isEmpty else { throw CSLError.notAStyle }
        if style.isDependent, let parent = style.parentID, !contains(parent) {
            let parentData = try await fetch(Self.repository.appending(path: parent + ".csl"))
            _ = try CSLStyle(xml: parentData)
            try parentData.write(to: file(parent), options: .atomic)
        }
        try data.write(to: file(style.id), options: .atomic)
        reload()
        return styles.first { $0.id == style.id } ?? Style(id: style.id, title: style.title, isBundled: false, parentID: style.parentID)
    }

    /// Removes a downloaded style. APA stays.
    func remove(_ id: String) {
        guard CSLStyle.bundledData(id) == nil else { return }
        try? FileManager.default.removeItem(at: file(id))
        reload()
    }

    // MARK: Catalog

    private var catalogFile: URL { folder.appending(path: ".catalog.json", directoryHint: .notDirectory) }

    private struct Listing: Decodable {
        struct Node: Decodable { let path: String }
        let tree: [Node]
    }

    /// Every style in the repository: independent styles at its root, journal
    /// styles under `dependent/`. Read from a week-old copy when there is one.
    func loadCatalog(refresh: Bool = false) async throws {
        var data: Data?
        if !refresh, let modified = try? catalogFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(modified) < Self.catalogLifetime {
            data = try? Data(contentsOf: catalogFile)
        }
        if data == nil {
            let fetched = try await fetch(Self.listing)
            try? fetched.write(to: catalogFile, options: .atomic)
            data = fetched
        }
        let listing = try JSONDecoder().decode(Listing.self, from: data ?? Data())
        catalog = listing.tree.compactMap { node in
            guard node.path.hasSuffix(".csl") else { return nil }
            let parts = node.path.dropLast(4).split(separator: "/")
            guard parts.count == 1 || (parts.count == 2 && parts[0] == "dependent") else { return nil }
            let id = String(parts.last!)
            return CatalogEntry(id: id, isDependent: parts.count == 2, name: Self.displayName(id))
        }.sorted {
            // General styles first; the eight thousand journal styles follow.
            $0.isDependent != $1.isDependent ? !$0.isDependent : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static let acronyms: Set<String> = ["apa", "mla", "ieee", "acs", "ama", "asa", "acm", "aip", "aps", "bmj", "cse",
                                                "nlm", "iso", "rsc", "apsa", "mhra", "oscola", "sist", "aaa", "aea", "ams",
                                                "jama", "nejm", "plos", "sage", "spie"]
    private static let minor: Set<String> = ["of", "and", "the", "for", "in", "on", "de", "des", "du", "la", "le", "et", "und", "für", "fur"]

    /// "academy-of-management-review" → "Academy of Management Review".
    static func displayName(_ id: String) -> String {
        id.split(separator: "-").enumerated().map { index, word in
            let lower = word.lowercased()
            if acronyms.contains(lower) { return lower.uppercased() }
            if index > 0, minor.contains(lower) { return lower }
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }.joined(separator: " ")
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("WriterTex", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw URLError(.badServerResponse) }
        switch status {
        case 200: return data
        case 403, 429: throw StyleDownloadError.rateLimited
        case 404: throw StyleDownloadError.notFound
        default: throw StyleDownloadError.http(status)
        }
    }
}

enum StyleDownloadError: LocalizedError {
    case rateLimited, notFound, http(Int)

    var errorDescription: String? {
        switch self {
        case .rateLimited: "GitHub is limiting requests right now. Try again in a few minutes."
        case .notFound: "That style is no longer in the CSL repository."
        case .http(let status): "The CSL repository couldn’t be reached (HTTP \(status))."
        }
    }
}
