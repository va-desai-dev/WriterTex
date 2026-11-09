//
//  BibDocument.swift
//  WriterTex
//
//  One .bib file, edited as text.
//
//  Writerly owned its library and could rewrite it wholesale. An IDE does not
//  own the user's .bib: it is hand-edited, version-controlled, full of comments,
//  @string macros and fields no emitter knows about. So nothing here ever
//  regenerates the file. Removal cuts an entry's exact character range; capture
//  appends new text at the end. Everything else is left byte-for-byte alone.
//

import Foundation

nonisolated struct BibEntry: Identifiable, Equatable, Sendable {
    /// The key, made unique within the file (`key#2`) so a .bib that repeats a
    /// key can still be listed and selected. Use `key` for citing.
    let id: String
    let key: String
    /// The raw entry type as written — `article`, `inproceedings`, …
    let entryType: String
    let citation: Citation
    /// 1-based line of the `@`, for jumping the editor to the entry.
    let line: Int
    /// True for the second and later entries sharing a key. BibTeX keeps the
    /// first and warns; biber errors. Either way the user should know.
    let isDuplicateKey: Bool
    let range: Range<Int>
}

nonisolated struct BibDocument: Sendable {
    private(set) var text: String
    private(set) var entries: [BibEntry] = []
    /// Written back in the encoding it was read in, so saving an old Latin-1
    /// file does not silently re-encode every accented byte in it.
    private(set) var encoding: String.Encoding

    init(text: String, encoding: String.Encoding = .utf8) {
        self.text = text
        self.encoding = encoding
        reparse()
    }

    /// From raw bytes, for files that arrive over a project's own file system
    /// (an SSH workspace, say) rather than from a local path.
    init(data: Data) {
        // Most .bib files are UTF-8; old BibTeX-era files are often Latin-1.
        // Fall back rather than refusing to show the file at all.
        if let text = String(data: data, encoding: .utf8) {
            self.init(text: text, encoding: .utf8)
        } else if let text = String(data: data, encoding: .isoLatin1) {
            self.init(text: text, encoding: .isoLatin1)
        } else {
            self.init(text: String(decoding: data, as: UTF8.self))
        }
    }

    init(contentsOf url: URL) throws {
        self.init(data: try Data(contentsOf: url))
    }

    /// The text in its original encoding — or UTF-8, when a capture added
    /// characters Latin-1 cannot hold.
    var data: Data {
        text.data(using: encoding) ?? Data(text.utf8)
    }

    func write(to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    var keys: Set<String> { Set(entries.map(\.key)) }

    /// The entry exactly as it appears in the file.
    func source(of entry: BibEntry) -> String {
        let chars = Array(text)
        guard entry.range.upperBound <= chars.count else { return "" }
        return String(chars[entry.range])
    }

    private mutating func reparse() {
        var seen: [String: Int] = [:]
        entries = BibTeXParser.entries(text).compactMap { raw in
            // @string/@comment/@preamble never reach here; skip keyless junk.
            guard !raw.key.isEmpty else { return nil }
            let n = (seen[raw.key] ?? 0) + 1
            seen[raw.key] = n
            return BibEntry(
                id: n == 1 ? raw.key : "\(raw.key)#\(n)",
                key: raw.key,
                entryType: raw.type.lowercased(),
                citation: BibTeXParser.citation(from: raw),
                line: raw.line,
                isDuplicateKey: n > 1,
                range: raw.range
            )
        }
    }

    // MARK: - Removing

    /// Cuts the chosen entries out of the text. Returns how many were removed.
    @discardableResult
    mutating func remove(ids: Set<String>) -> Int {
        let doomed = entries.filter { ids.contains($0.id) }
            .sorted { $0.range.lowerBound > $1.range.lowerBound }
        guard !doomed.isEmpty else { return 0 }

        var chars = Array(text)
        for entry in doomed {
            // Take the entry's own line ending and at most one blank line after
            // it, so removals do not leave growing gaps. Anything else nearby —
            // a comment describing the entry, say — is the user's and stays.
            var end = entry.range.upperBound
            while end < chars.count, chars[end] == " " || chars[end] == "\t" { end += 1 }
            var newlines = 0
            while end < chars.count, chars[end].isNewline, newlines < 2 {
                end += 1
                newlines += 1
            }
            chars.removeSubrange(entry.range.lowerBound..<end)
        }
        text = String(chars)
        reparse()
        return doomed.count
    }

    // MARK: - Editing one entry

    /// The entry's fields as written — LaTeX undecoded, `@string` macros
    /// unexpanded — which is what an editor must show to write back losslessly.
    func rawEntry(_ entry: BibEntry) -> BibTeXParser.Entry? {
        BibTeXParser.entries(source(of: entry)).first
    }

    /// Swaps one entry's exact character range for `replacement`. Fails when
    /// the entry is gone or no longer reads `expected` — the file changed
    /// under the editor, and that change must not be overwritten.
    @discardableResult
    mutating func replace(id: String, expected: String, with replacement: String) -> Bool {
        guard let entry = entries.first(where: { $0.id == id }), source(of: entry) == expected else {
            return false
        }
        var chars = Array(text)
        chars.replaceSubrange(entry.range, with: Array(replacement))
        text = String(chars)
        reparse()
        return true
    }

    /// One entry's source from raw field values, braced verbatim: they are
    /// LaTeX the user wrote, so nothing is escaped.
    static func source(type: String, key: String, fields: [(name: String, value: String)]) -> String {
        let body = fields.filter { !$0.name.isEmpty }
            .map { "  \($0.name) = {\($0.value)}" }
            .joined(separator: ",\n")
        return "@\(type){\(key),\n\(body)\n}"
    }

    // MARK: - Appending

    struct AppendReport: Sendable {
        var added: [String] = []           // keys actually written
        var skipped = 0                    // already in the file
        var renamed = 0                    // key collided with a different work

        var summary: String {
            var bits: [String] = []
            if !added.isEmpty {
                bits.append(added.count == 1 ? "Added @\(added[0])" : "Added \(added.count) entries")
            }
            if skipped > 0 { bits.append("skipped \(skipped) already present") }
            if renamed > 0 { bits.append("disambiguated \(renamed) clashing keys") }
            return bits.isEmpty ? "Nothing to add." : bits.joined(separator: ", ") + "."
        }
    }

    /// Appends new records at the end of the file.
    ///
    /// A record is skipped when the file already holds the same work — same DOI
    /// under any key, or same key and title. Scraped keys are minted
    /// (`smith2020neural`) and rarely match a hand-chosen key, so the DOI check
    /// is what actually stops a second capture of a paper from duplicating it.
    /// A key that collides with a *different* work gets a suffix; existing
    /// entries are never touched, so a manuscript's citations keep resolving.
    @discardableResult
    mutating func append(_ incoming: [Citation]) -> AppendReport {
        var report = AppendReport()
        var taken = keys
        var titleByKey: [String: String] = [:]
        var dois = Set<String>()
        for e in entries {
            titleByKey[e.key] = titleByKey[e.key] ?? e.citation.title.lowercased()
            if let d = e.citation.doi?.lowercased(), !d.isEmpty { dois.insert(d) }
        }

        var fresh: [Citation] = []
        for var rec in incoming {
            if let d = rec.doi?.lowercased(), !d.isEmpty, dois.contains(d) {
                report.skipped += 1
                continue
            }
            if let existing = titleByKey[rec.id] {
                if existing == rec.title.lowercased() {
                    report.skipped += 1
                    continue
                }
                rec.id = Self.uniqueKey(rec.id, taken: taken)
                report.renamed += 1
            }
            taken.insert(rec.id)
            titleByKey[rec.id] = rec.title.lowercased()
            if let d = rec.doi?.lowercased(), !d.isEmpty { dois.insert(d) }
            fresh.append(rec)
            report.added.append(rec.id)
        }
        guard !fresh.isEmpty else { return report }

        var out = text
        if !out.isEmpty {
            if !(out.last?.isNewline ?? true) { out += "\n" }
            out += "\n"
        }
        out += BibTeX.document(fresh)
        text = out
        reparse()
        return report
    }

    /// Give `proposed` a key nothing else is using: `smith2020b`, `smith2020c`, …
    static func uniqueKey(_ proposed: String, taken: Set<String>) -> String {
        for suffix in "bcdefghijklmnopqrstuvwxyz" {
            let candidate = proposed + String(suffix)
            if !taken.contains(candidate) { return candidate }
        }
        var n = 2
        while taken.contains("\(proposed)-\(n)") { n += 1 }
        return "\(proposed)-\(n)"
    }
}
