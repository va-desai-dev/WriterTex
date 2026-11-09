//
//  CitationRepair.swift
//  WriterTex
//
//  Faults in publisher metadata that survive into .bib files: author lists
//  scraped twice, organizations split into a given and family name, names in
//  capitals, a book's page count filed as its pages, and Elsevier's
//  "Chapter 20" left in a chapter title. Applied when a capture is normalized
//  and again whenever a .bib entry is read, so entries already saved are
//  formatted correctly without editing the file.
//

import Foundation

nonisolated extension CitationNormalizer {
    static func repair(_ fields: inout [String: JSONValue]) {
        for role in ["author", "editor", "translator", "container-author", "director"] {
            if let names = fields[role]?.arrayValue { fields[role] = .array(repairNames(names)) }
        }
        let type = fields["type"]?.stringValue
        // A book has no page range; a lone number is how long it is.
        if type == "book", fields["number-of-pages"] == nil,
           let page = fields["page"]?.stringValue?.trimmingCharacters(in: .whitespaces), Int(page) != nil {
            fields["number-of-pages"] = .string(page)
            fields.removeValue(forKey: "page")
        }
        if type == "chapter", let title = fields["title"]?.stringValue,
           let number = title.range(of: #"^Chapter\s+\d+[.:]?\s+(?=\p{Lu})"#, options: .regularExpression) {
            fields["title"] = .string(String(title[number.upperBound...]))
        }
    }

    /// A list that is one list repeated ("A, B, A, B") is that list once.
    static func repairNames(_ names: [JSONValue]) -> [JSONValue] {
        var names = names
        let count = names.count
        for period in stride(from: 1, through: count / 2, by: 1) where count % period == 0 {
            let first = Array(names[..<period])
            if stride(from: period, to: count, by: period).allSatisfy({ Array(names[$0..<($0 + period)]) == first }) {
                names = first
                break
            }
        }
        return names.map(repairName)
    }

    static func repairName(_ value: JSONValue) -> JSONValue {
        guard var name = value.objectValue, name["literal"] == nil else { return value }
        let family = name["family"]?.stringValue ?? "", given = name["given"]?.stringValue ?? ""
        let whole = [given, family].filter { !$0.isEmpty }.joined(separator: " ")
        // "National Institute of Health" read as given "National Institute", family "of Health".
        let words = whole.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        if words.count >= 3, words.contains(where: institutionWords.contains) {
            return .object(["literal": .string(whole)])
        }
        if isCapitals(family) {
            name["family"] = .string(recased(family))
            if isCapitals(given) { name["given"] = .string(recased(given)) }
        }
        return .object(name)
    }

    /// "CARSKADON", "MARY A.": two or more letters, none lowercase. Initials
    /// alone ("J. A.") don't count.
    static func isCapitals(_ text: String) -> Bool {
        text.range(of: #"\p{Lu}{2}"#, options: .regularExpression) != nil && !text.contains(where: \.isLowercase)
    }

    /// "JENNI-OSKAR" → "Jenni-Oskar", "O'BRIEN" → "O'Brien".
    static func recased(_ text: String) -> String {
        var result = "", capitalizeNext = true
        for character in text.lowercased() {
            result += capitalizeNext ? character.uppercased() : String(character)
            capitalizeNext = !character.isLetter
        }
        return result
    }
}
