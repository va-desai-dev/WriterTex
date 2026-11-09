//
//  EditorBarItems.swift
//  TypeNBash
//
//  The individual controls that go in an editor pane's `PaneBar`s. Each one
//  takes only what it reads; which ones appear for which document is decided
//  where the bar is assembled, not here.
//

import AppKit
import SwiftUI

// MARK: - Document

/// Saves the window's document.
struct EditorSaveButton: View {
    let model: FileBrowserModel

    var body: some View {
        Button {
            NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil)
        } label: {
            Label("Save", systemImage: "checkmark")
        }
        .buttonStyle(.glassButton)
        .disabled(!model.hasUnsavedChanges)
        .help("Save (⌘S)")
    }
}

/// Swaps the editor's text and background colors.
struct DocumentBackgroundColorButton: View {
    @Binding var isInverted: Bool

    var body: some View {
        Button(
            isInverted ? "Restore Document Colors" : "Invert Document Colors",
            systemImage: isInverted ? "sun.min.fill" : "moon"
        ) {
            isInverted.toggle()
        }
        .buttonStyle(.glassButton)
        .background(isInverted ? Color.accentColor : Color.clear, in: .circle)
        .help(isInverted ? "Restore Document Colors" : "Invert Document Colors")
    }
}

/// RTF Editor Tools
struct RTFTools: View {
    let session: EditorSession

    var body: some View {
        Menu {
            // Headings can't apply inside lists or tables; inline code still can.
            Button { session.setBodyStyle() } label: { Text("Body") }
                .disabled(!session.canSetHeadingLevel && !(session.selectionContainsList && session.canSetListKind))
            Group {
                Button { session.setHeadingLevel(1) } label: { Text("Heading 1") }
                Button { session.setHeadingLevel(2) } label: { Text("Heading 2") }
                Button { session.setHeadingLevel(3) } label: { Text("Heading 3") }
                Button { session.setHeadingLevel(4) } label: { Text("Heading 4") }
                Button { session.setHeadingLevel(5) } label: { Text("Heading 5") }
                Button { session.setHeadingLevel(6) } label: { Text("Heading 6") }
            }
            .disabled(!session.canSetHeadingLevel)
            Divider()
            Toggle("Block Quote", isOn: Binding(get: { session.isBlockQuote }, set: { session.setBlockQuote($0) }))
                .disabled(!session.canSetBlockQuote)
            Divider()
            // Unchecking the current list style turns it back into body text.
            ForEach(MarkdownListKind.allCases, id: \.self) { kind in
                Toggle(isOn: Binding(get: {
                    session.selectedListKind == kind
                }, set: { _ in
                    session.setListKind(kind)
                })) {
                    Text(kind.title)
                }
            }
            .disabled(!session.canSetListKind)
            Divider()
            Button("Insert Table") { session.insertTable() }
                .disabled(!session.canInsertTable)
            Menu("Table") {
                ForEach(MarkdownTableEdit.allCases, id: \.self) { edit in
                    if edit == .deleteRow {
                        Divider()
                        ForEach([("Align Column Left", MarkdownRichText.TableAlignment.left),
                                 ("Center Column", .center), ("Align Column Right", .right)], id: \.0) { title, alignment in
                            Toggle(isOn: Binding(get: { session.selectedColumnAlignment == alignment },
                                                 set: { _ in session.alignColumn(alignment) })) { Text(title) }
                        }
                        Divider()
                    }
                    Button(edit.title) { session.editTable(edit) }
                }
            }
            .disabled(!session.selectionInTable)
            Divider()
            Toggle(isOn: Binding(get: {
                session.selectedInlineStyle.contains(.code)
            }, set: {
                session.setInlineStyle(.code, enabled: $0)
            })) {
                Text("Inline Code")
            }
        } label: {
            HStack(spacing: 4) {
                Text(session.isBlockQuote ? "Block Quote" : session.selectedListKind?.title
                     ?? (session.selectedHeadingLevel == 0 || session.selectedHeadingLevel == nil ? "Body" : "Heading \(session.selectedHeadingLevel!)"))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(Color.secondary)
            }
            .padding(.horizontal, 6)
        }
        .menuStyle(.button)
        .buttonStyle(.glassTitleButton)
        .help("Paragraph Style")
        DynamicLiquidGlassStrip {
            Toggle(isOn: Binding(get: {
                session.selectedInlineStyle.contains(.strong)
            }, set: {
                session.setInlineStyle(.strong, enabled: $0)
            })) {
                Label("Bold", systemImage: "bold")
                    .labelStyle(.iconOnly)
                    .fontWeight(
                        session.selectedInlineStyle.contains(.strong) ? .bold
                        : .regular)
                    .foregroundStyle(
                        session.selectedInlineStyle.contains(.strong) ? Color.accentColor
                        : Color.foreground)
            }
            .toggleStyle(.button)
            .buttonStyle(.glassSegment)
            .help("Bold (⌘B)")
            Toggle(isOn: Binding(get: {
                session.selectedInlineStyle.contains(.emphasis)
            }, set: {
                session.setInlineStyle(.emphasis, enabled: $0)
            })) {
                Label("Italics", systemImage: "italic")
                    .labelStyle(.iconOnly)
                    .fontWeight(
                        session.selectedInlineStyle.contains(.emphasis) ? .bold
                        : .regular)
                    .foregroundStyle(
                        session.selectedInlineStyle.contains(.emphasis) ? Color.accentColor
                        : Color.foreground)
            }
            .toggleStyle(.button)
            .buttonStyle(.glassSegment)
            .help("Italic (⌘I)")
            Toggle(isOn: Binding(get: {
                session.selectedInlineStyle.contains(.strikethrough)
            }, set: {
                session.setInlineStyle(.strikethrough, enabled: $0)
            })) {
                Label("Strikethrough", systemImage: "strikethrough")
                    .labelStyle(.iconOnly)
                    .fontWeight(
                        session.selectedInlineStyle.contains(.strikethrough) ? .bold
                        : .regular)
                    .foregroundStyle(
                        session.selectedInlineStyle.contains(.strikethrough) ? Color.accentColor
                        : Color.foreground)
            }
            .toggleStyle(.button)
            .buttonStyle(.glassSegment)
            .help("Strikethrough")
            Toggle(isOn: Binding(get: {
                session.selectedInlineStyle.contains(.highlight)
            }, set: {
                session.setInlineStyle(.highlight, enabled: $0)
            })) {
                Label("Highlight", systemImage: "highlighter")
                    .labelStyle(.iconOnly)
                    .fontWeight(
                        session.selectedInlineStyle.contains(.highlight) ? .bold
                        : .regular)
                    .foregroundStyle(
                        session.selectedInlineStyle.contains(.highlight) ? Color.accentColor
                        : Color.foreground)
            }
            .toggleStyle(.button)
            .buttonStyle(.glassSegment)
            .help("Highlight")
        }
    }
}

/// File name and the last document error. The title bar already says it's edited.
struct EditorDocumentTitle: View {
    let model: FileBrowserModel

    var body: some View {
        Text(model.selectedFile?.deletingPathExtension().lastPathComponent ?? "Untitled")
            .lineLimit(1)
        if let saveError = model.saveError {
            Text(saveError)
                .foregroundStyle(Color.red)
        }
    }
}

/// Copies the table grid, with its edits and column headers, as CSV.
struct TableDataMenu<S: ButtonStyle>: View {
    let session: EditorSession
    let style: S

    @State private var error: String?

    var body: some View {
        Menu {
            Button("Copy All Rows as CSV") { copyCSV(scope: .allRows) }
            Button("Copy Filtered Rows as CSV") { copyCSV(scope: .visibleRows) }
        } label: {
            Label("Copy Data", systemImage: "document.on.document.fill")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.button)
        .buttonStyle(style)
        .menuIndicator(.hidden)
        .help("Copy the current edited table, including column headers")
        .alert("Couldn’t Prepare CSV", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: { Text(error ?? "") }
    }

    private func copyCSV(scope: CSVAnalysisSnapshot.Scope) {
        do {
            let snapshot = try session.csvAnalysisSnapshot(scope: scope)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(snapshot.csvText, forType: .string)
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Text editing

struct GlassButtonLabelStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 14, weight: .semibold))
            .frame(width: 26, height: 26)
            .glassOrMaterial(in: Circle())
    }
}

struct GlassTitleLabelStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(height: 26)
            .glassOrMaterial(in: Capsule())
    }
}

struct GlassTitleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .pickerStyle(.menu)
            .modifier(GlassTitleLabelStyle())
            .foregroundStyle(enabled ? Color.foreground : Color.secondary)
            .opacity(configuration.isPressed ? 0.95 : 1.0)
            .labelStyle(.titleOnly)
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
    }
}

struct GlassFullLabelButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .pickerStyle(.menu)
            .modifier(GlassTitleLabelStyle())
            .foregroundStyle(enabled ? Color.foreground : Color.secondary)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .labelStyle(.titleAndIcon)
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
    }
}



struct GlassButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .pickerStyle(.menu)
            .modifier(GlassButtonLabelStyle())
            .foregroundStyle(enabled ? Color.foreground : Color.secondary)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .labelStyle(.iconOnly)
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
    }
}

extension ButtonStyle where Self == GlassFullLabelButtonStyle {
    static var glassFullButton: GlassFullLabelButtonStyle { GlassFullLabelButtonStyle() }
}

extension ButtonStyle where Self == GlassButtonStyle {
    static var glassButton: GlassButtonStyle { GlassButtonStyle() }
}

extension ButtonStyle where Self == GlassTitleButtonStyle {
    static var glassTitleButton: GlassTitleButtonStyle { GlassTitleButtonStyle() }
}



struct GlassControlGroupButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? Color.foreground : Color.secondary)
            .labelStyle(.iconOnly)
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .font(.system(size: 14, weight: .semibold))
            .frame(width: 26, height: 26)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
    }
}

extension ButtonStyle where Self == GlassControlGroupButtonStyle {
    static var glassSegment: GlassControlGroupButtonStyle { GlassControlGroupButtonStyle() }
}

/// Icon controls fused into one Liquid Glass capsule with hairlines between
/// them, the way Pages and Notes group their editing controls. One glass
/// shape for the whole strip: per-item unions re-materialize every time a
/// control comes or goes, which is what made the bar assemble a piece at a time.
struct DynamicLiquidGlassStrip<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Group(subviews: content) { subviews in
            HStack(spacing: 0) {
                ForEach(subviews) { subview in
                    subview
                    if subview.id != subviews.last?.id {
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor).opacity(0.4))
                            .frame(width: 0.5, height: 14)
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 26)
        .glassOrMaterial(in: Capsule())
        // The set of controls follows the open document; when it changes the
        // capsule should snap to its new width, not tween through each step.
        .transaction { $0.animation = nil }
    }
}
