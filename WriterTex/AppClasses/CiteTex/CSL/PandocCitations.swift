//
//  PandocCitations.swift
//  WriterTex
//
//  Pandoc's citation syntax, the one WriterTex and TypeNBash documents use:
//
//      [@smith2020]                    (Smith, 2020)
//      [see @smith2020, pp. 33-35; also @doe99, chap. 1]
//      [-@smith2020]                   (2020)
//      @smith2020 says                 Smith (2020) says
//      @smith2020 [p. 33] says         Smith (2020, p. 33) says
//

import Foundation

nonisolated enum PandocCitations {
    struct Match: Equatable, Sendable {
        /// UTF-16 range of the whole citation in the searched text.
        var range: NSRange
        var citation: CSLCitation
    }

    private static let key = #"[\p{L}\p{N}_](?:[\p{L}\p{N}_]|[:.#$%&+?<>~/\-](?=[\p{L}\p{N}_]))*"#
    private static let bracketed = try! NSRegularExpression(pattern: #"(?<!\\)\[([^\[\]\n]*@[^\[\]\n]*)\](?![\[(])"#)
    private static let narrative = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_\\@\]/:.=])@(\{[^{}\n]+\}|"# + key + #")(?:[ ]?\[([^\[\]\n@]*)\](?![\[(]))?"#)
    private static let cite = try! NSRegularExpression(pattern: #"^(.*?)(-?)@(\{[^{}]+\}|"# + key + #")(.*)$"#,
                                                       options: .dotMatchesLineSeparators)

    /// Every citation in `text`, in order. `isKey` decides whether a bare
    /// `@word` is a narrative citation, so handles and decorators stay text.
    static func find(in text: String, isKey: (String) -> Bool = { _ in true }) -> [Match] {
        let source = text as NSString
        let whole = NSRange(location: 0, length: source.length)
        var matches: [Match] = bracketed.matches(in: text, range: whole).compactMap { match in
            guard let citation = parse(cluster: source.substring(with: match.range(at: 1))) else { return nil }
            return Match(range: match.range, citation: citation)
        }
        let taken = matches.map(\.range)
        for match in narrative.matches(in: text, range: whole) {
            guard !taken.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            let id = unbrace(source.substring(with: match.range(at: 1)))
            guard isKey(id) else { continue }
            var cite = CSLCite(id: id)
            if match.range(at: 2).location != NSNotFound {
                apply(source.substring(with: match.range(at: 2)), to: &cite, afterComma: false)
            }
            matches.append(Match(range: match.range, citation: CSLCitation(cites: [cite], narrative: true)))
        }
        return matches.sorted { $0.range.location < $1.range.location }
    }

    /// The inside of a bracketed citation, without its brackets.
    static func parse(cluster: String) -> CSLCitation? {
        var cites: [CSLCite] = []
        for piece in cluster.split(separator: ";", omittingEmptySubsequences: true) {
            let text = String(piece)
            let source = text as NSString
            guard let match = cite.firstMatch(in: text, range: NSRange(location: 0, length: source.length)) else { return nil }
            // "user@example.com" isn't a citation: the @ must start a word.
            let prefix = source.substring(with: match.range(at: 1))
            if let last = prefix.last, last.isLetter || last.isNumber { return nil }
            var cite = CSLCite(id: unbrace(source.substring(with: match.range(at: 3))),
                               prefix: prefix.trimmingCharacters(in: .whitespaces),
                               suppressAuthor: match.range(at: 2).length > 0)
            let rest = source.substring(with: match.range(at: 4))
            if rest.hasPrefix(",") {
                apply(String(rest.dropFirst()), to: &cite, afterComma: true)
            } else {
                cite.suffix = rest.trimmingCharacters(in: .whitespaces)
            }
            cites.append(cite)
        }
        return cites.isEmpty ? nil : CSLCitation(cites: cites)
    }

    private static func unbrace(_ key: String) -> String {
        key.hasPrefix("{") && key.hasSuffix("}") ? String(key.dropFirst().dropLast()) : key
    }

    /// Locator labels Pandoc recognizes, longest spelling first within each.
    static let labels: [(spelling: String, term: String)] = {
        let table: [String: [String]] = [
            "book": ["books", "book", "bks.", "bk."], "chapter": ["chapters", "chapter", "chaps.", "chap.", "ch."],
            "column": ["columns", "column", "cols.", "col."], "figure": ["figures", "figure", "figs.", "fig."],
            "folio": ["folios", "folio", "fols.", "fol."], "number": ["numbers", "number", "nos.", "no."],
            "line": ["lines", "line", "ll.", "l."], "note": ["notes", "note", "nn.", "n."],
            "opus": ["opera", "opus", "opp.", "op."], "page": ["pages", "page", "pp.", "p."],
            "paragraph": ["paragraphs", "paragraph", "paras.", "para.", "¶¶", "¶"],
            "part": ["parts", "part", "pts.", "pt."], "section": ["sections", "section", "secs.", "sec.", "§§", "§"],
            "sub verbo": ["sub verbis", "sub verbo", "s.vv.", "s.v."], "verse": ["verses", "verse", "vv.", "v."],
            "volume": ["volumes", "volume", "vols.", "vol."],
        ]
        return table.flatMap { term, spellings in spellings.map { ($0, term) } }.sorted { $0.spelling.count > $1.spelling.count }
    }()

    private static let locatorValue = try! NSRegularExpression(
        pattern: #"^(?:[\p{L}]*\d[\p{L}\p{N}]*|[ivxlcdmIVXLCDM]+)(?:\s*[-–—,&]\s*(?:[\p{L}]*\d[\p{L}\p{N}]*|[ivxlcdmIVXLCDM]+))*"#)

    /// Reads "p. 33 and passim" into a locator and suffix. Without a label or
    /// a leading number, the whole text is a suffix.
    static func apply(_ text: String, to cite: inout CSLCite, afterComma: Bool) {
        var rest = Substring(text).drop { $0 == " " }
        if rest.hasPrefix("{"), let close = rest.firstIndex(of: "}") {
            var braced = rest[rest.index(after: rest.startIndex)..<close]
            cite.label = takeLabel(&braced) ?? "page"
            cite.locator = braced.trimmingCharacters(in: .whitespaces)
            cite.suffix = String(rest[rest.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            return
        }
        let original = rest
        let label = takeLabel(&rest)
        rest = rest.drop { $0 == " " }
        let value = String(rest)
        if let match = locatorValue.firstMatch(in: value, range: NSRange(location: 0, length: (value as NSString).length)),
           label != nil || value.first?.isNumber == true {
            // A comma followed by words ends the locator: "33, and passim".
            var locator = (value as NSString).substring(with: match.range)
            var suffix = (value as NSString).substring(from: NSMaxRange(match.range))
            while locator.hasSuffix(",") || locator.hasSuffix(" ") {
                suffix = String(locator.removeLast()) + suffix
            }
            cite.label = label ?? "page"
            cite.locator = locator
            cite.suffix = suffix.trimmingCharacters(in: .whitespaces)
        } else {
            cite.suffix = ((afterComma ? ", " : "") + original).trimmingCharacters(in: .whitespaces)
        }
    }

    private static func takeLabel(_ text: inout Substring) -> String? {
        for (spelling, term) in labels where text.lowercased().hasPrefix(spelling) {
            let after = text.dropFirst(spelling.count)
            // A word label needs a space after it: "page 3", not "pages3" or "pageant".
            if spelling.last?.isLetter == true, after.first != " " { continue }
            text = after
            return term
        }
        return nil
    }
}
