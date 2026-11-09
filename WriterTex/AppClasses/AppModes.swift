import SwiftUI
import UniformTypeIdentifiers

/// The two kinds of WriterTex window, each its own document type: a writer
/// never sees the statistics, an analyst never sees the typesetting.
enum AppModes: String, CaseIterable, Hashable, Sendable, Identifiable {
    case files = "Manuscript"
    case notebook = "Analysis Notebook"

    var id: String { rawValue }

    var contentType: UTType {
        switch self {
            case .files: .writerTexManuscript
            case .notebook: .writerTexNotebook
        }
    }

    var newLabel: String {
        switch self {
            case .files: "New Manuscript"
            case .notebook: "New Analysis"
        }
    }

    var symbol: String {
        switch self {
            case .files: "doc.richtext"
            case .notebook: "function"
        }
    }

    var icon: Image { Image(systemName: symbol) }

    /// The custom document glyph (asset catalog symbol) for this mode's files.
    var fileIcon: Image {
        switch self {
            case .files: Image("wrtxfile")
            case .notebook:
                Image("wrstatxfile")
        }
    }

    /// Whether `url` is this kind of document.
    ///
    /// The lookup must name the supertype: it defaults to `public.data`, and the
    /// notebook is a package, so a bare lookup yields a dynamic type for `.wrstatx`.
    func opens(_ url: URL) -> Bool {
        let supertype: UTType = contentType.conforms(to: .package) ? .package : .data
        return UTType(filenameExtension: url.pathExtension, conformingTo: supertype)?
            .conforms(to: contentType) == true
    }
    var fileIconColor: Color {
        switch self {
            case .files: Color(NSColor.hex("F45B38"))
            case .notebook: Color(NSColor.hex("A68978"))
        }
    }
    /// A new, untitled document of this kind, in its own window.
    @MainActor func makeNew(with action: NewDocumentAction) {
        switch self {
            case .files: action { ManuscriptFile() }
            case .notebook: action { NotebookFile() }
        }
    }
}
