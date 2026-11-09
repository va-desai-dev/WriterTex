import AppKit
import CoreText

extension NSAttributedString.Key {
    /// Character formats a citation style asks for that Markdown has no syntax
    /// for (small caps, superscript, subscript, underline), as a `CSLFormat`
    /// raw value. Only exports carry it.
    static let manuscriptFormat = NSAttributedString.Key("WriterTex.manuscriptFormat")
    /// Marks a reference-list paragraph, which Word gets as its Bibliography style.
    static let manuscriptReference = NSAttributedString.Key("WriterTex.manuscriptReference")
}

/// What an export needs to format citations: the style and the project's records.
struct ManuscriptCitationSource {
    let style: CSLStyle
    let items: [Citation]
    /// The heading over the reference list ("References").
    let referencesTitle: String
}

/// Turns the Pandoc citations in an exported manuscript into formatted
/// citations and adds the reference list. Runs on the semantic rich text the
/// exporters share, so PDF and Word come out the same.
@MainActor enum ManuscriptCitations {
    private static let linkScheme = "writertex-citation"
    private static let markerPattern = try! NSRegularExpression(pattern: #"\[[^\]\n]*@[^\]\n]+\]"#)

    static func isLink(_ value: Any?) -> Bool {
        let url = value as? URL ?? (value as? String).flatMap(URL.init(string:))
        return url?.scheme == linkScheme
    }

    /// Native links provide display color and AppKit interaction. Only the edited
    /// paragraphs are revisited; no parsing or decoration happens during scrolling.
    static func updateLinks(in text: NSMutableAttributedString, editedRange: NSRange) {
        guard text.length > 0, editedRange.location <= text.length else { return }
        let string = text.string as NSString
        let start = max(0, editedRange.location - 1)
        let end = min(text.length, NSMaxRange(editedRange) + 1)
        let range = string.paragraphRange(for: NSRange(location: start, length: end - start))
        var current: [(NSRange, URL)] = []
        text.enumerateAttribute(.link, in: range) { value, run, _ in
            if isLink(value), let url = value as? URL ?? (value as? String).flatMap(URL.init(string:)) { current.append((run, url)) }
        }
        var wanted: [(NSRange, URL)] = []
        if string.range(of: "@", range: range).location != NSNotFound {
            for match in markerPattern.matches(in: text.string, range: range) where isProse(text, match.range) {
                var url = URLComponents()
                url.scheme = linkScheme
                url.path = string.substring(with: match.range)
                if let url = url.url { wanted.append((match.range, url)) }
            }
        }
        // Unchanged links stay as they are; rewriting them on every keystroke
        // would invalidate the paragraph's layout each time.
        guard !current.elementsEqual(wanted, by: { $0.0 == $1.0 && $0.1 == $1.1 }) else { return }
        for (run, _) in current { text.removeAttribute(.link, range: run) }
        for (match, url) in wanted { text.addAttribute(.link, value: url, range: match) }
    }

    static func linkRange(in text: NSAttributedString, at index: Int) -> NSRange? {
        guard index >= 0, index < text.length else { return nil }
        var range = NSRange()
        let value = text.attribute(.link, at: index, longestEffectiveRange: &range,
                                   in: NSRange(location: 0, length: text.length))
        return isLink(value) ? range : nil
    }

    /// Rewrites `text` in place and returns the cited keys the library lacks.
    static func resolve(in text: NSMutableAttributedString, source: ManuscriptCitationSource, style: MarkdownStyleSheet) -> [String] {
        let keys = Set(source.items.map(\.id))
        let matches = PandocCitations.find(in: text.string, isKey: keys.contains).filter { isProse(text, $0.range) }
        guard !matches.isEmpty else { return [] }
        let result = CSLProcessor(style: source.style, locale: .englishUS, items: source.items)
            .process(matches.map(\.citation))

        // Bibliography first: it goes at the end, so citation offsets stay valid.
        if let bibliography = result.bibliography, !bibliography.entries.isEmpty {
            appendBibliography(bibliography, title: source.referencesTitle, to: text, style: style)
        }
        for (match, runs) in zip(matches, result.citations).reversed() {
            var base = text.attributes(at: match.range.location, effectiveRange: nil)
            base[.link] = nil
            base[.markdownSpan] = nil
            text.replaceCharacters(in: match.range, with: attributed(runs, base: base, style: style))
        }
        return result.missing
    }

    /// Citations in code, links and figures are left as typed.
    private static func isProse(_ text: NSAttributedString, _ range: NSRange) -> Bool {
        var prose = true
        text.enumerateAttributes(in: range) { attributes, _, stop in
            let code = MarkdownInlineStyle(attributes).contains(.code)
                || (attributes[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.contains { $0 is MarkdownCodeBlock } == true
            let externalLink = attributes[.link] != nil && !isLink(attributes[.link])
            if code || attributes[.markdownSpan] != nil || externalLink || attributes[.attachment] != nil {
                prose = false
                stop.pointee = true
            }
        }
        return prose
    }

    /// Runs styled like the text around them. Italic and bold become the
    /// editor's own emphasis and strong; the rest ride on `.manuscriptFormat`.
    /// Capitalization leaves citations alone, as the style already cased them.
    private static func attributed(_ runs: [CSLRun], base: [NSAttributedString.Key: Any], style: MarkdownStyleSheet) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for run in runs {
            var attributes = base
            var inline = MarkdownInlineStyle(base).subtracting(.code)
            if run.format.contains(.italic) { inline.insert(.emphasis) }
            if run.format.contains(.bold) { inline.insert(.strong) }
            inline.store(in: &attributes)
            let extra = run.format.subtracting([.italic, .bold])
            attributes[.manuscriptFormat] = extra.isEmpty ? nil : extra.rawValue
            attributes[.markdownSpan] = "citation"
            style.apply(to: &attributes)
            applyFormat(to: &attributes)
            output.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return output
    }

    /// How `.manuscriptFormat` looks on the page (Word reads the attribute itself).
    static func applyFormat(to attributes: inout [NSAttributedString.Key: Any]) {
        guard let raw = attributes[.manuscriptFormat] as? UInt8, var font = attributes[.font] as? NSFont else { return }
        let format = CSLFormat(rawValue: raw)
        if format.contains(.smallCaps) {
            let smallCaps: [NSFontDescriptor.FeatureKey: Int] = [.typeIdentifier: kLowerCaseType, .selectorIdentifier: kLowerCaseSmallCapsSelector]
            font = NSFont(descriptor: font.fontDescriptor.addingAttributes([.featureSettings: [smallCaps]]), size: font.pointSize) ?? font
        }
        if !format.isDisjoint(with: [.superscript, .subscript]) {
            let size = font.pointSize
            font = NSFont(descriptor: font.fontDescriptor, size: size * 0.7) ?? font
            attributes[.baselineOffset] = format.contains(.superscript) ? size * 0.35 : -size * 0.15
        }
        if format.contains(.underline) { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        attributes[.font] = font
    }

    /// Words that mean "the reference list goes here" when they head an empty
    /// last section.
    private static let referenceHeadings: Set<String> = ["references", "bibliography", "works cited", "reference list", "sources"]

    /// The reference list under the document's own empty last heading when it
    /// names one, or under a new level-1 heading.
    private static func appendBibliography(_ bibliography: CSLBibliography, title: String, to text: NSMutableAttributedString, style: MarkdownStyleSheet) {
        let string = text.string as NSString
        let paragraphs = MarkdownRichText.paragraphs(in: text)
        let lastContent = paragraphs.last { string.substring(with: $0).trimmingCharacters(in: .whitespacesAndNewlines) != "" }
        let headingText = lastContent.map { string.substring(with: $0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let ownHeading = lastContent.flatMap { text.attribute(.markdownHeading, at: $0.location, effectiveRange: nil) as? Int } != nil
            && (headingText == title.lowercased() || referenceHeadings.contains(headingText ?? ""))

        if ownHeading, let heading = lastContent {
            // Drop the blank paragraphs after it.
            text.deleteCharacters(in: NSRange(location: NSMaxRange(heading), length: text.length - NSMaxRange(heading)))
            if !text.string.hasSuffix("\n") { text.append(NSAttributedString(string: "\n", attributes: text.attributes(at: text.length - 1, effectiveRange: nil))) }
        } else {
            if text.length > 0, !text.string.hasSuffix("\n") {
                text.append(NSAttributedString(string: "\n", attributes: text.attributes(at: text.length - 1, effectiveRange: nil)))
            }
            var attributes = style.bodyAttributes
            attributes[.paragraphStyle] = style.headingParagraphStyle(1, from: style.bodyParagraphStyle)
            attributes[.markdownHeading] = 1
            style.apply(to: &attributes)
            text.append(NSAttributedString(string: title + "\n", attributes: attributes))
        }

        let font = style.baseFont(size: style.manuscript.body.size)
        let paragraph = style.bodyParagraphStyle.mutableCopy() as! NSMutableParagraphStyle
        // References sit flush left whatever the body's alignment and indent.
        paragraph.alignment = .natural
        paragraph.firstLineHeadIndent = 0
        if bibliography.secondFieldAlign != nil {
            // "[12]" set apart: the body starts at a tab past the widest number.
            let widest = bibliography.entries.compactMap(\.margin).map { runs in
                (runs.plainText as NSString).size(withAttributes: [.font: font]).width
            }.max() ?? 0
            let indent = ceil(widest) + font.pointSize * 0.75
            paragraph.headIndent = indent
            paragraph.firstLineHeadIndent = 0
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        } else if bibliography.hangingIndent {
            paragraph.headIndent = style.manuscript.referencesHanging
        }
        var base = style.bodyAttributes
        base[.paragraphStyle] = paragraph
        base[.manuscriptReference] = true
        for (index, entry) in bibliography.entries.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "\n", attributes: base)) }
            if let margin = entry.margin {
                text.append(attributed(margin, base: base, style: style))
                text.append(NSAttributedString(string: "\t", attributes: base))
            }
            text.append(attributed(entry.runs, base: base, style: style))
        }
    }
}
