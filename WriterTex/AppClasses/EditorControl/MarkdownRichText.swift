import AppKit
import ImageIO

extension NSAttributedString.Key {
    /// Heading level 1–6 of the run's paragraph; absent for body text.
    static let markdownHeading = NSAttributedString.Key("TypeNBash.markdownHeading")
    /// `MarkdownInlineStyle` raw value; absent for plain text.
    static let markdownInline = NSAttributedString.Key("TypeNBash.markdownInline")
    /// Source an atomic run stands for: "wiki:<target>", "image:<alt>\u{1F}<url>".
    static let markdownSpan = NSAttributedString.Key("TypeNBash.markdownSpan")
}

/// A text block that isn't a table cell otherwise shrinks to its narrowest
/// content, one character per line; these fill the width they sit in.
class MarkdownFullWidthBlock: NSTextBlock {
    override init() {
        super.init()
        setValue(100, type: .percentageValueType, for: .width)
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
}

final class MarkdownQuoteBlock: MarkdownFullWidthBlock {}
final class MarkdownRuleBlock: MarkdownFullWidthBlock {}

final class MarkdownCodeBlock: MarkdownFullWidthBlock {
    var language = ""
    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone) as! MarkdownCodeBlock
        copy.language = language
        return copy
    }
}

/// List paragraph styles, as Notes offers them. Imported unordered lists keep
/// their source marker: `-` is dashed, `*` and `+` are bulleted.
enum MarkdownListKind: CaseIterable {
    case bulleted, dashed, numbered

    var title: String {
        switch self {
        case .bulleted: "Bulleted List"
        case .dashed: "Dashed List"
        case .numbered: "Numbered List"
        }
    }
}

final class MarkdownTable: NSTextTable {
    var alignments: [PresentationIntent.TableColumn.Alignment] = []
    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone) as! MarkdownTable
        copy.alignments = alignments
        return copy
    }
}

/// The Formatted view's document model: paragraph formatting for the editor,
/// and a one-way Markdown import for documents saved before WriterTex wrote RTFD.
@MainActor final class MarkdownRichText {
    private enum Extra {
        case wiki(target: String, label: String)
    }

    let baseURL: URL?
    var style: MarkdownStyleSheet
    private var theme: ManuscriptPalette { style.theme }

    init(baseURL: URL?, style: MarkdownStyleSheet) {
        self.baseURL = baseURL
        self.style = style
    }

    // MARK: Paragraph formatting

    func headingSelection(in text: NSAttributedString) -> (level: Int?, canApply: Bool) {
        var levels = Set<Int>()
        var canApply = true
        let string = text.string as NSString
        var location = 0
        while location < text.length {
            let attributes = text.attributes(at: location, effectiveRange: nil)
            let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle ?? .default
            canApply = canApply && paragraph.textLists.isEmpty && paragraph.textBlocks.allSatisfy { $0 is MarkdownQuoteBlock }
            levels.insert(attributes[.markdownHeading] as? Int ?? 0)
            location = NSMaxRange(string.paragraphRange(for: NSRange(location: location, length: 0)))
        }
        return (levels.count == 1 ? levels.first : nil, canApply)
    }

    /// Makes every paragraph a heading of `level`, or body text for 0, keeping inline
    /// content and quote containers. No source markers are inserted into the editor.
    func applyingHeading(_ level: Int, to text: NSAttributedString) -> NSAttributedString {
        guard (0...6).contains(level), headingSelection(in: text).canApply else { return text }
        let result = NSMutableAttributedString(attributedString: text)
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            var updated = attributes
            updated[.paragraphStyle] = style.headingParagraphStyle(level, from: attributes[.paragraphStyle] as? NSParagraphStyle ?? .default)
            updated[.markdownHeading] = level == 0 ? nil : level
            style.apply(to: &updated)
            result.setAttributes(updated, range: range)
        }
        return result
    }

    /// Body paragraphs out of any quote, code block or heading; inline formatting stays.
    func applyingBody(to text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            var updated = attributes
            updated[.paragraphStyle] = style.bodyParagraphStyle
            updated[.foregroundColor] = theme.bodyText
            updated[.markdownHeading] = nil
            style.apply(to: &updated)
            result.setAttributes(updated, range: range)
        }
        return result
    }

    func quoteSelection(in text: NSAttributedString) -> (isQuoted: Bool, containsQuote: Bool, canApply: Bool) {
        var all = text.length > 0, any = false, allowed = true
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            let blocks = (value as? NSParagraphStyle)?.textBlocks ?? []
            let quoted = blocks.contains { $0 is MarkdownQuoteBlock }
            all = all && quoted
            any = any || quoted
            allowed = allowed && blocks.allSatisfy { $0 is MarkdownQuoteBlock }
        }
        return (all, any, allowed)
    }

    /// Quote is paragraph formatting; changing it never inserts or removes text.
    func applyingQuote(_ enabled: Bool, to text: NSAttributedString) -> NSAttributedString {
        guard quoteSelection(in: text).canApply else { return text }
        let result = NSMutableAttributedString(attributedString: text)
        let block = style.quoteBlock()
        text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            let paragraph = (value as? NSParagraphStyle ?? style.bodyParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
            paragraph.textBlocks = enabled ? [block] : []
            result.addAttribute(.paragraphStyle, value: paragraph, range: range)
        }
        return result
    }

    /// The selection's list style when every paragraph shares one. Lists can't go in
    /// code blocks, tables or rules.
    func listSelection(in text: NSAttributedString) -> (kind: MarkdownListKind?, containsList: Bool, canApply: Bool) {
        var kinds = Set<MarkdownListKind?>()
        var canApply = true
        let string = text.string as NSString
        var location = 0
        while location < text.length {
            let attributes = text.attributes(at: location, effectiveRange: nil)
            let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle ?? .default
            canApply = canApply && paragraph.textBlocks.allSatisfy { $0 is MarkdownQuoteBlock }
            kinds.insert(paragraph.textLists.last?.kind)
            location = NSMaxRange(string.paragraphRange(for: NSRange(location: location, length: 0)))
        }
        return (kinds.count == 1 ? kinds.first ?? nil : nil, kinds.contains { $0 != nil }, canApply)
    }

    /// Length of the `\t•\t` marker a list item's first paragraph starts with.
    static func listMarkerLength(of paragraph: NSRange, in text: NSAttributedString) -> Int {
        paragraph.length > 0 ? contentRange(of: paragraph, in: text).location - paragraph.location : 0
    }

    /// Makes every paragraph an item of `kind`, or body text for nil, keeping inline
    /// formatting, quotes and nesting depth. Selected top-level paragraphs join one
    /// list; headings become body text. An empty `text` yields a lone marker.
    func applyingList(_ kind: MarkdownListKind?, startingAt start: Int = 1, to text: NSAttributedString,
                      typingAttributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let bodyStyle = style.bodyParagraphStyle
        let top = kind.map { kind in
            let list = NSTextList(kind, depth: 1)
            list.startingItemNumber = start
            return list
        }
        let sampleStyle = top.map { style.listParagraphStyle([$0], from: bodyStyle) }
        var nested: [ObjectIdentifier: NSTextList] = [:], numbers: [ObjectIdentifier: Int] = [:]
        func list(replacing old: NSTextList, depth: Int) -> NSTextList {
            if depth == 1, let top { return top }
            if let list = nested[ObjectIdentifier(old)] { return list }
            let list = NSTextList(kind ?? .bulleted, depth: depth)
            nested[ObjectIdentifier(old)] = list
            return list
        }

        let string = text.string as NSString
        var paragraphs: [NSRange] = []
        var location = 0
        while location < string.length {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            paragraphs.append(paragraph)
            location = NSMaxRange(paragraph)
        }
        if paragraphs.isEmpty { paragraphs = [NSRange(location: 0, length: 0)] }

        let result = NSMutableAttributedString()
        for paragraph in paragraphs {
            let attributes = paragraph.length > 0 ? text.attributes(at: paragraph.location, effectiveRange: nil) : typingAttributes
            let old = attributes[.paragraphStyle] as? NSParagraphStyle ?? bodyStyle
            if kind == nil, old.textLists.isEmpty {
                result.append(text.attributedSubstring(from: paragraph))
                continue
            }
            let markerLength = Self.listMarkerLength(of: paragraph, in: text)
            var content = text.attributedSubstring(from: NSRange(location: paragraph.location + markerLength, length: paragraph.length - markerLength))
            if kind != nil, attributes[.markdownHeading] != nil {
                content = applyingHeading(0, to: content)
            }
            let paragraphStyle: NSParagraphStyle
            if kind == nil || old.textLists.isEmpty {
                let layout = sampleStyle ?? bodyStyle
                let updated = old.mutableCopy() as! NSMutableParagraphStyle
                updated.textLists = layout.textLists
                updated.headIndent = layout.headIndent
                updated.firstLineHeadIndent = layout.firstLineHeadIndent
                updated.tabStops = layout.tabStops
                paragraphStyle = style.spaced(updated, heading: kind == nil ? attributes[.markdownHeading] as? Int : nil)
            } else {
                let updated = old.mutableCopy() as! NSMutableParagraphStyle
                updated.textLists = old.textLists.enumerated().map { list(replacing: $1, depth: $0 + 1) }
                paragraphStyle = updated
            }
            // Body paragraphs each become an item; a list's continuation paragraphs stay continuations.
            if let list = paragraphStyle.textLists.last, old.textLists.isEmpty || markerLength > 0 {
                let number = numbers[ObjectIdentifier(list), default: list.startingItemNumber]
                numbers[ObjectIdentifier(list)] = number + 1
                var markerAttributes = style.bodyAttributes
                markerAttributes[.paragraphStyle] = paragraphStyle
                markerAttributes[.foregroundColor] = attributes[.foregroundColor] ?? markerAttributes[.foregroundColor]
                result.append(NSAttributedString(string: "\t" + list.marker(forItemNumber: number) + "\t", attributes: markerAttributes))
            }
            let styled = NSMutableAttributedString(attributedString: content)
            styled.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: styled.length))
            result.append(styled)
        }
        return result
    }
    // MARK: Markdown → rich text
    /// Rich text from another app, given meaning: bold and italic fonts become
    /// emphasis, strikethrough stays, and the style sheet sets the look. Lists and
    /// tables keep their structure; other paragraphs become body text.
    func importing(_ rich: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(string: rich.string)
        rich.enumerateAttributes(in: NSRange(location: 0, length: rich.length)) { source, range, _ in
            var attributes = style.bodyAttributes
            let paragraph = source[.paragraphStyle] as? NSParagraphStyle
            if let paragraph {
                attributes[.paragraphStyle] = paragraph
                if (1...6).contains(paragraph.headerLevel) { attributes[.markdownHeading] = paragraph.headerLevel }
            }
            var inline: MarkdownInlineStyle = []
            if let font = source[.font] as? NSFont {
                let traits = NSFontManager.shared.traits(of: font)
                // Header cells are bold by position, not emphasis.
                if traits.contains(.boldFontMask), (paragraph?.textBlocks.last as? NSTextTableBlock)?.startingRow != 0 { inline.insert(.strong) }
                if traits.contains(.italicFontMask) { inline.insert(.emphasis) }
            }
            if (source[.strikethroughStyle] as? Int ?? 0) != 0 { inline.insert(.strikethrough) }
            inline.store(in: &attributes)
            for key: NSAttributedString.Key in [.link, .attachment] { attributes[key] = source[key] }
            style.apply(to: &attributes)
            result.setAttributes(attributes, range: range)
        }
        return result
    }


    // MARK: Tables

    typealias TableAlignment = PresentationIntent.TableColumn.Alignment

    /// The table around `location` in `text`: its range, each cell's content by
    /// row with inline formatting kept, its column alignments, and the cell at
    /// `location`. Nil outside a table.
    func tableGrid(at location: Int, in text: NSAttributedString)
        -> (range: NSRange, cells: [[NSAttributedString]], alignments: [TableAlignment], row: Int, column: Int)? {
        let string = text.string as NSString
        func block(_ paragraph: NSRange) -> NSTextTableBlock? {
            guard paragraph.length > 0 else { return nil }
            return (text.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.last as? NSTextTableBlock
        }
        func paragraph(at index: Int) -> NSRange { string.paragraphRange(for: NSRange(location: index, length: 0)) }
        guard location <= string.length, let current = block(paragraph(at: location)) else { return nil }
        let table = current.table
        var start = paragraph(at: location).location, end = NSMaxRange(paragraph(at: location))
        while start > 0, block(paragraph(at: start - 1))?.table === table { start = paragraph(at: start - 1).location }
        while end < string.length, block(paragraph(at: end))?.table === table { end = NSMaxRange(paragraph(at: end)) }
        var alignments = (table as? MarkdownTable)?.alignments ?? []
        alignments += Array(repeating: .left, count: max(0, table.numberOfColumns - alignments.count))
        var cells: [[NSAttributedString]] = [], aligned = Set<Int>()
        var index = start
        while index < end {
            let range = paragraph(at: index)
            index = NSMaxRange(range)
            guard let cell = block(range), cell.startingColumn < table.numberOfColumns else { continue }
            while cells.count <= cell.startingRow { cells.append(Array(repeating: NSAttributedString(), count: table.numberOfColumns)) }
            let content = text.attributedSubstring(from: Self.contentRange(of: range, in: text))
            let existing = cells[cell.startingRow][cell.startingColumn]
            if existing.length > 0 {
                // A cell holds one line in Markdown; extra paragraphs join it.
                let joined = NSMutableAttributedString(attributedString: existing)
                joined.append(NSAttributedString(string: " "))
                joined.append(content)
                cells[cell.startingRow][cell.startingColumn] = joined
            } else {
                cells[cell.startingRow][cell.startingColumn] = content
            }
            // Tables pasted from other apps carry alignment on the cell paragraph.
            if !(table is MarkdownTable), aligned.insert(cell.startingColumn).inserted {
                switch (text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.alignment {
                case .center: alignments[cell.startingColumn] = .center
                case .right: alignments[cell.startingColumn] = .right
                default: break
                }
            }
        }
        return (NSRange(location: start, length: end - start), cells, alignments, current.startingRow, current.startingColumn)
    }

    /// `cells`, rows of contents, as a new table in editor text, and where each
    /// cell starts, by row. Every cell is one paragraph; row 0 is the header.
    func table(_ cells: [[NSAttributedString]], alignments: [TableAlignment]) -> (text: NSAttributedString, starts: [[Int]]) {
        let table = style.table(alignments: alignments)
        let result = NSMutableAttributedString()
        var starts: [[Int]] = []
        for (row, line) in cells.enumerated() {
            starts.append([])
            for column in alignments.indices {
                let attributes = cellAttributes(table, row: row, column: column)
                starts[row].append(result.length)
                if column < line.count, line[column].length > 0 {
                    let content = NSMutableAttributedString(attributedString: line[column])
                    content.enumerateAttributes(in: NSRange(location: 0, length: content.length)) { source, range, _ in
                        var updated = source
                        updated[.paragraphStyle] = attributes[.paragraphStyle]
                        updated[.markdownHeading] = nil
                        style.apply(to: &updated)
                        content.setAttributes(updated, range: range)
                    }
                    result.append(content)
                }
                result.append(NSAttributedString(string: "\n", attributes: attributes))
            }
        }
        return (result, starts)
    }

    /// Attributes for a cell's paragraph; an empty cell is just its terminator.
    func cellAttributes(_ table: MarkdownTable, row: Int, column: Int) -> [NSAttributedString.Key: Any] {
        var attributes = style.bodyAttributes
        let paragraph = NSMutableParagraphStyle()
        paragraph.textBlocks = [style.cellBlock(table, row: row, column: column)]
        paragraph.alignment = Self.alignment(table.alignments, column)
        attributes[.paragraphStyle] = paragraph
        style.apply(to: &attributes)
        return attributes
    }

    private static func alignment(_ alignments: [PresentationIntent.TableColumn.Alignment], _ column: Int) -> NSTextAlignment {
        guard alignments.indices.contains(column) else { return .natural }
        switch alignments[column] {
        case .center: return .center
        case .right: return .right
        default: return .natural
        }
    }
}

// MARK: Paragraph ranges

extension MarkdownRichText {
    static func paragraphs(in text: NSAttributedString) -> [NSRange] {
        let string = text.string as NSString
        var ranges: [NSRange] = []
        var location = 0
        while location < string.length {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            ranges.append(range)
            location = NSMaxRange(range)
        }
        return ranges
    }

    /// The paragraph without its terminator and, for a list item, its marker.
    static func contentRange(of paragraph: NSRange, in text: NSAttributedString) -> NSRange {
        let string = text.string as NSString
        var range = paragraph
        while range.length > 0, [0x0A, 0x0D, 0x2029].contains(string.character(at: NSMaxRange(range) - 1)) { range.length -= 1 }
        let style = text.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle
        if style?.textLists.isEmpty == false, range.length > 0, string.character(at: range.location) == 0x09 {
            let second = string.range(of: "\t", range: NSRange(location: range.location + 1, length: range.length - 1))
            if second.location != NSNotFound { range = NSRange(location: NSMaxRange(second), length: NSMaxRange(range) - NSMaxRange(second)) }
        }
        return range
    }
}

extension NSTextList {
    static let dash = NSTextList.MarkerFormat("–")

    convenience init(_ kind: MarkdownListKind, depth: Int) {
        switch kind {
        case .numbered: self.init(markerFormat: NSTextList.MarkerFormat("{decimal}."), options: 0)
        case .dashed: self.init(markerFormat: Self.dash, options: 0)
        case .bulleted: self.init(markerFormat: depth > 1 ? .circle : .disc, options: 0)
        }
    }

    var isOrdered: Bool { markerFormat.rawValue.contains("decimal") }
    /// Lists pasted from other apps may use AppKit's hyphen rather than our dash.
    var kind: MarkdownListKind { isOrdered ? .numbered : markerFormat == Self.dash || markerFormat == .hyphen ? .dashed : .bulleted }
}
