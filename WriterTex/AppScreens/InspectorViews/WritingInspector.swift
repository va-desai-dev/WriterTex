import SwiftUI

struct WritingInspectorContent: View {
    let model: FileBrowserModel
    @State private var monitor = WritingStatisticsMonitor()

    var body: some View {
        let file = model.selectedFile
        if model.pendingReadableText != nil {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Writing", systemImage: "pencil.line")
                        .font(.headline)
                    Text(file?.lastPathComponent ?? "Untitled")
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    let statistics = monitor.file == file ? monitor.statistics : nil
                    LabeledContent("Words", value: statistics?.words.formatted() ?? "—")
                    LabeledContent("Paragraphs", value: statistics?.paragraphs.formatted() ?? "—")
                    LabeledContent("Sentences", value: statistics?.sentences.formatted() ?? "—")
                    Divider()
                    LabeledContent("Pages (estimated)", value: statistics?.pages.formatted() ?? "—")
                    Text("250 words per page, rounded up. Paragraphs are nonempty text blocks. Counts include unsaved edits.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .monospacedDigit()
                .padding(16)
            }
            .task(id: file) {
                await monitor.sample(model: model, file: file)
            }
            .id(file)
        } else {
            ContentUnavailableView("No Text Available", systemImage: "doc.text",
                                   description: Text("Statistics appear when the document is loaded."))
        }
    }
}

