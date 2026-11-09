import SwiftUI

/// Year range, author, and work-type filters for CrossRef results.
struct CrossrefFilterPopover: View {
    @Bindable var model: CrossrefSearchModel
    /// Owned by the search tab so the sections stay open between popover presentations.
    @Binding var isAuthorsExpanded: Bool
    @Binding var isTypesExpanded: Bool
    @State private var expandedGroups: Set<CrossrefTypes> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                dateSection
                authorSection
                typeSection
            }
            .toggleStyle(.selectionCapsule)
            .padding(12)
            .frame(width: 230)
            .tint(Color.accentColor)
        }
    }

    @ViewBuilder
    private var dateSection: some View {
        Text("Show Sources")
            .font(.headline)
        ForEach(CrossrefSearchModel.DateFilter.allCases) { filter in
            Toggle(filter.title, isOn: $model.dateFilter.selects(filter))
        }
        if model.dateFilter == .custom {
            HStack {
                TextField("From", text: $model.fromYear)
                    .monospacedDigit()
                Text("-")
                TextField("To", text: $model.toYear)
                    .monospacedDigit()
            }
            .fixedSize(horizontal: false, vertical: true)
            .focusEffectDisabled()
        }
    }

    private var authorSection: some View {
        DisclosureGroup(isExpanded: $isAuthorsExpanded) {
            ForEach(0..<model.authorFilters.count, id: \.self) { index in
                HStack(spacing: 12) {
                    Image(systemName: "person.fill")
                    // Guard the index: after a removal SwiftUI can read a stale row once before it disappears.
                    TextField("Author name", text: Binding(
                        get: { model.authorFilters.indices.contains(index) ? model.authorFilters[index] : "" },
                        set: { if model.authorFilters.indices.contains(index) { model.authorFilters[index] = $0 } }
                    ))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(1)
                    .focusEffectDisabled()
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    Spacer()
                    Button {
                        model.authorFilters.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .glassOrMaterial()
            }
            Button {
                model.authorFilters.append("")
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "person.badge.plus.fill")
                    Text("Add Author")
                    Spacer()
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
            }
            .buttonStyle(.glassFullButton)
            .background(Color.accentColor, in: .capsule)
            .padding(.top, 4)
        } label: {
            Text("Filter by Authors")
                .font(.headline)
        }
        .customDisclosureStyle()
    }

    // 2. Update your typeSection ViewBuilder block to track expansion independently
    private var typeSection: some View {
        DisclosureGroup(isExpanded: $isTypesExpanded) {
            ForEach(CrossrefTypes.allCases) { group in

                // Generate a dedicated layout binding for expanding this specific folder
                let isExpandedBinding = Binding<Bool>(
                    get: { expandedGroups.contains(group) },
                    set: { isOpen in
                        if isOpen {
                            expandedGroups.insert(group)
                        } else {
                            expandedGroups.remove(group)
                        }
                    }
                )

                // FIX: Point isExpanded to the UI binding, NOT the selection binding
                DisclosureGroup(isExpanded: isExpandedBinding) {
                    ForEach(group.members, id: \.self) { type in
                        Toggle(isOn: typeBinding(type)) {
                            Text(CrossrefTypes.title(for: type))
                                .italic()
                        }
                        .padding(.horizontal, 18)

                    }
                } label: {
                    // Keep the structural checkbox handling your data model array
                    Toggle(isOn: groupBinding(group)) {
                        Text(group.rawValue)
                            .fontWeight(.bold)
                    }
                }
                .customDisclosureStyle()
            }
        } label: {
            HStack {
                Text("Filter by Type")
                    .font(.headline)
                Spacer()
                if !model.typeFilters.isEmpty {
                    Button("Show All Types", systemImage: "xmark.circle.fill") {
                        model.typeFilters.removeAll()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
        }
        .customDisclosureStyle()
    }


    private func groupBinding(_ group: CrossrefTypes) -> Binding<Bool> {
        // Missing 'return' added here
        return Binding(
            get: {
                group.members.allSatisfy { model.typeFilters.contains($0) }
            },
            set: { newValue in
                for member in group.members {
                    if newValue {
                        model.typeFilters.insert(member)
                    } else {
                        model.typeFilters.remove(member)
                    }
                }
            }
        )
    }

    /// Whether one Crossref type is in the filter set, as a toggle binding.
    private func typeBinding(_ type: String) -> Binding<Bool> {
        Binding(
            get: {
                model.typeFilters.contains(type)
            }, set: { isOn in
                if isOn {
                    model.typeFilters.insert(type)
                } else {
                    model.typeFilters.remove(type)
                }
            }
        )
    }
}

struct RepositionedChevronStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // This button handles the row tap action cleanly
            Button {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack {
                    // Your row label text/checkboxes stay on the left
                    configuration.label

                    Spacer()

                    // Place the custom chevron completely on the trailing edge
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle()) // Makes the entire row canvas clickable
            }
            .buttonStyle(.plain)

            // Render the interior items container row if expanded
            if configuration.isExpanded {
                configuration.content
                    .padding(.top, 4)
            }
        }
    }
}

// 2. Wrap it inside a clean view modifier extension for easy use
extension View {
    func customDisclosureStyle() -> some View {
        self.disclosureGroupStyle(RepositionedChevronStyle())
    }
}

