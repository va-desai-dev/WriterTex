import AppKit

/// What the export sheet asks for: the manuscript's look and the text above and
/// below every page. Remembered between exports.
struct ManuscriptExportSettings: Codable, Equatable {
    /// Left, center and right text of a header or footer. `{page}`, `{pages}`
    /// and `{title}` are filled in on each page.
    struct Furniture: Codable, Equatable {
        var left = ""
        var center = ""
        var right = ""
    }

    var style = ManuscriptStyle.manuscript
    var header = Furniture()
    var footer = Furniture(center: "{page}")
    /// The CSL style citations are formatted with, by id ("apa").
    var citationStyle = "apa"
    /// The heading over the reference list.
    var referencesTitle = "References"

    init() {}

    /// Settings saved before a field existed keep the rest of what was chosen.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        style = try container.decodeIfPresent(ManuscriptStyle.self, forKey: .style) ?? defaults.style
        header = try container.decodeIfPresent(Furniture.self, forKey: .header) ?? defaults.header
        footer = try container.decodeIfPresent(Furniture.self, forKey: .footer) ?? defaults.footer
        citationStyle = try container.decodeIfPresent(String.self, forKey: .citationStyle) ?? defaults.citationStyle
        referencesTitle = try container.decodeIfPresent(String.self, forKey: .referencesTitle) ?? defaults.referencesTitle
    }

    private static let defaultsKey = "ManuscriptExportSettings"

    static var saved: ManuscriptExportSettings {
        UserDefaults.standard.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.defaultsKey)
    }
}

/// The publication manuals the export sheet can set everything up for at once:
/// type, heading levels, indents, running head and citation style.
enum ManuscriptManual: String, CaseIterable, Identifiable {
    case apa, mla, chicago

    var id: Self { self }

    var title: String {
        switch self {
        case .apa: "APA 7th Edition"
        case .mla: "MLA 9th Edition"
        case .chicago: "Chicago 17th (Author-Date)"
        }
    }

    /// The manual's CSL style in the CSL repository.
    var citationStyle: String {
        switch self {
        case .apa: "apa"
        case .mla: "modern-language-association"
        case .chicago: "chicago-author-date"
        }
    }

    var settings: ManuscriptExportSettings {
        var settings = ManuscriptExportSettings()
        settings.citationStyle = citationStyle
        switch self {
        case .apa:
            settings.style = .manuscript
            settings.header = .init(right: "{page}")
            settings.footer = .init()
        case .mla:
            // MLA wants the author's surname before the number; they add it.
            settings.style = .mla
            settings.header = .init(right: "{page}")
            settings.footer = .init()
            settings.referencesTitle = "Works Cited"
        case .chicago:
            settings.style = .chicago
            settings.header = .init()
            settings.footer = .init(center: "{page}")
        }
        return settings
    }

    /// The manual `settings` were set up from, while they still follow it.
    static func matching(_ settings: ManuscriptExportSettings) -> ManuscriptManual? {
        allCases.first { $0.settings.style == settings.style && $0.citationStyle == settings.citationStyle }
    }
}

/// Lays a manuscript out as pages: the semantic rich text the
/// editor uses, restyled with the export's `ManuscriptStyle`, paginated by TextKit 1
/// (which keeps tables as tables) and drawn straight into a PDF.
@MainActor enum ManuscriptPDF {
    static let margin: CGFloat = 72

    /// The page image of a manuscript, and the cited keys the library lacks.
    static func render(_ source: NSAttributedString, baseURL: URL?, title: String, settings: ManuscriptExportSettings,
                       citations: ManuscriptCitationSource?) -> (data: Data, missing: [String]) {
        var result = (Data(), [String]())
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            result = draw(source, baseURL: baseURL, title: title, settings: settings, citations: citations)
        }
        return result
    }

    /// The semantic rich text both exporters start from: citations formatted,
    /// the reference list added and each level's capitalization applied.
    static func manuscriptText(_ source: NSAttributedString, baseURL: URL?, style: MarkdownStyleSheet, settings: ManuscriptExportSettings,
                               citations: ManuscriptCitationSource?) -> (text: NSMutableAttributedString, missing: [String]) {
        let text = NSMutableAttributedString(attributedString: source)
        var blocks: [ObjectIdentifier: NSTextBlock] = [:]
        var tables: [ObjectIdentifier: MarkdownTable] = [:]
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            var updated = attributes
            if ManuscriptCitations.isLink(updated[.link]) { updated[.link] = nil }
            updated[.foregroundColor] = style.theme.bodyText
            if let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle, !paragraph.textBlocks.isEmpty {
                let printed = paragraph.mutableCopy() as! NSMutableParagraphStyle
                printed.textBlocks = paragraph.textBlocks.map { block in
                    let id = ObjectIdentifier(block)
                    if let copy = blocks[id] { return copy }
                    let copy: NSTextBlock
                    switch block {
                    case let cell as NSTextTableBlock:
                        let tableID = ObjectIdentifier(cell.table)
                        let table = tables[tableID] ?? style.table(alignments: Array(repeating: .left, count: cell.table.numberOfColumns))
                        tables[tableID] = table
                        copy = style.cellBlock(table, row: cell.startingRow, column: cell.startingColumn)
                    case let code as MarkdownCodeBlock: copy = style.codeBlock(language: code.language)
                    case is MarkdownQuoteBlock: copy = style.quoteBlock()
                    case is MarkdownRuleBlock: copy = style.ruleBlock()
                    default: copy = block.copy() as! NSTextBlock
                    }
                    blocks[id] = copy
                    return copy
                }
                updated[.paragraphStyle] = printed
            }
            if let attachment = attributes[.attachment] as? NSTextAttachment {
                let copy = NSTextAttachment()
                copy.fileWrapper = attachment.fileWrapper
                copy.image = attachment.image
                copy.bounds = attachment.bounds
                updated[.attachment] = copy
            }
            style.apply(to: &updated)
            text.setAttributes(updated, range: range)
        }
        let missing = citations.map { ManuscriptCitations.resolve(in: text, source: $0, style: style) } ?? []
        capitalize(text, settings.style)
        return (text, missing)
    }

    private static func draw(_ source: NSAttributedString, baseURL: URL?, title: String, settings: ManuscriptExportSettings,
                             citations: ManuscriptCitationSource?) -> (Data, [String]) {
        let paper = NSPrintInfo.shared.paperSize
        let content = CGRect(x: margin, y: margin, width: paper.width - 2 * margin, height: paper.height - 2 * margin)
        let style = MarkdownStyleSheet(theme: .print, manuscript: settings.style,
                                       codeBackground: NSColor(white: 0.94, alpha: 1))
        let (text, missing) = manuscriptText(source, baseURL: baseURL, style: style, settings: settings, citations: citations)
        let all = NSRange(location: 0, length: text.length)
        text.removeAttribute(.link, range: all)
        // Figures are sized for the editor; a page may be narrower.
        text.enumerateAttribute(.attachment, in: all) { value, _, _ in
            guard let attachment = value as? NSTextAttachment, attachment.bounds.width > 0 else { return }
            let scale = min(1, content.width / attachment.bounds.width, content.height / max(attachment.bounds.height, 1))
            attachment.bounds.size = CGSize(width: attachment.bounds.width * scale, height: attachment.bounds.height * scale)
        }

        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        var pages: [NSTextContainer] = []
        while true {
            let container = NSTextContainer(size: content.size)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            pages.append(container)
            let range = layout.glyphRange(for: container)
            // An empty page means nothing more fits anywhere; stop rather than loop.
            if NSMaxRange(range) >= layout.numberOfGlyphs || range.length == 0 { break }
        }

        let output = NSMutableData()
        var box = CGRect(origin: .zero, size: paper)
        let info = [kCGPDFContextTitle: title, kCGPDFContextCreator: "WriterTex"] as CFDictionary
        guard let consumer = CGDataConsumer(data: output), let pdf = CGContext(consumer: consumer, mediaBox: &box, info) else { return (Data(), missing) }
        let furnitureFont = style.baseFont(size: max(8, settings.style.body.size - 2))
        for (index, container) in pages.enumerated() {
            pdf.beginPDFPage(nil)
            pdf.translateBy(x: 0, y: paper.height)
            pdf.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: true)
            let glyphs = layout.glyphRange(for: container)
            layout.drawBackground(forGlyphRange: glyphs, at: content.origin)
            layout.drawGlyphs(forGlyphRange: glyphs, at: content.origin)
            func fill(_ template: String) -> String {
                template.replacingOccurrences(of: "{pages}", with: "\(pages.count)")
                    .replacingOccurrences(of: "{page}", with: "\(index + 1)")
                    .replacingOccurrences(of: "{title}", with: title)
            }
            let lineHeight = ceil(furnitureFont.ascender - furnitureFont.descender + furnitureFont.leading)
            for (furniture, top) in [(settings.header, (margin - lineHeight) / 2),
                                     (settings.footer, paper.height - margin + (margin - lineHeight) / 2)] {
                let line = CGRect(x: content.minX, y: top, width: content.width, height: lineHeight)
                for (template, alignment) in [(furniture.left, NSTextAlignment.left), (furniture.center, .center), (furniture.right, .right)]
                where !template.isEmpty {
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.alignment = alignment
                    paragraph.lineBreakMode = .byTruncatingTail
                    NSAttributedString(string: fill(template), attributes: [.font: furnitureFont, .foregroundColor: NSColor.black, .paragraphStyle: paragraph])
                        .draw(in: line)
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            pdf.endPDFPage()
        }
        pdf.closePDF()
        return (output as Data, missing)
    }

    /// Words title case leaves lowercase unless they start the line.
    private static let minorWords: Set<String> = ["a", "an", "the", "and", "but", "or", "nor", "for", "so", "yet",
                                                  "as", "at", "by", "in", "of", "off", "on", "per", "to", "up", "via"]

    /// Applies each level's capitalization to its prose; code, wiki links and
    /// figures keep their source text.
    static func capitalize(_ text: NSMutableAttributedString, _ style: ManuscriptStyle) {
        let original = text.string as NSString
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length), options: .reverse) { attributes, range, _ in
            let capitalization = style.level(attributes[.markdownHeading] as? Int ?? 0).capitalization
            guard capitalization != .asTyped, attributes[.markdownSpan] == nil, attributes[.attachment] == nil,
                  !MarkdownInlineStyle(attributes).contains(.code),
                  !((attributes[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.last is MarkdownCodeBlock) else { return }
            let piece = original.substring(with: range)
            let changed: String
            switch capitalization {
            case .asTyped: return
            case .upper: changed = piece.uppercased()
            case .lower: changed = piece.lowercased()
            case .title:
                var result = "", last = piece.startIndex
                var first = original.paragraphRange(for: NSRange(location: range.location, length: 0)).location == range.location
                piece.enumerateSubstrings(in: piece.startIndex..., options: .byWords) { word, wordRange, _, _ in
                    guard let word else { return }
                    result += piece[last..<wordRange.lowerBound]
                    result += !first && minorWords.contains(word.lowercased()) ? word : word.prefix(1).uppercased() + word.dropFirst()
                    last = wordRange.upperBound
                    first = false
                }
                changed = result + piece[last...]
            }
            if changed != piece { text.replaceCharacters(in: range, with: changed) }
        }
    }
}

/// The files a WriterTex document exports as.
enum ManuscriptFormat: String, CaseIterable {
    case pdf, docx

    var title: String { self == .pdf ? "PDF" : "Word" }
}

extension FileBrowserModel {
    /// Renders the open WriterTex document as a manuscript named after it and
    /// writes it into `directory`, or beside the document. Returns where it went and the cited keys `citations` lacks.
    func exportManuscript(_ settings: ManuscriptExportSettings, as format: ManuscriptFormat, into directory: URL?,
                          citations: ManuscriptCitationSource?) async throws -> (url: URL, missing: [String]) {
        let text = try manuscriptSnapshot()
        guard let folder = directory ?? selectedFile?.deletingLastPathComponent() else {
            throw ProjectSetupError.invalid("Save the document before exporting it.")
        }
        let title = selectedFile?.deletingPathExtension().lastPathComponent ?? writerTexDocTitle
        let baseURL = selectedFile?.deletingLastPathComponent()
        let (data, missing) = switch format {
        case .pdf: ManuscriptPDF.render(text, baseURL: baseURL, title: title, settings: settings, citations: citations)
        case .docx: ManuscriptDOCX.render(text, baseURL: baseURL, title: title, settings: settings, citations: citations)
        }
        let url = folder.appendingPathComponent(title).appendingPathExtension(format.rawValue)
        try data.write(to: url, options: .atomic)
        return (url, missing)
    }
}
