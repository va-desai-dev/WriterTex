import AppKit

/// A WriterTex file contains native RTFD plus the semantic styles RTF cannot
/// express (heading levels, code and citation spans), and the one .bib the
/// manuscript cites from. No Markdown is stored.
nonisolated struct ManuscriptDocument: Codable {
    var version = 1
    let rtfd: Data
    let runs: [Run]

    struct Run: Codable {
        let location: Int
        let length: Int
        let heading: Int?
        let inline: Int?
        let span: String?
        let blocks: [Int]
        let lists: [Int]
        let attachmentBounds: CGRect?
        /// Kept here rather than in the RTFD; see `encode`. Absent in older files.
        var link: String? = nil
    }

    struct Block: Codable {
        let kind: String
        let language: String?
    }
    let blocks: [Block]
    struct List: Codable {
        let marker: String
        let start: Int
    }
    let lists: [List]
    /// Absent in files written before manuscripts chose their own .bib.
    var bibliography: BibliographyLink? = nil

    /// The bibliography a saved manuscript links to, without decoding its text.
    static func bibliography(in data: Data) -> BibliographyLink? {
        guard data.starts(with: Data("bplist".utf8)) else { return nil }
        return (try? PropertyListDecoder().decode(Linked.self, from: data))?.bibliography
    }

    /// `data`, an encoded manuscript, linked to `bibliography` instead.
    static func linking(_ data: Data, to bibliography: BibliographyLink?) throws -> Data {
        var saved = try PropertyListDecoder().decode(Self.self, from: data)
        saved.bibliography = bibliography
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(saved)
    }

    /// Only the link, so reading it skips the text runs.
    private struct Linked: Decodable { let bibliography: BibliographyLink? }

    /// WriterTex rich text on a pasteboard: an encoded manuscript, so styles,
    /// tables and images survive between editors.
    static let pasteboardType = NSPasteboard.PasteboardType("com.writertex.rich-text")

    /// Puts `text` on `pasteboard` for any app: WriterTex rich text, RTF in the
    /// receiving document's own text color, and `plain`.
    @MainActor static func write(_ text: NSAttributedString, plain: String, to pasteboard: NSPasteboard) throws {
        let data = try encode(text)
        let foreign = NSMutableAttributedString(attributedString: text)
        foreign.removeAttribute(.foregroundColor, range: NSRange(location: 0, length: foreign.length))
        let rtf = try foreign.data(from: NSRange(location: 0, length: foreign.length),
                                   documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        pasteboard.clearContents()
        pasteboard.setData(data, forType: pasteboardType)
        pasteboard.setData(rtf, forType: .rtf)
        pasteboard.setString(plain, forType: .string)
    }

    @MainActor static func encode(_ text: NSAttributedString) throws -> Data {
        var blocks: [Block] = [], identities: [ObjectIdentifier: Int] = [:], runs: [Run] = []
        var lists: [List] = [], listIdentities: [ObjectIdentifier: Int] = [:]
        let native = NSMutableAttributedString(attributedString: text)
        // No link goes into the RTFD: AppKit's RTF reader sends each one through
        // the system data detectors, which wait on the spell checker at a lower
        // priority and stall opening. Other links are stored with the runs;
        // citation links come from the text and are rebuilt on opening.
        native.removeAttribute(.link, range: NSRange(location: 0, length: native.length))
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            let attachment = attributes[.attachment] as? NSTextAttachment
            if let attachment, attachment.fileWrapper == nil, let data = attachment.image?.tiffRepresentation {
                let wrapper = FileWrapper(regularFileWithContents: data)
                wrapper.preferredFilename = "Figure.tiff"
                let stored = NSTextAttachment(fileWrapper: wrapper)
                stored.bounds = attachment.bounds
                native.addAttribute(.attachment, value: stored, range: range)
            }
            let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle
            let listIDs: [Int] = paragraph?.textLists.map { list in
                let id = ObjectIdentifier(list)
                if let index = listIdentities[id] { return index }
                listIdentities[id] = lists.count
                lists.append(List(marker: list.markerFormat.rawValue, start: list.startingItemNumber))
                return lists.count - 1
            } ?? []
            // AppKit's RTF writer removes explicit list markers. Store the list
            // objects separately so UTF-16 run offsets and visible text stay exact.
            if let paragraph {
                let plain = paragraph.mutableCopy() as! NSMutableParagraphStyle
                plain.textLists = []
                // RTF represents generic text blocks as tables. Quote/code/rule
                // identity lives in the semantic metadata, never as fake cells.
                plain.textBlocks = paragraph.textBlocks.filter { $0 is NSTextTableBlock }
                native.addAttribute(.paragraphStyle, value: plain, range: range)
            }
            let ids = (attributes[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.compactMap { block -> Int? in
                guard !(block is NSTextTableBlock) else { return nil }
                let identity = ObjectIdentifier(block)
                if let id = identities[identity] { return id }
                let kind = block is MarkdownQuoteBlock ? "quote" : block is MarkdownCodeBlock ? "code" : "rule"
                identities[identity] = blocks.count
                blocks.append(Block(kind: kind, language: (block as? MarkdownCodeBlock)?.language))
                return blocks.count - 1
            } ?? []
            runs.append(Run(location: range.location, length: range.length,
                            heading: attributes[.markdownHeading] as? Int,
                            inline: attributes[.markdownInline] as? Int,
                            span: attributes[.markdownSpan] as? String, blocks: ids, lists: listIDs,
                            attachmentBounds: attachment?.bounds, link: Self.storedLink(attributes[.link])))
        }
        let data = try native.data(from: NSRange(location: 0, length: native.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(Self(rtfd: data, runs: runs, blocks: blocks, lists: lists))
    }

    @MainActor private static func storedLink(_ value: Any?) -> String? {
        guard !ManuscriptCitations.isLink(value) else { return nil }
        return (value as? URL)?.absoluteString ?? value as? String
    }

    @MainActor static func decode(_ data: Data, using document: MarkdownRichText) throws -> NSAttributedString {
        if data.isEmpty { return NSAttributedString() }
        if data.starts(with: Data("{\\rtf".utf8)) {
            return document.importing(try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil))
        }
        let saved = try PropertyListDecoder().decode(Self.self, from: data)
        guard saved.version == 1 else { throw CocoaError(.fileReadUnknown) }
        let text = NSMutableAttributedString(attributedString: try NSAttributedString(data: saved.rtfd, options: [.documentType: NSAttributedString.DocumentType.rtfd], documentAttributes: nil))

        let blocks: [NSTextBlock] = try saved.blocks.map {
            switch $0.kind {
            case "quote": return document.style.quoteBlock()
            case "code": return document.style.codeBlock(language: $0.language ?? "")
            case "rule": return document.style.ruleBlock()
            default: throw CocoaError(.fileReadCorruptFile)
            }
        }
        let lists = saved.lists.map { saved in
            let list = NSTextList(markerFormat: NSTextList.MarkerFormat(saved.marker), options: 0)
            list.startingItemNumber = saved.start
            return list
        }
        var tables: [ObjectIdentifier: MarkdownTable] = [:]
        for run in saved.runs {
            guard run.location >= 0, run.length > 0, run.location <= text.length,
                  run.length <= text.length - run.location, run.blocks.allSatisfy({ blocks.indices.contains($0) }),
                  run.lists.allSatisfy({ lists.indices.contains($0) }),
                  run.heading.map({ (1...6).contains($0) }) ?? true else { throw CocoaError(.fileReadCorruptFile) }
            let range = NSRange(location: run.location, length: run.length)
            text.addAttributes([.markdownInline: run.inline ?? 0], range: range)
            if let heading = run.heading { text.addAttribute(.markdownHeading, value: heading, range: range) }
            if let span = run.span, !span.hasPrefix("source:") { text.addAttribute(.markdownSpan, value: span, range: range) }
            if let link = run.link { text.addAttribute(.link, value: (URL(string: link) as Any?) ?? link, range: range) }
            text.enumerateAttribute(.attachment, in: range) { value, _, _ in
                guard let attachment = value as? NSTextAttachment else { return }
                if attachment.image == nil {
                    attachment.image = attachment.fileWrapper?.regularFileContents.flatMap(NSImage.init(data:))
                        ?? (attachment.attachmentCell as? NSCell)?.image
                }
                if let bounds = run.attachmentBounds { attachment.bounds = bounds }
            }
            text.enumerateAttribute(.paragraphStyle, in: range) { value, subrange, _ in
                let paragraph = (value as? NSParagraphStyle ?? document.style.bodyParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
                let cells = paragraph.textBlocks.compactMap { $0 as? NSTextTableBlock }.map { cell -> NSTextTableBlock in
                    let id = ObjectIdentifier(cell.table)
                    let table = tables[id] ?? document.style.table(alignments: Array(repeating: .left, count: cell.table.numberOfColumns))
                    tables[id] = table
                    if table.alignments.indices.contains(cell.startingColumn) {
                        table.alignments[cell.startingColumn] = switch paragraph.alignment {
                        case .center: .center
                        case .right: .right
                        default: .left
                        }
                    }
                    return document.style.cellBlock(table, row: cell.startingRow, column: cell.startingColumn)
                }
                paragraph.textBlocks = run.blocks.map { blocks[$0] } + cells
                paragraph.textLists = run.lists.map { lists[$0] }
                text.addAttribute(.paragraphStyle, value: paragraph, range: subrange)
            }
        }
        document.style.restyle(text, in: NSRange(location: 0, length: text.length))
        document.style.recolor(text, in: NSRange(location: 0, length: text.length))
        ManuscriptCitations.updateLinks(in: text, editedRange: NSRange(location: 0, length: text.length))
        return text
    }
}
