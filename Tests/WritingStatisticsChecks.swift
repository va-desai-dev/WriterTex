import Foundation
@testable import WriterTex

@main
struct WritingStatisticsChecks {
    @MainActor static func main() async throws {
        let empty = WritingStatistics(text: " \r\n\t")
        precondition(empty.words == 0 && empty.paragraphs == 0 && empty.sentences == 0 && empty.pages == 0)
        let prose = WritingStatistics(text: "Hello world.\r\nAnother sentence!\r\n \r\nLast paragraph")
        precondition(prose.words == 6 && prose.paragraphs == 2 && prose.sentences == 3 && prose.pages == 1)
        for (wordCount, pages) in [(1, 1), (250, 1), (251, 2), (500, 2)] {
            precondition(WritingStatistics(text: Array(repeating: "word", count: wordCount).joined(separator: " ")).pages == pages)
        }
        let unicode = WritingStatistics(text: "Café déjà vu. 你好世界。")
        precondition(unicode.words >= 4 && unicode.sentences == 2)

        let model = FileBrowserModel()
        let original = manuscriptData("Original words.")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sample.wrtx")
        model.hostDocument(original, at: file)
        precondition(model.pendingReadableText == nil, "No counts before the editor attaches")
        model.attachEditor(showing: "Original words.")
        model.type("Unsaved replacement has five words.")
        let text = model.pendingReadableText!
        precondition(text == "Unsaved replacement has five words.", "Counts read the editor's unsaved text")
        precondition(WritingStatistics(text: text).words == 5)
        model.hostDocument(original, at: file)
        precondition(model.pendingReadableText == nil, "Re-hosting clears the old editor's text")
        model.attachEditor(showing: "Original words.")
        let monitor = WritingStatisticsMonitor()
        let sampling = Task { await monitor.sample(model: model, file: file) }
        for _ in 0..<200 {
            if monitor.statistics != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(monitor.statistics?.words == 2, "Opening a document counts immediately")
        model.type("Now there are five words.")
        try await Task.sleep(for: .milliseconds(300))
        precondition(monitor.statistics?.words == 2, "Typing retains the previous counts")
        // Keep editing through the next tick: continuous typing must not defer it.
        for index in 0..<70 {
            model.type("Now there are five words" + (index.isMultiple(of: 2) ? "." : "!"))
            if monitor.statistics?.words == 5 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        precondition(monitor.statistics?.words == 5, "A five-second tick samples ongoing edits")
        sampling.cancel()
        await sampling.value
        model.type("Stopped.")
        precondition(monitor.statistics?.words == 5, "Cancellation ends the sampling loop")
        print("Writing statistics checks passed, including silent periodic refresh during continuous edits and cancellation.")
    }
}
