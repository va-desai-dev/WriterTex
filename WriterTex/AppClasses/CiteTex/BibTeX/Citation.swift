//
//  Citation.swift
//  WriterTex
//
//  Carved from Writerly's WriterTexShared.swift. The App Group identifiers that
//  lived here moved to CiteTexInbox; the record model is unchanged apart from
//  Sendable conformance.
//

import Foundation
import SwiftUI

// MARK: - A lossless JSON value

/// CSL-JSON carries fields no fixed Swift model can anticipate. Decoding into a
/// closed struct would silently discard them, so records are held as raw JSON
/// and read through typed accessors.
nonisolated indirect enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognised JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v):
            // Keep integers looking like integers.
            if v == v.rounded(), abs(v) < 1e15 { try c.encode(Int(v)) } else { try c.encode(v) }
        case .bool(let v):   try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v):  try c.encode(v)
        case .null:          try c.encodeNil()
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        default: return nil
        }
    }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
}

// MARK: - A citation record

nonisolated struct Citation: Codable, Identifiable, Equatable, Sendable {
    var fields: [String: JSONValue]

    init(fields: [String: JSONValue]) { self.fields = fields }

    init(from decoder: Decoder) throws {
        fields = try [String: JSONValue](from: decoder)
    }
    func encode(to encoder: Encoder) throws {
        try fields.encode(to: encoder)
    }

    var id: String {
        get { fields["id"]?.stringValue ?? "" }
        set { fields["id"] = .string(newValue) }
    }

    var type: String { fields["type"]?.stringValue ?? "document" }
    var title: String { fields["title"]?.stringValue ?? "Untitled" }
    var containerTitle: String? { fields["container-title"]?.stringValue }
    var publisher: String? { fields["publisher"]?.stringValue }
    var doi: String? { fields["DOI"]?.stringValue }
    var url: String? { fields["URL"]?.stringValue }
    var page: String? { fields["page"]?.stringValue }
    var volume: String? { fields["volume"]?.stringValue }
    var issue: String? { fields["issue"]?.stringValue }

    var year: String? {
        guard let issued = fields["issued"]?.objectValue,
              let parts = issued["date-parts"]?.arrayValue,
              let first = parts.first?.arrayValue,
              let y = first.first?.stringValue else { return nil }
        return y
    }

    struct Name: Equatable, Sendable {
        var family: String?
        var given: String?
        var literal: String?
        var display: String {
            if let l = literal { return l }
            return [given, family].compactMap { $0 }.joined(separator: " ")
        }
        /// "Family, Given" — the order BibTeX expects.
        var bibtex: String {
            if let l = literal { return "{\(l)}" }
            if let f = family, let g = given { return "\(f), \(g)" }
            // A lone multi-word family name would be split on the way back in.
            if let f = family, f.contains(" ") { return "{\(f)}" }
            return family ?? given ?? ""
        }
    }

    private func names(_ key: String) -> [Name] {
        guard let arr = fields[key]?.arrayValue else { return [] }
        return arr.compactMap { v in
            guard let o = v.objectValue else { return nil }
            return Name(family: o["family"]?.stringValue,
                        given: o["given"]?.stringValue,
                        literal: o["literal"]?.stringValue)
        }
    }

    var authors: [Name] { names("author") }
    var editors: [Name] { names("editor") }

    var nameClean: String {
        let who = authors.isEmpty ? editors : authors

        if who.isEmpty {
            return "Anon."
        }
        let formattedNames = who.prefix(4).map { $0.bibtex }
        return formattedNames.joined(separator: "; ")
    }


    /// A one-line description for lists and pickers.
    var summary: String {
        let who = authors.isEmpty ? editors : authors
        var lead = "Anon."
        if let first = who.first {
            lead = first.literal ?? first.family ?? first.display
            if who.count == 2 { lead += " & " + (who[1].family ?? who[1].display) }
            else if who.count > 2 { lead += " et al." }
        }
        var s = "\(lead) (\(year ?? "n.d."))"
        if let c = containerTitle { s += " · \(c)" }
        else if let p = publisher { s += " · \(p)" }
        return s
    }
}

// MARK: - BibTeX emission

nonisolated enum BibTeX {
    static let typeMap: [String: String] = [
        "article-journal": "article", "article-magazine": "article",
        "article-newspaper": "article", "chapter": "incollection",
        "book": "book", "thesis": "phdthesis", "report": "techreport",
        "paper-conference": "inproceedings", "webpage": "misc", "document": "misc"
    ]

    /// Braces and backslashes must be escaped or the .bib will not parse, and
    /// the LaTeX specials must be escaped or the *document* will not compile:
    /// Writerly fed .bib to Pandoc, which forgave a bare `&`; pdflatex does not.
    /// BibTeXParser decodes all of these back, so a round trip is lossless.
    static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "\\": out += "\\textbackslash{}"
            case "{", "}", "&", "%", "$", "#", "_": out += "\\\(ch)"
            default: out.append(ch)
            }
        }
        return out
    }

    static func entry(for c: Citation) -> String {
        let kind = typeMap[c.type] ?? "misc"
        var out = "@\(kind){\(c.id),\n"

        func put(_ name: String, _ value: String?) {
            guard let v = value, !v.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            out += "  \(name) = {\(escape(v))},\n"
        }

        /// Name lists already carry the braces that mark a corporate author, and
        /// DOIs and URLs are read verbatim by the url/hyperref packages — an
        /// escaped `\_` there becomes a broken link. Neither goes through `escape`.
        func putRaw(_ name: String, _ value: String?) {
            guard let v = value, !v.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            out += "  \(name) = {\(v)},\n"
        }

        let a = c.authors, e = c.editors
        if !a.isEmpty { putRaw("author", a.map(\.bibtex).joined(separator: " and ")) }
        if !e.isEmpty { putRaw("editor", e.map(\.bibtex).joined(separator: " and ")) }
        put("title", c.title)
        if c.type == "chapter" || c.type == "paper-conference" {
            put("booktitle", c.containerTitle)
        } else if c.type == "article-journal" {
            put("journal", c.containerTitle)
        }
        // A thesis takes `school` and a report `institution`; emitting
        // `publisher` as well produces a duplicate field that some tools reject.
        switch c.type {
        case "thesis": put("school", c.publisher)
        case "report": put("institution", c.publisher)
        default:       put("publisher", c.publisher)
        }
        put("year", c.year)
        put("volume", c.volume)
        put("number", c.issue)
        // BibTeX page ranges use a double hyphen.
        put("pages", c.page.map { $0.replacingOccurrences(of: "-", with: "--")
                                    .replacingOccurrences(of: "----", with: "--") })
        putRaw("doi", c.doi)
        putRaw("url", c.url)
        put("pagetotal", c.fields["number-of-pages"]?.stringValue)
        put("isbn", c.fields["ISBN"]?.stringValue)
        put("issn", c.fields["ISSN"]?.stringValue)
        out += "}\n"
        return out
    }

    static func document(_ items: [Citation]) -> String {
        items.map { entry(for: $0) }.joined(separator: "\n")
    }
}
