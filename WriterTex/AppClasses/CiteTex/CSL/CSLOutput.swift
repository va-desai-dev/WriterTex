//
//  CSLOutput.swift
//  WriterTex
//
//  What rendering produces before it's flattened: a tree of text with
//  formatting and quotes still structural, so text-case and quote nesting can
//  be applied correctly. Flattening joins it into runs and tidies the
//  punctuation where affixes and delimiters meet (no ".." or ",.").
//

import Foundation

/// Character formatting a style can ask for.
nonisolated struct CSLFormat: OptionSet, Hashable, Sendable {
    let rawValue: UInt8
    init(rawValue: UInt8) { self.rawValue = rawValue }

    static let italic = CSLFormat(rawValue: 1 << 0)
    static let bold = CSLFormat(rawValue: 1 << 1)
    static let smallCaps = CSLFormat(rawValue: 1 << 2)
    static let underline = CSLFormat(rawValue: 1 << 3)
    static let superscript = CSLFormat(rawValue: 1 << 4)
    static let `subscript` = CSLFormat(rawValue: 1 << 5)
}

/// A stretch of formatted citation or bibliography text.
nonisolated struct CSLRun: Equatable, Sendable {
    var text: String
    var format: CSLFormat

    init(_ text: String, _ format: CSLFormat = []) {
        self.text = text
        self.format = format
    }
}

nonisolated extension [CSLRun] {
    /// The text without formatting.
    var plainText: String { map(\.text).joined() }
}

/// Formatting attributes of one element: what it turns on and what an
/// explicit "normal" turns off.
nonisolated struct CSLStyling: Equatable, Sendable {
    var on: CSLFormat = []
    var off: CSLFormat = []

    init(_ node: CSLNode) {
        func apply(_ attribute: String, on: [String: CSLFormat], off: [String: CSLFormat]) {
            guard let value = node[attribute] else { return }
            if let format = on[value] { self.on.insert(format) }
            if let format = off[value] { self.off.formUnion(format) }
        }
        apply("font-style", on: ["italic": .italic, "oblique": .italic], off: ["normal": .italic])
        apply("font-weight", on: ["bold": .bold], off: ["normal": .bold, "light": .bold])
        apply("font-variant", on: ["small-caps": .smallCaps], off: ["normal": .smallCaps])
        apply("text-decoration", on: ["underline": .underline], off: ["none": .underline])
        apply("vertical-align", on: ["sup": .superscript, "sub": .subscript],
              off: ["baseline": [.superscript, .subscript]])
    }

    init(on: CSLFormat) { self.on = on }

    var isEmpty: Bool { on.isEmpty && off.isEmpty }
}

nonisolated indirect enum CSLOut: Sendable {
    case text(String)
    case group([CSLOut])
    case styled(CSLStyling, CSLOut)
    case quoted(CSLOut)

    static let empty = CSLOut.group([])

    var isEmpty: Bool {
        switch self {
        case .text(let text): text.isEmpty
        case .group(let parts): parts.allSatisfy(\.isEmpty)
        case .styled(_, let inner), .quoted(let inner): inner.isEmpty
        }
    }

    /// The text alone, for sorting and comparing renderings.
    var plain: String {
        switch self {
        case .text(let text): text
        case .group(let parts): parts.map(\.plain).joined()
        case .styled(_, let inner), .quoted(let inner): inner.plain
        }
    }

    static func joined(_ parts: [CSLOut], delimiter: String?) -> CSLOut {
        let parts = parts.filter { !$0.isEmpty }
        guard let delimiter, !delimiter.isEmpty, parts.count > 1 else { return parts.count == 1 ? parts[0] : .group(parts) }
        var joined: [CSLOut] = []
        for (index, part) in parts.enumerated() {
            if index > 0 { joined.append(.text(delimiter)) }
            joined.append(part)
        }
        return .group(joined)
    }

    // MARK: Leaf transforms

    private var leaves: [String] {
        switch self {
        case .text(let text): [text]
        case .group(let parts): parts.flatMap(\.leaves)
        case .styled(_, let inner), .quoted(let inner): inner.leaves
        }
    }

    private func replacingLeaves(_ iterator: inout IndexingIterator<[String]>) -> CSLOut {
        switch self {
        case .text: .text(iterator.next() ?? "")
        case .group(let parts): .group(parts.map { $0.replacingLeaves(&iterator) })
        case .styled(let styling, let inner): .styled(styling, inner.replacingLeaves(&iterator))
        case .quoted(let inner): .quoted(inner.replacingLeaves(&iterator))
        }
    }

    func mapLeaves(_ transform: ([String]) -> [String]) -> CSLOut {
        var iterator = transform(leaves).makeIterator()
        return replacingLeaves(&iterator)
    }

    func strippingPeriods() -> CSLOut { mapLeaves { $0.map { $0.replacingOccurrences(of: ".", with: "") } } }

    func textCase(_ mode: String, english: Bool) -> CSLOut {
        mapLeaves { CSLTextCase.apply(mode, to: $0, english: english) }
    }

    // MARK: Flattening

    func runs(_ locale: CSLLocale) -> [CSLRun] {
        var builder = CSLRunBuilder(locale: locale)
        builder.add(self, format: [], quoteDepth: 0)
        return builder.finished()
    }
}

nonisolated struct CSLRunBuilder {
    let locale: CSLLocale
    private(set) var runs: [CSLRun] = []
    private let closers: [String]

    init(locale: CSLLocale) {
        self.locale = locale
        closers = [locale.term("close-quote") ?? "”", locale.term("close-inner-quote") ?? "’"].filter { !$0.isEmpty }
    }

    mutating func add(_ out: CSLOut, format: CSLFormat, quoteDepth: Int) {
        switch out {
        case .text(let text):
            append(text, format)
        case .group(let parts):
            for part in parts { add(part, format: format, quoteDepth: quoteDepth) }
        case .styled(let styling, let inner):
            add(inner, format: format.subtracting(styling.off).union(styling.on), quoteDepth: quoteDepth)
        case .quoted(let inner):
            guard !inner.isEmpty else { return }
            let outer = quoteDepth % 2 == 0
            append(locale.term(outer ? "open-quote" : "open-inner-quote") ?? (outer ? "“" : "‘"), format)
            add(inner, format: format, quoteDepth: quoteDepth + 1)
            append(locale.term(outer ? "close-quote" : "close-inner-quote") ?? (outer ? "”" : "’"), format)
        }
    }

    private static let punctuation: Set<Character> = [".", ",", ";", ":", "!", "?"]

    private var lastCharacter: Character? { runs.last { !$0.text.isEmpty }?.text.last }

    private mutating func dropLastCharacter() {
        guard let index = runs.lastIndex(where: { !$0.text.isEmpty }) else { return }
        runs[index].text.removeLast()
    }

    mutating func append(_ string: String, _ format: CSLFormat) {
        var text = Substring(string)
        guard !text.isEmpty else { return }
        if let first = text.first, Self.punctuation.contains(first) {
            if locale.punctuationInQuote, first == "." || first == ",", movesInsideQuote(first) {
                text.removeFirst()
            } else if let last = lastCharacter, Self.punctuation.contains(last) {
                if last == first || ("!?".contains(last) && first == ".") || (",;:".contains(last) && ",;:".contains(first)) {
                    text.removeFirst()
                } else if ",;:".contains(last), first == "." {
                    dropLastCharacter()
                }
            }
        }
        if text.first == " ", lastCharacter == " " || runs.allSatisfy({ $0.text.isEmpty }) {
            text = text.drop { $0 == " " }
        }
        guard !text.isEmpty else { return }
        if let last = runs.last, last.format == format {
            runs[runs.count - 1].text += text
        } else {
            runs.append(CSLRun(String(text), format))
        }
    }

    /// American punctuation: a period or comma after a closing quote moves
    /// inside it ("Title.” rather than “Title”.). Returns false when there's
    /// no closing quote to move inside.
    private mutating func movesInsideQuote(_ mark: Character) -> Bool {
        guard let index = runs.lastIndex(where: { !$0.text.isEmpty }) else { return false }
        var text = runs[index].text
        var trailing = ""
        while let closer = closers.first(where: { text.hasSuffix($0) }) {
            trailing = closer + trailing
            text.removeLast(closer.count)
        }
        guard !trailing.isEmpty else { return false }
        if let before = text.last, Self.punctuation.contains(before), before == mark || ".!?".contains(before) {
            return true
        }
        runs[index].text = text + String(mark) + trailing
        return true
    }

    func finished() -> [CSLRun] {
        var runs = self.runs.filter { !$0.text.isEmpty }
        if let last = runs.indices.last {
            while runs[last].text.last?.isWhitespace == true { runs[last].text.removeLast() }
        }
        return runs.filter { !$0.text.isEmpty }
    }
}

/// CSL's text-case transforms.
nonisolated enum CSLTextCase {
    static let stopWords: Set<String> = ["a", "an", "and", "as", "at", "but", "by", "down", "for", "from", "in",
                                         "into", "nor", "of", "on", "onto", "or", "over", "so", "the", "till",
                                         "to", "up", "via", "with", "yet"]

    static func apply(_ mode: String, to leaves: [String], english: Bool) -> [String] {
        switch mode {
        case "lowercase": return leaves.map { $0.lowercased() }
        case "uppercase": return leaves.map { $0.uppercased() }
        case "capitalize-first": return capitalize(leaves, allWords: false)
        case "capitalize-all": return capitalize(leaves, allWords: true)
        case "sentence":
            let joined = leaves.joined()
            return capitalize(joined == joined.uppercased() ? leaves.map { $0.lowercased() } : leaves, allWords: false)
        case "title":
            guard english else { return leaves }
            let joined = leaves.joined()
            return title(joined == joined.uppercased() ? leaves.map { $0.lowercased() } : leaves)
        default: return leaves
        }
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "'" || character == "’"
    }

    /// Words across all leaves, as (leaf, start, end) offsets in each leaf's
    /// Character array, with the non-space character before each word.
    private static func words(_ leaves: [[Character]]) -> [(leaf: Int, range: Range<Int>, before: Character?)] {
        var result: [(Int, Range<Int>, Character?)] = []
        var previous: Character?
        for (leafIndex, characters) in leaves.enumerated() {
            var index = 0
            while index < characters.count {
                if isWordCharacter(characters[index]) {
                    let start = index
                    while index < characters.count, isWordCharacter(characters[index]) { index += 1 }
                    result.append((leafIndex, start..<index, previous))
                    previous = characters[index - 1]
                } else {
                    if !characters[index].isWhitespace { previous = characters[index] }
                    index += 1
                }
            }
        }
        return result
    }

    private static func capitalize(_ leaves: [String], allWords: Bool) -> [String] {
        var characters = leaves.map { $0.map(String.init) }
        for (number, word) in words(leaves.map(Array.init)).enumerated() {
            guard allWords || number == 0 else { break }
            let first = characters[word.leaf][word.range.lowerBound]
            characters[word.leaf][word.range.lowerBound] = first.uppercased()
        }
        return characters.map { $0.joined() }
    }

    private static func title(_ leaves: [String]) -> [String] {
        let arrays = leaves.map(Array.init)
        var characters = arrays.map { $0.map(String.init) }
        let found = words(arrays)
        for (number, word) in found.enumerated() {
            let text = String(arrays[word.leaf][word.range])
            let lower = text.lowercased()
            let opensPhrase = number == 0 || word.before.map { ":?!".contains($0) } == true
            if stopWords.contains(lower), !opensPhrase, number != found.count - 1 {
                for (offset, character) in lower.enumerated() { characters[word.leaf][word.range.lowerBound + offset] = String(character) }
            } else if text == lower {
                characters[word.leaf][word.range.lowerBound] = String(arrays[word.leaf][word.range.lowerBound]).uppercased()
            }
        }
        return characters.map { $0.joined() }
    }
}
