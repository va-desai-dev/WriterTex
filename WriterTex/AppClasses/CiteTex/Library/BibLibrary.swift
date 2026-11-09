//
//  BibLibrary.swift
//  WriterTex
//
//  The model behind the bibliography views: one per manuscript. It holds the
//  .bib that manuscript has chosen, kept live as it changes, and drains CiteTex
//  captures into it when this manuscript is the capture target.
//
//  Carved from Writerly's CitationLibrary. Dropped: the App Group JSON library,
//  import/export, key renaming, repair, and APA 7 gap tracking. The .bib is now
//  the library, so there is nothing to import into or export out of.
//

import Foundation
import AppKit
import UniformTypeIdentifiers
import Combine

@MainActor
final class BibLibrary: ObservableObject {
    let projectID: UUID
    let projectRoot: URL

    /// The project's chosen .bib, or nil when none is chosen yet.
    @Published private(set) var fileURL: URL?
    @Published private(set) var document: BibDocument?
    /// Captures from the Safari extension not yet written to a .bib.
    @Published private(set) var pendingCaptures = 0
    @Published private(set) var isCaptureTarget = false
    @Published var lastMessage: String?

    /// When true, captures land in the .bib the moment they arrive. When
    /// false, the browser shows a banner and waits for `acceptCaptures()`.
    var autoAcceptCaptures: Bool

    var entries: [BibEntry] { document?.entries ?? [] }

    private let inbox: CiteTexInbox?
    private let selections: any BibSelectionStoring
    private var fileWatch: FileWatcher?
    private var inboxWatch: FileWatcher?
    private var loadTask: Task<Void, Never>?
    /// Edits run one at a time, in order: each re-reads the file, and two
    /// overlapping read-modify-writes would lose one of the edits.
    private var editQueue: Task<Void, Never>?

    /// The library that receives Safari captures. There is one inbox and
    /// possibly several open projects; the capture belongs in exactly one.
    private static weak var captureTarget: BibLibrary?

    /// - Parameters:
    ///   - projectID: The host's stable project identity; the .bib choice is
    ///     remembered under it.
    ///   - root: The manuscript's folder; paths are shown relative to it.
    ///   - inbox: Pass nil for a plain viewer with no Safari capture.
    init(projectID: UUID,
                root: URL,
                selections: any BibSelectionStoring = BibSelectionStore(),
                inbox: CiteTexInbox? = CiteTexInbox(),
                autoAcceptCaptures: Bool = true) {
        self.projectID = projectID
        self.projectRoot = root
        self.selections = selections
        self.inbox = inbox
        self.autoAcceptCaptures = autoAcceptCaptures

        if let inbox {
            do {
                try inbox.prepare()
                inboxWatch = FileWatcher(url: inbox.fileURL) { [weak self] in self?.inboxChanged() }
                inboxWatch?.start()
            } catch {
                lastMessage = "CiteTex inbox unavailable: \(error.localizedDescription)"
            }
            // The first project opened receives captures until another claims them.
            if Self.captureTarget == nil { Self.captureTarget = self; isCaptureTarget = true }
            refreshPending()
        }

        if let saved = selections.bibURL(forProject: projectID, root: root) {
            attach(saved)
        }
    }

    isolated deinit {
        fileWatch?.stop()
        inboxWatch?.stop()
        loadTask?.cancel()
    }

    // MARK: - Choosing the file

    /// Use `url` as this project's bibliography and remember the choice.
    /// Pass nil to clear it.
    func select(_ url: URL?) {
        let url = url?.standardizedFileURL
        selections.setBibURL(url, forProject: projectID, root: projectRoot)
        attach(url)
    }

    /// An open panel for a .bib anywhere on this Mac.
    func chooseOtherFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose Bibliography"
        panel.message = "Choose the .bib file this project cites from."
        panel.allowedContentTypes = [UTType(filenameExtension: "bib") ?? .plainText, .plainText]
        panel.directoryURL = fileURL?.deletingLastPathComponent() ?? projectRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        select(url)
    }

    /// The path as the picker shows it: relative inside the project.
    func displayPath(_ url: URL) -> String {
        BibSelectionStore.relativePath(of: url, root: projectRoot)
    }

    private func attach(_ url: URL?) {
        guard url != fileURL else { return }
        fileWatch?.stop()
        fileWatch = nil
        loadTask?.cancel()
        fileURL = url
        document = nil
        lastMessage = nil
        guard let url else { return }

        fileWatch = FileWatcher(url: url) { [weak self] in self?.reload() }
        fileWatch?.start()
        reload()
        inboxChanged()
    }

    // MARK: - Reading

    /// Re-reads the file. Parsing runs off the main thread; a large .bib takes
    /// a moment to decode all its LaTeX.
    func reload() {
        guard let url = fileURL else { return }
        loadTask?.cancel()
        loadTask = Task {
            do {
                let data = try await Self.read(url)
                let doc = await Task.detached(priority: .userInitiated) { BibDocument(data: data) }.value
                guard !Task.isCancelled, url == fileURL else { return }
                document = doc
            } catch is CancellationError {
            } catch {
                guard url == fileURL else { return }
                document = nil
                lastMessage = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Editing

    func delete(ids: Set<String>) {
        enqueue {
            do {
                try await self.apply { doc in
                    let n = doc.remove(ids: ids)
                    // Plain text: a String shown with Text(_:) is verbatim, so
                    // ^[…](inflect: true) markup would appear literally.
                    return n > 0 ? "Removed \(n) \(n == 1 ? "entry" : "entries")." : nil
                }
            } catch {
                self.lastMessage = error.localizedDescription
            }
        }
    }

    /// Rewrites one entry in place; the rest of the file is untouched.
    /// `original` is the entry's source when editing began.
    func replace(id: String, original: String, with replacement: String) {
        enqueue {
            do {
                try await self.apply { doc in
                    doc.replace(id: id, expected: original, with: replacement)
                        ? "Saved @\(id)."
                        : "@\(id) changed on disk; reopen it to edit."
                }
            } catch {
                self.lastMessage = error.localizedDescription
            }
        }
    }

    private func enqueue(_ edit: @escaping @MainActor () async -> Void) {
        let previous = editQueue
        editQueue = Task {
            await previous?.value
            await edit()
        }
    }

    /// Every edit starts from the file as it is *now*, not from the last load:
    /// the user may have saved from the editor a moment ago, inside the
    /// watcher's debounce window, and that edit must not be overwritten.
    private func apply(_ body: (inout BibDocument) -> String?) async throws {
        guard let url = fileURL else { return }
        loadTask?.cancel()
        var doc: BibDocument
        do {
            doc = BibDocument(data: try await Self.read(url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            doc = BibDocument(text: "")       // chosen but not created yet
        }
        let before = doc.text
        let message = body(&doc)
        if doc.text != before { try await Self.write(doc.data, to: url) }
        guard url == fileURL else { return }
        document = doc
        if let message { lastMessage = message }
    }

    @concurrent nonisolated private static func read(_ url: URL) async throws -> Data {
        try Data(contentsOf: url)
    }

    /// In place, not atomically: the sandbox grants a manuscript's .bib, not
    /// its folder, so there is nowhere to put the temporary file an atomic
    /// write needs.
    @concurrent nonisolated private static func write(_ data: Data, to url: URL) async throws {
        try data.write(to: url)
    }

    // MARK: - CiteTex captures

    /// Make this project the one Safari captures go to. Call when its window
    /// becomes key — not when it resigns: while the user is in Safari no
    /// TypeNBash window is key, and the last one used should still receive.
    func becomeCaptureTarget() {
        guard inbox != nil, Self.captureTarget !== self else { return }
        Self.captureTarget?.isCaptureTarget = false
        Self.captureTarget = self
        isCaptureTarget = true
        inboxChanged()
    }

    /// Moves every waiting capture into this project's .bib. A capture leaves
    /// the inbox only once the .bib write has succeeded.
    func acceptCaptures() {
        enqueue {
            guard let inbox = self.inbox else { return }
            guard self.fileURL != nil else {
                self.lastMessage = "Choose a .bib file to receive captured citations."
                return
            }
            do {
                let captured = try inbox.pending()
                guard !captured.isEmpty else { return }
                try await self.apply { doc in doc.append(captured).summary }
                try inbox.discard(keys: Set(captured.map(\.id)))
            } catch {
                self.lastMessage = "Could not add captures: \(error.localizedDescription)"
            }
            self.refreshPending()
        }
    }

    private func inboxChanged() {
        refreshPending()
        if autoAcceptCaptures, isCaptureTarget, fileURL != nil, pendingCaptures > 0 {
            acceptCaptures()
        }
    }

    private func refreshPending() {
        pendingCaptures = (try? inbox?.pendingCount()) ?? 0
    }

    // MARK: - Finder

    func revealInFinder() {
        guard let url = fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
