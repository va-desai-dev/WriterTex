import Foundation

/// A place a step reads variables into, such as an outcome or a list of
/// predictors, and how many variables it takes.
///
/// Every step is described this way, whether it reads one variable, two named
/// ones or a free list, so the composer has one shape to show. A step that
/// grows another variable, such as an ANOVA with a second factor, widens a
/// role's `count` instead of needing a new layout.
nonisolated struct StepRole: Hashable, Sendable {
    var label: String
    /// How many variables the step needs here, fewest to most. `Int.max` as
    /// the upper bound means any number.
    var count: ClosedRange<Int>
    /// Whether each variable here can be declared categorical and given a
    /// baseline level, as a regression predictor can.
    var codesLevels = false

    var isOpen: Bool { self.count.upperBound == .max }
    /// More than one variable fits here, so their order is the user's to set.
    var takesSeveral: Bool { self.count.upperBound > 1 }

    static func one(_ label: String) -> StepRole { StepRole(label: label, count: 1...1) }
    static func many(_ label: String, atLeast fewest: Int = 1, codesLevels: Bool = false) -> StepRole {
        StepRole(label: label, count: fewest...Int.max, codesLevels: codesLevels)
    }
}

/// Which of a table's columns fill each of a step's roles, in order.
///
/// A column fills one role at most: an outcome is never also a predictor, and
/// a cross-tabulation's rows are never also its columns. The order inside a
/// role is the order the step reads them in, so it is kept as the user set it
/// rather than sorted.
nonisolated struct StepRoleAssignment: Hashable, Sendable {
    let roles: [StepRole]
    private(set) var columns: [[Int]]
    /// The role a click in the variable list fills next.
    var active = 0

    init(_ roles: [StepRole]) {
        self.roles = roles
        self.columns = roles.map { _ in [] }
    }

    func role(of column: Int) -> Int? {
        self.columns.firstIndex { $0.contains(column) }
    }

    func isFull(_ role: Int) -> Bool {
        self.columns[role].count >= self.roles[role].count.upperBound
    }

    /// Every role holds as many variables as its step needs.
    var isComplete: Bool {
        zip(self.roles, self.columns).allSatisfy { $0.count.contains($1.count) }
    }

    /// A click in the variable list: a column already in a role leaves it;
    /// any other fills the active role, replacing the one there if the role
    /// takes only one. The active role then moves on once it is full.
    mutating func pick(_ column: Int) {
        if self.role(of: column) != nil {
            self.remove(column)
            return
        }
        guard self.roles.indices.contains(self.active) else { return }
        if self.isFull(self.active) {
            self.columns[self.active].removeLast()
        }
        self.columns[self.active].append(column)
        self.advance()
    }

    /// Puts a column into a role at a position, from the variable list or from
    /// another role. Moving into a full role trades places with the column at
    /// that position, which sends it back where the moved column came from;
    /// with nowhere to send it, it leaves.
    mutating func place(_ column: Int, in role: Int, at position: Int? = nil) {
        guard self.roles.indices.contains(role) else { return }
        let source = self.role(of: column)
        let sourcePosition = source.flatMap { self.columns[$0].firstIndex(of: column) }

        if source == role, let sourcePosition {
            let target = min(position ?? self.columns[role].count, self.columns[role].count)
            self.move(in: role, fromOffsets: [sourcePosition], toOffset: target)
            return
        }

        if let source { self.columns[source].removeAll { $0 == column } }
        var target = min(position ?? self.columns[role].count, self.columns[role].count)
        if self.isFull(role) {
            let displaced = min(target, self.columns[role].count - 1)
            let occupant = self.columns[role].remove(at: displaced)
            target = displaced
            if let source, !self.isFull(source) {
                self.columns[source].insert(occupant, at: min(sourcePosition ?? 0, self.columns[source].count))
            }
        }
        self.columns[role].insert(column, at: target)
        if role == self.active { self.advance() }
    }

    /// Reorders within one role, as a list's move does.
    mutating func move(in role: Int, fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard self.roles.indices.contains(role) else { return }
        let moving = offsets.filter { self.columns[role].indices.contains($0) }.map { self.columns[role][$0] }
        let before = offsets.filter { $0 < destination }.count
        self.columns[role].removeAll { moving.contains($0) }
        self.columns[role].insert(contentsOf: moving, at: min(destination - before, self.columns[role].count))
    }

    mutating func remove(_ column: Int) {
        guard let role = self.role(of: column) else { return }
        self.columns[role].removeAll { $0 == column }
        self.active = role
    }

    /// The next role still short of variables after the active one, or the
    /// active one if every other is full.
    private mutating func advance() {
        guard self.isFull(self.active) else { return }
        let order = self.roles.indices.map { (self.active + 1 + $0) % self.roles.count }
        if let next = order.first(where: { !self.isFull($0) }) { self.active = next }
    }
}
