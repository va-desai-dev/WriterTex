import AppKit
import SwiftUI

/// How a manuscript's levels look: body text and headings 1–6. The editor shows
/// the screen preset; export applies the author's own.
struct ManuscriptStyle: Codable, Equatable {
    enum Capitalization: String, Codable, CaseIterable {
        case asTyped, upper, lower, title
    }

    enum TextAlignment: String, Codable, CaseIterable {
        case left, center, right, justified

        var title: String {
            switch self {
            case .left: "Left"
            case .center: "Center"
            case .right: "Right"
            case .justified: "Justified"
            }
        }

        var symbol: String {
            switch self {
            case .left: "text.alignleft"
            case .center: "text.aligncenter"
            case .right: "text.alignright"
            case .justified: "text.justify"
            }
        }

        /// Left is natural so the editor's untouched paragraphs already match it.
        var native: NSTextAlignment {
            switch self {
            case .left: .natural
            case .center: .center
            case .right: .right
            case .justified: .justified
            }
        }
    }

    struct Level: Codable, Equatable {
        var size: CGFloat
        var capitalization = Capitalization.asTyped
        /// Applies to prose and headings; lists, quotes, code and tables keep their own.
        var alignment = TextAlignment.left
        var bold = false
        var italic = false
        var underline = false
        /// Points of space above and below the paragraph, as in a word
        /// processor's paragraph spacing.
        var spaceBefore: CGFloat = 0
        var spaceAfter: CGFloat = 0

        init(size: CGFloat, capitalization: Capitalization = .asTyped, alignment: TextAlignment = .left, bold: Bool = false, italic: Bool = false,
             underline: Bool = false, spaceBefore: CGFloat = 0, spaceAfter: CGFloat = 0) {
            self.size = size
            self.capitalization = capitalization
            self.alignment = alignment
            self.bold = bold
            self.italic = italic
            self.underline = underline
            self.spaceBefore = spaceBefore
            self.spaceAfter = spaceAfter
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            size = try container.decode(CGFloat.self, forKey: .size)
            capitalization = try container.decodeIfPresent(Capitalization.self, forKey: .capitalization) ?? .asTyped
            alignment = try container.decodeIfPresent(TextAlignment.self, forKey: .alignment) ?? .left
            bold = try container.decodeIfPresent(Bool.self, forKey: .bold) ?? false
            italic = try container.decodeIfPresent(Bool.self, forKey: .italic) ?? false
            underline = try container.decodeIfPresent(Bool.self, forKey: .underline) ?? false
            spaceBefore = try container.decodeIfPresent(CGFloat.self, forKey: .spaceBefore) ?? 0
            spaceAfter = try container.decodeIfPresent(CGFloat.self, forKey: .spaceAfter) ?? 0
        }
    }

    /// Font family for body and headings; nil is the system font.
    var fontFamily: String?
    var body: Level
    /// Headings 1–6, in order.
    var headings: [Level]
    /// Points the first line of each body paragraph is indented; the manuals ask for 36 (half an inch).
    var firstLineIndent: CGFloat = 0
    /// Points a reference's second and later lines hang in, when the citation style hangs them.
    var referencesHanging: CGFloat = 36
    /// Line spacing as a multiple of single spacing: 1, 1.15, 1.5, 2.
    var lineSpacing: CGFloat = 1.15

    /// 0 is body; 1–6 are headings.
    func level(_ heading: Int) -> Level {
        headings.indices.contains(heading - 1) ? headings[heading - 1] : body
    }

    init(fontFamily: String? = nil, body: Level, headings: [Level], firstLineIndent: CGFloat = 0,
         referencesHanging: CGFloat = 36, lineSpacing: CGFloat) {
        self.fontFamily = fontFamily
        self.body = body
        self.headings = headings
        self.firstLineIndent = firstLineIndent
        self.referencesHanging = referencesHanging
        self.lineSpacing = lineSpacing
    }

    /// Styles saved before spacing existed keep the spacing exports had then.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fontFamily = try container.decodeIfPresent(String.self, forKey: .fontFamily)
        body = try container.decode(Level.self, forKey: .body)
        headings = try container.decode([Level].self, forKey: .headings)
        firstLineIndent = try container.decodeIfPresent(CGFloat.self, forKey: .firstLineIndent) ?? 0
        referencesHanging = try container.decodeIfPresent(CGFloat.self, forKey: .referencesHanging) ?? 36
        if let lineSpacing = try container.decodeIfPresent(CGFloat.self, forKey: .lineSpacing) {
            self.lineSpacing = lineSpacing
        } else {
            let screen = Self.screen
            body.spaceAfter = screen.body.spaceAfter
            for index in headings.indices where screen.headings.indices.contains(index) {
                headings[index].spaceBefore = screen.headings[index].spaceBefore
                headings[index].spaceAfter = screen.headings[index].spaceAfter
            }
        }
    }

    static let screen = ManuscriptStyle(
        body: Level(size: 14, spaceAfter: 8),
        headings: [26, 22, 18, 16, 14, 14].enumerated().map { index, size in
            Level(size: size, bold: true, spaceBefore: index < 2 ? 10 : 6, spaceAfter: 8)
        },
        lineSpacing: 1.15)

    /// A bare academic manuscript, as APA 7 asks: one size throughout, levels told
    /// apart by emphasis, double-spaced with no extra space between paragraphs,
    /// body paragraphs and references indented half an inch. Level 4 and 5
    /// headings are run-in in APA; here they stand on their own line.
    static let manuscript = ManuscriptStyle(
        fontFamily: "Times New Roman",
        body: Level(size: 12),
        headings: [
            Level(size: 12, capitalization: .title, alignment: .center, bold: true),
            Level(size: 12, capitalization: .title, bold: true),
            Level(size: 12, capitalization: .title, bold: true, italic: true),
            Level(size: 12, capitalization: .title, bold: true),
            Level(size: 12, capitalization: .title, bold: true, italic: true),
            Level(size: 12, italic: true),
        ],
        firstLineIndent: 36,
        lineSpacing: 2)

    /// MLA 9: its recommended heading levels, Works Cited hung half an inch.
    static let mla = ManuscriptStyle(
        fontFamily: "Times New Roman",
        body: Level(size: 12),
        headings: [
            Level(size: 12, bold: true),
            Level(size: 12, italic: true),
            Level(size: 12, alignment: .center, bold: true),
            Level(size: 12, alignment: .center, italic: true),
            Level(size: 12, underline: true),
            Level(size: 12, italic: true),
        ],
        firstLineIndent: 36,
        lineSpacing: 2)

    /// Chicago 17 / Turabian: centered upper levels, headline-style capitalization.
    static let chicago = ManuscriptStyle(
        fontFamily: "Times New Roman",
        body: Level(size: 12),
        headings: [
            Level(size: 12, capitalization: .title, alignment: .center, bold: true),
            Level(size: 12, capitalization: .title, alignment: .center),
            Level(size: 12, capitalization: .title, bold: true),
            Level(size: 12, capitalization: .title),
            Level(size: 12, bold: true, italic: true),
            Level(size: 12, italic: true),
        ],
        firstLineIndent: 36,
        lineSpacing: 2)
}

/// The colors a manuscript is drawn in: the app's on screen, ink on paper for
/// export.
struct ManuscriptPalette: Equatable {
    var bodyText: NSColor
    var mutedText: NSColor
    var link: NSColor
    var strikethroughColor: NSColor
    var highlightColor: NSColor

    /// The editor's colors, following `AppTheme` and the user's overrides.
    @MainActor static var screen: ManuscriptPalette {
        let theme = AppTheme.shared
        return ManuscriptPalette(
            bodyText: NSColor(theme.foreground),
            mutedText: NSColor(theme.secondary),
            link: NSColor(theme.accent),
            strikethroughColor: NSColor(theme.foreground),
            highlightColor: AppTheme.highlightColor)
    }

    /// `screen` with text and background swapped: text in the card color, to
    /// sit on a page filled with the theme's foreground.
    @MainActor static var screenInverted: ManuscriptPalette {
        let theme = AppTheme.shared
        var palette = screen
        palette.bodyText = NSColor(theme.card)
        palette.strikethroughColor = NSColor(theme.card)
        return palette
    }

    /// Ink on paper: fixed colors, whatever the app's appearance.
    static let print = ManuscriptPalette(
        bodyText: .black,
        mutedText: NSColor(white: 0.35, alpha: 1),
        link: .black,
        strikethroughColor: .black,
        highlightColor: NSColor(srgbRed: 1, green: 0.93, blue: 0.55, alpha: 1))
}

/// What a run means inline. Stored as `.markdownInline`; the font and decorations
/// a run shows are derived from it, never read back from them.
struct MarkdownInlineStyle: OptionSet, Hashable {
    let rawValue: Int
    static let strong = MarkdownInlineStyle(rawValue: 1 << 0)
    static let emphasis = MarkdownInlineStyle(rawValue: 1 << 1)
    static let strikethrough = MarkdownInlineStyle(rawValue: 1 << 2)
    static let highlight = MarkdownInlineStyle(rawValue: 1 << 3)
    static let code = MarkdownInlineStyle(rawValue: 1 << 4)

    init(rawValue: Int) { self.rawValue = rawValue }
    init(_ attributes: [NSAttributedString.Key: Any]) { self.init(rawValue: attributes[.markdownInline] as? Int ?? 0) }

    /// Writes the style into `attributes`, leaving no key for plain text so
    /// untouched runs compare equal to freshly loaded ones.
    func store(in attributes: inout [NSAttributedString.Key: Any]) {
        attributes[.markdownInline] = isEmpty ? nil : rawValue
    }
}

/// Turns what text means into how it looks. Fonts, decorations and block
/// geometry in the editor's storage all come from here, so the same document can
/// be restyled for another theme or a manuscript without reparsing.
@MainActor struct MarkdownStyleSheet: Equatable {
    let theme: ManuscriptPalette
    let manuscript: ManuscriptStyle
    /// Fill behind code; nil is a tint of the theme's muted text.
    var codeBackground: NSColor?

    /// Code is plain monospaced text on a fill, as in Notes: a writing document
    /// never runs the code editor's parsers.
    var codeFont: NSFont { .monospacedSystemFont(ofSize: manuscript.body.size - 1, weight: .regular) }
    var codeFill: NSColor { codeBackground ?? theme.mutedText.withAlphaComponent(0.12) }

    /// Fonts by family, size and emphasis. Making them was most of the cost of
    /// styling a run, and a document asks for the same handful thousands of times.
    private struct FontKey: Hashable {
        let family: String?, size: CGFloat, traits: UInt
    }
    private static var fonts: [FontKey: NSFont] = [:]

    func baseFont(size: CGFloat) -> NSFont { font(size: size, traits: []) }

    private func font(size: CGFloat, traits: NSFontTraitMask) -> NSFont {
        let key = FontKey(family: manuscript.fontFamily, size: size, traits: traits.rawValue)
        if let font = Self.fonts[key] { return font }
        let base = manuscript.fontFamily.flatMap { NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: size) }
            ?? .systemFont(ofSize: size)
        let font = traits.isEmpty ? base : NSFontManager.shared.convert(base, toHaveTrait: traits)
        Self.fonts[key] = font
        return font
    }

    var bodyParagraphStyle: NSParagraphStyle { spaced(.default, heading: nil) }

    /// Native paragraph metrics: TextKit owns font leading and fractional layout.
    func spaced(_ paragraph: NSParagraphStyle, heading: Int?, isReference: Bool = false) -> NSParagraphStyle {
        let block = paragraph.textBlocks.last
        let level = manuscript.level(heading ?? 0)
        let code = block is MarkdownCodeBlock
        let multiple: CGFloat = code ? 1 : manuscript.lineSpacing
        // Cells, code and list items sit close; their blocks carry the margins.
        let before: CGFloat = code || block is NSTextTableBlock || !paragraph.textLists.isEmpty ? 0 : level.spaceBefore
        let after: CGFloat = code || block is NSTextTableBlock ? 0
            : paragraph.textLists.isEmpty ? level.spaceAfter : min(level.spaceAfter, 3)
        // Alignment and the first-line indent belong to prose and headings; lists,
        // blocks and references lay out their own lines.
        let prose = paragraph.textBlocks.isEmpty && paragraph.textLists.isEmpty && !isReference
        let alignment = prose ? level.alignment.native : paragraph.alignment
        let firstLine = prose ? (heading == nil ? manuscript.firstLineIndent : 0) : paragraph.firstLineHeadIndent
        guard paragraph.minimumLineHeight != 0 || paragraph.lineHeightMultiple != multiple
                || paragraph.paragraphSpacingBefore != before || paragraph.paragraphSpacing != after
                || paragraph.alignment != alignment || paragraph.firstLineHeadIndent != firstLine else { return paragraph }
        let style = paragraph.mutableCopy() as! NSMutableParagraphStyle
        style.lineHeightMultiple = multiple
        style.minimumLineHeight = 0
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.alignment = alignment
        style.firstLineHeadIndent = firstLine
        return style.copy() as! NSParagraphStyle
    }

    var bodyAttributes: [NSAttributedString.Key: Any] {
        [
            .font: baseFont(size: manuscript.body.size),
            .foregroundColor: theme.bodyText,
            .paragraphStyle: bodyParagraphStyle
        ]
    }

    func font(for attributes: [NSAttributedString.Key: Any]) -> NSFont {
        let block = (attributes[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.last
        let inline = MarkdownInlineStyle(attributes)
        if block is MarkdownRuleBlock { return .systemFont(ofSize: 4) }
        if inline.contains(.code) || block is MarkdownCodeBlock { return codeFont }
        let level = manuscript.level(attributes[.markdownHeading] as? Int ?? 0)
        var traits: NSFontTraitMask = []
        // Header cells are bold by position.
        if level.bold || inline.contains(.strong) || (block as? NSTextTableBlock)?.startingRow == 0 { traits.insert(.boldFontMask) }
        if level.italic || inline.contains(.emphasis) { traits.insert(.italicFontMask) }
        return font(size: level.size, traits: traits)
    }

    /// Derives a run's font and decorations from its meaning.
    func apply(to attributes: inout [NSAttributedString.Key: Any]) {
        let inline = MarkdownInlineStyle(attributes)
        attributes[.font] = font(for: attributes)
        let strike = inline.contains(.strikethrough)
        attributes[.strikethroughStyle] = strike ? NSUnderlineStyle.single.rawValue : nil
        attributes[.strikethroughColor] = strike ? theme.strikethroughColor : nil
        // Code paints its own background, so it wins over a highlight.
        attributes[.backgroundColor] = inline.contains(.code) ? codeFill
            : inline.contains(.highlight) ? theme.highlightColor : nil
        let heading = attributes[.markdownHeading] as? Int
        attributes[.underlineStyle] = heading.map { manuscript.level($0).underline } == true ? NSUnderlineStyle.single.rawValue : nil
        if let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle {
            attributes[.paragraphStyle] = spaced(paragraph, heading: heading, isReference: attributes[.manuscriptReference] != nil)
        }
    }

    /// The color a run's role is drawn in: wiki links and missing figures in the
    /// link color, quotes muted, the rest body text. Files store no display
    /// colors, so reopening and theme changes both go through here.
    func color(for attributes: [NSAttributedString.Key: Any]) -> NSColor {
        let span = attributes[.markdownSpan] as? String ?? ""
        if span.hasPrefix("wiki:") || span.hasPrefix("image:") { return theme.link }
        let blocks = (attributes[.paragraphStyle] as? NSParagraphStyle)?.textBlocks ?? []
        return blocks.contains { $0 is MarkdownQuoteBlock } ? theme.mutedText : theme.bodyText
    }

    func recolor(_ text: NSMutableAttributedString, in range: NSRange) {
        text.enumerateAttributes(in: range) { attributes, subrange, _ in
            text.addAttribute(.foregroundColor, value: color(for: attributes), range: subrange)
            if attributes[.strikethroughColor] != nil { text.addAttribute(.strikethroughColor, value: theme.strikethroughColor, range: subrange) }
        }
    }

    func restyle(_ text: NSMutableAttributedString, in range: NSRange) {
        text.enumerateAttributes(in: range) { attributes, subrange, _ in
            var updated = attributes
            apply(to: &updated)
            text.setAttributes(updated, range: subrange)
        }
    }

    // MARK: Blocks

    func headingParagraphStyle(_ level: Int, from base: NSParagraphStyle) -> NSParagraphStyle {
        let style = base.mutableCopy() as! NSMutableParagraphStyle
        style.headerLevel = level
        return spaced(style, heading: level == 0 ? nil : level)
    }

    /// Indents and marker tabs for a paragraph nested `depth` lists deep.
    func listParagraphStyle(_ lists: [NSTextList], from base: NSParagraphStyle) -> NSParagraphStyle {
        let style = base.mutableCopy() as! NSMutableParagraphStyle
        let indent = CGFloat(lists.count) * 24
        style.textLists = lists
        style.headIndent = indent
        style.firstLineHeadIndent = indent - 24
        style.tabStops = [NSTextTab(textAlignment: .right, location: indent - 6), NSTextTab(textAlignment: .left, location: indent)]
        return spaced(style, heading: nil)
    }

    func quoteBlock() -> MarkdownQuoteBlock {
        let block = MarkdownQuoteBlock()
        block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
        block.setBorderColor(theme.mutedText.withAlphaComponent(0.5), for: .minX)
        block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(4, type: .absoluteValueType, for: .margin, edge: .minY)
        return block
    }

    func codeBlock(language: String) -> MarkdownCodeBlock {
        let block = MarkdownCodeBlock()
        block.language = language
        block.backgroundColor = codeFill
        block.setWidth(10, type: .absoluteValueType, for: .padding)
        block.setWidth(4, type: .absoluteValueType, for: .margin, edge: .minY)
        block.setWidth(4, type: .absoluteValueType, for: .margin, edge: .maxY)
        return block
    }

    /// A rule is one non-breaking space in a bordered block.
    func ruleBlock() -> MarkdownRuleBlock {
        let block = MarkdownRuleBlock()
        block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
        block.setBorderColor(theme.mutedText.withAlphaComponent(0.4), for: .maxY)
        block.setWidth(6, type: .absoluteValueType, for: .margin, edge: .minY)
        return block
    }

    /// A table spanning the text width, its columns sharing it evenly.
    func table(alignments: [PresentationIntent.TableColumn.Alignment]) -> MarkdownTable {
        let table = MarkdownTable()
        table.numberOfColumns = alignments.count
        table.alignments = alignments
        table.layoutAlgorithm = .fixed
        table.setValue(100, type: .percentageValueType, for: .width)
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        return table
    }

    func cellBlock(_ table: MarkdownTable, row: Int, column: Int) -> NSTextTableBlock {
        let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
        block.setValue(100 / CGFloat(max(1, table.numberOfColumns)), type: .percentageValueType, for: .width)
        block.setWidth(1, type: .absoluteValueType, for: .border)
        block.setBorderColor(theme.mutedText.withAlphaComponent(0.35))
        block.setWidth(6, type: .absoluteValueType, for: .padding)
        if row == 0 { block.backgroundColor = theme.mutedText.withAlphaComponent(0.08) }
        return block
    }
}
