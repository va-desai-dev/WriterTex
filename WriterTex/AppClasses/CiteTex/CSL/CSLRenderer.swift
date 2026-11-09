//
//  CSLRenderer.swift
//  WriterTex
//
//  Evaluates a style's rendering elements (text, number, label, group,
//  choose, date, names) for one item. A renderer is made per item and per
//  cite: substitution and author suppression are state of that one rendering.
//

import Foundation

/// Where a cite falls relative to earlier cites of the same item.
nonisolated enum CSLPosition {
    case first, subsequent, ibid, ibidWithLocator
}

/// What a single cite adds to its item: the pinpoint and the cite's place.
nonisolated struct CSLCiteContext {
    var locator: String?
    var label: String?
    var position: CSLPosition?
    var citationNumber: Int?
    var yearSuffix: String?
}

/// A rendered element and whether it touched variables, which is what decides
/// if an enclosing group is shown (CSL's implicit conditional).
nonisolated struct CSLRendered: Sendable {
    var out: CSLOut
    var calledVariable = false
    var renderedVariable = false

    static let nothing = CSLRendered(out: .empty)
}

nonisolated final class CSLRenderer {
    enum Mode { case citation, bibliography, sort }

    struct SortNames { var min: Int?; var useFirst: Int?; var useLast: Bool? }

    let style: CSLStyle
    let locale: CSLLocale
    let item: CSLItem
    let mode: Mode
    let cite: CSLCiteContext
    let nameOptions: [String: String]
    var sortNames: SortNames?
    var disambiguate = false
    /// The first cs:names renders nothing, for "-@key" (Smith says (2020)).
    var suppressAuthor = false
    /// Stop after the first cs:names and keep it, for narrative citations.
    var capturesAuthor = false
    /// Names in their short form whatever the style says (narrative fallback).
    var forcesShortNames = false
    private(set) var capturedAuthor: CSLOut?

    private var suppressed: Set<String> = []
    private var renderedVariables: Set<String> = []
    private var substituteDepth = 0
    private let english: Bool

    /// `section` is the cs:citation or cs:bibliography whose name options apply.
    init(style: CSLStyle, locale: CSLLocale, item: CSLItem, mode: Mode, section: CSLNode?, cite: CSLCiteContext = CSLCiteContext()) {
        self.style = style
        self.locale = locale
        self.item = item
        self.mode = mode
        self.cite = cite
        nameOptions = style.inheritedNameOptions(for: section)
        english = item.language.map { $0.lowercased().hasPrefix("en") } ?? locale.isEnglish
    }

    // MARK: Elements

    func render(_ nodes: [CSLNode]) -> CSLRendered {
        var parts: [CSLOut] = []
        var result = CSLRendered.nothing
        for node in nodes {
            if capturesAuthor, capturedAuthor != nil { break }
            let rendered = render(node)
            parts.append(rendered.out)
            result.calledVariable = result.calledVariable || rendered.calledVariable
            result.renderedVariable = result.renderedVariable || rendered.renderedVariable
        }
        result.out = .group(parts.filter { !$0.isEmpty })
        return result
    }

    func render(_ node: CSLNode) -> CSLRendered {
        switch node.name {
        case "text": text(node)
        case "number": number(node)
        case "label": label(node)
        case "group": group(node)
        case "choose": choose(node)
        case "date": date(node)
        case "names": names(node)
        default: .nothing
        }
    }

    /// Affixes, formatting, text-case and quotes, in CSL's order: affixes sit
    /// outside everything else.
    func decorate(_ out: CSLOut, _ node: CSLNode) -> CSLOut {
        guard !out.isEmpty else { return .empty }
        var out = out
        if node["strip-periods"] == "true" { out = out.strippingPeriods() }
        if let textCase = node["text-case"] { out = out.textCase(textCase, english: english) }
        let styling = CSLStyling(node)
        if !styling.isEmpty { out = .styled(styling, out) }
        if node["quotes"] == "true" { out = .quoted(out) }
        let prefix = node["prefix"] ?? "", suffix = node["suffix"] ?? ""
        return prefix.isEmpty && suffix.isEmpty ? out : .group([.text(prefix), out, .text(suffix)])
    }

    private func text(_ node: CSLNode) -> CSLRendered {
        if let variable = node["variable"] {
            guard let value = variableText(variable, form: node["form"]) else {
                return CSLRendered(out: .empty, calledVariable: true)
            }
            renderedVariables.insert(variable)
            return CSLRendered(out: decorate(.text(value), node), calledVariable: true, renderedVariable: true)
        }
        if let name = node["macro"] {
            guard let macro = style.macros[name] else { return .nothing }
            var rendered = render(macro.children)
            rendered.out = decorate(rendered.out, node)
            return rendered
        }
        if let term = node["term"] {
            let value = locale.term(term, form: node["form"] ?? "long", plural: node["plural"] == "true") ?? ""
            return CSLRendered(out: decorate(.text(value), node))
        }
        return CSLRendered(out: decorate(.text(node["value"] ?? ""), node))
    }

    private func variableText(_ variable: String, form: String?) -> String? {
        guard !suppressed.contains(variable) else { return nil }
        switch variable {
        case "citation-number": return cite.citationNumber.map(String.init)
        case "year-suffix": return cite.yearSuffix
        case "locator":
            guard let locator = cite.locator, !locator.isEmpty else { return nil }
            return (cite.label ?? "page") == "page" ? pageRange(locator) : locator.replacingOccurrences(of: "-", with: "–")
        case "page": return item.string("page").map(pageRange)
        default:
            if form == "short", let short = item.string(variable + "-short") { return short }
            return item.string(variable)
        }
    }

    private func value(of variable: String) -> String? {
        guard !suppressed.contains(variable) else { return nil }
        switch variable {
        case "citation-number": return cite.citationNumber.map(String.init)
        case "locator": return cite.locator.flatMap { $0.isEmpty ? nil : $0 }
        case "year-suffix": return cite.yearSuffix
        default: return item.string(variable)
        }
    }

    private func number(_ node: CSLNode) -> CSLRendered {
        guard let variable = node["variable"] else { return .nothing }
        guard let value = value(of: variable) else { return CSLRendered(out: .empty, calledVariable: true) }
        renderedVariables.insert(variable)
        let text = Self.isNumeric(value) ? formatNumbers(value, form: node["form"] ?? "numeric") : value
        return CSLRendered(out: decorate(.text(text), node), calledVariable: true, renderedVariable: true)
    }

    private func label(_ node: CSLNode) -> CSLRendered {
        guard let variable = node["variable"] else { return .nothing }
        let term = variable == "locator" ? (cite.label ?? "page") : variable
        guard let value = value(of: variable) else { return .nothing }
        let plural: Bool = switch node["plural"] ?? "contextual" {
        case "always": true
        case "never": false
        default:
            ["number-of-pages", "number-of-volumes"].contains(variable)
                ? (Int(value).map { $0 > 1 } ?? false)
                : Self.hasMultipleNumbers(value)
        }
        guard let text = locale.term(term, form: node["form"] ?? "long", plural: plural) else { return .nothing }
        return CSLRendered(out: decorate(.text(text), node))
    }

    private func group(_ node: CSLNode) -> CSLRendered {
        var parts: [CSLOut] = []
        var called = false, rendered = false
        for result in node.children.lazy.flatMap(members) {
            if capturesAuthor, capturedAuthor != nil { break }
            called = called || result.calledVariable
            rendered = rendered || result.renderedVariable
            parts.append(result.out)
        }
        if called, !rendered { return CSLRendered(out: .empty, calledVariable: true) }
        let joined = CSLOut.joined(parts, delimiter: node["delimiter"])
        return CSLRendered(out: decorate(joined, node), calledVariable: called, renderedVariable: rendered)
    }

    /// A group's members for its delimiter: cs:choose is transparent, so the
    /// elements of the branch taken sit directly in the group.
    private func members(_ node: CSLNode) -> [CSLRendered] {
        guard node.name == "choose" else { return [render(node)] }
        guard let branch = node.children.first(where: { $0.name == "else" || test($0) }) else { return [] }
        return branch.children.flatMap(members)
    }

    private func choose(_ node: CSLNode) -> CSLRendered {
        for branch in node.children where branch.name == "else" || test(branch) {
            return render(branch.children)
        }
        return .nothing
    }

    private func test(_ branch: CSLNode) -> Bool {
        var results: [Bool] = []
        for (attribute, list) in branch.attributes where attribute != "match" {
            let values = list.split(separator: " ").map(String.init)
            switch attribute {
            case "type": results += values.map { item.type == $0 }
            case "variable": results += values.map { value(of: $0) != nil || hasNamesOrDate($0) }
            case "is-numeric": results += values.map { value(of: $0).map(Self.isNumeric) ?? false }
            case "is-uncertain-date": results += values.map { item.date($0)?.circa ?? false }
            case "locator":
                results += values.map { cite.locator?.isEmpty == false && (cite.label ?? "page") == $0.replacingOccurrences(of: "-", with: " ") }
            case "position": results += values.map(testPosition)
            case "disambiguate": results.append(disambiguate == (list == "true"))
            default: break
            }
        }
        return switch branch["match"] ?? "all" {
        case "any": results.contains(true)
        case "none": !results.contains(true)
        default: !results.isEmpty && results.allSatisfy { $0 }
        }
    }

    private func hasNamesOrDate(_ variable: String) -> Bool {
        guard !suppressed.contains(variable) else { return false }
        return !item.names(variable).isEmpty || item.date(variable) != nil
    }

    private func testPosition(_ value: String) -> Bool {
        guard mode == .citation, let position = cite.position else { return false }
        return switch value {
        case "first": position == .first
        case "subsequent": position != .first
        case "ibid": position == .ibid || position == .ibidWithLocator
        case "ibid-with-locator": position == .ibidWithLocator
        case "near-note": false
        default: false
        }
    }

    // MARK: Numbers

    static func isNumeric(_ value: String) -> Bool {
        value.range(of: #"^\s*[A-Za-z]?\d+[A-Za-z]*(\s*([-–&,]|and)\s*[A-Za-z]?\d+[A-Za-z]*)*\s*$"#, options: .regularExpression) != nil
    }

    static func hasMultipleNumbers(_ value: String) -> Bool {
        value.range(of: #"\d+\s*([-–&,]|and)\s*\d+"#, options: .regularExpression) != nil
    }

    private func formatNumbers(_ value: String, form: String) -> String {
        var output = ""
        var digits = ""
        func flush() {
            guard let number = Int(digits) else { output += digits; digits = ""; return }
            switch form {
            case "ordinal": output += "\(number)" + locale.ordinalSuffix(number)
            case "long-ordinal": output += locale.longOrdinal(number)
            case "roman": output += Self.roman(number)
            default: output += digits
            }
            digits = ""
        }
        var afterNumber = false
        for character in value {
            if character.isNumber { digits.append(character); afterNumber = true; continue }
            flush()
            // "4th" as an ordinal is 4 + the locale's suffix, not "4thth".
            if form != "numeric", afterNumber, character.isLetter { continue }
            afterNumber = false
            switch character {
            case "-", "–": output += "–"
            default: output.append(character)
            }
        }
        flush()
        return output
            .replacingOccurrences(of: #"\s*–\s*"#, with: "–", options: .regularExpression)
            .replacingOccurrences(of: #"\s*,\s*"#, with: ", ", options: .regularExpression)
            .replacingOccurrences(of: #"\s*&\s*"#, with: " & ", options: .regularExpression)
    }

    static func roman(_ number: Int) -> String {
        guard number > 0, number < 4000 else { return "\(number)" }
        let table = [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"),
                     (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
        var remaining = number, result = ""
        for (value, numeral) in table {
            while remaining >= value { result += numeral; remaining -= value }
        }
        return result
    }

    /// Page ranges in the style's page-range-format, joined by an en dash.
    func pageRange(_ value: String) -> String {
        let pattern = try! NSRegularExpression(pattern: #"([A-Za-z]*)(\d+)\s*[-–—]+\s*([A-Za-z]*)(\d+)"#)
        let source = value as NSString
        var result = ""
        var last = 0
        for match in pattern.matches(in: value, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: last, length: match.range.location - last))
            let prefix = source.substring(with: match.range(at: 1)), endPrefix = source.substring(with: match.range(at: 3))
            let start = source.substring(with: match.range(at: 2)), end = source.substring(with: match.range(at: 4))
            // "S286-S289": the letters stay on both ends; only the digits shorten.
            let second = endPrefix + (prefix == endPrefix ? Self.collapse(start, end, format: style.pageRangeFormat) : end)
            result += prefix + start + (locale.term("page-range-delimiter") ?? "–") + second
            last = NSMaxRange(match.range)
        }
        result += source.substring(from: last)
        return result
    }

    static func collapse(_ start: String, _ end: String, format: String?) -> String {
        guard let format, let first = Int(start), Int(end) != nil else { return end }
        // Expand an abbreviated end ("321-28") before shortening it again.
        var full = end
        if end.count < start.count { full = String(start.prefix(start.count - end.count)) + end }
        guard let last = Int(full), last > first, full.count == start.count else { return full }
        func minimal(keeping minimum: Int) -> String {
            let a = Array(start), b = Array(full)
            var index = 0
            while index < b.count - minimum, a[index] == b[index] { index += 1 }
            return String(b[index...])
        }
        switch format {
        case "expanded": return full
        case "minimal": return minimal(keeping: 1)
        case "minimal-two": return minimal(keeping: min(2, full.count))
        case "chicago", "chicago-15", "chicago-16":
            if first < 100 || first % 100 == 0 { return full }
            if first % 100 < 10 { return minimal(keeping: 1) }
            let shortened = minimal(keeping: min(2, full.count))
            // Chicago 15 writes all digits when three or more change in a four-digit number.
            if format != "chicago-16", start.count == 4, shortened.count >= 3 { return full }
            return shortened
        default: return full
        }
    }

    // MARK: Dates

    private func date(_ node: CSLNode) -> CSLRendered {
        guard let variable = node["variable"] else { return .nothing }
        guard !suppressed.contains(variable), let date = item.date(variable) else {
            return CSLRendered(out: .empty, calledVariable: true)
        }
        renderedVariables.insert(variable)
        let parts = dateParts(node)
        if mode == .sort {
            return CSLRendered(out: .text(sortKey(date, parts: parts.map { $0["name"] ?? "" })), calledVariable: true, renderedVariable: true)
        }
        if date.parts.isEmpty {
            return CSLRendered(out: decorate(.text(date.literal ?? ""), node), calledVariable: true, renderedVariable: true)
        }
        let delimiter = node["form"] == nil ? node["delimiter"] : nil
        var out: CSLOut
        if date.parts.count > 1, date.parts[0] != date.parts[1] {
            out = range(date.parts[0], date.parts[1], parts: parts, delimiter: delimiter, season: date.season)
        } else {
            out = .joined(parts.map { datePart($0, date.parts[0], season: date.season) }, delimiter: delimiter)
        }
        out = decorate(out, node)
        return CSLRendered(out: out, calledVariable: true, renderedVariable: !out.isEmpty)
    }

    /// The date-part elements to render: a localized date's from the locale,
    /// filtered by date-parts and adjusted by the style's own date-parts.
    private func dateParts(_ node: CSLNode) -> [CSLNode] {
        guard let form = node["form"], let localized = locale.dateFormats[form] else { return node.children("date-part") }
        let allowed: Set<String> = switch node["date-parts"] ?? "year-month-day" {
        case "year": ["year"]
        case "year-month": ["year", "month"]
        default: ["year", "month", "day"]
        }
        return localized.children("date-part").compactMap { part in
            guard let name = part["name"], allowed.contains(name) else { return nil }
            var merged = part
            if let override = node.children("date-part").first(where: { $0["name"] == name }) {
                for (key, value) in override.attributes where key != "prefix" && key != "suffix" { merged.attributes[key] = value }
            }
            return merged
        }
    }

    private func datePart(_ node: CSLNode, _ values: [Int], season: String?) -> CSLOut {
        let year = values.first, month = values.count > 1 ? values[1] : nil, day = values.count > 2 ? values[2] : nil
        var text: String?
        switch node["name"] {
        case "year":
            guard let year else { break }
            if node["form"] == "short" {
                text = String(format: "%02d", abs(year) % 100)
            } else if year < 0 {
                text = "\(-year)" + (locale.term("bc") ?? "BC")
            } else if year < 1000 {
                text = "\(year)" + (locale.term("ad") ?? "AD")
            } else {
                text = "\(year)"
            }
        case "month":
            if let month, (13...16).contains(month) {
                text = locale.term(String(format: "season-%02d", month - 12))
            } else if let month, (1...12).contains(month) {
                switch node["form"] ?? "long" {
                case "numeric": text = "\(month)"
                case "numeric-leading-zeros": text = String(format: "%02d", month)
                case let form: text = locale.term(String(format: "month-%02d", month), form: form)
                }
            } else if let season {
                text = Int(season).flatMap { locale.term(String(format: "season-%02d", $0)) } ?? season
            }
        case "day":
            guard let day, month != nil else { break }
            switch node["form"] ?? "numeric" {
            case "numeric-leading-zeros": text = String(format: "%02d", day)
            case "ordinal":
                text = locale.limitDayOrdinalsToDay1 && day != 1 ? "\(day)" : "\(day)" + locale.ordinalSuffix(day)
            default: text = "\(day)"
            }
        default: break
        }
        guard let text, !text.isEmpty else { return .empty }
        return decorate(.text(text), node)
    }

    /// "May 3–5, 2020": parts that agree are written once, the ones from the
    /// largest that differs downward are written for both ends.
    private func range(_ start: [Int], _ end: [Int], parts: [CSLNode], delimiter: String?, season: String?) -> CSLOut {
        let names = ["year", "month", "day"]
        guard let differing = names.indices.first(where: { index in
            (start.count > index ? start[index] : nil) != (end.count > index ? end[index] : nil)
        }) else {
            return .joined(parts.map { datePart($0, start, season: season) }, delimiter: delimiter)
        }
        let varying = Set(names[differing...])
        let indices = parts.indices.filter { varying.contains(parts[$0]["name"] ?? "") }
        guard let lower = indices.first, let upper = indices.last else {
            return .joined(parts.map { datePart($0, start, season: season) }, delimiter: delimiter)
        }
        let rangeDelimiter = parts.first { $0["name"] == names[differing] }?["range-delimiter"] ?? "–"
        func run(_ values: [Int], dropsSuffix: Bool) -> [CSLOut] {
            parts[lower...upper].enumerated().map { offset, part in
                var part = part
                if dropsSuffix, lower + offset == upper { part.attributes["suffix"] = nil }
                return datePart(part, values, season: season)
            }
        }
        let before = parts[..<lower].map { datePart($0, start, season: season) }
        let after = parts[(upper + 1)...].map { datePart($0, start, season: season) }
        let middle = CSLOut.group([.joined(run(start, dropsSuffix: true), delimiter: delimiter), .text(rangeDelimiter),
                                   .joined(run(end, dropsSuffix: false), delimiter: delimiter)])
        return .joined(before + [middle] + after, delimiter: delimiter)
    }

    private func sortKey(_ date: CSLDate, parts names: [String]) -> String {
        let wanted = names.isEmpty ? ["year", "month", "day"] : names
        func key(_ values: [Int]) -> String {
            let year = wanted.contains("year") ? (values.first ?? 0) + 50_000 : 0
            let month = wanted.contains("month") && values.count > 1 ? values[1] : 0
            let day = wanted.contains("day") && values.count > 2 ? values[2] : 0
            return String(format: "%06d%02d%02d", year, month, day)
        }
        return date.parts.map(key).joined(separator: "-")
    }

    // MARK: Names

    private var namesStack: [CSLNode] = []

    private func names(_ node: CSLNode) -> CSLRendered {
        let variables = (node["variable"] ?? "").split(separator: " ").map(String.init)
        // Inside cs:substitute a bare <names variable="..."/> borrows the
        // enclosing cs:names' name, et-al and label.
        let outer = namesStack.last
        let nameNode = node.child("name") ?? outer?.child("name")
        let etAlNode = node.child("et-al") ?? outer?.child("et-al")
        let labelNode = node.child("label") ?? outer?.child("label")
        let labelFirst: Bool = {
            let source = node.child("name") != nil || node.child("label") != nil ? node : (outer ?? node)
            let order = source.children.map(\.name)
            guard let label = order.firstIndex(of: "label"), let name = order.firstIndex(of: "name") else { return false }
            return label < name
        }()

        var lists: [(variable: String, names: [CSLName])] = variables.compactMap { variable in
            guard !suppressed.contains(variable) else { return nil }
            let names = item.names(variable)
            return names.isEmpty ? nil : (variable, names)
        }
        // An editor who is also the translator is named once.
        if let editor = lists.firstIndex(where: { $0.variable == "editor" }),
           let translator = lists.firstIndex(where: { $0.variable == "translator" }),
           lists[editor].names == lists[translator].names {
            lists[editor].variable = "editortranslator"
            lists.remove(at: translator)
        }

        var rendered: CSLOut = .empty
        if !lists.isEmpty {
            let parts: [CSLOut] = lists.map { list in
                let namesOut = nameList(list.names, nameNode: nameNode, etAlNode: etAlNode)
                guard let labelNode, nameNode?["form"] != "count" else { return namesOut }
                let term = locale.term(list.variable, form: labelNode["form"] ?? "long", plural: list.names.count > 1) ?? ""
                let labelOut = decorate(.text(term), labelNode)
                return .group(labelFirst ? [labelOut, namesOut] : [namesOut, labelOut])
            }
            for list in lists { renderedVariables.insert(list.variable) }
            rendered = decorate(.joined(parts, delimiter: node["delimiter"] ?? nameOptions["names-delimiter"]), node)
        } else if let substitute = node.child("substitute") {
            namesStack.append(node)
            substituteDepth += 1
            for child in substitute.children {
                let before = renderedVariables
                let result = render(child)
                if !result.out.isEmpty {
                    suppressed.formUnion(renderedVariables.subtracting(before))
                    rendered = decorate(result.out, node)
                    break
                }
            }
            substituteDepth -= 1
            namesStack.removeLast()
        }

        if substituteDepth == 0, namesStack.isEmpty {
            if capturesAuthor, capturedAuthor == nil, !rendered.isEmpty {
                capturedAuthor = rendered
            }
            if suppressAuthor, !rendered.isEmpty {
                suppressAuthor = false
                return CSLRendered(out: .empty, calledVariable: true, renderedVariable: true)
            }
        }
        return CSLRendered(out: rendered, calledVariable: true, renderedVariable: !rendered.isEmpty)
    }

    private func option(_ key: String, _ nameNode: CSLNode?) -> String? { nameNode?[key] ?? nameOptions[key] }

    private func nameList(_ names: [CSLName], nameNode: CSLNode?, etAlNode: CSLNode?) -> CSLOut {
        let subsequent = mode == .citation && cite.position != nil && cite.position != .first
        var etAlMin = Int(option("et-al-min", nameNode) ?? "") ?? 0
        var useFirst = Int(option("et-al-use-first", nameNode) ?? "") ?? 0
        var useLast = option("et-al-use-last", nameNode) == "true"
        if subsequent {
            if let value = option("et-al-subsequent-min", nameNode).flatMap(Int.init) { etAlMin = value }
            if let value = option("et-al-subsequent-use-first", nameNode).flatMap(Int.init) { useFirst = value }
        }
        if let sortNames {
            if let value = sortNames.min { etAlMin = value }
            if let value = sortNames.useFirst { useFirst = value }
            if let value = sortNames.useLast { useLast = value }
        }
        let truncated = etAlMin > 0 && names.count >= etAlMin && useFirst < names.count && useFirst > 0
        let shown = truncated ? Array(names.prefix(useFirst)) : names

        if option("form", nameNode) == "count" {
            return .text(shown.isEmpty ? "" : "\(shown.count)")
        }

        let delimiter = option("delimiter", nameNode) ?? ", "
        let sortOrder = mode == .sort ? "all" : option("name-as-sort-order", nameNode)
        func inverted(_ index: Int) -> Bool { sortOrder == "all" || (sortOrder == "first" && index == 0) }
        let andTerm: String? = switch option("and", nameNode) {
        case "text": locale.term("and")
        case "symbol": "&"
        default: nil
        }

        var parts: [CSLOut] = []
        for (index, name) in shown.enumerated() {
            if index > 0 {
                if index == shown.count - 1, !truncated, let andTerm {
                    let precedes: Bool = switch option("delimiter-precedes-last", nameNode) ?? "contextual" {
                    case "always": true
                    case "never": false
                    case "after-inverted-name": inverted(index - 1)
                    default: shown.count >= 3
                    }
                    parts.append(.text((precedes ? delimiter : " ") + andTerm + " "))
                } else {
                    parts.append(.text(delimiter))
                }
            }
            parts.append(format(name, inverted: inverted(index), nameNode: nameNode))
        }
        if truncated {
            if useLast, names.count >= useFirst + 2, let last = names.last {
                parts.append(.text(delimiter + "… "))
                parts.append(format(last, inverted: inverted(names.count - 1), nameNode: nameNode))
            } else if let etAl = locale.term(etAlNode?["term"] ?? "et-al") {
                let precedes: Bool = switch option("delimiter-precedes-et-al", nameNode) ?? "contextual" {
                case "always": true
                case "never": false
                case "after-inverted-name": inverted(shown.count - 1)
                default: shown.count >= 2
                }
                parts.append(.text(precedes ? delimiter : " "))
                parts.append(etAlNode.map { decorate(.text(etAl), $0) } ?? .text(etAl))
            }
        }
        let out = CSLOut.group(parts)
        return nameNode.map { decorate(out, $0) } ?? out
    }

    private func format(_ name: CSLName, inverted: Bool, nameNode: CSLNode?) -> CSLOut {
        let partNodes = nameNode?.children("name-part") ?? []
        func part(_ which: String, _ text: String) -> CSLOut {
            guard let node = partNodes.first(where: { $0["name"] == which }) else { return .text(text) }
            return decorate(.text(text), node)
        }
        if let literal = name.literal { return part("family", literal) }

        let family = name.family ?? ""
        let particle = name.nonDroppingParticle
        let form = mode == .sort ? "long" : forcesShortNames ? "short" : option("form", nameNode) ?? "long"
        let demote = style.demoteNonDroppingParticle
        if form == "short" || name.given == nil {
            return part("family", [particle, family].compactMap { $0 }.joined(separator: " "))
        }
        var given = initialize(name.given ?? "", nameNode: nameNode)
        if let dropping = name.droppingParticle { given += " " + dropping }
        let suffix = name.suffix

        if Self.isCJK(family) {
            return .group([part("family", family), part("given", given)])
        }
        if !inverted {
            var pieces: [CSLOut] = [part("given", given), .text(" "),
                                    part("family", [particle, family].compactMap { $0 }.joined(separator: " "))]
            if let suffix { pieces.append(.text((name.commaSuffix ? ", " : " ") + suffix)) }
            return .group(pieces)
        }
        let separator = option("sort-separator", nameNode) ?? ", "
        var pieces: [CSLOut]
        if demote == "display-and-sort" || (demote == "sort-only" && mode == .sort) {
            pieces = [part("family", family), .text(separator),
                      part("given", [given, particle].compactMap { $0 }.joined(separator: " "))]
        } else {
            pieces = [part("family", [particle, family].compactMap { $0 }.joined(separator: " ")), .text(separator), part("given", given)]
        }
        if let suffix { pieces.append(.text(separator + suffix)) }
        return .group(pieces)
    }

    /// "John Paul" → "J. P.", "Jean-Paul" → "J.-P." with initialize-with=". ".
    private func initialize(_ given: String, nameNode: CSLNode?) -> String {
        guard let with = option("initialize-with", nameNode) else { return given }
        let initializes = option("initialize", nameNode) != "false"
        let trimmed = with.trimmingCharacters(in: .whitespaces)
        var tokens: [(text: String, isInitial: Bool)] = []
        for word in given.split(separator: " ") {
            // "J.R.R." is three initials.
            if word.range(of: #"^(\p{Lu}\.)+$"#, options: .regularExpression) != nil {
                tokens += word.split(separator: ".").map { (String($0) + with, true) }
                continue
            }
            let pieces = word.split(separator: "-", omittingEmptySubsequences: true)
            let converted = pieces.map { piece -> (String, Bool) in
                let bare = piece.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                let isInitial = bare.count == 1
                guard (initializes || isInitial), let first = bare.first else { return (String(piece), false) }
                return (first.uppercased(), true)
            }
            if converted.allSatisfy(\.1) {
                let joiner = style.initializeWithHyphen ? trimmed + "-" : trimmed
                tokens.append((converted.map(\.0).joined(separator: joiner) + with, true))
            } else {
                tokens.append((converted.map { $0.1 ? $0.0 + trimmed : $0.0 }.joined(separator: "-"), false))
            }
        }
        var result = ""
        var afterInitial = false
        for token in tokens {
            if !result.isEmpty, !result.hasSuffix(" "), !(token.isInitial && afterInitial) { result += " " }
            result += token.text
            afterInitial = token.isInitial
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func isCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3040...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
    }
}
