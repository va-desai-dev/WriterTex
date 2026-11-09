import Foundation

/// New values for a column, worked out from the others: Compute evaluates an
/// Excel-style formula for every case, and Recode maps old values to new ones
/// the way SPSS's Recode does. Both return the column's cells as text, ready to
/// write into the CSV; the model decides where they go.
///
/// Missing follows SPSS rather than Excel: a blank or missing-code cell is
/// missing, arithmetic on a missing value is missing, and SUM, MEAN, MIN and MAX
/// skip it. A missing result is written as a blank cell.
nonisolated enum DataTransform {

    /// What a run did, for the sheet to report.
    struct Summary: Equatable, Sendable {
        var cases = 0
        /// Cases whose result was missing and so written blank.
        var blank = 0
        /// Cases where a cell that isn't a number, such as `12kg`, met arithmetic.
        var notNumbers = 0
    }

    struct FormulaError: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { self.message }
    }

    /// One formula's value for every case, in row order.
    static func compute(_ formula: String, in table: CSVTable, missingCodes: Set<String>) throws -> (cells: [String], summary: Summary) {
        var parser = Parser(formula, columns: table.columns)
        let expression = try parser.parse()
        var summary = Summary(cases: table.rows.count)
        let cells = table.rows.map { row in
            var context = Context(row: row, missingCodes: missingCodes)
            let value = expression.evaluate(&context)
            if context.metText { summary.notNumbers += 1 }
            if value == .missing { summary.blank += 1 }
            return value.cell
        }
        return (cells, summary)
    }

    /// A column's cells under `rules`, the first matching rule deciding each.
    /// A cell no rule matches keeps its value when `keepsUnmatched`, as when
    /// recoding into the same variable, and is left blank otherwise.
    static func recode(_ cells: [String], rules: [RecodeRule], missingCodes: Set<String>, keepsUnmatched: Bool) -> [String] {
        cells.map { cell in
            let value = cell.trimmingCharacters(in: .whitespacesAndNewlines)
            let isMissing = value.isEmpty || missingCodes.contains(value)
            guard let rule = rules.first(where: { $0.match.matches(value, isMissing: isMissing) }) else {
                return keepsUnmatched ? cell : ""
            }
            switch rule.output {
            case .value(let new): return new
            case .blank: return ""
            case .copy: return cell
            }
        }
    }

    /// Puts `cells` in the column headed `target`, or in a new one at the end.
    static func write(_ cells: [String], into target: String, in table: inout CSVTable) throws {
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { throw FormulaError(message: "Name the variable to overwrite.") }
        let column = table.columns.firstIndex(of: target) ?? table.columns.count
        if column == table.columns.count { table.columns.append(target) }
        for row in table.rows.indices {
            while table.rows[row].count <= column { table.rows[row].append("") }
            table.rows[row][column] = cells[row]
        }
    }

    // MARK: Values

    enum Value: Equatable {
        case number(Double), text(String), missing

        /// The cell a value is written as. Numbers carry 15 significant digits,
        /// so 0.1 + 0.2 writes 0.3 rather than its binary remainder.
        var cell: String {
            switch self {
            case .number(let value): value == 0 ? "0" : String(format: "%.15g", value)
            case .text(let text): text
            case .missing: ""
            }
        }
    }

    struct Context {
        let row: [String]
        let missingCodes: Set<String>
        var metText = false

        func cell(_ column: Int) -> Value {
            let text = (column < self.row.count ? self.row[column] : "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || self.missingCodes.contains(text) { return .missing }
            if let number = Double(text), number.isFinite { return .number(number) }
            return .text(text)
        }

        /// A value arithmetic can use, or nil for missing, noting text that isn't a number.
        mutating func number(_ value: Value) -> Double? {
            switch value {
            case .number(let number): return number
            case .text: self.metText = true; return nil
            case .missing: return nil
            }
        }
    }

    // MARK: Expressions

    indirect enum Expression {
        case literal(Value)
        case column(Int)
        case negate(Expression)
        case binary(String, Expression, Expression)
        case call(Function, [Expression])

        func evaluate(_ context: inout Context) -> Value {
            switch self {
            case .literal(let value): return value
            case .column(let column): return context.cell(column)
            case .negate(let operand):
                return context.number(operand.evaluate(&context)).map { .number(-$0) } ?? .missing
            case .binary(let op, let lhs, let rhs):
                let left = lhs.evaluate(&context), right = rhs.evaluate(&context)
                switch op {
                case "&": return .text(Self.joined(left) + Self.joined(right))
                case "=", "<>", "<", ">", "<=", ">=":
                    guard left != .missing, right != .missing else { return .missing }
                    let order: ComparisonResult = if case .number(let a) = left, case .number(let b) = right {
                        a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
                    } else {
                        left.cell.caseInsensitiveCompare(right.cell)
                    }
                    let holds = switch op {
                    case "=": order == .orderedSame
                    case "<>": order != .orderedSame
                    case "<": order == .orderedAscending
                    case ">": order == .orderedDescending
                    case "<=": order != .orderedDescending
                    default: order != .orderedAscending
                    }
                    return .number(holds ? 1 : 0)
                default:
                    guard let a = context.number(left), let b = context.number(right) else { return .missing }
                    let result = switch op {
                    case "+": a + b
                    case "-": a - b
                    case "*": a * b
                    case "/": b == 0 ? .nan : a / b
                    default: pow(a, b)
                    }
                    return result.isFinite ? .number(result) : .missing
                }
            case .call(let function, let arguments):
                return function.evaluate(arguments, &context)
            }
        }

        /// `&` joins a missing value as nothing, the way Excel joins a blank.
        private static func joined(_ value: Value) -> String { value.cell }
    }

    enum Function: String, CaseIterable {
        case abs = "ABS", sqrt = "SQRT", exp = "EXP", ln = "LN", log10 = "LOG10", int = "INT", round = "ROUND"
        case sum = "SUM", mean = "MEAN", average = "AVERAGE", min = "MIN", max = "MAX"
        case `if` = "IF", and = "AND", or = "OR", not = "NOT", isBlank = "ISBLANK"

        /// How many arguments it takes.
        var arity: ClosedRange<Int> {
            switch self {
            case .abs, .sqrt, .exp, .ln, .log10, .int, .not, .isBlank: 1...1
            case .round: 1...2
            case .if: 2...3
            case .sum, .mean, .average, .min, .max, .and, .or: 1...Int.max
            }
        }

        func evaluate(_ arguments: [Expression], _ context: inout Context) -> Value {
            switch self {
            case .if:
                // Only the branch taken is evaluated, so the other can't flag text.
                guard let condition = context.number(arguments[0].evaluate(&context)) else { return .missing }
                return condition != 0 ? arguments[1].evaluate(&context)
                    : arguments.count > 2 ? arguments[2].evaluate(&context) : .missing
            case .isBlank:
                return .number(arguments[0].evaluate(&context) == .missing ? 1 : 0)
            default:
                break
            }
            var numbers: [Double] = []
            var anyMissing = false
            for argument in arguments {
                if let number = context.number(argument.evaluate(&context)) { numbers.append(number) } else { anyMissing = true }
            }
            let skipsMissing = [.sum, .mean, .average, .min, .max].contains(self)
            guard skipsMissing ? !numbers.isEmpty : !anyMissing else { return .missing }
            let result: Double = switch self {
            case .abs: Swift.abs(numbers[0])
            case .sqrt: numbers[0] < 0 ? .nan : numbers[0].squareRoot()
            case .exp: Foundation.exp(numbers[0])
            case .ln: numbers[0] <= 0 ? .nan : Foundation.log(numbers[0])
            case .log10: numbers[0] <= 0 ? .nan : Foundation.log10(numbers[0])
            case .int: numbers[0].rounded(.down)
            case .round:
                Self.rounded(numbers[0], digits: numbers.count > 1 ? Int(numbers[1]) : 0)
            case .sum: numbers.reduce(0, +)
            case .mean, .average: numbers.reduce(0, +) / Double(numbers.count)
            case .min: numbers.min()!
            case .max: numbers.max()!
            case .and: numbers.allSatisfy { $0 != 0 } ? 1 : 0
            case .or: numbers.contains { $0 != 0 } ? 1 : 0
            case .not: numbers[0] == 0 ? 1 : 0
            case .if, .isBlank: .nan
            }
            return result.isFinite ? .number(result) : .missing
        }

        /// Halves round away from zero, as in Excel and SPSS.
        private static func rounded(_ value: Double, digits: Int) -> Double {
            let scale = pow(10, Double(digits))
            return (value * scale).rounded(.toNearestOrAwayFromZero) / scale
        }
    }

    // MARK: Parsing

    /// Reads a formula such as `=ROUND((score - 50) / 10, 1)` or
    /// `IF([First Name] = "", 0, 1)`. Bare names read a column whose header is a
    /// single word; brackets read any header. Names match case-insensitively
    /// when no header matches exactly. A leading `=` is optional. Powers bind
    /// tighter than a leading minus, so `-2^2` is -4, as in SPSS and R.
    struct Parser {
        private let characters: [Character]
        private let columns: [String]
        private var position = 0

        init(_ formula: String, columns: [String]) {
            var text = Substring(formula.trimmingCharacters(in: .whitespacesAndNewlines))
            if text.first == "=" { text = text.dropFirst() }
            self.characters = Array(text)
            self.columns = columns
        }

        mutating func parse() throws -> Expression {
            guard !self.characters.isEmpty else { throw FormulaError(message: "Enter syntax to compute.") }
            let expression = try self.comparison()
            self.skipSpaces()
            guard self.position == self.characters.count else { throw self.error("Unexpected “\(self.characters[self.position])”") }
            return expression
        }

        private mutating func comparison() throws -> Expression {
            let left = try self.concatenation()
            for op in ["<=", ">=", "<>", "=", "<", ">"] where self.take(op) {
                return .binary(op, left, try self.concatenation())
            }
            return left
        }

        private mutating func concatenation() throws -> Expression {
            var expression = try self.additive()
            while self.take("&") { expression = .binary("&", expression, try self.additive()) }
            return expression
        }

        private mutating func additive() throws -> Expression {
            var expression = try self.term()
            while true {
                if self.take("+") { expression = .binary("+", expression, try self.term()) }
                else if self.take("-") { expression = .binary("-", expression, try self.term()) }
                else { return expression }
            }
        }

        private mutating func term() throws -> Expression {
            var expression = try self.unary()
            while true {
                if self.take("*") { expression = .binary("*", expression, try self.unary()) }
                else if self.take("/") { expression = .binary("/", expression, try self.unary()) }
                else { return expression }
            }
        }

        private mutating func unary() throws -> Expression {
            if self.take("-") { return .negate(try self.unary()) }
            if self.take("+") { return try self.unary() }
            return try self.power()
        }

        private mutating func power() throws -> Expression {
            let base = try self.primary()
            return self.take("^") ? .binary("^", base, try self.unary()) : base
        }

        private mutating func primary() throws -> Expression {
            self.skipSpaces()
            guard self.position < self.characters.count else { throw self.error("Incomplete syntax.") }
            let character = self.characters[self.position]
            if self.take("(") {
                let expression = try self.comparison()
                guard self.take(")") else { throw self.error("Expected “)”") }
                return expression
            }
            if character == "\"" { return .literal(.text(try self.quoted())) }
            if character == "[" {
                self.position += 1
                let start = self.position
                while self.position < self.characters.count, self.characters[self.position] != "]" { self.position += 1 }
                guard self.position < self.characters.count else { throw self.error("Expected “]”") }
                let name = String(self.characters[start..<self.position])
                self.position += 1
                return .column(try self.column(named: name))
            }
            if character.isNumber || character == "." { return .literal(.number(try self.number())) }
            if character.isLetter || character == "_" {
                let start = self.position
                while self.position < self.characters.count,
                      self.characters[self.position].isLetter || self.characters[self.position].isNumber
                        || "_.".contains(self.characters[self.position]) {
                    self.position += 1
                }
                let name = String(self.characters[start..<self.position])
                if self.take("(") { return try self.call(name) }
                switch name.uppercased() {
                case "TRUE": return .literal(.number(1))
                case "FALSE": return .literal(.number(0))
                default: return .column(try self.column(named: name))
                }
            }
            throw self.error("Unexpected “\(character)”")
        }

        private mutating func call(_ name: String) throws -> Expression {
            guard let function = Function(rawValue: name.uppercased()) else { throw self.error("There is no function \(name.uppercased())") }
            var arguments: [Expression] = []
            if !self.take(")") {
                repeat { arguments.append(try self.comparison()) } while self.take(",")
                guard self.take(")") else { throw self.error("Expected “,” or “)” in \(function.rawValue)") }
            }
            guard function.arity.contains(arguments.count) else {
                let range = function.arity
                let count = range.upperBound == Int.max ? "at least \(range.lowerBound)"
                    : range.count == 1 ? "\(range.lowerBound)" : "\(range.lowerBound) or \(range.upperBound)"
                throw FormulaError(message: "\(function.rawValue) takes \(count) argument\(range == 1...1 ? "" : "s").")
            }
            return .call(function, arguments)
        }

        private func column(named name: String) throws -> Int {
            if let index = self.columns.firstIndex(of: name) { return index }
            let folded = self.columns.indices.filter { self.columns[$0].caseInsensitiveCompare(name) == .orderedSame }
            guard folded.count == 1 else {
                throw FormulaError(message: folded.isEmpty ? "No variable is named “\(name)”." : "More than one variable is named “\(name)”.")
            }
            return folded[0]
        }

        private mutating func quoted() throws -> String {
            self.position += 1
            var text = ""
            while self.position < self.characters.count {
                let character = self.characters[self.position]
                self.position += 1
                if character == "\"" {
                    // A doubled quote is a quote, as in Excel and CSV.
                    guard self.position < self.characters.count, self.characters[self.position] == "\"" else { return text }
                    self.position += 1
                }
                text.append(character)
            }
            throw self.error("Expected a closing quote")
        }

        private mutating func number() throws -> Double {
            let start = self.position
            while self.position < self.characters.count, self.characters[self.position].isNumber || self.characters[self.position] == "." {
                self.position += 1
            }
            if self.position < self.characters.count, "eE".contains(self.characters[self.position]) {
                self.position += 1
                if self.position < self.characters.count, "+-".contains(self.characters[self.position]) { self.position += 1 }
                while self.position < self.characters.count, self.characters[self.position].isNumber { self.position += 1 }
            }
            guard let value = Double(String(self.characters[start..<self.position])) else {
                throw self.error("“\(String(self.characters[start..<self.position]))” isn’t a number")
            }
            return value
        }

        private mutating func skipSpaces() {
            while self.position < self.characters.count, self.characters[self.position].isWhitespace { self.position += 1 }
        }

        /// Consumes `token` after any spaces, if it comes next.
        private mutating func take(_ token: String) -> Bool {
            self.skipSpaces()
            let token = Array(token)
            guard self.position + token.count <= self.characters.count,
                  Array(self.characters[self.position..<self.position + token.count]) == token else { return false }
            self.position += token.count
            return true
        }

        private func error(_ message: String) -> FormulaError {
            FormulaError(message: "\(message) at character \(self.position + 1).")
        }
    }
}

/// One line of a recode: which old values it takes, and what they become.
nonisolated struct RecodeRule: Hashable, Identifiable, Sendable {
    enum Match: Hashable, Sendable {
        /// The same text, or the same number written another way: `3` matches `3.0`.
        case value(String)
        /// Numbers from `low` through `high`, either end open when nil, as in
        /// SPSS's LOWEST THRU and THRU HIGHEST.
        case range(low: Double?, high: Double?)
        /// Blank cells and missing codes.
        case missing
        /// Everything not matched by an earlier rule: SPSS's ELSE.
        case other

        func matches(_ value: String, isMissing: Bool) -> Bool {
            switch self {
            case .value(let old):
                let old = old.trimmingCharacters(in: .whitespacesAndNewlines)
                if value == old { return true }
                guard let a = Double(value), let b = Double(old) else { return false }
                return a == b
            case .range(let low, let high):
                guard !isMissing, let number = Double(value), number.isFinite else { return false }
                return (low.map { number >= $0 } ?? true) && (high.map { number <= $0 } ?? true)
            case .missing: return isMissing
            case .other: return true
            }
        }
    }

    enum Output: Hashable, Sendable {
        case value(String), blank, copy
    }

    var id = UUID()
    var match: Match
    var output: Output
}
