//
//  Item.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 9/12/26.
//
import AppKit
import Observation

/// An editor that keeps edits in native text storage and encodes only on request.
@MainActor protocol PendingMarkdownSource: AnyObject {
    /// The text as shown, one paragraph per line.
    var readableText: String { get }
    /// The edited document as RTFD, or nil when nothing changed since the last call.
    func takeRichText() throws -> Data?
    var richTextSnapshot: NSAttributedString? { get }
}

extension PendingMarkdownSource {
    var richTextSnapshot: NSAttributedString? { nil }
}

/// A manuscript window's document as its editor shows it. The system saves
/// it, asking `documentContents()`; nothing here writes the file.
@MainActor
@Observable
final class FileBrowserModel {
    /// Where the manuscript is saved; nil while it's untitled.
    private(set) var selectedFile: URL?
    /// The manuscript as RTFD, as opened or as the editor last handed it over.
    var richData: Data { hosted.data }
    /// Bumped by each `hostDocument`, so hosting the same bytes again still
    /// replaces what the editor shows. Observed with `richData`, as one value.
    var hostRevision: Int { hosted.revision }
    private var hosted = (revision: 0, data: Data())
    private(set) var hasUnsavedChanges = false
    private(set) var saveError: String?
    private var savedRichData: Data?

    func reportDocumentError(_ error: Error) { saveError = error.localizedDescription }

    /// Live native edits. Observed, so writing counts appear once the editor attaches.
    private weak var pendingMarkdown: (any PendingMarkdownSource)?

    /// The Formatted editor registers here once it has loaded the document.
    func attachPendingMarkdown(_ source: any PendingMarkdownSource) {
        if pendingMarkdown !== source { pendingMarkdown = source }
    }

    func detachPendingMarkdown(_ source: any PendingMarkdownSource) {
        if pendingMarkdown === source { pendingMarkdown = nil }
    }

    /// The Formatted editor's first edit since it last handed over its document.
    func markPendingMarkdownEdited() {
        if !hasUnsavedChanges { hasUnsavedChanges = true }
    }

    /// Commits native edits, as RTFD, for saving or a view handoff.
    @discardableResult func commitPendingMarkdown() -> Bool {
        guard let source = pendingMarkdown else { return true }
        do {
            if let data = try source.takeRichText() {
                hosted.data = data
                hasUnsavedChanges = data != savedRichData
            }
            return true
        } catch {
            reportDocumentError(error)
            return false
        }
    }

    /// Exports read the live rich text, or the opened document when no editor is attached.
    func manuscriptSnapshot() throws -> NSAttributedString {
        if let text = pendingMarkdown?.richTextSnapshot { return text }
        let document = MarkdownRichText(baseURL: selectedFile?.deletingLastPathComponent(), style: MarkdownStyleSheet(theme: .screen, manuscript: .screen))
        return try ManuscriptDocument.decode(richData, using: document)
    }

    /// The Formatted editor's visible text, for writing counts; nil until it attaches.
    var pendingReadableText: String? { pendingMarkdown?.readableText }

    /// Shows a manuscript window's document, untitled when `url` is nil.
    func hostDocument(_ data: Data, at url: URL?) {
        pendingMarkdown = nil
        selectedFile = url
        hosted = (hosted.revision + 1, data)
        savedRichData = data
        hasUnsavedChanges = false
        saveError = nil
    }

    /// The same document after Save As, a move or a rename.
    func documentMoved(to url: URL?) {
        selectedFile = url
    }

    /// The manuscript as it stands, edits included, encoded for saving. What
    /// it returns is the new saved baseline, so Save disables until the next edit.
    func documentContents() throws -> Data {
        guard commitPendingMarkdown() else { throw CocoaError(.fileWriteUnknown) }
        savedRichData = richData
        hasUnsavedChanges = false
        if richData.starts(with: Data("bplist".utf8)) { return richData }
        // A new or older plain-RTF manuscript is written in the current format.
        return try ManuscriptDocument.encode(manuscriptSnapshot())
    }

    /// The first nonempty line, which names an untitled manuscript's export.
    var writerTexDocTitle: String {
        guard let text = try? manuscriptSnapshot() else { return "Untitled Document" }
        return text.string.components(separatedBy: .newlines).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? "Untitled Document"
    }
}
