import SwiftUI

//MARK: WORKSPACECANVAS
/// A manuscript window. Its session is made once, when the window first
/// appears, because making one claims the file and a CiteTex menu entry.
struct ManuscriptWindow: View {
    let file: ManuscriptFile
    let fileURL: URL?
    @State private var session: ManuscriptSession?

    var body: some View {
        // One container, so it appears and disappears once with the window.
        // The placeholder is there to appear: an empty view never does, so
        // the session would never be made.
        ZStack {
            if let session { ManuscriptWorkspaceView(session: session) } else { Color.clear }
        }
        .onAppear { if session == nil { session = ManuscriptSession(file: file, fileURL: fileURL) } }
        .onChange(of: fileURL) { session?.fileMoved(to: fileURL) }
        .onDisappear { session?.close() }
    }
}

enum StatsPickables: String, CaseIterable, Identifiable, Hashable, Sendable {

    var id: String { rawValue }

    case words = "Words"
    case sentences = "Sentences"
    case paragraphs = "Paragraphs"
    case pages = "Pages"

    /// This stat's count, formatted, or a dash while there are no statistics.
    func value(in statistics: WritingStatistics?) -> String {
        guard let statistics else { return "—" }
        switch self {
            case .words: return statistics.words.formatted()
            case .sentences: return statistics.sentences.formatted()
            case .paragraphs: return statistics.paragraphs.formatted()
            case .pages: return statistics.pages.formatted()
        }
    }
}

/// One manuscript: its editor, the bibliography it cites, and its writing stats.
struct ManuscriptWorkspaceView: View {
    let session: ManuscriptSession
    @State private var editorSession = EditorSession()
    @State private var writingSubselection: WritingInspectorSubtabs = .citations
    @State private var showsInspector = true
    @Environment(\.undoManager) private var undoManager
    @State private var monitor = WritingStatisticsMonitor()
    @State private var statsState: StatsPickables = .words



    @State private var docColorInverted = false

    @State private var headings: [DecodedHeading] = []

    var body: some View {
        CanvasView(showsInspector: $showsInspector) {
                WorkspacePane(
                    model: session.editor,
                    bibliography: session.bibliography,
                    session: editorSession,
                    outputDirectory: {
                        [editor = session.editor] in try Self.chooseExportFolder(
                            near: editor.selectedFile
                        )
                    },
                    invertsDocumentColors: $docColorInverted
                )
                .softScrollEdge(for: .bottom)
                .safeAreaBarOrInset(edge: .bottom) {
                    let statistics = monitor.file == session.editor.selectedFile ? monitor.statistics : nil
                    Menu {
                        // Every stat is listed; choosing one puts it in the capsule.
                        ForEach(StatsPickables.allCases) { stat in
                            Button {
                                statsState = stat
                            } label: {
                                LabeledContent(stat.rawValue, value: stat.value(in: statistics))
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            LabeledContent(
                                statsState.rawValue,
                                value: statsState.value(in: statistics)
                            )
                        }
                        .padding(.horizontal)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glassTitleButton)
                    .safeAreaPadding(.bottom, 10)
                }
                .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
        } sidebar: {
            ManuscriptSidebar(session: session, headings: headings)
        } inspector: {
            WritingInspector(session: session, subselection: $writingSubselection)
        }
        .focusedSceneValue(\.editorSession, editorSession)
        .onChange(of: undoManager.map(ObjectIdentifier.init), initial: true) {
            session.file.undoManager = undoManager
        }
        .task(id: session.editor.selectedFile) {
            await monitor.sample(model: session.editor, file: session.editor.selectedFile)
        }
        .task(id: session.editor.selectedFile) {
            await sampleHeadings()
        }
        .id(session.editor.selectedFile)
    }

    /// Re-reads the outline from the live editor once a second, as the writing
    /// counts do. Waits for the editor to attach rather than decoding the file.
    private func sampleHeadings() async {
        while !Task.isCancelled {
            if session.editor.pendingReadableText != nil,
               let text = try? session.editor.manuscriptSnapshot() {
                let found = DecodedHeading.headings(in: text)
                if found != headings { headings = found }
            }
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
        }
    }

    /// The sandbox lets WriterTex write only where the user points, so an
    /// export asks for its folder, starting beside the manuscript.
    private static func chooseExportFolder(near file: URL?) throws -> URL {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose the folder for the exported manuscript."
        panel.directoryURL = file?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { throw CancellationError() }
        return url
    }
}
