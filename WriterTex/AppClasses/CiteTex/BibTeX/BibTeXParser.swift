//
//  BibTeXParser.swift
//  WriterTex
//
//  BibTeX / BibLaTeX → CSL-JSON records. Carved from Writerly; the one addition
//  is that each entry remembers where it sits in the source (character range and
//  line), so BibDocument can edit a .bib in place instead of regenerating it.
//
//  The awkward part is not the grammar — it is LaTeX. A .bib file in the wild
//  contains brace-protected capitals, accent commands, tie characters and
//  em-dash ligatures, none of which belong in a CSL record. Decoding those is
//  most of this file.
//

import Foundation

nonisolated enum BibTeXParser {

    struct Entry: Sendable {
        var type: String
        var key: String
        var fields: [String: String]
        /// `fields`' names in the order they are written, for editing an entry
        /// without reshuffling it.
        var fieldOrder: [String] = []
        /// Offsets in `Array(source)` — Characters, not UTF-16 — from the `@`
        /// through the closing delimiter.
        var range: Range<Int>
        /// 1-based line of the `@`.
        var line: Int
    }

    // MARK: - Public

    static func parse(_ source: String) -> [Citation] {
        entries(source).map { citation(from: $0) }
    }

    // MARK: - Entry scanning

    static func entries(_ source: String) -> [Entry] {
        var scanner = Scanner(source)
        var results: [Entry] = []
        var macros: [String: String] = [:]

        while let raw = scanner.nextEntry() {
            let type = raw.type.lowercased()
            switch type {
            case "string":
                // @string{ key = "value" } defines a macro used by later fields.
                for (name, value) in raw.fields { macros[name] = value }
            case "comment", "preamble":
                continue
            default:
                var entry = raw
                entry.fields = entry.fields.mapValues { expand($0, macros: macros) }
                results.append(entry)
            }
        }
        return results
    }

    private static func expand(_ value: String, macros: [String: String]) -> String {
        guard let replacement = macros[value.lowercased()] else { return value }
        return replacement
    }

    // MARK: - Mapping to CSL

    /// Every entry type the parser maps, for offering a choice of type.
    static let entryTypes: [String] = typeMap.keys.sorted()

    private static let typeMap: [String: String] = [
        "article": "article-journal",
        "book": "book",
        "booklet": "book",
        "inbook": "chapter",
        "incollection": "chapter",
        "inproceedings": "paper-conference",
        "conference": "paper-conference",
        "proceedings": "book",
        "phdthesis": "thesis",
        "mastersthesis": "thesis",
        "thesis": "thesis",
        "techreport": "report",
        "report": "report",
        "manual": "book",
        "online": "webpage",
        "electronic": "webpage",
        "www": "webpage",
        "patent": "patent",
        "misc": "document",
        "unpublished": "manuscript"
    ]

    static func citation(from entry: Entry) -> Citation {
        let cslType = typeMap[entry.type.lowercased()] ?? "document"
        var fields: [String: JSONValue] = [
            "id": .string(entry.key),
            "type": .string(cslType)
        ]

        func field(_ names: String...) -> String? {
            for name in names {
                if let raw = entry.fields[name], !raw.isEmpty {
                    let decoded = LaTeX.decode(raw)
                    if !decoded.isEmpty { return decoded }
                }
            }
            return nil
        }
        func put(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            fields[key] = .string(value)
        }

        put("title", field("title"))
        put("volume", field("volume"))
        put("edition", field("edition"))
        put("abstract", field("abstract"))
        put("note", field("note", "annote"))
        put("collection-title", field("series"))
        put("chapter-number", field("chapter"))
        put("publisher-place", field("address", "location"))
        put("ISBN", field("isbn"))
        put("ISSN", field("issn"))
        put("URL", field("url", "howpublished"))

        // A chapter or paper takes its container from booktitle; an article
        // from journal. Getting this wrong is what produces a reference list
        // with the book title missing.
        switch cslType {
        case "chapter", "paper-conference":
            put("container-title", field("booktitle", "journal"))
        default:
            put("container-title", field("journal", "journaltitle", "booktitle"))
        }

        // BibTeX overloads `number`: an issue for articles, a report number
        // otherwise.
        if cslType == "article-journal" {
            put("issue", field("number", "issue"))
        } else {
            put("number", field("number"))
            put("issue", field("issue"))
        }

        // The publisher lives under a different name for theses and reports.
        switch cslType {
        case "thesis":  put("publisher", field("school", "institution", "publisher"))
        case "report":  put("publisher", field("institution", "publisher", "school"))
        default:        put("publisher", field("publisher", "organization", "institution"))
        }

        if let pages = field("pages") {
            // BibTeX writes ranges with a double hyphen.
            put("page", pages.replacingOccurrences(of: "--", with: "-")
                             .replacingOccurrences(of: "–", with: "-"))
        }

        if let doi = field("doi") {
            // Publishers increasingly export the DOI as a full URL; CSL wants
            // the bare identifier.
            var bare = doi
            for prefix in ["https://doi.org/", "http://doi.org/",
                           "https://dx.doi.org/", "http://dx.doi.org/", "doi:"] {
                if bare.lowercased().hasPrefix(prefix) {
                    bare = String(bare.dropFirst(prefix.count))
                    break
                }
            }
            put("DOI", bare)
        }

        if let keywords = field("keywords") {
            let separator: Character = keywords.contains(";") ? ";" : ","
            let terms = keywords.split(separator: separator)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !terms.isEmpty { fields["keyword"] = .string(terms.joined(separator: ", ")) }
        }

        // Name fields are handed over undecoded. The braces in
        // `{World Health Organization}` are what marks it a corporate author
        // rather than a person, and LaTeX decoding strips them — so each name
        // is decoded individually, after the list has been split.
        func rawField(_ name: String) -> String? {
            guard let raw = entry.fields[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { return nil }
            return raw
        }

        if let authors = rawField("author") {
            fields["author"] = .array(Names.parse(authors))
        }
        if let editors = rawField("editor") {
            fields["editor"] = .array(Names.parse(editors))
        }
        if let translators = rawField("translator") {
            fields["translator"] = .array(Names.parse(translators))
        }

        if let issued = date(from: entry) {
            fields["issued"] = issued
        }
        put("number-of-pages", field("pagetotal"))

        CitationNormalizer.repair(&fields)
        return Citation(fields: fields)
    }

    /// Builds a CSL `issued` value from either BibLaTeX's `date` or classic
    /// `year` plus `month`.
    private static func date(from entry: Entry) -> JSONValue? {
        func parts(_ values: [Int]) -> JSONValue {
            .object(["date-parts": .array([.array(values.map { .number(Double($0)) })])])
        }

        if let raw = entry.fields["date"], !raw.isEmpty {
            let numbers = raw.split(whereSeparator: { !$0.isNumber })
                .compactMap { Int($0) }
            if !numbers.isEmpty { return parts(Array(numbers.prefix(3))) }
        }

        guard let yearText = entry.fields["year"],
              let year = Int(yearText.filter(\.isNumber)) else { return nil }

        guard let monthText = entry.fields["month"],
              let month = monthNumber(monthText) else { return parts([year]) }
        return parts([year, month])
    }

    private static func monthNumber(_ text: String) -> Int? {
        let cleaned = LaTeX.decode(text).lowercased().trimmingCharacters(in: .whitespaces)
        if let number = Int(cleaned), (1...12).contains(number) { return number }
        let months = ["jan", "feb", "mar", "apr", "may", "jun",
                      "jul", "aug", "sep", "oct", "nov", "dec"]
        guard let index = months.firstIndex(where: { cleaned.hasPrefix($0) }) else { return nil }
        return index + 1
    }
}

// MARK: - Scanner

nonisolated private struct Scanner {
    private let characters: [Character]
    private var position = 0
    /// Line-counting cursor. Entries arrive in order, so counting only the
    /// stretch since the previous entry keeps this linear overall.
    private var countedTo = 0
    private var lineAtCounted = 1

    init(_ source: String) {
        characters = Array(source)
    }

    /// `isNewline`, not `== "\n"`: a CRLF file's "\r\n" is one Character.
    private mutating func line(at offset: Int) -> Int {
        while countedTo < offset {
            if characters[countedTo].isNewline { lineAtCounted += 1 }
            countedTo += 1
        }
        return lineAtCounted
    }

    mutating func nextEntry() -> BibTeXParser.Entry? {
        // Anything outside an @entry is a comment as far as BibTeX cares.
        while position < characters.count, characters[position] != "@" {
            position += 1
        }
        guard position < characters.count else { return nil }
        let start = position
        position += 1

        var type = ""
        while position < characters.count, characters[position].isLetter {
            type.append(characters[position])
            position += 1
        }
        skipWhitespace()

        guard position < characters.count else { return nil }
        let opener = characters[position]
        guard opener == "{" || opener == "(" else { return nextEntry() }
        let closer: Character = opener == "{" ? "}" : ")"
        position += 1
        skipWhitespace()

        // @string has no citation key, only assignments.
        var key = ""
        if type.lowercased() != "string" {
            while position < characters.count,
                  characters[position] != ",", characters[position] != closer {
                key.append(characters[position])
                position += 1
            }
            if position < characters.count, characters[position] == "," { position += 1 }
        }

        var fields: [String: String] = [:]
        var fieldOrder: [String] = []
        while position < characters.count, characters[position] != closer {
            skipWhitespace()
            guard position < characters.count, characters[position] != closer else { break }

            var name = ""
            while position < characters.count,
                  characters[position] != "=", characters[position] != ",",
                  characters[position] != closer {
                name.append(characters[position])
                position += 1
            }
            guard position < characters.count else { break }

            if characters[position] == "," {
                position += 1
                continue
            }
            if characters[position] == closer { break }
            position += 1                                   // consume '='

            let value = readValue(closer: closer)
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !trimmed.isEmpty {
                if fields[trimmed] == nil { fieldOrder.append(trimmed) }
                fields[trimmed] = value
            }

            skipWhitespace()
            if position < characters.count, characters[position] == "," { position += 1 }
        }
        if position < characters.count { position += 1 }     // consume closer

        return BibTeXParser.Entry(
            type: type,
            key: key.trimmingCharacters(in: .whitespacesAndNewlines),
            fields: fields,
            fieldOrder: fieldOrder,
            range: start..<position,
            line: line(at: start)
        )
    }

    /// Values may be braced, quoted, bare, or several of those joined by `#`.
    private mutating func readValue(closer: Character) -> String {
        var pieces: [String] = []

        while position < characters.count {
            skipWhitespace()
            guard position < characters.count else { break }

            switch characters[position] {
            case "{":
                pieces.append(readBraced())
            case "\"":
                pieces.append(readQuoted())
            default:
                var bare = ""
                while position < characters.count,
                      characters[position] != ",", characters[position] != closer,
                      characters[position] != "#" {
                    bare.append(characters[position])
                    position += 1
                }
                pieces.append(bare.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            skipWhitespace()
            guard position < characters.count, characters[position] == "#" else { break }
            position += 1                                   // concatenation
        }
        return pieces.joined()
    }

    private mutating func readBraced() -> String {
        var depth = 0
        var value = ""
        while position < characters.count {
            let character = characters[position]
            if character == "\\", position + 1 < characters.count {
                value.append(character)
                value.append(characters[position + 1])
                position += 2
                continue
            }
            if character == "{" {
                depth += 1
                position += 1
                if depth == 1 { continue }          // drop the outermost brace
            } else if character == "}" {
                depth -= 1
                position += 1
                if depth == 0 { break }
            } else {
                position += 1
            }
            value.append(character)
        }
        return value
    }

    private mutating func readQuoted() -> String {
        position += 1                                       // opening quote
        var value = ""
        var depth = 0
        while position < characters.count {
            let character = characters[position]
            if character == "\\", position + 1 < characters.count {
                value.append(character)
                value.append(characters[position + 1])
                position += 2
                continue
            }
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
            if character == "\"", depth <= 0 {
                position += 1
                break
            }
            value.append(character)
            position += 1
        }
        return value
    }

    private mutating func skipWhitespace() {
        while position < characters.count, characters[position].isWhitespace {
            position += 1
        }
    }
}

// MARK: - Names

nonisolated private enum Names {
    /// Splits on a brace-level-zero " and ", then reads each name in the four
    /// shapes BibTeX allows.
    static func parse(_ field: String) -> [JSONValue] {
        split(field).compactMap { name in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            // A fully braced name is a corporate author and must not be split.
            if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
                let literal = String(trimmed.dropFirst().dropLast())
                return .object(["literal": .string(LaTeX.decode(literal))])
            }

            let commaParts = splitTopLevel(trimmed, separator: ",")
            switch commaParts.count {
            case 0:
                return nil
            case 1:
                // "Given von Last" — the surname is the last word, unless a
                // lowercase particle marks where it starts.
                let words = trimmed.split(separator: " ").map(String.init)
                guard words.count > 1 else {
                    return .object(["family": .string(LaTeX.decode(trimmed))])
                }
                let particle = words.dropLast().firstIndex { $0.first?.isLowercase == true }
                let splitPoint = particle ?? words.count - 1
                let given = words[..<splitPoint].joined(separator: " ")
                let family = words[splitPoint...].joined(separator: " ")
                return object(given: given, family: family, suffix: nil)
            case 2:
                return object(given: commaParts[1], family: commaParts[0], suffix: nil)
            default:
                // "Last, Jr., First"
                return object(given: commaParts[2], family: commaParts[0], suffix: commaParts[1])
            }
        }
    }

    private static func object(given: String, family: String, suffix: String?) -> JSONValue {
        var fields: [String: JSONValue] = [:]
        let decodedFamily = LaTeX.decode(family).trimmingCharacters(in: .whitespaces)
        let decodedGiven = LaTeX.decode(given).trimmingCharacters(in: .whitespaces)
        if !decodedFamily.isEmpty { fields["family"] = .string(decodedFamily) }
        if !decodedGiven.isEmpty { fields["given"] = .string(decodedGiven) }
        if let suffix {
            let decoded = LaTeX.decode(suffix).trimmingCharacters(in: .whitespaces)
            if !decoded.isEmpty { fields["suffix"] = .string(decoded) }
        }
        return .object(fields)
    }

    private static func split(_ field: String) -> [String] {
        var results: [String] = []
        var current = ""
        var depth = 0
        var index = field.startIndex

        while index < field.endIndex {
            let character = field[index]
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }

            if depth == 0, field[index...].hasPrefix(" and ") {
                results.append(current)
                current = ""
                index = field.index(index, offsetBy: 5)
                continue
            }
            current.append(character)
            index = field.index(after: index)
        }
        results.append(current)
        return results
    }

    private static func splitTopLevel(_ text: String, separator: Character) -> [String] {
        var results: [String] = []
        var current = ""
        var depth = 0
        for character in text {
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
            if character == separator, depth == 0 {
                results.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            current.append(character)
        }
        results.append(current.trimmingCharacters(in: .whitespaces))
        return results.filter { !$0.isEmpty }
    }
}

// MARK: - LaTeX

nonisolated enum LaTeX {

    private static let commands: [String: String] = [
        "\\&": "&", "\\%": "%", "\\$": "$", "\\#": "#", "\\_": "_",
        "\\{": "{", "\\}": "}", "\\textbackslash": "\\",
        "\\ss": "ß", "\\aa": "å", "\\AA": "Å", "\\o": "ø", "\\O": "Ø",
        "\\ae": "æ", "\\AE": "Æ", "\\oe": "œ", "\\OE": "Œ",
        "\\l": "ł", "\\L": "Ł", "\\i": "ı", "\\j": "ȷ",
        "\\ldots": "…", "\\dots": "…", "\\textendash": "–", "\\textemdash": "—",
        "\\textquoteleft": "‘", "\\textquoteright": "’",
        "\\textquotedblleft": "“", "\\textquotedblright": "”",
        "\\textbar": "|", "\\textless": "<", "\\textgreater": ">", "\\textasciitilde": "~",
        "\\textregistered": "®", "\\texttrademark": "™", "\\textcopyright": "©", "\\textdegree": "°"
    ]

    /// Accent command → the combining mark it applies to the next character.
    private static let accents: [Character: String] = [
        "`": "\u{0300}", "'": "\u{0301}", "^": "\u{0302}", "\"": "\u{0308}",
        "~": "\u{0303}", "=": "\u{0304}", ".": "\u{0307}", "u": "\u{0306}",
        "v": "\u{030C}", "H": "\u{030B}", "c": "\u{0327}", "k": "\u{0328}",
        "b": "\u{0331}", "d": "\u{0323}", "r": "\u{030A}"
    ]

    static func decode(_ input: String) -> String {
        var text = input

        // Ligatures first: they are plain character sequences, not commands.
        text = text.replacingOccurrences(of: "---", with: "—")
        text = text.replacingOccurrences(of: "--", with: "–")
        text = text.replacingOccurrences(of: "``", with: "“")
        text = text.replacingOccurrences(of: "''", with: "”")
        text = text.replacingOccurrences(of: "~", with: "\u{00A0}")

        text = decodeAccents(text)

        for (command, replacement) in commands.sorted(by: { $0.key.count > $1.key.count }) {
            text = text.replacingOccurrences(of: command, with: replacement)
        }

        // Whatever braces remain were protecting capitalisation, which Unicode
        // does not need. Drop them and keep the letters.
        text = text.replacingOccurrences(of: "{", with: "")
        text = text.replacingOccurrences(of: "}", with: "")

        // Collapse the whitespace that line-wrapped .bib fields leave behind.
        text = text.replacingOccurrences(of: "\n", with: " ")
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
    }

    /// Handles `\"o`, `\"{o}`, `{\"o}` and `\c{c}` uniformly by emitting the
    /// base character followed by a combining mark, then normalising.
    private static func decodeAccents(_ input: String) -> String {
        var output = ""
        let characters = Array(input)
        var index = 0

        while index < characters.count {
            guard characters[index] == "\\", index + 1 < characters.count else {
                output.append(characters[index])
                index += 1
                continue
            }

            let command = characters[index + 1]
            guard let mark = accents[command] else {
                output.append(characters[index])
                index += 1
                continue
            }

            // A letter command such as \v or \c must be followed by a brace or
            // space, or it is the start of a longer command like \verb.
            var cursor = index + 2
            if command.isLetter {
                guard cursor < characters.count,
                      characters[cursor] == "{" || characters[cursor] == " " else {
                    output.append(characters[index])
                    index += 1
                    continue
                }
            }
            while cursor < characters.count, characters[cursor] == " " { cursor += 1 }
            guard cursor < characters.count else { break }

            var base = ""
            if characters[cursor] == "{" {
                cursor += 1
                while cursor < characters.count, characters[cursor] != "}" {
                    base.append(characters[cursor])
                    cursor += 1
                }
                if cursor < characters.count { cursor += 1 }
            } else {
                base.append(characters[cursor])
                cursor += 1
            }

            // \i and \j lose their dot when accented.
            base = base.replacingOccurrences(of: "\\i", with: "i")
                       .replacingOccurrences(of: "\\j", with: "j")
            output += base + mark
            index = cursor
        }
        return output
    }
}
