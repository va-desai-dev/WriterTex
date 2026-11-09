//
//  CSLLocale.swift
//  WriterTex
//
//  Terms ("and", "edited by", month names, ordinals), the two localized date
//  formats and a couple of punctuation options. A style may override any of
//  them in its own <locale> elements; `merging(_:)` layers those on top.
//

import Foundation

nonisolated struct CSLLocale: Sendable {
    struct Term: Sendable {
        var single: String
        var multiple: String
        /// For ordinal terms: "last-digit", "last-two-digits" or "whole-number".
        var match: String?
    }

    private(set) var language: String
    var terms: [String: Term] = [:]
    var dateFormats: [String: CSLNode] = [:]
    var punctuationInQuote = false
    var limitDayOrdinalsToDay1 = false

    init(xml data: Data) throws {
        let root = try CSLNode.parse(data)
        guard root.name == "locale" else { throw CSLError.malformed("Not a CSL locale.") }
        language = root["xml:lang"] ?? "en-US"
        merge(root)
    }

    /// The locale with a style's `<locale>` overrides applied: those without a
    /// language first, then the bare language ("en"), then the exact one
    /// ("en-US"), so the most specific wins.
    func merging(_ style: CSLStyle) -> CSLLocale {
        var merged = self
        let primary = language.split(separator: "-").first.map(String.init) ?? language
        let languages: [String?] = primary == language ? [nil, primary] : [nil, primary, language]
        for lang in languages {
            for node in style.localeOverrides where node["xml:lang"] == lang { merged.merge(node) }
        }
        return merged
    }

    var isEnglish: Bool { language.hasPrefix("en") }

    private static func key(_ name: String, _ form: String) -> String { form == "long" ? name : name + "|" + form }

    private mutating func merge(_ node: CSLNode) {
        for child in node.children {
            switch child.name {
            case "style-options":
                if let value = child["punctuation-in-quote"] { punctuationInQuote = value == "true" }
                if let value = child["limit-day-ordinals-to-day-1"] { limitDayOrdinalsToDay1 = value == "true" }
            case "date":
                if let form = child["form"] { dateFormats[form] = child }
            case "terms":
                // Ordinals are replaced as a set: a locale that defines any
                // ordinal term drops the inherited ones.
                if child.children.contains(where: { $0["name"]?.hasPrefix("ordinal") == true }) {
                    terms = terms.filter { !$0.key.hasPrefix("ordinal") }
                }
                for term in child.children("term") {
                    guard let name = term["name"], term["gender-form"] == nil else { continue }
                    let single = term.child("single")?.text ?? term.text
                    let multiple = term.child("multiple")?.text ?? single
                    terms[Self.key(name, term["form"] ?? "long")] = Term(single: single, multiple: multiple, match: term["match"])
                }
            default:
                break
            }
        }
    }

    /// A term in the requested form, falling back the way CSL specifies:
    /// verb-short → verb → long, symbol → short → long, short → long.
    func term(_ name: String, form: String = "long", plural: Bool = false) -> String? {
        let chain: [String] = switch form {
        case "verb-short": ["verb-short", "verb", "long"]
        case "symbol": ["symbol", "short", "long"]
        case "short": ["short", "long"]
        case "verb": ["verb", "long"]
        default: ["long"]
        }
        for form in chain {
            if let term = terms[Self.key(name, form)] { return plural ? term.multiple : term.single }
        }
        return nil
    }

    func ordinalSuffix(_ number: Int) -> String {
        let n = abs(number)
        func lookup(_ value: Int, _ allowed: Set<String>) -> String? {
            let name = String(format: "ordinal-%02d", value)
            guard let term = terms[name] else { return nil }
            return allowed.contains(term.match ?? (value < 10 ? "last-digit" : "last-two-digits")) ? term.single : nil
        }
        if n < 100, let exact = lookup(n, ["whole-number", "last-two-digits", "last-digit"]) { return exact }
        if n % 100 >= 10, let twoDigit = lookup(n % 100, ["last-two-digits"]) { return twoDigit }
        if let lastDigit = lookup(n % 10, ["last-digit"]) { return lastDigit }
        return term("ordinal") ?? ""
    }

    func longOrdinal(_ number: Int) -> String {
        if (1...10).contains(number), let word = term(String(format: "long-ordinal-%02d", number)) { return word }
        return "\(number)" + ordinalSuffix(number)
    }
}
