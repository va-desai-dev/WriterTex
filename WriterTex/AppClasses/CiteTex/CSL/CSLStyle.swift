//
//  CSLStyle.swift
//  WriterTex
//

import Foundation

/// A parsed `.csl` file.
nonisolated struct CSLStyle: Sendable {
    let id: String
    let title: String
    /// Footnote styles, which CSLKit doesn't lay out yet.
    let isNoteStyle: Bool
    /// For a dependent style, the id of the style whose rules it uses (the last
    /// path component of its `independent-parent` link, e.g. "apa").
    let parentID: String?
    let defaultLocale: String?

    let root: CSLNode
    let macros: [String: CSLNode]
    let citation: CSLNode?
    let bibliography: CSLNode?
    let localeOverrides: [CSLNode]

    init(xml data: Data) throws {
        root = try CSLNode.parse(data)
        guard root.name == "style" else { throw CSLError.notAStyle }
        let info = root.child("info")
        title = info?.child("title")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Untitled Style"
        let rawID = info?.child("id")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        id = Self.shortID(rawID)
        parentID = info?.children("link").first { $0["rel"] == "independent-parent" }?["href"].map(Self.shortID)
        isNoteStyle = root["class"] == "note"
        defaultLocale = root["default-locale"]
        macros = Dictionary(root.children("macro").compactMap { node in node["name"].map { ($0, node) } }) { first, _ in first }
        citation = root.child("citation")
        bibliography = root.child("bibliography")
        localeOverrides = root.children("locale")
    }

    /// A dependent style only names its parent and carries no layout of its own.
    var isDependent: Bool { citation == nil && parentID != nil }

    /// "http://www.zotero.org/styles/apa" → "apa".
    static func shortID(_ id: String) -> String {
        guard let last = id.split(separator: "/").last else { return id }
        return String(last)
    }

    /// Name options set on the style and on `section` (citation or
    /// bibliography), which every `cs:names` inherits.
    func inheritedNameOptions(for section: CSLNode?) -> [String: String] {
        let keys: Set<String> = ["and", "delimiter-precedes-et-al", "delimiter-precedes-last", "et-al-min",
                                 "et-al-use-first", "et-al-use-last", "et-al-subsequent-min",
                                 "et-al-subsequent-use-first", "initialize", "initialize-with",
                                 "name-as-sort-order", "sort-separator", "name-form", "name-delimiter",
                                 "names-delimiter"]
        var options: [String: String] = [:]
        for node in [root, section].compactMap({ $0 }) {
            for (key, value) in node.attributes where keys.contains(key) { options[key] = value }
        }
        // `name-form` and `name-delimiter` are the inheritable spellings of
        // cs:name's `form` and `delimiter`.
        if let form = options.removeValue(forKey: "name-form") { options["form"] = form }
        if let delimiter = options.removeValue(forKey: "name-delimiter") { options["delimiter"] = delimiter }
        return options
    }

    var pageRangeFormat: String? { root["page-range-format"] }
    var initializeWithHyphen: Bool { root["initialize-with-hyphen"] != "false" }
    var demoteNonDroppingParticle: String { root["demote-non-dropping-particle"] ?? "display-and-sort" }
}
