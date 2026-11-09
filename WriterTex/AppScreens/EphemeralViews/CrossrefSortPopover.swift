import SwiftUI

/// Sort key and direction for CrossRef results.
struct CrossrefSortPopover: View {
    @Bindable var model: CrossrefSearchModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sort By")
                    .font(.headline)
                ForEach(CrossrefSearchModel.SortKey.allCases) { key in
                    Toggle(key.rawValue, isOn: $model.sortKey.selects(key))
                }
                if model.sortKey != .relevance {
                    Divider()
                    HStack {
                        Toggle(model.sortKey == .year ? "Oldest" : "A to Z", isOn: $model.sortOrder.selects(.forward))
                        Toggle(model.sortKey == .year ? "Newest" : "Z to A", isOn: $model.sortOrder.selects(.reverse))
                    }
                }
            }
            .toggleStyle(.selectionCapsule)
            .padding(12)
        }
        .frame(width: 230)
        .frame(minHeight: 200)
        .tint(Color.accentColor)
    }
}
