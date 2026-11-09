//
//  Item.swift
//  DFeZY
//
//  Created by Vedant A. Desai on 9/13/26.
//

import Foundation
import SwiftData
import SwiftUI
import Observation

/// A parsed CSV as a value.
///
/// `CSVStorage` below is a mutable class the grid edits in place, which is what
/// the grid wants and exactly what a parsed dataset cannot be: it is parsed
/// off the main actor and has to be `Sendable`. So the model carries one of
/// these and the view turns it into storage. `nonisolated` because the
/// target's default isolation is `MainActor`.
nonisolated struct CSVTable: Sendable {
    var columns: [String] = []
    var rows: [[String]] = []

    /// No columns means there was no header row to read, so nothing to table.
    var isEmpty: Bool { self.columns.isEmpty }

    /// Each column's type as its cells read, for any column not given one.
    func inferredTypes(missingCodes: Set<String>) -> [Int: CSVArrangement.VariableFlag] {
        Dictionary(uniqueKeysWithValues: self.columns.indices.map { column in
            (column, .inferred(from: self.rows.lazy.map { column < $0.count ? $0[column] : "" }, missingCodes: missingCodes))
        })
    }
}

nonisolated extension CSVArrangement.VariableFlag {
    /// Text repeating at most this many levels reads as a factor.
    static let factorLevelLimit = 20

    /// The type every value in a column fits, skipping blanks and missing codes:
    /// logical for only 0/1, yes/no or true/false in any case; integer, then
    /// numeric, for numbers; date, time or date-time for ISO 8601; factor for
    /// text that repeats a few levels; character otherwise, including a column
    /// with no values to read. Numeric codes stay numbers: whether 1, 2, 3 are
    /// categories is the analyst's call.
    static func inferred(from cells: some Sequence<String>, missingCodes: Set<String>) -> Self {
        var logical = true, integer = true, numeric = true
        var iso: Self??
        var levels: Set<String> = []
        var count = 0
        for cell in cells {
            let value = cell.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !missingCodes.contains(value) else { continue }
            count += 1
            if logical {
                logical = ["0", "1", "yes", "no", "true", "false", "on", "off"]
                    .contains(value.lowercased())
            }
            if integer { integer = Int(value) != nil }
            if numeric { numeric = Double(value)?.isFinite == true }
            if iso != .some(nil) {
                let kind = Self.isoKind(value)
                iso = iso == nil || iso == kind ? kind : .some(nil)
            }
            if levels.count <= Self.factorLevelLimit { levels.insert(value) }
        }
        if count == 0 { return .character }
        if logical { return .logical }
        if integer { return .integer }
        if numeric { return .numeric }
        if let kind = iso ?? nil { return kind }
        return levels.count <= Self.factorLevelLimit && levels.count * 2 <= count ? .factor : .character
    }

    /// `2026-11-05` is a date, `14:30` or `14:30:05.25` a time, and the two
    /// joined by `T` or a space, with an optional `Z` or `+05:30`, a date-time.
    static func isoKind(_ value: String) -> Self? {
        let bytes = Array(value.utf8)
        func number(_ start: Int, _ length: Int, _ range: ClosedRange<Int>) -> Bool {
            guard start + length <= bytes.count else { return false }
            var total = 0
            for byte in bytes[start..<start + length] {
                guard (48...57).contains(byte) else { return false }
                total = total * 10 + Int(byte - 48)
            }
            return range.contains(total)
        }
        func byte(_ index: Int, _ character: Character) -> Bool { index < bytes.count && bytes[index] == character.asciiValue }
        /// Where a time starting at `start` ends, or nil when there is none.
        func time(at start: Int) -> Int? {
            guard number(start, 2, 0...23), byte(start + 2, ":"), number(start + 3, 2, 0...59) else { return nil }
            var end = start + 5
            if byte(end, ":") {
                guard number(end + 1, 2, 0...60) else { return nil }
                end += 3
                if byte(end, ".") {
                    end += 1
                    let digits = end
                    while end < bytes.count, (48...57).contains(bytes[end]) { end += 1 }
                    guard end > digits else { return nil }
                }
            }
            return end
        }
        let isDate = number(0, 4, 0...9999) && byte(4, "-") && number(5, 2, 1...12) && byte(7, "-") && number(8, 2, 1...31)
        if isDate, bytes.count == 10 { return .date }
        if isDate, byte(10, "T") || byte(10, " "), let end = time(at: 11) {
            if end == bytes.count || (byte(end, "Z") && end + 1 == bytes.count) { return .datetime }
            if byte(end, "+") || byte(end, "-"), number(end + 1, 2, 0...23) {
                let minutes = byte(end + 3, ":") ? end + 4 : end + 3
                if number(minutes, 2, 0...59), minutes + 2 == bytes.count { return .datetime }
            }
            return nil
        }
        if let end = time(at: 0), end == bytes.count { return .time }
        return nil
    }
}

/// Flat, unobserved memory footprint designed to handle millions of cells instantly
final class CSVStorage {
    var columns: [String] = []
    var rows: [[String]] = []

    static let empty = CSVStorage()

    init() { }

    init(_ table: CSVTable) {
        self.columns = table.columns
        self.rows = table.rows
    }

    /// A snapshot of the current cells, to hand back to a model or write to disk.
    var table: CSVTable {
        CSVTable(columns: self.columns, rows: self.rows)
    }

    func clear() {
        columns.removeAll()
        rows.removeAll()
    }
}

/// A view-only sort + filter over a `CSVStorage`, the way Numbers' column menu
/// works: the rules reorder and hide rows for display and never touch the
/// file's record order, so arranging a table doesn't dirty the document.
///
/// `visibleRows` is the indirection the grid draws through — display row *n* is
/// `storage.rows[visibleRows[n]]`. Everything that used to index `rows` by a
/// screen position has to go through it, or a sorted edit lands on the wrong
/// record.
final class CSVArrangement {

    enum Direction: Hashable {
        case ascending, descending
    }

    nonisolated enum VariableFlag: String, CaseIterable, Identifiable, Codable, Sendable {
        case logical = "Logical"
        case character = "Character"
        case integer = "Integer"
        case numeric = "Numeric"
        case datetime = "DateTime"
        case date = "Date"
        case time = "Time"
        case factor = "Factor"
        case skip = "Skip"
        var id: String { self.rawValue }

        var icon: String {
            switch self {
                case .logical: "switch.2"
                case .character: "textformat"
                case .integer: "textformat.numbers"
                case .numeric: "number.sign"
                case .datetime: "clock"
                case .date: "calendar"
                case .time: "hourglass"
                case .factor: "chart.pie"
                case .skip: "nosign"
            }
        }
    }
    /// Numbers' filter conditions. The two emptiness tests take no operand,
    /// which is what `needsValue` drives in the popover.
    enum Condition: String, CaseIterable, Identifiable {
        case contains = "contains"
        case doesNotContain = "does not contain"
        case equals = "is"
        case doesNotEqual = "is not"
        case beginsWith = "begins with"
        case endsWith = "ends with"
        case isEmpty = "is empty"
        case isNotEmpty = "is not empty"

        var id: String { self.rawValue }
        var needsValue: Bool { self != .isEmpty && self != .isNotEmpty }

        func matches(_ field: String, _ value: String) -> Bool {
            switch self {
            case .contains: field.localizedCaseInsensitiveContains(value)
            case .doesNotContain: !field.localizedCaseInsensitiveContains(value)
            case .equals: field.caseInsensitiveCompare(value) == .orderedSame
            case .doesNotEqual: field.caseInsensitiveCompare(value) != .orderedSame
            case .beginsWith: field.lowercased().hasPrefix(value.lowercased())
            case .endsWith: field.lowercased().hasSuffix(value.lowercased())
            case .isEmpty: field.isEmpty
            case .isNotEmpty: !field.isEmpty
            }
        }
    }

    struct Filter: Equatable {
        var condition: Condition = .contains
        var value: String = ""

        /// `contains ""` matches every row, so treat a half-typed rule as no
        /// rule rather than blanking the table while the user types.
        var isActive: Bool { !self.condition.needsValue || !self.value.isEmpty }
    }

    /// The sort and filters, apart from the row order they produce, so the
    /// notebook can keep them for a dataset while grids come and go.
    struct Rules: Equatable {
        var sortColumn: Int?
        var sortDirection: Direction = .ascending
        var filters: [Int: Filter] = [:]

        func direction(for column: Int) -> Direction? {
            self.sortColumn == column ? self.sortDirection : nil
        }

        func filter(for column: Int) -> Filter { self.filters[column] ?? Filter() }

        /// Sort is single-column, like clicking a header: setting one replaces
        /// any other. Filters accumulate across columns.
        mutating func set(column: Int, direction: Direction?, filter: Filter) {
            if let direction {
                self.sortColumn = column
                self.sortDirection = direction
            } else if self.sortColumn == column {
                self.sortColumn = nil
            }
            self.filters[column] = filter.isActive ? filter : nil
        }

        /// The same rules after columns move; a column `transform` maps to nil
        /// was deleted, and its rules go with it.
        func mappingColumns(_ transform: (Int) -> Int?) -> Rules {
            var rules = Rules(sortColumn: self.sortColumn.flatMap(transform), sortDirection: self.sortDirection)
            for (column, filter) in self.filters {
                if let moved = transform(column) { rules.filters[moved] = filter }
            }
            return rules
        }
    }

    /// Shared identity arrangement, for a grid with no container attached yet.
    static let identity = CSVArrangement()

    var rules = Rules()

    /// Display row → storage row.
    private(set) var visibleRows: [Int] = []

    var rowCount: Int { self.visibleRows.count }

    /// The storage row behind a display row, or nil past the end.
    func storageRow(_ displayRow: Int) -> Int? {
        self.visibleRows.indices.contains(displayRow) ? self.visibleRows[displayRow] : nil
    }

    func isSorted(_ column: Int) -> Bool { self.rules.sortColumn == column }

    func isFiltered(_ column: Int) -> Bool { self.rules.filters[column]?.isActive == true }

    /// Whether a column's rules decide what shows or in what order — an edit to
    /// such a column has to rebuild, since the row may now belong elsewhere.
    func affectsArrangement(column: Int) -> Bool {
        self.isSorted(column) || self.isFiltered(column)
    }

    /// Recomputes `visibleRows`: O(rows) filtering, O(rows log rows) sorting.
    /// Cheap enough to run on every rule change and after edits to a ruled
    /// column, which is the only thing that keeps the mapping honest.
    func rebuild(from storage: CSVStorage) {
        let active = self.rules.filters
            .filter(\.value.isActive)
            .map { (column: $0.key, filter: $0.value) }

        var indices: [Int]
        if active.isEmpty {
            indices = Array(storage.rows.indices)
        } else {
            indices = storage.rows.indices.filter { row in
                active.allSatisfy {
                    $0.filter.condition.matches(Self.field(storage, row, $0.column), $0.filter.value)
                }
            }
        }

        if let column = self.rules.sortColumn {
            let ascending = self.rules.sortDirection == .ascending
            indices.sort { lhs, rhs in
                let left = Self.field(storage, lhs, column)
                let right = Self.field(storage, rhs, column)
                // Blanks sink to the bottom in both directions, like a spreadsheet.
                if left.isEmpty != right.isEmpty { return right.isEmpty }
                let order = Self.compare(left, right)
                // Swift's sort isn't stable; tie-break on file position so equal
                // keys keep their original order.
                if order == .orderedSame { return lhs < rhs }
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
        }

        self.visibleRows = indices
    }

    /// Short rows are legal CSV, so a missing cell reads as empty.
    private static func field(_ storage: CSVStorage, _ row: Int, _ column: Int) -> String {
        let cells = storage.rows[row]
        return column < cells.count ? cells[column] : ""
    }

    /// Numeric when both sides parse as numbers, so "10" sorts after "9" rather
    /// than between "1" and "2"; otherwise a localized compare, which still
    /// orders embedded digits sensibly.
    private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if let left = Double(lhs), let right = Double(rhs) {
            if left == right { return .orderedSame }
            return left < right ? .orderedAscending : .orderedDescending
        }
        return lhs.localizedStandardCompare(rhs)
    }
}

struct CSVEngine {

    /// Parses into a value, so a preview can be built off the main actor.
    nonisolated static func parse(_ text: String) -> CSVTable {
        var parsedRows: [[String]] = []
        var currentField = ""
        var currentRow: [String] = []
        var insideQuotes = false

        var iterator = text.makeIterator()
        var next = iterator.next()
        var hasRecord = false
        while let char = next {
            next = iterator.next()
            hasRecord = true
            if insideQuotes {
                if char == "\"" {
                    if next == "\"" {
                        currentField.append("\"")
                        next = iterator.next()
                    } else {
                        insideQuotes = false
                    }
                } else {
                    currentField.append(char)
                }
            } else {
                switch char {
                case "\"":
                    insideQuotes = true
                case ",":
                    currentRow.append(currentField)
                    currentField = ""
                case "\n", "\r", "\r\n":
                    currentRow.append(currentField)
                    parsedRows.append(currentRow)
                    currentField = ""
                    currentRow = []
                    hasRecord = false
                default:
                    currentField.append(char)
                }
            }
        }

        if hasRecord {
            currentRow.append(currentField)
            parsedRows.append(currentRow)
        }

        guard let firstRow = parsedRows.first else { return CSVTable() }
        return CSVTable(columns: firstRow, rows: Array(parsedRows.dropFirst()))
    }

    static func parse(_ text: String, into storage: CSVStorage) {
        storage.clear()
        let table = Self.parse(text)
        storage.columns = table.columns
        storage.rows = table.rows
    }

    nonisolated static func generate(from table: CSVTable) -> String {
        var output = ""
        let escapedHeaders = table.columns.map { escapeField($0) }.joined(separator: ",")
        output.append(escapedHeaders + "\n")

        for row in table.rows {
            let escapedCells = row.map { escapeField($0) }.joined(separator: ",")
            output.append(escapedCells + "\n")
        }
        return output
    }

    static func generate(from storage: CSVStorage) -> String {
        Self.generate(from: storage.table)
    }

    nonisolated private static func escapeField(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains(where: \.isNewline) {
            let sanitized = field.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(sanitized)\""
        }
        return field
    }
}
