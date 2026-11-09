import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
@testable import WriterTex

/// A `.wrtx` manuscript as a document: what it saves, and the one .bib it
/// links to, which it keeps across saves, Undo and a missing file.
@main
struct ManuscriptFileChecks {
    @MainActor static func main() async throws {
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL"): \(label)")
            if !condition { failures += 1 }
        }
        func settle(_ done: () -> Bool) async throws {
            for _ in 0..<150 where !done() { try await Task.sleep(for: .milliseconds(20)) }
        }
        AppDefaults.register()

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Manuscript \(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bibURL = folder.appendingPathComponent("references.bib")
        try Data("""
        @article{smith2020, author = {Smith, Jane}, title = {On Things}, year = {2020}}
        @book{doe2019, author = {Doe, John}, title = {Other Things}, year = {2019}}

        """.utf8).write(to: bibURL)

        check(UTType.writerTexManuscript.preferredFilenameExtension == "wrtx", "Manuscripts are .wrtx files")

        // A new manuscript, with a bibliography chosen for it.
        let file = ManuscriptFile()
        let undo = UndoManager()
        undo.groupsByEvent = false
        file.undoManager = undo
        let session = ManuscriptSession(file: file, fileURL: nil)
        defer { session.close() }
        check(session.editor.selectedFile == nil, "A new manuscript opens untitled in its editor")
        check(session.bibliography.fileURL == nil, "A new manuscript cites nothing yet")

        undo.beginUndoGrouping()
        session.bibliography.select(bibURL)
        undo.endUndoGrouping()
        try await settle { session.bibliography.entries.count == 2 }
        check(session.bibliography.entries.count == 2, "The chosen .bib is read where it is, not copied")
        check(undo.canUndo && undo.undoActionName == "Choose Bibliography",
              "Choosing it is an undoable edit, which is what marks the window edited")

        // Saving writes the text and the link together.
        let saved = try file.snapshot(contentType: .writerTexManuscript)
        check(saved.starts(with: Data("bplist".utf8)), "An untouched new manuscript still saves in the current format")
        check(ManuscriptDocument.bibliography(in: saved)?.path == bibURL.standardizedFileURL.path,
              "The link to the .bib is saved inside the manuscript")
        let text = try ManuscriptDocument.decode(saved, using: MarkdownRichText(baseURL: nil, style: MarkdownStyleSheet(theme: .screen, manuscript: .screen)))
        check(text.length == 0, "And the text alongside it")

        // Reopening follows the saved link.
        let reopened = ManuscriptFile(contents: saved)
        let second = ManuscriptSession(file: reopened, fileURL: folder.appendingPathComponent("Paper.wrtx"))
        defer { second.close() }
        try await settle { second.bibliography.entries.count == 2 }
        check(second.bibliography.fileURL?.standardizedFileURL == bibURL.standardizedFileURL,
              "A reopened manuscript cites the same .bib")
        check(second.title == "Paper", "Its window is named after the file")

        // Edits to the bibliography land in the .bib itself.
        second.bibliography.delete(ids: ["doe2019"])
        try await settle { (try? String(contentsOf: bibURL, encoding: .utf8))?.contains("doe2019") == false }
        let rewritten = try String(contentsOf: bibURL, encoding: .utf8)
        check(!rewritten.contains("doe2019") && rewritten.contains("smith2020"),
              "Removing a citation rewrites the linked .bib in place")

        // Undo and redo follow the choice.
        undo.undo()
        check(session.bibliography.fileURL == nil, "Undo unlinks the bibliography")
        check(ManuscriptDocument.bibliography(in: try file.snapshot(contentType: .writerTexManuscript)) == nil,
              "And the manuscript saves without it")
        undo.redo()
        try await settle { session.bibliography.fileURL != nil }
        check(session.bibliography.fileURL?.standardizedFileURL == bibURL.standardizedFileURL, "Redo links it again")

        // Save As and renames keep the editor, and only retitle it.
        session.fileMoved(to: folder.appendingPathComponent("Thesis.wrtx"))
        check(session.title == "Thesis" && session.editor.selectedFile != nil, "Saving names the untitled manuscript")

        // A manuscript from another Mac, or whose .bib is gone.
        try FileManager.default.removeItem(at: bibURL)
        let orphan = ManuscriptFile(contents: saved)
        let third = ManuscriptSession(file: orphan, fileURL: nil)
        defer { third.close() }
        check(third.bibliography.fileURL == nil && orphan.unreachableBibliography == "references.bib",
              "A .bib this Mac can't reach is named, so it can be relinked")
        check(ManuscriptDocument.bibliography(in: try orphan.snapshot(contentType: .writerTexManuscript)) != nil,
              "Saving keeps the link rather than dropping it")

        // Manuscripts written before the link existed.
        let older = try ManuscriptDocument.encode(NSAttributedString(string: "Hello"))
        check(ManuscriptDocument.bibliography(in: older) == nil, "An older manuscript opens with no bibliography")
        let linked = try ManuscriptDocument.linking(older, to: nil)
        check(try ManuscriptDocument.decode(linked, using: MarkdownRichText(baseURL: nil, style: MarkdownStyleSheet(theme: .screen, manuscript: .screen))).string == "Hello",
              "Relinking leaves the text alone")

        // A new window shows its document, as DocumentGroup mounts it.
        func views(in view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(views) }
        func mount<Content: View>(_ content: Content) -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: content)
            window.orderFront(nil)
            return window
        }
        let targets = CiteTexTargets.shared.targets.count
        let newManuscript = ManuscriptFile()
        let manuscriptWindow = mount(ManuscriptWindow(file: newManuscript, fileURL: nil))
        try await settle { views(in: manuscriptWindow.contentView!).contains { $0 is MarkdownRichTextView } }
        check(newManuscript.editor != nil, "A new manuscript window makes its session")
        check(views(in: manuscriptWindow.contentView!).contains { $0 is MarkdownRichTextView },
              "And shows the manuscript in its editor, not a blank pane")
        check(CiteTexTargets.shared.targets.count == targets + 1,
              "Its session stays open once the window shows it")
        // The Stats tab counts once the editor attaches, even before the manuscript has a name.
        try await settle { newManuscript.editor?.pendingReadableText != nil }
        check(newManuscript.editor?.pendingReadableText != nil,
              "An untitled manuscript's writing stats are counted, not refused as unsupported")
        manuscriptWindow.close()

        let notebookWindow = mount(NotebookWindow(file: NotebookFile(), fileURL: nil))
        try await settle { views(in: notebookWindow.contentView!).contains { $0 is NSTextField } }
        check(views(in: notebookWindow.contentView!).contains { $0 is NSTextField },
              "A new notebook window shows the notebook, not a blank pane")
        notebookWindow.close()

        precondition(failures == 0, "\(failures) manuscript file checks failed")
    }
}
