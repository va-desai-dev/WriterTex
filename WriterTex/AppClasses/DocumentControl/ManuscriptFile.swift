import SwiftUI
import UniformTypeIdentifiers
import Combine

/// A `.wrtx` manuscript: one per window. The open editor holds the live text,
/// so saving asks it; `contents` is only what the window opened with.
///
/// It is also where its `BibLibrary` keeps the .bib choice, so the one
/// bibliography a manuscript cites from travels inside the manuscript.
final class ManuscriptFile: ReferenceFileDocument, BibSelectionStoring {
    static var readableContentTypes: [UTType] { [.writerTexManuscript] }

    let contents: Data
    private(set) var bibliography: BibliographyLink?
    /// The linked .bib's name when this Mac can't reach it, for the relink prompt.
    @Published private(set) var unreachableBibliography: String?

    /// Asked for the text when the system saves.
    weak var editor: FileBrowserModel?
    /// Re-attached on Undo, so the library follows the restored choice.
    weak var library: BibLibrary?
    /// The window's, so choosing a bibliography marks the manuscript edited.
    weak var undoManager: UndoManager?
    /// The .bib this window is reading, held open for the sandbox.
    private var accessed: URL?

    /// Empty for a new manuscript.
    nonisolated init(contents: Data = Data()) {
        self.contents = contents
        bibliography = ManuscriptDocument.bibliography(in: contents)
    }

    nonisolated convenience init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.init(contents: data)
    }



    func snapshot(contentType: UTType) throws -> Data {
        let text = try editor?.documentContents() ?? contents
        guard !text.isEmpty else { return text }
        return try ManuscriptDocument.linking(text, to: bibliography)
    }

    nonisolated func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)
    }

    isolated deinit {
        accessed?.stopAccessingSecurityScopedResource()
    }

    // MARK: BibSelectionStoring

    func bibURL(forProject id: UUID, root: URL) -> URL? { resolveLink() }

    /// Links `url`, or no bibliography, as one undoable change.
    func setBibURL(_ url: URL?, forProject id: UUID, root: URL) {
        guard !isRestoring else { return }
        let previous = bibliography
        if let url {
            guard let link = try? BibliographyLink(url) else {
                library?.lastMessage = "WriterTex can’t keep access to \(url.lastPathComponent). Choose it again."
                return
            }
            bibliography = link
        } else {
            bibliography = nil
        }
        access(url)
        unreachableBibliography = nil
        registerUndo(restoring: previous, named: url == nil ? "Remove Bibliography" : "Choose Bibliography")
    }

    /// Set while Undo hands the library a restored choice, which it echoes back.
    private var isRestoring = false

    private func restore(_ link: BibliographyLink?) {
        let current = bibliography
        bibliography = link
        unreachableBibliography = nil
        let url = resolveLink()
        if url == nil { access(nil) }
        isRestoring = true
        library?.select(url)
        isRestoring = false
        registerUndo(restoring: current, named: "Choose Bibliography")
    }

    private func registerUndo(restoring link: BibliographyLink?, named name: String) {
        undoManager?.registerUndo(withTarget: self) { $0.restore(link) }
        undoManager?.setActionName(name)
    }

    /// The linked file, opened for the sandbox, or nil when this Mac can't reach it.
    private func resolveLink() -> URL? {
        guard let bibliography else { return nil }
        guard let (url, isStale) = bibliography.resolve() else {
            unreachableBibliography = bibliography.fileName
            return nil
        }
        access(url)
        if isStale, let renewed = try? BibliographyLink(url) { self.bibliography = renewed }
        return url
    }

    private func access(_ url: URL?) {
        guard url != accessed else { return }
        accessed?.stopAccessingSecurityScopedResource()
        accessed = url
        _ = url?.startAccessingSecurityScopedResource()
    }
}

/// What a manuscript window works with: its file, the editor showing it and
/// the bibliography it cites.
@MainActor
@Observable
final class ManuscriptSession {
    let file: ManuscriptFile
    let editor = FileBrowserModel()
    let bibliography: BibLibrary
    private var citeTexTargetID: UUID?

    init(file: ManuscriptFile, fileURL: URL?) {
        self.file = file
        editor.hostDocument(file.contents, at: fileURL)
        file.editor = editor
        bibliography = BibLibrary(
            projectID: UUID(),
            root: fileURL?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser,
            selections: file,
            inbox: CiteTexInbox(appGroup: CiteTexInbox.writerTexAppGroup)
        )
        file.library = bibliography
        citeTexTargetID = CiteTexTargets.shared.register(bibliography, projectName: Self.name(fileURL))
    }

    var title: String { Self.name(editor.selectedFile) }

    private static func name(_ url: URL?) -> String {
        url?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    /// A new .bib at `url`, chosen in a save panel, linked as this manuscript's.
    /// A file already there is linked as it is, never emptied.
    func createBibliography(at url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url, options: .withoutOverwriting)
        }
        bibliography.select(url)
    }

    func fileMoved(to url: URL?) {
        editor.documentMoved(to: url)
        if let citeTexTargetID { CiteTexTargets.shared.rename(citeTexTargetID, to: title) }
    }

    func close() {
        if let citeTexTargetID { CiteTexTargets.shared.unregister(citeTexTargetID) }
        citeTexTargetID = nil
    }
}


/// One heading in a manuscript's outline.
struct DecodedHeading: Identifiable, Equatable {
    let level: Int     // 1 through 6
    let text: String   // The heading string
    /// Where the heading starts in the text; unique, so repeated titles stay distinct rows.
    let location: Int
    var id: Int { location }

    /// The headings in editor text, which marks each heading paragraph with `.markdownHeading`.
    static func headings(in text: NSAttributedString) -> [DecodedHeading] {
        var found: [DecodedHeading] = []
        let string = text.string as NSString
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length),
                                   options: .byParagraphs) { paragraph, range, _, _ in
            guard range.length > 0,
                  let level = text.attribute(.markdownHeading, at: range.location, effectiveRange: nil) as? Int,
                  (1...6).contains(level),
                  let title = paragraph?.trimmingCharacters(in: .whitespaces), !title.isEmpty
            else { return }
            found.append(DecodedHeading(level: level, text: title, location: range.location))
        }
        return found
    }
}
