//
//  FileViewer.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 10/24/26.
//
import AppKit
import SwiftUI


struct FileViewer: View {
    @Bindable var model: FileBrowserModel
    /// Owned by the enclosing SwiftUI view and shared with the header and
    /// footer, which drive and read this editor's text view.
    let session: EditorSession
    var bibliography: BibLibrary? = nil
    /// Swaps text and background: card-colored text on a foreground-colored page.
    var invertsColors = false
    @State private var editorIsFocused = true
    /// How far a bottom `safeAreaBar` overlaps the editor.
    @State private var bottomInset: CGFloat = 0
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        // A document keeps its editor through Save As and renames.
        RichMarkdownEditor(richData: model.richData, model: model,
                           editorIsFocused: $editorIsFocused, session: session,
                           fileURL: model.selectedFile,
                           palette: invertsColors ? .screenInverted : .screen,
                           undoManager: undoManager,
                           bottomInset: bottomInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            // SwiftUI keeps a representable inside the safe area, so the
            // NSScrollView would stop short of a bottom bar. Extending it lets
            // the text run under the bar; the measured overlap becomes the
            // scroll view's content inset so the last line still clears it.
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { bottomInset = $0 }
            .ignoresSafeArea(.container, edges: .bottom)
            // The editor draws no background of its own; the pane's shows
            // through unless the colors are inverted.
            .background(invertsColors ? Color.foreground : Color.clear, ignoresSafeAreaEdges: .bottom)
            // Lets the editor resolve its citations to the project's entries.
            .onChange(of: bibliography.map(ObjectIdentifier.init), initial: true) {
                session.bibliography = bibliography
            }
    }
}
