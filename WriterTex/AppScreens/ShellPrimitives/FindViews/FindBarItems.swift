import AppKit
import SwiftUI

/// Font and control sizing for every pane's find rows. The rows sit in a
/// `PaneBar`, which supplies the padding, background and divider.
struct FindBarContent: ViewModifier {
    static var font: NSFont { .preferredFont(forTextStyle: .body) }
    /// Every find row is this tall whatever sits beside the field, so rows in
    /// neighbouring panes line up.
    static var rowHeight: CGFloat { 24 }
    /// Width of a field's icon and label ("Find", "Replace", "With").
    static var labelWidth: CGFloat { 80 }

    func body(content: Content) -> some View {
        content
            .font(Font(Self.font))
            .controlSize(.small)
            .buttonStyle(.borderless)
    }
}

extension View {
    /// For a bordered button's label in a find row. The bezel is drawn behind the
    /// label, so a flexible label makes the button run the row's full height and
    /// share any spare width with its neighbours.
    func fillsFindRow() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Switches between Find and Replace.
/// `onSelect` receives `true` for Replace so the caller can move focus.
struct FindModeMenu: View {
    let showsChevron: Bool
    @Binding var showsReplace: Bool
    let onSelect: (_ replacing: Bool) -> Void

    var body: some View {
        Menu {
            Button("Find") { showsReplace = false; onSelect(false) }
            Button("Replace") { showsReplace = true; onSelect(true) }
        } label: {
            HStack(alignment: .center, spacing: 0) {
                Text(showsReplace ? "Replace" : "Find")
                Spacer(minLength: 0)
                if showsChevron {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                }
            }
            .contentShape(.rect)
        }
        .foregroundStyle(Color.accentColor)
        .menuIndicator(.hidden)
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help("Find and replace")
        .accessibilityLabel("Change mode")
    }
}

struct MatchCaseToggle: View {
    @Binding var ignoresCase: Bool

    var body: some View {
        Toggle("Aa", isOn: Binding(get: { !ignoresCase }, set: { ignoresCase = !$0 }))
            .foregroundStyle(ignoresCase ? .secondary : Color.yellow)
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .help("Match the case of the search text.")
            .accessibilityLabel("Match Case")
    }
}

/// The match options the find bar keeps out of the way.
struct FindOptionsMenu: View {
    @Binding var usesRegularExpression: Bool
    @Binding var matchesFullWord: Bool

    var body: some View {
        Menu {
            Toggle("Whole Words", isOn: $matchesFullWord)
                .help("Match only whole words.")
            Toggle("Regular Expression", isOn: $usesRegularExpression)
                .help("Search with a regular expression.")
        } label: {
            HStack(alignment: .center, spacing: 0) {
                Text("Options")
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
            }
            .contentShape(.rect)
        }
        .foregroundStyle(Color.accentColor)
        .menuIndicator(.hidden)
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help("More find options")
        .accessibilityLabel("More Find Options")
    }
}
