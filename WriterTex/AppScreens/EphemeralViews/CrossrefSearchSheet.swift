import SwiftUI

struct CrossrefSearchTab: View {
    @State private var model = CrossrefSearchModel()
    var citationDestination: URL?

    @State private var showFilterPopover = false
    @State private var showSortPopover = false
    @State private var isAuthorsExpanded = false
    @State private var isTypesExpanded = false
    @State private var isSubTypeExpanded = false


    var body: some View {
        List(model.results) { source in
            CrossrefResultRow(source: source, model: model, citationDestination: citationDestination)
        }
        .overlay(alignment: .top) { messageBanner }
        .tableStyle(.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .softScrollEdge(for: .bottom)
        .paneBar(.top) {
            PaneBar {
                Text("CrossRef Search")
                    .font(.headline)
                Spacer()
                Button("Sort & Filter", systemImage: "line.3.horizontal.decrease") { showFilterPopover = true }
                    .buttonStyle(.glassButton)
                    .popover(isPresented: $showFilterPopover) {
                        CrossrefFilterPopover(
                            model: model,
                            isAuthorsExpanded: $isAuthorsExpanded,
                            isTypesExpanded: $isTypesExpanded
                        )
                    }
                Button("Sort", systemImage: "arrow.up.arrow.down") { showSortPopover = true }
                    .buttonStyle(.glassButton)
                    .popover(isPresented: $showSortPopover) {
                        CrossrefSortPopover(model: model)
                    }
            }
        }
        .safeAreaBarOrInset(edge: .bottom) { searchField }
        .overlay { emptyState }
        .onDisappear { model.cancel() }
    }

    @ViewBuilder
    private var messageBanner: some View {
        if let message = model.message {
            HStack {
                Image(systemName: "quote.bubble.fill")
                Text(message)
                Spacer()
            }
            .padding()
            .foregroundStyle(Color.yellow)
            .font(.callout)
            .background(.ultraThickMaterial,
                        in: .rect(cornerRadius: 6, style: .continuous)
            )
            .task {
                do {
                    // Wait 5 seconds safely
                    try await Task.sleep(for: .seconds(5))
                    // Execute the dismissal on the main thread
                    await MainActor.run {
                        withAnimation(.easeInOut) {
                            model.dismissMessage()
                        }
                    }
                } catch {
                }
            }
            .macOSSwipeToDismiss { model.dismissMessage() }
        }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .font(.body)
            TextField("Title, author, DOI, or DOI URL", text: $model.query)
                .fixedSize(horizontal: false, vertical: true)
                .textFieldStyle(.plain)
                .lineLimit(1)
                .focusEffectDisabled()
                .onSubmit { model.search() }
            Spacer()
            if !model.query.isEmpty || model.isSearching {
                Button(model.isSearching ? "Cancel request" : "Clear", systemImage: "xmark.circle.fill", action: {
                    if model.isSearching {
                        model.cancel()
                    } else {
                        model.query.removeAll()
                    }
                })
                .labelStyle(.iconOnly)
                .foregroundStyle(Color.secondary)
                .buttonStyle(.plain)
                .font(.system(size: 10))
            }
            if model.isSearching {
                ProgressView().controlSize(.mini)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .glassOrMaterial()
        .safeAreaPadding(.vertical, 10)
        .safeAreaPadding(.horizontal, 10)
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isFilteredEmpty && !model.isSearching {
            if model.hasAuthorFilter {
                ContentUnavailableView(
                    "No Matching Sources",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("None of the results match the selected authors and years.")
                        .foregroundStyle(.secondary)
                )
            } else if !model.typeFilters.isEmpty {
                ContentUnavailableView(
                    "No Matching Sources",
                    systemImage: "doc.questionmark",
                    description: Text("None of the results match the selected types and years.")
                        .foregroundStyle(.secondary)
                )
            } else {
                ContentUnavailableView(
                    "No Sources in Range",
                    systemImage: "calendar",
                    description: Text("None of the results were published in the selected years.")
                        .foregroundStyle(.secondary)
                )
            }
        } else if model.results.isEmpty && !model.isSearching && model.message == nil {
            ContentUnavailableView(
                "Search CrossRef",
                systemImage: "",
                description: Text("Find scholarly works by title or author,\nor paste a DOI for an exact lookup.")
                    .foregroundStyle(.secondary)
            )
        }
    }
}

/// One CrossRef work: title, summary, DOI link, and library actions.
private struct CrossrefResultRow: View {
    let source: AcademicSource
    let model: CrossrefSearchModel
    let citationDestination: URL?
    @Environment(\.openURL) private var gotoLink

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(source.citation.title)
                .font(.callout)
                .textSelection(.enabled)
            Text(source.citation.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                if let url = source.url {
                    Button { gotoLink(url) } label: {
                        Text(source.doi)
                            .textSelection(.enabled)
                            .lineLimit(1)
                    }
                    .pointerStyle(.link)
                    .foregroundStyle(.link)
                    .buttonStyle(.link)
                }
                Spacer()
                if let citationDestination {
                    Button("Add to Library", systemImage: "plus") {
                        model.add(source, to: citationDestination)
                    }
                    .buttonStyle(.glassButton)
                }
                Button("Copy BibTeX", systemImage: "document.on.document") { model.copy(source) }
                    .buttonStyle(.glassButton)
            }
            .font(.caption)
        }
        .padding(.vertical, 6)
    }
}
