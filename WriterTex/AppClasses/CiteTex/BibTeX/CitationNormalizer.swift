//
//  CitationNormalizer.swift
//  BibTeXKit — used by the Safari extension to clean scraped CSL-JSON and mint
//  a citation key before the record is written as BibTeX.
//
//  Reference managers disagree about almost everything below the top level of
//  CSL-JSON: where the year lives, what an author object is called, whether a
//  type is "journalArticle" or "article-journal". This file absorbs that
//  variation on the way in, so the rest of the app can assume one shape.
//
//  Writerly also validated records against APA 7 here; that is style-specific
//  and was dropped from this copy.
//

import Foundation

nonisolated enum CitationNormalizer {

    // MARK: - Small helpers

    static func clean(_ s: String?) -> String {
        (s ?? "").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                 .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stripAccents(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US"))
    }

    /// Case-insensitive lookup, because exporters disagree about capitalisation.
    static func value(_ dict: [String: JSONValue], anyOf keys: [String]) -> JSONValue? {
        let lower = Dictionary(dict.map { ($0.key.lowercased(), $0.value) },
                               uniquingKeysWith: { a, _ in a })
        for k in keys {
            if let v = lower[k.lowercased()] { return v }
        }
        return nil
    }

    static func string(_ dict: [String: JSONValue], anyOf keys: [String]) -> String {
        clean(value(dict, anyOf: keys)?.stringValue)
    }

    // MARK: - Names

    static let institutionWords: Set<String> = [
        "university","college","institute","department","ministry","agency",
        "association","society","centre","center","foundation","organization",
        "organisation","committee","council","bureau","office","press","group",
        "team","consortium"
    ]
    static let suffixes: Set<String> = ["jr","sr","ii","iii","iv","phd","md","edd","msw"]
    static let particles: Set<String> = [
        "van","von","de","del","della","der","den","di","da","du","la","le",
        "dos","das","bin","ibn","al","st"
    ]

    static func name(fromString raw: String) -> [String: JSONValue]? {
        let s = clean(raw)
        guard !s.isEmpty else { return nil }

        if !s.contains(",") {
            let words = s.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            if words.contains(where: { institutionWords.contains($0) }) {
                return ["literal": .string(s)]
            }
        }

        if s.contains(",") {
            let parts = s.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            let family = clean(String(parts[0]))
            let given = parts.count > 1 ? clean(String(parts[1])) : ""
            if !family.isEmpty {
                return given.isEmpty ? ["family": .string(family)]
                                     : ["family": .string(family), "given": .string(given)]
            }
        }

        var toks = s.split(separator: " ").map(String.init)
        guard toks.count > 1 else { return ["family": .string(toks[0])] }

        var suffix = ""
        while toks.count > 1,
              suffixes.contains(toks[toks.count - 1]
                .lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) {
            let s2 = toks.removeLast()
            suffix = suffix.isEmpty ? s2 : "\(s2) \(suffix)"
        }
        guard toks.count > 1 else {
            let fam = toks[0] + (suffix.isEmpty ? "" : ", \(suffix)")
            return ["family": .string(fam)]
        }

        var famStart = toks.count - 1
        while famStart > 1, particles.contains(toks[famStart - 1]
                .lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))) {
            famStart -= 1
        }

        var family = toks[famStart...].joined(separator: " ")
        if !suffix.isEmpty { family += ", \(suffix)" }
        let given = toks[..<famStart].joined(separator: " ")
        return given.isEmpty ? ["family": .string(family)]
                             : ["family": .string(family), "given": .string(given)]
    }

    static func name(from value: JSONValue) -> [String: JSONValue]? {
        if let s = value.stringValue, value.objectValue == nil { return name(fromString: s) }
        guard let obj = value.objectValue else { return nil }

        let family  = string(obj, anyOf: ["family", "lastname", "last", "surname", "familyname"])
        let given   = string(obj, anyOf: ["given", "firstname", "first", "forename", "givenname"])
        let literal = string(obj, anyOf: ["literal", "name", "fullname", "institution",
                                          "organization", "organisation"])
        let suffix  = string(obj, anyOf: ["suffix"])

        if !family.isEmpty {
            let fam = suffix.isEmpty ? family : "\(family), \(suffix)"
            return given.isEmpty ? ["family": .string(fam)]
                                 : ["family": .string(fam), "given": .string(given)]
        }
        if !literal.isEmpty {
            // A "name" field usually holds a person, not an institution.
            return name(fromString: literal) ?? ["literal": .string(literal)]
        }
        if !given.isEmpty { return ["family": .string(given)] }
        return nil
    }

    static func nameList(from value: JSONValue?) -> [JSONValue] {
        guard let value else { return [] }
        let items: [JSONValue] = value.arrayValue ?? [value]
        var out: [JSONValue] = []
        for item in items {
            if item.objectValue == nil, let s = item.stringValue {
                // One field sometimes carries several names.
                let pieces = s.components(separatedBy: ";")
                    .flatMap { $0.components(separatedBy: " and ") }
                for p in pieces {
                    if let n = name(fromString: p) { out.append(.object(n)) }
                }
            } else if let n = name(from: item) {
                out.append(.object(n))
            }
        }
        return out
    }

    // MARK: - Dates

    static let monthNames: [String: Int] = [
        "jan":1,"feb":2,"mar":3,"apr":4,"may":5,"jun":6,
        "jul":7,"aug":8,"sep":9,"oct":10,"nov":11,"dec":12
    ]

    static func dateParts(_ nums: [Int]) -> JSONValue {
        .object(["date-parts": .array([.array(nums.map { .number(Double($0)) })])])
    }

    static func date(fromString raw: String) -> JSONValue? {
        let s = clean(raw)
        guard !s.isEmpty else { return nil }

        func match(_ pattern: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
            else { return nil }
            return (0..<m.numberOfRanges).map { i in
                guard let r = Range(m.range(at: i), in: s) else { return "" }
                return String(s[r])
            }
        }

        if let g = match(#"(\d{4})[\/\-.](\d{1,2})[\/\-.](\d{1,2})"#),
           let y = Int(g[1]), let mo = Int(g[2]), let d = Int(g[3]) {
            return dateParts([y, mo, d])
        }
        if let g = match(#"(\d{4})[\/\-.](\d{1,2})(?![\d])"#),
           let y = Int(g[1]), let mo = Int(g[2]), (1...12).contains(mo) {
            return dateParts([y, mo])
        }

        guard let yg = match(#"\b(1[6-9]\d{2}|20\d{2}|21\d{2})\b"#), let y = Int(yg[1]) else {
            return nil
        }
        if let mg = match(#"\b([A-Za-z]{3,9})\b"#) {
            let key = String(mg[1].lowercased().prefix(3))
            if let mo = monthNames[key] {
                if let dg = match(#"\b(\d{1,2})\b(?!\d)"#), let d = Int(dg[1]), (1...31).contains(d) {
                    return dateParts([y, mo, d])
                }
                return dateParts([y, mo])
            }
        }
        return dateParts([y])
    }

    static func date(from value: JSONValue?) -> JSONValue? {
        guard let value else { return nil }

        switch value {
        case .number(let n):
            let y = Int(n)
            return (y > 1000 && y < 2200) ? dateParts([y]) : nil

        case .string(let s):
            return date(fromString: s)

        case .array(let arr):
            let flat = arr.flatMap { $0.arrayValue ?? [$0] }
            let nums = flat.compactMap { $0.stringValue.flatMap(Int.init) }.filter { $0 != 0 }
            if let f = nums.first, f > 1000, f < 2200 { return dateParts(Array(nums.prefix(3))) }
            return nil

        case .object(let obj):
            if let parts = obj["date-parts"]?.arrayValue,
               let first = parts.first?.arrayValue {
                let nums = first.compactMap { $0.stringValue.flatMap(Int.init) }.filter { $0 != 0 }
                if let f = nums.first, f > 1000, f < 2200 { return dateParts(Array(nums.prefix(3))) }
                // date-parts present but empty — fall through to the other keys.
            }
            for key in ["raw", "literal", "date", "value", "iso"] {
                let s = string(obj, anyOf: [key])
                if !s.isEmpty, let d = date(fromString: s) { return d }
            }
            let yearStr = string(obj, anyOf: ["year"])
            if let y = Int(yearStr), y > 1000, y < 2200 {
                var parts = [y]
                if let mo = Int(string(obj, anyOf: ["month"])), (1...12).contains(mo) {
                    parts.append(mo)
                    if let d = Int(string(obj, anyOf: ["day"])), (1...31).contains(d) { parts.append(d) }
                }
                return dateParts(parts)
            }
            return nil

        default:
            return nil
        }
    }

    // MARK: - Citation keys

    static let stopWords: Set<String> = [
        "the","a","an","of","on","in","for","and","to","with","at","from","by",
        "as","into","is","are","was","were","new","study","studies","research",
        "analysis","review","toward","towards","using","use","case"
    ]

    /// Deliberately disambiguating: surname + year + first distinctive title
    /// word. A bare surname-and-year key is a query, not an identifier.
    static func mintKey(for fields: [String: JSONValue]) -> String {
        var family = "anon"
        let lead = fields["author"]?.arrayValue?.first ?? fields["editor"]?.arrayValue?.first
        if let obj = lead?.objectValue {
            family = clean(obj["family"]?.stringValue) .isEmpty
                ? clean(obj["literal"]?.stringValue)
                : clean(obj["family"]?.stringValue)
            if family.isEmpty { family = "anon" }
        }
        family = stripAccents(family).lowercased().filter { $0.isLetter && $0.isASCII }
        if family.isEmpty { family = "anon" }
        if family.count > 16 { family = String(family.prefix(16)) }

        var year = "nd"
        if let parts = fields["issued"]?.objectValue?["date-parts"]?.arrayValue,
           let first = parts.first?.arrayValue,
           let y = first.first?.stringValue, !y.isEmpty {
            year = y
        }

        let title = stripAccents(clean(fields["title"]?.stringValue)).lowercased()
        let words = title
            .map { ($0.isLetter || $0.isNumber) && $0.isASCII ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ").map(String.init)
            .filter { $0.count > 2 && !stopWords.contains($0) }
        let hint = String((words.first ?? "").prefix(12))

        return family + year + hint
    }

    // MARK: - Types

    static let typeAliases: [String: String] = [
        "journalarticle": "article-journal", "journal article": "article-journal",
        "article": "article-journal", "magazinearticle": "article-magazine",
        "newspaperarticle": "article-newspaper", "booksection": "chapter",
        "book section": "chapter", "incollection": "chapter", "inbook": "chapter",
        "conferencepaper": "paper-conference", "inproceedings": "paper-conference",
        "phdthesis": "thesis", "mastersthesis": "thesis", "dissertation": "thesis",
        "techreport": "report", "blogpost": "webpage", "web page": "webpage",
        "misc": "document", "manuscript": "document",
        // Crossref's own vocabulary, which leaks through some CSL exports.
        "journal-article": "article-journal", "proceedings-article": "paper-conference",
        "book-chapter": "chapter"
    ]

    // MARK: - The main entry point

    struct Result: Sendable {
        var citation: Citation
        var notes: [String]
    }

    /// A placeholder key carries no information and must be replaced. So must
    /// one BibTeX cannot hold: scraped CSL sometimes arrives with a DOI URL as
    /// its `id`, and `@article{https://doi.org/…,` breaks the whole .bib.
    static func isPlaceholderKey(_ key: String) -> Bool {
        key.isEmpty
            || key.range(of: #"^imported\d+$"#, options: .regularExpression) != nil
            || key.contains("://")
            || key.contains(where: { $0.isWhitespace || ",{}()\"#%'=~\\".contains($0) })
    }

    static func normalize(_ input: [String: JSONValue]) -> Result {
        var f = input
        var notes: [String] = []

        // ---- type
        let rawType = string(f, anyOf: ["type", "itemtype"]).lowercased()
        if let mapped = typeAliases[rawType] {
            f["type"] = .string(mapped)
        } else if !rawType.isEmpty {
            f["type"] = .string(rawType)
        } else {
            f["type"] = .string(f["container-title"] != nil ? "article-journal" : "document")
            notes.append("type inferred")
        }
        f.removeValue(forKey: "itemType")

        // ---- names
        for role in ["author", "editor", "translator", "container-author", "director"] {
            guard let existing = f[role] else { continue }
            let list = nameList(from: existing)
            if list.isEmpty { f.removeValue(forKey: role) }
            else {
                if list.count != (existing.arrayValue?.count ?? 1) { notes.append("\(role) reshaped") }
                f[role] = .array(list)
            }
        }

        // Zotero's native export keeps everyone in `creators`.
        if f["author"] == nil, let creators = f["creators"]?.arrayValue {
            var authors: [JSONValue] = [], editors: [JSONValue] = []
            for c in creators {
                guard let n = name(from: c) else { continue }
                let role = clean(c.objectValue?["creatorType"]?.stringValue).lowercased()
                if role == "editor" { editors.append(.object(n)) } else { authors.append(.object(n)) }
            }
            if !authors.isEmpty { f["author"] = .array(authors) }
            if !editors.isEmpty { f["editor"] = .array(editors) }
            f.removeValue(forKey: "creators")
            notes.append("creators converted")
        }

        // ---- dates
        for field in ["issued", "accessed", "submitted", "original-date", "event-date"] {
            guard f[field] != nil else { continue }
            if let d = date(from: f[field]) { f[field] = d } else { f.removeValue(forKey: field) }
        }
        if f["issued"] == nil {
            for alt in ["date", "year", "publicationDate", "issued-date", "pub-date"] {
                if let v = value(f, anyOf: [alt]), let d = date(from: v) {
                    f["issued"] = d
                    notes.append("year recovered from \(alt)")
                    break
                }
            }
        }

        // ---- container
        if clean(f["container-title"]?.stringValue).isEmpty {
            for alt in ["containerTitle", "journalAbbreviation", "publicationTitle",
                        "journal", "booktitle", "bookTitle", "publication"] {
                let s = string(f, anyOf: [alt])
                if !s.isEmpty { f["container-title"] = .string(s); notes.append("container from \(alt)"); break }
            }
        }
        if let obj = f["container-title"]?.objectValue {
            let s = clean(obj["name"]?.stringValue ?? obj["literal"]?.stringValue)
            if s.isEmpty { f.removeValue(forKey: "container-title") } else { f["container-title"] = .string(s) }
        }

        // ---- pages, DOI, title
        if clean(f["page"]?.stringValue).isEmpty {
            for alt in ["pages", "page-range", "pageRange"] {
                let s = string(f, anyOf: [alt])
                if !s.isEmpty { f["page"] = .string(s); break }
            }
        }
        if let p = f["page"]?.stringValue {
            f["page"] = .string(clean(p).replacingOccurrences(
                of: #"\s*(?:--|–|—|-)\s*"#, with: "-", options: .regularExpression))
        }

        if clean(f["DOI"]?.stringValue).isEmpty {
            let s = string(f, anyOf: ["doi"])
            if !s.isEmpty { f["DOI"] = .string(s) }
        }
        if let d = f["DOI"]?.stringValue {
            f["DOI"] = .string(clean(d)
                .replacingOccurrences(of: #"^https?://(dx\.)?doi\.org/"#, with: "",
                                      options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: #"^doi:\s*"#, with: "",
                                      options: [.regularExpression, .caseInsensitive]))
        }

        if let obj = f["title"]?.objectValue {
            f["title"] = .string(clean(obj["name"]?.stringValue ?? obj["literal"]?.stringValue))
        }
        f["title"] = .string(clean(f["title"]?.stringValue))

        repair(&f)

        // ---- key
        let currentKey = clean(f["id"]?.stringValue)
        if isPlaceholderKey(currentKey) {
            f["id"] = .string(mintKey(for: f))
            notes.append("key minted")
        }

        return Result(citation: Citation(fields: f), notes: notes)
    }
}
