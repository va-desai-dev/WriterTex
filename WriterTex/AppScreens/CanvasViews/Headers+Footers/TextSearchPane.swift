import AppKit
import SwiftUI

/// The manuscript editor's inline Find & Replace bar.
struct EditorFindBar: View {
    let session: EditorSession
    @Bindable private var strings: FindStrings = .shared
    @AppStorage(.findUsesRegularExpression) private var usesRegularExpression: Bool
    @AppStorage(.findIgnoresCase) private var ignoresCase: Bool
    @AppStorage(.findMatchesFullWord) private var matchesFullWord: Bool
    @State private var showsReplace = false
    @State private var findFocus = 0
    @State private var replaceFocus = 0

    var body: some View {
        VStack(spacing: 0) {
            if session.isFindBarPresented {
                // Fields in one column, actions in another. The action column is pinned to
                // its widest row's natural width and every row's buttons stretch to fill it,
                // so both fields end at the same x and the buttons sit flush with them.
                // A `PaneBar` like every other bar, so its height, fill and divider match
                // the sidebar's search header across the split.
                PaneBar(spacing: 6) {
                    VStack(spacing: 4) {
                        FindField(text: $strings.findString, placeholder: "Find", systemImage: "magnifyingglass",
                                  identifier: "editor.search.query",
                                  message: session.findMessage,
                                  focusRequest: session.findFocusRequest + findFocus,
                                  onSubmit: { session.performFind(NSEvent.modifierFlags.contains(.shift) ? .previousMatch : .nextMatch) },
                                  onDismiss: session.dismissFind) {
                            modeMenu
                        } trailing: {
                            MatchCaseToggle(ignoresCase: $ignoresCase)
                            Divider().opacity(0.5)
                            optionsMenu
                        }
                        if showsReplace {
                            FindField(text: $strings.replacementString, placeholder: "Replace with", systemImage: "pencil",
                                      identifier: "search.replacement",
                                      focusRequest: replaceFocus,
                                      onSubmit: { session.performFind(.replaceAndFind) },
                                      onDismiss: session.dismissFind) {
                                Text("With")
                            }
                            .disabled(strings.findString.isEmpty)
                        }
                    }
                    .padding(.vertical, 5)
                    VStack(alignment: .trailing , spacing: 4) {
                        navigationButtons
                            .frame(height: FindBarContent.rowHeight)
                        if showsReplace {
                            ControlGroup {
                                Button { session.performFind(.replaceAndFind) } label: { Text("Replace").fillsFindRow() }
                                    .help("Replace this match, then find the next one.")
                                Button { session.performFind(.replaceAll) } label: { Text("All").fillsFindRow() }
                                    .help("Replace every match.")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .frame(height: FindBarContent.rowHeight)
                            .disabled(strings.findString.isEmpty)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .modifier(FindBarContent())
                .onExitCommand(perform: session.dismissFind)
                .onAppear { findFocus += 1; session.incrementalSearch() }
            }
        }
        .onChange(of: strings.findString) { searchAgain() }
        .onChange(of: usesRegularExpression) { searchAgain() }
        .onChange(of: ignoresCase) { searchAgain() }
        .onChange(of: matchesFullWord) { searchAgain() }
        .onChange(of: session.isFindBarPresented) {
            if !session.isFindBarPresented { showsReplace = false }
        }
    }

    /// Search as you type, in the key window's editor only.
    private func searchAgain() {
        session.findMessage = nil
        guard session.isFindBarPresented, session.findTextView?.window?.isKeyWindow == true else { return }
        session.incrementalSearch()
    }

    private var modeMenu: some View {
        FindModeMenu(showsChevron: true, showsReplace: $showsReplace) { replacing in
            if replacing { replaceFocus += 1 } else { findFocus += 1 }
        }
    }

    private var optionsMenu: some View {
        FindOptionsMenu(usesRegularExpression: $usesRegularExpression, matchesFullWord: $matchesFullWord)
    }

    private var navigationButtons: some View {
        ControlGroup {
            Button { session.performFind(.previousMatch) } label: { Image(systemName: "chevron.left").fillsFindRow() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .help("Find the previous match (⇧⌘G)").accessibilityLabel("Find Previous")
                .disabled(strings.findString.isEmpty)
            Button { session.performFind(.nextMatch) } label: { Image(systemName: "chevron.right").fillsFindRow() }
                .keyboardShortcut("g", modifiers: .command)
                .help("Find the next match (⌘G)").accessibilityLabel("Find Next")
                .disabled(strings.findString.isEmpty)
            Button(action: session.dismissFind) { Text("Done").fillsFindRow() }
                .buttonStyle(.accessoryBar)
                .help("Close find bar (⎋)")
                .accessibilityLabel("Close Find Bar")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
