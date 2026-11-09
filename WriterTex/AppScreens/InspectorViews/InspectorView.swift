//
//  WritingInspectorSubtabs.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 10/24/26.
//

import SwiftUI


enum WritingInspectorSubtabs: String, CaseIterable, Identifiable {
    case citations, crossRef
    var id: String { rawValue }
    var title: String {
        switch self {
            case .citations: return "References"
            case .crossRef: return "CrossRef"
        }
    }
    var icon: String {
        switch self {
            case .citations: return "quote.bubble"
            case .crossRef: return "network"
        }
    }
    var nsImage: NSImage? { NSImage(systemSymbolName: icon, accessibilityDescription: nil) }
}



struct WritingInspector: View {
    let session: ManuscriptSession
    @ObservedObject var file: ManuscriptFile
    @Binding var subselection: WritingInspectorSubtabs
    @State private var createError: String?

    init(session: ManuscriptSession, subselection: Binding<WritingInspectorSubtabs>) {
        self.session = session
        file = session.file
        _subselection = subselection
    }

    var body: some View {
        ZStack {
            switch subselection {
                case .citations:
                    VStack(spacing: 0) {
                        if let missing = file.unreachableBibliography {
                            HStack {
                                Label("“\(missing)” isn’t available on this Mac.", systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                Spacer(minLength: 0)
                                Button("Locate…", action: session.bibliography.chooseOtherFile)
                                    .controlSize(.small)
                            }
                            .padding(10)
                            Divider()
                        }
                        BibliographyInspector(
                            library: session.bibliography,
                            onChooseFile: session.bibliography.chooseOtherFile,
                            onCreateFile: createBibliography
                        )
                    }
                case .crossRef:
                    CrossrefSearchTab(citationDestination: session.bibliography.fileURL)
            }
        }
        .paneBar(.top) {
            PaneBar {
                FillingTabStrip(accessibilityLabel: "Writing Inspector Tabs", tabs: WritingInspectorSubtabs.allCases,
                                selection: $subselection, title: \.rawValue) { .image($0.nsImage) }
            }
        }
        .alert("Couldn’t Create Bibliography", isPresented: Binding(
            get: { createError != nil }, set: { if !$0 { createError = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: { Text(createError ?? "") }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func createBibliography() {
        let panel = NSSavePanel()
        panel.title = "New Bibliography"
        panel.message = "This manuscript will cite from the new .bib file."
        panel.allowedContentTypes = [.bibTeX]
        panel.nameFieldStringValue = "references.bib"
        panel.directoryURL = session.editor.selectedFile?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try session.createBibliography(at: url) } catch { createError = error.localizedDescription }
    }
}
