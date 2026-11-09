import Foundation
import NaturalLanguage
import Observation

/// Counts the readable text's words, paragraphs and sentences.
/// Pages are a manuscript estimate, independent of the editor's window size.
nonisolated struct WritingStatistics: Equatable, Sendable {
    let words: Int
    let paragraphs: Int
    let sentences: Int
    var pages: Int { (words + 249) / 250 }

    init(text: String) {
        // Soft line breaks belong to the same paragraph; blank lines separate them.
        var blocks: [String] = []
        var paragraph = ""
        text.enumerateLines { line, _ in
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !paragraph.isEmpty { blocks.append(paragraph); paragraph = "" }
            } else {
                if !paragraph.isEmpty { paragraph += " " }
                paragraph += line
            }
        }
        if !paragraph.isEmpty { blocks.append(paragraph) }

        let wordTokenizer = NLTokenizer(unit: .word)
        let sentenceTokenizer = NLTokenizer(unit: .sentence)
        var words = 0
        var sentences = 0
        for block in blocks {
            wordTokenizer.string = block
            wordTokenizer.enumerateTokens(in: block.startIndex..<block.endIndex) { _, _ in
                words += 1
                return true
            }
            sentenceTokenizer.string = block
            sentenceTokenizer.enumerateTokens(in: block.startIndex..<block.endIndex) { range, _ in
                // Punctuation-only blocks aren't sentences.
                if block[range].unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) {
                    sentences += 1
                }
                return true
            }
        }
        self.words = words
        self.paragraphs = blocks.count
        self.sentences = sentences
    }
}

/// One sampling loop per mounted document; edits don't restart it or clear counts.
@MainActor @Observable
final class WritingStatisticsMonitor {
    private(set) var statistics: WritingStatistics?
    /// The manuscript being counted; nil while it's untitled.
    private(set) var file: URL?

    func sample(model: FileBrowserModel, file: URL?) async {
        self.file = file
        statistics = nil
        var previousText: String?
        while !Task.isCancelled, model.selectedFile == file {
            if let text = model.pendingReadableText, text != previousText {
                let result = await Task.detached(priority: .utility) {
                    WritingStatistics(text: text)
                }.value
                guard !Task.isCancelled, model.selectedFile == file else { return }
                statistics = result
                previousText = text
            }
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
        }
    }
}
