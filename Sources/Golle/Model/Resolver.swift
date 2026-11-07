import Foundation

/// Reads values the way the user sees them: formulas calculated, linked records by name.
/// Make one per render or query; it caches parsed formulas and a record index for its lifetime.
final class Resolver {
    let database: Database
    let table: DataTable

    /// Shared by the resolvers of one database: parsed formulas, the record index, the resolvers of
    /// other tables, and the formula depth, so formulas that look each other up across tables stop
    /// with an error instead of recursing forever.
    private final class Shared {
        var formulas: [String: Formula.Result] = [:]
        var depth = 0
        var resolvers: [DataTable.ID: Resolver] = [:]
        var recordIndex: [UUID: (table: Int, record: Int)]?
        /// Results of formulas already calculated, and the ones being calculated right now (a
        /// formula met again while it is still being calculated refers to itself).
        var computed: [FormulaKey: Computed] = [:]
        var inProgress: Set<FormulaKey> = []
        /// How often a chain was cut off for being too long. A result computed while that
        /// happened depends on where the chain started, so it isn't remembered.
        var cutOffs = 0
        /// Where the last chain was cut off, so it can be calculated from that end first.
        var cut: (record: Record, field: Field)?
        /// False once the resolver that made this is gone: nothing may be added that would keep
        /// the rest alive.
        var alive = true
        /// For unique fields: how many records of the table have each value.
        var valueCounts: [Field.ID: [String: Int]] = [:]
        /// For "Linked From": per link field, the records that link to each record.
        var backlinks: [Field.ID: [UUID: [Record]]] = [:]
    }

    private struct FormulaKey: Hashable {
        let record: UUID
        let field: UUID
        let formula: String
    }

    private let shared: Shared
    /// The resolver made by the caller owns the others; they go when it goes.
    private let isRoot: Bool

    private var recordIndex: [UUID: (table: Int, record: Int)] {
        if let index = shared.recordIndex { return index }
        var index: [UUID: (Int, Int)] = [:]
        for (t, table) in database.tables.enumerated() {
            for (r, record) in table.records.enumerated() { index[record.id] = (t, r) }
        }
        shared.recordIndex = index
        return index
    }

    init(database: Database, table: DataTable) {
        self.database = database
        self.table = table
        self.shared = Shared()
        self.isRoot = true
    }

    private init(database: Database, table: DataTable, shared: Shared) {
        self.database = database
        self.table = table
        self.shared = shared
        self.isRoot = false
    }

    deinit {
        // The other tables' resolvers point back at `shared`; letting go of them breaks the cycle.
        if isRoot {
            shared.alive = false
            shared.resolvers.removeAll()
        }
    }

    /// The resolver for another table in the same database (for linked records).
    func resolver(for other: DataTable) -> Resolver {
        if other.id == table.id { return self }
        if let existing = shared.resolvers[other.id] { return existing }
        let made = Resolver(database: database, table: other, shared: shared)
        if shared.alive { shared.resolvers[other.id] = made }
        return made
    }

    func value(_ record: Record, _ field: Field) -> Value? {
        switch field.type {
        case .formula: formulaValue(record, field).value
        case .rollup: rollup(record, field)?.value
        case .lookup: lookupValue(record, field)
        case .createdAt: .date(record.created)
        case .modifiedAt: .date(record.modified)
        default: record[field.id]
        }
    }

    /// The cell as text: what tables show, search finds and CSV exports.
    func text(_ record: Record, _ field: Field) -> String {
        switch field.type {
        case .link:
            return linkedRecords(record, field).map { $0.table.title(of: $0.record) }.joined(separator: ", ")
        case .checklist:
            return (record[field.id]?.checkItems ?? []).map(\.text).joined(separator: ", ")
        case .formula:
            let result = formulaValue(record, field)
            return result.value?.display(for: field) ?? result.error.map { "⚠︎ \($0)" } ?? ""
        case .lookup:
            return lookupTexts(record, field).joined(separator: ", ")
        case .rollup:
            // Sums, averages and extremes keep the units of what they add up (durations, currency),
            // unless the rollup has a number format of its own.
            guard let (value, shownAs) = rollup(record, field) else { return "" }
            if case .text(let s) = value { return s }
            return value.display(for: field.options.numberFormat == nil ? shownAs : field)
        default:
            return value(record, field)?.display(for: field) ?? ""
        }
    }

    /// The cell as a person reads it: like `text`, with formatted text without its Markdown marks.
    /// For printing, labels and cards.
    func readable(_ record: Record, _ field: Field) -> String {
        let text = self.text(record, field)
        return field.type == .longText && field.options.richText ? Markdown.plain(text) : text
    }

        // MARK: Links

    /// The records a link field points at, in order, skipping any that were deleted.
    func linkedRecords(_ record: Record, _ field: Field) -> [(table: DataTable, record: Record)] {
        (record[field.id]?.links ?? []).compactMap(lookup)
    }

    func lookup(_ id: UUID) -> (table: DataTable, record: Record)? {
        guard let (t, r) = recordIndex[id] else { return nil }
        return (database.tables[t], database.tables[t].records[r])
    }

    /// Records elsewhere that link to this one: (their table, the link field, the records).
    func backlinks(to record: Record) -> [(table: DataTable, field: Field, records: [Record])] {
        database.tables.flatMap { other in
            other.fields.filter { $0.type == .link && $0.options.linkedTableID == table.id }.compactMap { field in
                let records = other.records.filter { $0[field.id]?.links.contains(record.id) == true }
                return records.isEmpty ? nil : (other, field, records)
            }
        }
    }

    // MARK: Rollups

    /// A rollup's value, and the field it should be shown like (the linked field for sums, averages
    /// and extremes; the rollup itself for counts). nil when it isn't set up or the links go round in
    /// a circle.
    func rollup(_ record: Record, _ field: Field) -> (value: Value, shownAs: Field)? {
        let options = field.options
        guard let linkID = options.rollupLinkFieldID, let (linkedRecords, targetTable) = rollupSource(record, linkID) else { return nil }
        let key = FormulaKey(record: record.id, field: field.id, formula: "rollup")
        guard !shared.inProgress.contains(key), shared.depth < Self.maxDepth else { return nil }
        shared.inProgress.insert(key)
        shared.depth += 1
        defer {
            shared.inProgress.remove(key)
            shared.depth -= 1
        }
        let linked = linkedRecords
        if options.rollupKind == .count { return (.number(Double(linked.count)), field) }
        guard let targetID = options.rollupFieldID, let target = targetTable.field(targetID) else { return nil }
        let other = resolver(for: targetTable)
        let values = linked.compactMap { other.value($0.record, target) }
        func number(_ value: Value) -> Double? {
            switch value {
            case .number(let n): n
            case .rating(let r): Double(r)
            case .bool(let b): b ? 1 : 0
            default: nil
            }
        }
        switch options.rollupKind {
        case .count:
            return nil
        case .sum:
            return (.number(values.compactMap(number).reduce(0, +)), target)
        case .average:
            let numbers = values.compactMap(number)
            return numbers.isEmpty ? nil : (.number(numbers.reduce(0, +) / Double(numbers.count)), target)
        case .minimum, .maximum:
            let dates = values.compactMap(\.date)
            if !dates.isEmpty, let d = options.rollupKind == .minimum ? dates.min() : dates.max() { return (.date(d), target) }
            let numbers = values.compactMap(number)
            guard let n = options.rollupKind == .minimum ? numbers.min() : numbers.max() else { return nil }
            return (.number(n), target)
        case .list:
            let texts = linked.map { other.text($0.record, target) }.filter { !$0.isEmpty }
            return texts.isEmpty ? nil : (.text(texts.joined(separator: ", ")), target)
        }
    }

    // MARK: Lookups

    /// The field a lookup shows, and its table.
    func lookupTarget(_ field: Field) -> (field: Field, table: DataTable)? {
        guard let linkID = field.options.rollupLinkFieldID, let targetID = field.options.rollupFieldID else { return nil }
        let table: DataTable?
        if let link = self.table.field(linkID) {
            table = link.type == .link ? database.table(link.options.linkedTableID ?? self.table.id) : nil
        } else {
            table = database.tables.first { other in
                other.field(linkID).map { $0.type == .link && ($0.options.linkedTableID ?? other.id) == self.table.id } == true
            }
        }
        guard let table, let target = table.field(targetID), target.id != field.id else { return nil }
        return (target, table)
    }

    /// The linked records' values of the looked-up field, each as the linked table reads it. nil
    /// when it isn't set up or the lookups go round in a circle.
    private func lookupEach<T>(_ record: Record, _ field: Field, _ read: (Resolver, Record, Field) -> T?) -> [T]? {
        guard let linkID = field.options.rollupLinkFieldID, let (target, targetTable) = lookupTarget(field),
              let (linked, _) = rollupSource(record, linkID) else { return nil }
        let key = FormulaKey(record: record.id, field: field.id, formula: "lookup")
        guard !shared.inProgress.contains(key), shared.depth < Self.maxDepth else { return nil }
        shared.inProgress.insert(key)
        shared.depth += 1
        defer {
            shared.inProgress.remove(key)
            shared.depth -= 1
        }
        let other = resolver(for: targetTable)
        return linked.compactMap { read(other, $0.record, target) }
    }

    /// The value of a lookup. One linked record: its value as it is (a number stays a number, so it
    /// sorts, filters and adds up). Several: choices and files together, anything else as a list.
    func lookupValue(_ record: Record, _ field: Field) -> Value? {
        // Read once: each value with its text. An unchecked box counts (it isn't missing).
        guard let both = lookupEach(record, field, { other, r, f -> (Value, String)? in
            guard let v = other.value(r, f), !v.isEmpty || f.type == .checkbox else { return nil }
            return (v, other.readable(r, f))
        }), !both.isEmpty else { return nil }
        let values = both.map(\.0)
        if values.count == 1 { return values[0] }
        if values.allSatisfy({ if case .choices = $0 { true } else { false } }) {
            var seen = Set<String>()
            return .choices(values.flatMap(\.choices).filter { seen.insert($0).inserted })
        }
        if values.allSatisfy({ if case .attachments = $0 { true } else { false } }) {
            return .attachments(values.flatMap(\.attachments))
        }
        let texts = both.map(\.1).filter { !$0.isEmpty }
        return texts.isEmpty ? nil : .text(texts.joined(separator: ", "))
    }

    /// The looked-up values as the linked table shows them (formatted text without its marks).
    func lookupTexts(_ record: Record, _ field: Field) -> [String] {
        (lookupEach(record, field) { $0.readable($1, $2) } ?? []).filter { !$0.isEmpty }
    }

    /// The field whose format a value of this field is shown in: for a lookup, the looked-up field.
    func formatField(_ field: Field) -> Field {
        field.type == .lookup ? lookupTarget(field)?.field ?? field : field
    }

    // MARK: Field rules

    enum RuleProblem: Equatable {
        case missing
        /// The number of other records with the same value.
        case duplicate(Int)
        /// Below the minimum or above the maximum, as shown ("Below 0").
        case outOfRange(String)
        case wrongDate(DateLimit)
        /// Doesn't match the pattern; its name.
        case noMatch(String)

        var message: String {
            switch self {
            case .missing: "Required"
            case .duplicate(let n): n == 1 ? "Same as another record" : "Same as \(n) other records"
            case .outOfRange(let text): text
            case .wrongDate(let limit): limit == .notFuture ? "In the future" : "In the past"
            case .noMatch(let name): "Not: \(name.lowercased())"
            }
        }

        /// A sentence for the record form: "Price is below 0".
        func sentence(_ field: Field) -> String {
            switch self {
            case .missing: "\(field.name) is required"
            case .duplicate: "\(field.name) is the same as in another record"
            case .outOfRange(let text): "\(field.name) is \(text.prefix(1).lowercased() + text.dropFirst())"
            case .wrongDate(let limit): "\(field.name) is \(limit == .notFuture ? "in the future" : "in the past")"
            case .noMatch(let name): "\(field.name) doesn't match: \(name.lowercased())"
            }
        }
    }

    /// The value a unique field compares: numbers and dates as they are (not as rounded for
    /// showing), text ignoring case, accents and spaces around it. nil for an empty cell or a
    /// formula error (those don't clash).
    func uniqueKey(_ record: Record, _ field: Field) -> String? {
        if field.type == .formula, formulaValue(record, field).error != nil { return nil }
        switch value(record, field) {
        case nil: return nil
        case .number(let n)?: return "#\(n)"
        case .date(let d)?: return "@\(d.timeIntervalSinceReferenceDate)"
        default: break
        }
        let text = self.text(record, field).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Which rule of the field the record breaks, if any.
    func ruleProblem(_ record: Record, _ field: Field) -> RuleProblem? {
        let options = field.options
        guard Self.hasRules(field) else { return nil }
        if options.required, field.type.canBeRequired {
            // Links to records that were deleted don't count.
            if field.type == .link {
                if linkedRecords(record, field).isEmpty { return .missing }
            } else if let value = self.value(record, field), !value.isEmpty {
            } else { return .missing }
        }
        if let problem = valueProblem(record, field) { return problem }
        if options.unique, field.type.canBeUnique, let key = uniqueKey(record, field) {
            let counts: [String: Int]
            if let known = shared.valueCounts[field.id] { counts = known } else {
                var made: [String: Int] = [:]
                for other in table.records { if let k = uniqueKey(other, field) { made[k, default: 0] += 1 } }
                counts = made
                if shared.alive { shared.valueCounts[field.id] = made }
            }
            let n = (counts[key] ?? 1) - 1
            if n > 0 { return .duplicate(n) }
        }
        return nil
    }

    /// A broken value rule: a number out of range, a date on the wrong side of today, text that
    /// doesn't match the pattern. Empty cells break none of these (Required is for that).
    func valueProblem(_ record: Record, _ field: Field) -> RuleProblem? {
        let options = field.options
        if field.type.canHaveRange, options.minimum != nil || options.maximum != nil {
            let n: Double? = switch value(record, field) {
            case .number(let n)?: n
            case .rating(let r)?: Double(r)
            default: nil
            }
            if let n {
                let shown = formatField(field)
                func text(_ x: Double) -> String { Value.number(x).display(for: shown) }
                if let min = options.minimum, n < min { return .outOfRange("Below \(text(min))") }
                if let max = options.maximum, n > max { return .outOfRange("Above \(text(max))") }
            }
        }
        if field.type.canLimitDates, let limit = options.dateLimit, let date = value(record, field)?.date {
            let calendar = Calendar.current
            let day = calendar.startOfDay(for: date), today = calendar.startOfDay(for: Date())
            if limit == .notFuture, day > today { return .wrongDate(limit) }
            if limit == .notPast, day < today { return .wrongDate(limit) }
        }
        if field.type.canHavePattern, let pattern = options.pattern, TextPattern.isValid(pattern) {
            let text = self.text(record, field).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty, text.range(of: pattern, options: .regularExpression) == nil {
                return .noMatch(options.patternName ?? "the pattern")
            }
        }
        return nil
    }

    /// The other records with the same value in a unique field.
    func sameValue(as record: Record, _ field: Field) -> [Record] {
        guard let key = uniqueKey(record, field) else { return [] }
        return table.records.filter { $0.id != record.id && uniqueKey($0, field) == key }
    }

    /// Every broken rule of a record, in field order.
    func ruleProblems(_ record: Record) -> [(field: Field, problem: RuleProblem)] {
        table.fields.compactMap { field in ruleProblem(record, field).map { (field, $0) } }
    }

    /// Whether the table has any rules at all (so views can skip the checks).
    var hasRules: Bool {
        table.fields.contains { Self.hasRules($0) }
    }

    static func hasRules(_ field: Field) -> Bool {
        let o = field.options, t = field.type
        return (o.required && t.canBeRequired) || (o.unique && t.canBeUnique)
            || (t.canHaveRange && (o.minimum != nil || o.maximum != nil))
            || (t.canLimitDates && o.dateLimit != nil)
            || (t.canHavePattern && o.pattern.map(TextPattern.isValid) == true)
    }

    /// The records a rollup works over, and their table: through one of this table's link fields,
    /// or "Linked From": another table's link field that points here (an artist's albums).
    func rollupSource(_ record: Record, _ linkID: Field.ID) -> (records: [(table: DataTable, record: Record)], table: DataTable)? {
        if let link = table.field(linkID) {
            guard link.type == .link, let target = database.table(link.options.linkedTableID ?? table.id) else { return nil }
            return (linkedRecords(record, link), target)
        }
        for other in database.tables {
            guard let link = other.field(linkID), link.type == .link, (link.options.linkedTableID ?? other.id) == table.id else { continue }
            // Who links to whom, worked out once per resolver rather than per cell.
            let index: [UUID: [Record]]
            if let known = shared.backlinks[link.id] { index = known } else {
                var made: [UUID: [Record]] = [:]
                for r in other.records {
                    for id in Set(r[link.id]?.links ?? []) { made[id, default: []].append(r) }
                }
                index = made
                if shared.alive { shared.backlinks[link.id] = made }
            }
            return ((index[record.id] ?? []).map { (other, $0) }, other)
        }
        return nil
    }

    // MARK: Formulas

    struct Computed {
        var value: Value?
        var error: String?
    }

    func formulaValue(_ record: Record, _ field: Field) -> Computed {
        let isOutermost = shared.depth == 0 && shared.inProgress.isEmpty
        var result = evaluateOnce(record, field)
        guard isOutermost else { return result }
        // A chain longer than the depth limit (a running total over many records) is calculated
        // from the far end first; each pass remembers a hundred more, so the result doesn't depend
        // on which record happened to be calculated first.
        var passes = 0
        // (Only stored records are remembered, so only for those does another pass get further.)
        while let cut = shared.cut, passes < 100, lookup(cut.record.id)?.record == cut.record {
            shared.cut = nil
            passes += 1
            _ = formulaValue(cut.record, cut.field)
            result = evaluateOnce(record, field)
        }
        shared.cut = nil
        return result
    }

    private func evaluateOnce(_ record: Record, _ field: Field) -> Computed {
        let key = FormulaKey(record: record.id, field: field.id, formula: field.options.formula)
        // Remembered only for the record as it is stored (a caller may pass an edited copy).
        let stored = lookup(record.id)?.record == record
        if stored, let known = shared.computed[key] { return known }
        // A formula met again while it is being calculated refers to itself (through links too).
        if shared.inProgress.contains(key) { return Computed(error: "Formula refers to itself") }
        guard shared.depth < Self.maxDepth else {
            shared.cutOffs += 1
            shared.cut = (record, field)
            return Computed(error: "Formulas refer to each other too deeply")
        }
        shared.inProgress.insert(key)
        defer { shared.inProgress.remove(key) }
        let cutOffsBefore = shared.cutOffs
        let result = calculate(record, field)
        if stored, shared.cutOffs == cutOffsBefore { shared.computed[key] = result }
        return result
    }

    /// Cycles are caught by `inProgress`; this only limits very long chains of linked formulas
    /// (a running total over many records), so the stack can't run out.
    static let maxDepth = 100

    private func calculate(_ record: Record, _ field: Field) -> Computed {
        let parsed: Formula.Result
        if let cached = shared.formulas[field.options.formula] { parsed = cached }
        else {
            parsed = Formula.parse(field.options.formula)
            shared.formulas[field.options.formula] = parsed
        }
        switch parsed {
        case .failure(let error): return Computed(error: error.message)
        case .success(let expression):
            shared.depth += 1
            defer { shared.depth -= 1 }
            let result = Formula.evaluate(expression, context: Formula.Context(resolver: self, record: record))
            if case .error(let message) = result { return Computed(error: message) }
            return Computed(value: result.value)
        }
    }
}
