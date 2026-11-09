import AppKit
@testable import WriterTex

/// A WriterTex document built from Markdown, the shorthand checks write fixtures in.
@MainActor func manuscript(_ markdown: String, baseURL: URL? = nil) -> NSAttributedString {
    MarkdownRichText(baseURL: baseURL, style: MarkdownStyleSheet(theme: .screen, manuscript: .screen)).load(markdown)
}

/// `manuscript(_:)` encoded as a `.wrtx` file holds it.
@MainActor func manuscriptData(_ markdown: String, baseURL: URL? = nil) -> Data {
    try! ManuscriptDocument.encode(manuscript(markdown, baseURL: baseURL))
}

extension FileBrowserModel {
    /// Opens a fixture at `url` as a saved WriterTex document, replacing
    /// whatever was open, even the same file.
    func openFixture(_ markdown: String, at url: URL) {
        openFixture(manuscript(markdown, baseURL: url.deletingLastPathComponent()), at: url)
    }

    func openFixture(_ text: NSAttributedString, at url: URL) {
        hostDocument(try! ManuscriptDocument.encode(text), at: url)
    }

    /// The open document's RTFD, with the editor's edits committed.
    var committedRichData: Data {
        commitPendingMarkdown()
        return richData
    }

    /// The open document as saving and reopening it shows it.
    var reopened: NSAttributedString {
        let data = committedRichData
        let document = MarkdownRichText(baseURL: selectedFile?.deletingLastPathComponent(),
                                        style: MarkdownStyleSheet(theme: .screen, manuscript: .screen))
        return data.isEmpty ? NSAttributedString() : (try? ManuscriptDocument.decode(data, using: document)) ?? NSAttributedString()
    }
}

/// The outline a document imported from `markdown` has, for comparing an
/// edited document's shape against the shorthand it should match.
@MainActor func outline(_ markdown: String) -> String { manuscript(markdown).outline }

extension NSAttributedString {
    /// The visible text without the trailing line break a document ends with.
    var shownText: String { string.trimmingCharacters(in: .newlines) }

    /// The document's shape in one string, one line per paragraph: `#` for a
    /// heading's level, `> ` per quote, `code: ` and `---` for code and rule
    /// blocks, a table row as `| a | b |`, and `**`, `*`, `` ` ``, `~~`, `==` and
    /// `[text](url)` around styled runs. List markers are the text the editor
    /// shows, indented two spaces per nesting level.
    @MainActor var outline: String {
        var lines: [String] = []
        var row: (table: NSTextTable, row: Int, prefix: String)?, cells: [String] = []
        func finishRow() {
            if let row, !cells.isEmpty { lines.append(row.prefix + "| " + cells.joined(separator: " | ") + " |") }
            row = nil
            cells = []
        }
        for paragraph in MarkdownRichText.paragraphs(in: self) {
            let style = attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle ?? .default
            let quote = String(repeating: "> ", count: style.textBlocks.filter { $0 is MarkdownQuoteBlock }.count)
            var content = paragraph
            while content.length > 0, [0x0A, 0x0D, 0x2029].contains((string as NSString).character(at: NSMaxRange(content) - 1)) { content.length -= 1 }
            let text = inlineOutline(content)
            if let cell = style.textBlocks.last as? NSTextTableBlock {
                if row?.table !== cell.table || row?.row != cell.startingRow {
                    finishRow()
                    row = (cell.table, cell.startingRow, quote)
                }
                cells.append(text)
                continue
            }
            finishRow()
            let indent = String(repeating: "  ", count: max(0, style.textLists.count - 1))
            switch style.textBlocks.last {
            case is MarkdownRuleBlock: lines.append(quote + "---")
            case is MarkdownCodeBlock: lines.append(quote + "code: " + text)
            default:
                let level = attribute(.markdownHeading, at: paragraph.location, effectiveRange: nil) as? Int
                lines.append(quote + indent + (level.map { String(repeating: "#", count: $0) + " " } ?? "") + text)
            }
        }
        finishRow()
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// A paragraph's text with its inline styles marked; runs that differ only
    /// in attributes the outline doesn't show are marked as one.
    @MainActor private func inlineOutline(_ range: NSRange) -> String {
        var segments: [(style: MarkdownInlineStyle, link: String?, text: String)] = []
        enumerateAttributes(in: range) { attributes, run, _ in
            let link = attributes[.link].flatMap { ManuscriptCitations.isLink($0) ? nil : (($0 as? URL)?.absoluteString ?? "\($0)") }
            let piece = (string as NSString).substring(with: run)
            let style = MarkdownInlineStyle(attributes)
            if let last = segments.last, last.style == style, last.link == link {
                segments[segments.count - 1].text += piece
            } else {
                segments.append((style, link, piece))
            }
        }
        return segments.map { segment in
            var text = segment.text
            for (mark, wraps) in [("`", MarkdownInlineStyle.code), ("*", .emphasis), ("**", .strong), ("~~", .strikethrough), ("==", .highlight)]
            where segment.style.contains(wraps) {
                text = mark + text + mark
            }
            return segment.link.map { "[" + text + "](" + $0 + ")" } ?? text
        }.joined()
    }

    /// Whether every character of `word` carries `style`.
    @MainActor func has(_ style: MarkdownInlineStyle, on word: String) -> Bool {
        let range = (string as NSString).range(of: word)
        guard range.location != NSNotFound else { return false }
        var found = true
        enumerateAttributes(in: range) { attributes, _, stop in
            if !MarkdownInlineStyle(attributes).contains(style) { found = false; stop.pointee = true }
        }
        return found
    }

    /// The heading level of the paragraph containing `word`, 0 for body text.
    func headingLevel(of word: String) -> Int? {
        let range = (string as NSString).range(of: word)
        guard range.location != NSNotFound else { return nil }
        return attribute(.markdownHeading, at: range.location, effectiveRange: nil) as? Int ?? 0
    }

    /// The first table's row count and column alignments.
    var firstTable: (rows: Int, alignments: [PresentationIntent.TableColumn.Alignment])? {
        var table: MarkdownTable?, rows = 0
        enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: length)) { value, _, _ in
            guard let block = (value as? NSParagraphStyle)?.textBlocks.last as? NSTextTableBlock,
                  let owner = block.table as? MarkdownTable, table == nil || owner === table else { return }
            table = owner
            rows = max(rows, block.startingRow + 1)
        }
        return table.map { (rows, $0.alignments) }
    }

    /// Whether any paragraph is a list item.
    var containsList: Bool {
        var found = false
        enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: length)) { value, _, stop in
            if (value as? NSParagraphStyle)?.textLists.isEmpty == false { found = true; stop.pointee = true }
        }
        return found
    }
}
