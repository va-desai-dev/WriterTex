//
//  WriterTexApp.swift
//  WriterTex
//
//  Created by Vedant A. Desai on 9/12/26.
//

import SwiftUI

// 1. This reads your Xcode Organizer version automatically
public struct AppVersion {
    public static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String
    }

    public static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as! String
    }
}

@main
struct WriterTexApp: App {
    @State private var citeTex = CiteTexTargets.shared
    
    static let welcomeID = "welcome"

    init() {
        AppDefaults.register()
    }

    var body: some Scene {
        Window("Welcome to WriterTex", id: Self.welcomeID) {
            EntryView()
                .tint(Color.accentColor)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(replacing: .newItem) { NewDocumentCommands() }
            TextEditingCommands()
            ManuscriptCommands()
        }
        DocumentGroup(newDocument: { ManuscriptFile() }) { file in
            ManuscriptWindow(file: file.document, fileURL: file.fileURL)
                .tint(Color.accentColor)
                .foregroundStyle(Color.foreground)
        }
        .defaultSize(width: 1100, height: 720)
        .defaultLaunchBehavior(.suppressed)
        DocumentGroup(newDocument: { NotebookFile() }) { file in
            NotebookWindow(file: file.document, fileURL: file.fileURL)
                .tint(Color.accentColor)
                .foregroundStyle(Color.foreground)
        }
        .defaultSize(width: 1100, height: 720)
        .defaultLaunchBehavior(.suppressed)
        MenuBarExtra("CiteTex", systemImage: "safari", isInserted: .constant(!citeTex.targets.isEmpty)) {
            CiteTexMenu(targets: citeTex)
        }
        Settings {
            IDESettingsView()
                .background(AppTheme.shared.windowBackground)
                .toolbar(removing: .title)
                .tint(Color.accentColor)
        }
        // Standard titlebar on purpose: `.hiddenTitleBar` makes the content view
        // full-size, which slides the panes' NSScrollViews under the titlebar and
        // AppKit then draws its hard scroll-edge pocket over them — something
        // `.scrollEdgeEffectHidden`/`.soft` can't reach.
    }
}
public extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// The manuscript editor's own commands. They act on the key window's editor
/// and are disabled while no manuscript window is in front.
private struct ManuscriptCommands: Commands {
    @FocusedValue(\.editorSession) private var session

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Insert Citation…") { session?.insertCitation() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(session?.hasManuscriptEditor != true)
        }
        CommandMenu("Format") {
            inlineStyleToggle("Bold", .strong)
                .keyboardShortcut("b", modifiers: .command)
            inlineStyleToggle("Italic", .emphasis)
                .keyboardShortcut("i", modifiers: .command)
            Divider()
            Toggle("Block Quote", isOn: Binding(
                get: { session?.isBlockQuote ?? false },
                set: { session?.setBlockQuote($0) }
            ))
            .keyboardShortcut("9", modifiers: [.command, .shift])
            .disabled(session?.canSetBlockQuote != true)
        }
    }

    private func inlineStyleToggle(_ title: String, _ style: MarkdownInlineStyle) -> some View {
        Toggle(title, isOn: Binding(
            get: { session?.selectedInlineStyle.contains(style) ?? false },
            set: { session?.setInlineStyle(style, enabled: $0) }
        ))
        .disabled(session?.hasManuscriptEditor != true)
    }
}


/// File ▸ New for each kind of document, and the welcome window. Open and
/// the rest of the File menu come from the document groups.
private struct NewDocumentCommands: View {
    @Environment(\.newDocument) private var newDocument
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Manuscript") { AppModes.files.makeNew(with: newDocument) }
            .keyboardShortcut("n", modifiers: .command)
        Button("New Analysis Notebook") { AppModes.notebook.makeNew(with: newDocument) }
            .keyboardShortcut("n", modifiers: [.command, .option])
        Divider()
        Button("Welcome to WriterTex") { openWindow(id: WriterTexApp.welcomeID) }
            .keyboardShortcut("0", modifiers: [.command, .shift])
    }
}
