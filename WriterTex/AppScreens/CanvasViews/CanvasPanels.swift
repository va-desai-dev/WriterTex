import SwiftUI


struct WorkspacePane: View {
    let model: FileBrowserModel
    var bibliography: BibLibrary? = nil
    @State var session = EditorSession()
    /// Where manuscript exports go: the project's output folder. Nil exports beside the document.
    var outputDirectory: (@MainActor @Sendable () async throws -> URL)? = nil
    @State private var showsExport = false
    /// Whether the editor draws text in the card color on a foreground-colored page.
    @Binding var invertsDocumentColors: Bool

    var body: some View {
        FileViewer(model: model, session: session, bibliography: bibliography,
                   invertsColors: invertsDocumentColors)
            .paneBar(.top) {
                PaneBar {
                    EditorSaveButton(model: model)
                    EditorDocumentTitle(model: model)
                    Spacer()
                    DocumentBackgroundColorButton(isInverted: $invertsDocumentColors)
                    RTFTools(session: session)
                    Button { showsExport = true } label: {
                        Label("Export", systemImage: "square.and.arrow.up").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.glassButton)
                    .help("Export Manuscript")
                } accessory: {
                    EditorFindBar(session: session)
                }
            }

            .sheet(isPresented: $showsExport) {
                ManuscriptExportSheet(
                    model: model,
                    bibliography: bibliography,
                    outputDirectory: outputDirectory
                )
            }
    }
}
