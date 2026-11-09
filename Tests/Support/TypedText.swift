import AppKit
@testable import WriterTex

/// Stands in for the Formatted editor: hands `FileBrowserModel` body text as if
/// the user had typed it, through the same `PendingMarkdownSource` hand-off.
@MainActor
final class TypedText: PendingMarkdownSource {
    private var text: String?
    private(set) var readableText: String

    init(_ text: String, edited: Bool = true) {
        self.text = edited ? text : nil
        readableText = text
    }

    func takeRichText() throws -> Data? {
        defer { text = nil }
        let style = MarkdownStyleSheet(theme: .screen, manuscript: .screen)
        return try text.map { try ManuscriptDocument.encode(NSAttributedString(string: $0, attributes: style.bodyAttributes)) }
    }
}

/// The model only holds its editor weakly; the checks keep the stand-ins alive.
@MainActor private var typedSources: [TypedText] = []

extension FileBrowserModel {
    /// Replaces the open manuscript's text as an edit, the way typing does.
    func type(_ text: String) {
        let source = TypedText(text)
        typedSources.append(source)
        attachPendingMarkdown(source)
        markPendingMarkdownEdited()
        commitPendingMarkdown()
    }

    /// Attaches a stand-in editor showing the open manuscript's `text`, unedited.
    func attachEditor(showing text: String) {
        let source = TypedText(text, edited: false)
        typedSources.append(source)
        attachPendingMarkdown(source)
    }
}
