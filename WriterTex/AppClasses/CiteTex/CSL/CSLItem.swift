//
//  CSLItem.swift
//  WriterTex
//
//  Typed reads of a CSL-JSON record: strings, names and dates.
//

import Foundation

nonisolated struct CSLName: Equatable {
    var family: String?
    var given: String?
    var droppingParticle: String?
    var nonDroppingParticle: String?
    var suffix: String?
    var literal: String?
    var commaSuffix = false
}

nonisolated struct CSLDate {
    /// One date, or a start and end for a range; each is [year, month?, day?].
    var parts: [[Int]]
    var season: String?
    var circa = false
    var literal: String?
}

nonisolated struct CSLItem {
    let id: String
    let fields: [String: JSONValue]

    /// CSL-JSON spellings that predate the hyphenated variable names.
    private static let aliases = ["shortTitle": "title-short", "journalAbbreviation": "container-title-short"]

    init(_ citation: Citation) {
        var fields = citation.fields
        for (old, new) in Self.aliases {
            if fields[new] == nil, let value = fields[old] { fields[new] = value }
        }
        self.fields = fields
        id = citation.id
    }

    var type: String { fields["type"]?.stringValue ?? "document" }

    var language: String? { string("language") }

    func string(_ variable: String) -> String? {
        guard let value = fields[variable] else { return nil }
        let text: String? = switch value {
        case .string, .number: value.stringValue
        case .array(let values): values.first?.stringValue
        default: nil
        }
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return Self.decodingEntities(text)
    }

    /// Crossref metadata often carries HTML entities ("Memory &amp; Cognition"),
    /// which would otherwise print, and title-case, literally.
    static func decodingEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var text = text
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                                    ("&nbsp;", "\u{00A0}"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character, options: .caseInsensitive)
        }
        return text
    }

    func names(_ variable: String) -> [CSLName] {
        guard let values = fields[variable]?.arrayValue else { return [] }
        return values.compactMap { value in
            guard let object = value.objectValue else { return nil }
            func text(_ key: String) -> String? {
                guard let text = object[key]?.stringValue?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
                return text
            }
            var name = CSLName(family: text("family"), given: text("given"),
                               droppingParticle: text("dropping-particle"),
                               nonDroppingParticle: text("non-dropping-particle"),
                               suffix: text("suffix"), literal: text("literal"))
            if name.family == nil, name.given == nil, name.literal == nil { return nil }
            if case .bool(true) = object["comma-suffix"] { name.commaSuffix = true }
            return name
        }
    }

    func date(_ variable: String) -> CSLDate? {
        guard let value = fields[variable] else { return nil }
        switch value {
        case .string(let raw): return Self.parse(raw: raw)
        case .number(let year): return CSLDate(parts: [[Int(year)]])
        case .object(let object):
            var parts: [[Int]] = (object["date-parts"]?.arrayValue ?? []).compactMap { part in
                let numbers = (part.arrayValue ?? []).compactMap { $0.stringValue.flatMap { Int($0) } }
                return numbers.isEmpty ? nil : numbers
            }
            if parts.isEmpty, let raw = object["raw"]?.stringValue, let parsed = Self.parse(raw: raw) { parts = parsed.parts }
            var date = CSLDate(parts: parts, season: object["season"]?.stringValue, literal: object["literal"]?.stringValue)
            switch object["circa"] {
            case .bool(let flag): date.circa = flag
            case .number(let number): date.circa = number != 0
            case .string(let text): date.circa = !text.isEmpty
            default: break
            }
            return parts.isEmpty && date.literal == nil ? nil : date
        default: return nil
        }
    }

    /// "2020", "2020-05-01" or "2019/2020".
    private static func parse(raw: String) -> CSLDate? {
        let ends = raw.split(separator: "/").map { end in
            end.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.prefix(3).map { $0 }
        }.filter { !$0.isEmpty }
        if ends.isEmpty { return raw.isEmpty ? nil : CSLDate(parts: [], literal: raw) }
        return CSLDate(parts: Array(ends.prefix(2)))
    }
}
