//
//  CSLProcessor.swift
//  WriterTex
//
//  Formats every citation in a document and its reference list in one pass,
//  because numbering, positions and year suffixes depend on the whole
//  document, not on any one citation.
//

import Foundation

/// One reference inside a citation: `[see @key, p. 33]`.
nonisolated struct CSLCite: Equatable, Sendable {
    var id: String
    var prefix: String
    var suffix: String
    var locator: String?
    /// The locator's CSL term ("page", "chapter", …); page when nil.
    var label: String?
    /// `[-@key]`: the author is left out because the sentence names them.
    var suppressAuthor: Bool

    init(id: String, prefix: String = "", suffix: String = "", locator: String? = nil,
                label: String? = nil, suppressAuthor: Bool = false) {
        self.id = id
        self.prefix = prefix
        self.suffix = suffix
        self.locator = locator
        self.label = label
        self.suppressAuthor = suppressAuthor
    }
}

/// A citation as written: one or more cites, either in brackets or narrative
/// (`@key says`, rendered "Smith (2020) says").
nonisolated struct CSLCitation: Equatable, Sendable {
    var cites: [CSLCite]
    var narrative: Bool

    init(cites: [CSLCite], narrative: Bool = false) {
        self.cites = cites
        self.narrative = narrative
    }
}

nonisolated struct CSLEntry: Equatable, Sendable {
    var id: String
    /// With second-field-align, the first field ("[1]") set apart in the margin.
    var margin: [CSLRun]?
    var runs: [CSLRun]
}

nonisolated struct CSLBibliography: Equatable, Sendable {
    var entries: [CSLEntry]
    var hangingIndent: Bool
    /// Multiples of single spacing, within and between entries.
    var lineSpacing: Int
    var entrySpacing: Int
    /// "flush" or "margin" when entries start with a number set apart.
    var secondFieldAlign: String?
}

nonisolated struct CSLResult: Sendable {
    /// One per input citation, in order.
    var citations: [[CSLRun]]
    var bibliography: CSLBibliography?
    /// Cited keys the library doesn't have, in first-cited order.
    var missing: [String]
}

nonisolated struct CSLProcessor: Sendable {
    let style: CSLStyle
    let locale: CSLLocale
    private let items: [String: CSLItem]

    /// `locale` is the base locale file; the style's overrides are applied here.
    init(style: CSLStyle, locale: CSLLocale, items: [Citation]) {
        self.style = style
        self.locale = locale.merging(style)
        var byID: [String: CSLItem] = [:]
        for citation in items where byID[citation.id] == nil { byID[citation.id] = CSLItem(citation) }
        self.items = byID
    }

    func process(_ citations: [CSLCitation]) -> CSLResult {
        var cited: [String] = []
        var missing: [String] = []
        for cite in citations.flatMap(\.cites) {
            if items[cite.id] != nil {
                if !cited.contains(cite.id) { cited.append(cite.id) }
            } else if !missing.contains(cite.id) {
                missing.append(cite.id)
            }
        }

        // Numbers follow the reference list's order, which may itself be
        // first-cited order.
        var order = cited
        if let sort = style.bibliography?.child("sort") {
            let firstCited = Dictionary(uniqueKeysWithValues: cited.enumerated().map { ($1, $0 + 1) })
            order = sorted(cited, by: sort, section: style.bibliography) { CSLCiteContext(citationNumber: firstCited[$0]) }
        }
        let numbers = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0 + 1) })
        let suffixes = yearSuffixes(order, numbers: numbers)
        func context(_ id: String) -> CSLCiteContext {
            CSLCiteContext(citationNumber: numbers[id], yearSuffix: suffixes[id])
        }

        var rendered: [[CSLRun]] = []
        var seen = Set<String>()
        var previous: CSLCite?
        var previousCount = 0
        for citation in citations {
            var positioned: [(cite: CSLCite, context: CSLCiteContext)] = []
            for (index, cite) in citation.cites.enumerated() {
                var context = context(cite.id)
                context.locator = cite.locator
                context.label = cite.label
                if !seen.contains(cite.id) {
                    context.position = .first
                } else if let previous, previous.id == cite.id, index > 0 || previousCount == 1 {
                    context.position = cite.locator == previous.locator ? .ibid
                        : cite.locator != nil ? .ibidWithLocator : .subsequent
                } else {
                    context.position = .subsequent
                }
                seen.insert(cite.id)
                previous = cite
                positioned.append((cite, context))
            }
            previousCount = citation.cites.count
            rendered.append(render(citation, positioned))
        }

        return CSLResult(citations: rendered, bibliography: bibliography(order, context: context), missing: missing)
    }

    // MARK: Citations

    private func render(_ citation: CSLCitation, _ cites: [(cite: CSLCite, context: CSLCiteContext)]) -> [CSLRun] {
        guard let section = style.citation, let layout = section.child("layout") else { return [] }
        var cites = cites
        if !citation.narrative, let sort = section.child("sort"), cites.count > 1 {
            let contexts = Dictionary(cites.map { ($0.cite.id, $0.context) }) { first, _ in first }
            let order = sorted(cites.map(\.cite.id).filter { items[$0] != nil }, by: sort, section: section) { contexts[$0] ?? CSLCiteContext() }
            cites.sort { a, b in
                (order.firstIndex(of: a.cite.id) ?? Int.max) < (order.firstIndex(of: b.cite.id) ?? Int.max)
            }
        }

        func cluster(suppressingFirstAuthor: Bool) -> CSLOut {
            let parts = cites.enumerated().map { index, entry -> CSLOut in
                guard let item = items[entry.cite.id] else {
                    return .styled(CSLStyling(on: .bold), .text(entry.cite.id + "?"))
                }
                let renderer = CSLRenderer(style: style, locale: locale, item: item, mode: .citation,
                                           section: section, cite: entry.context)
                renderer.suppressAuthor = entry.cite.suppressAuthor || (suppressingFirstAuthor && index == 0)
                var pieces: [CSLOut] = []
                if !entry.cite.prefix.isEmpty {
                    let prefix = entry.cite.prefix
                    pieces.append(.text(prefix.last?.isWhitespace == true ? prefix : prefix + " "))
                }
                pieces.append(renderer.render(layout.children).out)
                if !entry.cite.suffix.isEmpty {
                    let suffix = entry.cite.suffix
                    let joined = suffix.first.map { $0.isWhitespace || ",.;:".contains($0) } == true
                    pieces.append(.text(joined ? suffix : " " + suffix))
                }
                return .group(pieces)
            }
            return CSLRenderer(style: style, locale: locale, item: CSLItem(Citation(fields: [:])), mode: .citation, section: section)
                .decorate(.joined(parts, delimiter: layout["delimiter"]), layout)
        }

        if citation.narrative, let first = cites.first, let item = items[first.cite.id],
           let author = narrativeAuthor(item, context: first.context) {
            return CSLOut.group([author, .text(" "), cluster(suppressingFirstAuthor: true)]).runs(locale)
        }
        return cluster(suppressingFirstAuthor: false).runs(locale)
    }

    /// The names a narrative citation starts with: the citation layout's
    /// first names, or the bibliography's for styles whose citations are
    /// only numbers.
    private func narrativeAuthor(_ item: CSLItem, context: CSLCiteContext) -> CSLOut? {
        for (index, section) in [style.citation, style.bibliography].enumerated() {
            guard let layout = section?.child("layout") else { continue }
            let renderer = CSLRenderer(style: style, locale: locale, item: item, mode: .citation, section: style.citation, cite: context)
            renderer.capturesAuthor = true
            renderer.forcesShortNames = index == 1
            _ = renderer.render(layout.children)
            if let author = renderer.capturedAuthor { return author }
        }
        return nil
    }

    // MARK: Bibliography

    private func bibliography(_ order: [String], context: (String) -> CSLCiteContext) -> CSLBibliography? {
        guard let section = style.bibliography, let layout = section.child("layout") else { return nil }
        let secondFieldAlign = section["second-field-align"]
        let entries: [CSLEntry] = order.compactMap { id in
            guard let item = items[id] else { return nil }
            let renderer = CSLRenderer(style: style, locale: locale, item: item, mode: .bibliography,
                                       section: section, cite: context(id))
            var margin: [CSLRun]?
            var children = layout.children
            if secondFieldAlign != nil, let first = children.first {
                margin = renderer.render(first).out.runs(locale)
                children.removeFirst()
            }
            let body = renderer.decorate(renderer.render(children).out, layout).runs(locale)
            guard !body.isEmpty else { return nil }
            return CSLEntry(id: id, margin: margin?.isEmpty == true ? nil : margin, runs: body)
        }
        return CSLBibliography(entries: entries,
                               hangingIndent: section["hanging-indent"] == "true",
                               lineSpacing: Int(section["line-spacing"] ?? "") ?? 1,
                               entrySpacing: Int(section["entry-spacing"] ?? "") ?? 1,
                               secondFieldAlign: secondFieldAlign)
    }

    // MARK: Disambiguation

    /// "2020a", "2020b" for works whose citations would otherwise read the same.
    private func yearSuffixes(_ order: [String], numbers: [String: Int]) -> [String: String] {
        guard let section = style.citation, section["disambiguate-add-year-suffix"] == "true",
              let layout = section.child("layout") else { return [:] }
        var groups: [String: [String]] = [:]
        for id in order {
            guard let item = items[id] else { continue }
            let renderer = CSLRenderer(style: style, locale: locale, item: item, mode: .citation, section: section,
                                       cite: CSLCiteContext(position: .first, citationNumber: numbers[id]))
            groups[renderer.render(layout.children).out.plain, default: []].append(id)
        }
        var suffixes: [String: String] = [:]
        for ids in groups.values where ids.count > 1 {
            for (index, id) in ids.enumerated() { suffixes[id] = Self.letters(index) }
        }
        return suffixes
    }

    /// 0 → "a", 25 → "z", 26 → "aa".
    static func letters(_ index: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
        var index = index, result = ""
        repeat {
            result = String(alphabet[index % 26]) + result
            index = index / 26 - 1
        } while index >= 0
        return result
    }

    // MARK: Sorting

    private func sorted(_ ids: [String], by sort: CSLNode, section: CSLNode?, context: (String) -> CSLCiteContext) -> [String] {
        let keyNodes = sort.children("key")
        let keyed: [(id: String, index: Int, keys: [String?])] = ids.enumerated().map { index, id in
            (id, index, keyNodes.map { key in items[id].flatMap { sortValue(key, item: $0, section: section, context: context(id)) } })
        }
        return keyed.sorted { a, b in
            for (index, key) in keyNodes.enumerated() {
                switch (a.keys[index], b.keys[index]) {
                case (nil, nil): continue
                case (nil, _): return false
                case (_, nil): return true
                case let (left?, right?):
                    let order = left.compare(right, options: [.caseInsensitive, .diacriticInsensitive, .numeric])
                    if order == .orderedSame { continue }
                    return (order == .orderedAscending) == (key["sort"] != "descending")
                }
            }
            return a.index < b.index
        }.map(\.id)
    }

    private func sortValue(_ key: CSLNode, item: CSLItem, section: CSLNode?, context: CSLCiteContext) -> String? {
        let renderer = CSLRenderer(style: style, locale: locale, item: item, mode: .sort, section: section, cite: context)
        renderer.sortNames = .init(min: key["names-min"].flatMap(Int.init), useFirst: key["names-use-first"].flatMap(Int.init),
                                   useLast: key["names-use-last"].map { $0 == "true" })
        let value: String
        if let macro = key["macro"].flatMap({ style.macros[$0] }) {
            value = renderer.render(macro.children).out.plain
        } else if let variable = key["variable"] {
            if variable == "citation-number" {
                value = context.citationNumber.map { String(format: "%08d", $0) } ?? ""
            } else if !item.names(variable).isEmpty || item.date(variable) != nil {
                let node = !item.names(variable).isEmpty
                    ? CSLNode(name: "names", attributes: ["variable": variable],
                              children: [CSLNode(name: "name", attributes: [:], children: [], text: "")], text: "")
                    : CSLNode(name: "date", attributes: ["variable": variable], children: [], text: "")
                value = renderer.render(node).out.plain
            } else {
                value = item.string(variable) ?? ""
            }
        } else {
            return nil
        }
        // Brackets and quotes don't count: “The Title” sorts under T.
        let trimmed = value.drop { !$0.isLetter && !$0.isNumber }
        return trimmed.isEmpty ? nil : String(trimmed)
    }
}
