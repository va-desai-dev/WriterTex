import SwiftUI

/// A full-width option row in a glass capsule that fills with the accent color when on.
/// A `Toggle(sources:)` that is only partly on shows a faded fill; clicking it turns every source on.
struct SelectionCapsuleToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack {
                configuration.label
                Spacer()
            }
            .padding(.horizontal)
            .contentShape(.capsule)
        }
        .buttonStyle(.glassTitleButton)
        .background(fill(for: configuration), in: .capsule)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }

    private func fill(for configuration: Configuration) -> Color {
        if configuration.isMixed { return Color.accentColor.opacity(0.4) }
        return configuration.isOn ? Color.accentColor : Color.clear
    }
}

extension ToggleStyle where Self == SelectionCapsuleToggleStyle {
    static var selectionCapsule: SelectionCapsuleToggleStyle { SelectionCapsuleToggleStyle() }
}

extension Binding where Value: Equatable {
    /// A radio-style toggle binding: on while this binding holds `value`; turning it on selects `value`.
    /// Turning it off does nothing, so one option always stays selected.
    func selects(_ value: Value) -> Binding<Bool> {
        Binding<Bool>(
            get: { wrappedValue == value },
            set: { if $0 { wrappedValue = value } }
        )
    }
}
