import Foundation
import UniformTypeIdentifiers

/// The two kinds of WriterTex document, declared in Info.plist.
nonisolated extension UTType {
    /// One manuscript, with the link to its bibliography.
    static let writerTexManuscript = UTType(exportedAs: "VD.WriterTex.wrtx", conformingTo: .data)
    /// A package holding an analysis notebook and the datasets it reads.
    static let writerTexNotebook = UTType(exportedAs: "VD.WriterTex.wrstatx", conformingTo: .package)
    /// .bib has no system-declared type; this dynamic one still filters panels by extension.
    static let bibTeX = UTType(filenameExtension: "bib") ?? .plainText
}

/// The one .bib a manuscript cites from, stored inside the manuscript.
///
/// The bookmark is app-scoped, so on this Mac the file reopens without asking
/// again even though the sandbox only granted it when it was chosen. Bookmarks
/// mean nothing on another Mac; there `path` still names the file and starts
/// the panel that relinks it.
nonisolated struct BibliographyLink: Codable, Hashable, Sendable {
    var bookmark: Data
    var path: String

    var fileName: String { URL(fileURLWithPath: path).lastPathComponent }

    /// Call while the sandbox grants `url`, such as right after an open panel.
    init(_ url: URL) throws {
        bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        path = url.standardizedFileURL.path
    }

    /// The file, if this Mac can still reach it. A stale bookmark still
    /// resolves; renew it once access has started.
    func resolve() -> (url: URL, isStale: Bool)? {
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &isStale) else { return nil }
        return (url, isStale)
    }
}

/// A refusal with a message written for the person who asked.
enum ProjectSetupError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}
