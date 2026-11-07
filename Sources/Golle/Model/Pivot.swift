import Foundation

/// A summary table (a pivot): records counted, or a number field added up, by one field along the
/// rows and optionally another along the columns, with totals.
struct PivotSettings: Codable, Equatable, Hashable {
    enum Measure: String, Codable, CaseIterable, Identifiable {
        case count, sum, average, minimum, maximum
        var id: String { rawValue }
        var label: String {
            switch self {
            case .count: "Number of records"
            case .sum: "Sum of"
            case .average: "Average of"
            case .minimum: "Lowest"
            case .maximum: "Highest"
            }
        }
    }

    /// How a number field is grouped: each value, or in steps (years by decade).
    enum NumberStep: Double, Codable, CaseIterable, Identifiable {
        case each = 1, tens = 10, hundreds = 100, thousands = 1000
        var id: Double { rawValue }
        var label: String {
            switch self {
            case .each: "Each value"
            case .tens: "By 10"
            case .hundreds: "By 100"
            case .thousands: "By 1000"
            }
        }
    }

    /// The field along the rows; nil picks the first choice field.
    var rowFieldID: Field.ID?
    /// The field along the columns; nil is none (one column of values).
    var columnFieldID: Field.ID?
    var measure = Measure.count
    var valueFieldID: Field.ID?
    var rowDateUnit = ChartSettings.DateUnit.year
    var columnDateUnit = ChartSettings.DateUnit.year
    var rowStep = NumberStep.each
    var columnStep = NumberStep.each

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rowFieldID = try c.decodeIfPresent(UUID.self, forKey: .rowFieldID)
        columnFieldID = try c.decodeIfPresent(UUID.self, forKey: .columnFieldID)
        measure = (try? c.decodeIfPresent(Measure.self, forKey: .measure)) ?? .count
        valueFieldID = try c.decodeIfPresent(UUID.self, forKey: .valueFieldID)
        rowDateUnit = (try? c.decodeIfPresent(ChartSettings.DateUnit.self, forKey: .rowDateUnit)) ?? .year
        columnDateUnit = (try? c.decodeIfPresent(ChartSettings.DateUnit.self, forKey: .columnDateUnit)) ?? .year
        rowStep = (try? c.decodeIfPresent(NumberStep.self, forKey: .rowStep)) ?? .each
        columnStep = (try? c.decodeIfPresent(NumberStep.self, forKey: .columnStep)) ?? .each
    }

    /// Fields a summary can be laid out by: those a chart groups by.
    static func axisFields(_ table: DataTable) -> [Field] { ChartSettings.categoryFields(table) }

    /// Fields that can be added up.
    static func valueFields(_ table: DataTable) -> [Field] {
        table.fields.filter { ($0.type.isNumeric && $0.type != .autoNumber) || $0.type == .formula || $0.type == .rollup || $0.type == .lookup }
    }

    func rowField(_ table: DataTable) -> Field? {
        let fields = Self.axisFields(table)
        return rowFieldID.flatMap { id in fields.first { $0.id == id } } ?? fields.first { $0.type == .choice } ?? fields.first
    }

    func columnField(_ table: DataTable) -> Field? {
        guard let id = columnFieldID, id != rowField(table)?.id else { return nil }
        return Self.axisFields(table).first { $0.id == id }
    }

    func valueField(_ table: DataTable) -> Field? {
        guard measure != .count else { return nil }
        let fields = Self.valueFields(table)
        return valueFieldID.flatMap { id in fields.first { $0.id == id } } ?? fields.first
    }
}

enum Pivot {
    /// One row or column: a value of the field (or a step of them), in order.
    struct Category: Hashable {
        let key: String
        let label: String
        /// What it sorts by, as grouping in the table does (numbers by size, ratings best first).
        var sort: Value? = nil
    }

    /// A cell: its records, and the measure over them (nil when there is nothing to measure).
    struct Cell: Equatable {
        var records: [Record.ID] = []
        var value: Double?
    }

    struct Result {
        let rows: [Category]
        /// Empty when there is no column field: then only the totals column.
        let columns: [Category]
        /// `cells[row][column]`.
        let cells: [[Cell]]
        let rowTotals: [Cell]
        let columnTotals: [Cell]
        let total: Cell
        /// The field the values are shown like (its format, currency, duration).
        let valueField: Field?
    }

    /// At most this many rows and columns: more would make a table no one can read.
    static let maxCategories = 200

    /// The categories a record falls under for a field: one, or one per option of a multiple choice.
    static func keys(_ record: Record, _ field: Field, dateUnit: ChartSettings.DateUnit, step: PivotSettings.NumberStep,
                     _ resolver: Resolver) -> [Category] {
        let empty = Category(key: "", label: "No \(field.name)")
        if field.type.isDate {
            guard let date = resolver.value(record, field)?.date,
                  let start = Calendar.current.dateInterval(of: dateUnit.component, for: date)?.start else { return [empty] }
            // Sorted by the key: the start as a number of seconds, padded.
            return [Category(key: String(format: "d%020.0f", start.timeIntervalSince1970 + 1e12), label: ChartData.label(start, dateUnit))]
        }
        if field.type == .multiChoice {
            let choices = record[field.id]?.choices ?? []
            return choices.isEmpty ? [empty] : choices.map { Category(key: "c" + $0, label: $0) }
        }
        if step != .each, case .number(let n)? = resolver.value(record, field) {
            let low = (n / step.rawValue).rounded(.down) * step.rawValue
            let shown = resolver.formatField(field)
            let label = "\(Value.number(low).display(for: shown)) – \(Value.number(low + step.rawValue - 1).display(for: shown))"
            return [Category(key: String(format: "n%030.6f", low + 1e15), label: label)]
        }
        let (key, sort) = Grouping.key(record, field, resolver)
        return key.isEmpty ? [empty] : [Category(key: "v" + key, label: key, sort: sort)]
    }

    static func compute(_ records: [Record], settings: PivotSettings, _ resolver: Resolver) -> Result? {
        let table = resolver.table
        guard let rowField = settings.rowField(table) else { return nil }
        let columnField = settings.columnField(table)
        let valueField = settings.valueField(table)

        var rows: [Category: [Category: [Record.ID]]] = [:]
        var rowRecords: [Category: [Record.ID]] = [:]
        var columnRecords: [Category: [Record.ID]] = [:]
        var byID: [Record.ID: Record] = [:]
        for record in records {
            byID[record.id] = record
            let rowKeys = keys(record, rowField, dateUnit: settings.rowDateUnit, step: settings.rowStep, resolver)
            let columnKeys = columnField.map { keys(record, $0, dateUnit: settings.columnDateUnit, step: settings.columnStep, resolver) } ?? []
            for row in rowKeys {
                rowRecords[row, default: []].append(record.id)
                for column in columnKeys {
                    rows[row, default: [:]][column, default: []].append(record.id)
                }
            }
            for column in columnKeys { columnRecords[column, default: []].append(record.id) }
        }

        func ordered(_ categories: some Collection<Category>, by field: Field) -> [Category] {
            let options = field.options.choices
            return categories.sorted { a, b in
                // Empty last; a choice field's own option order; otherwise by value.
                if a.key.isEmpty != b.key.isEmpty { return !a.key.isEmpty }
                if field.type.usesChoices {
                    let i = options.firstIndex(of: a.label) ?? Int.max, j = options.firstIndex(of: b.label) ?? Int.max
                    if i != j { return i < j }
                }
                if a.key.first == "d" || a.key.first == "n" { return a.key < b.key }
                let order = Query.compare(a.sort, b.sort)
                if order != .orderedSame { return order == .orderedAscending }
                return a.label.localizedStandardCompare(b.label) == .orderedAscending
            }
        }
        let rowOrder = Array(ordered(rowRecords.keys, by: rowField).prefix(maxCategories))
        let columnOrder = columnField.map { Array(ordered(columnRecords.keys, by: $0).prefix(maxCategories)) } ?? []

        func cell(_ ids: [Record.ID]) -> Cell {
            // Each record once (a multiple choice puts it in several categories of the other field).
            var seen = Set<Record.ID>()
            let unique = ids.filter { seen.insert($0).inserted }
            return Cell(records: unique, value: measure(unique.compactMap { byID[$0] }, settings.measure, valueField, resolver))
        }
        let cells = rowOrder.map { row in columnOrder.map { column in cell(rows[row]?[column] ?? []) } }
        return Result(rows: rowOrder, columns: columnOrder, cells: cells,
                      rowTotals: rowOrder.map { cell(rowRecords[$0] ?? []) },
                      columnTotals: columnOrder.map { cell(columnRecords[$0] ?? []) },
                      total: cell(records.map(\.id)), valueField: valueField)
    }

    /// The count, sum, average, lowest or highest of the records. Records without a number don't
    /// count in an average, lowest or highest; with none, there is nothing to show.
    static func measure(_ records: [Record], _ measure: PivotSettings.Measure, _ field: Field?, _ resolver: Resolver) -> Double? {
        guard measure != .count, let field else { return records.isEmpty ? nil : Double(records.count) }
        let numbers = records.compactMap { record -> Double? in
            switch resolver.value(record, field) {
            case .number(let n)?: n
            case .rating(let r)?: Double(r)
            default: nil
            }
        }
        switch measure {
        case .count: return Double(records.count)
        // Records without any number: nothing to add up (not 0, which would read as "cost nothing").
        case .sum: return numbers.isEmpty ? nil : numbers.reduce(0, +)
        case .average: return numbers.isEmpty ? nil : numbers.reduce(0, +) / Double(numbers.count)
        case .minimum: return numbers.min()
        case .maximum: return numbers.max()
        }
    }

    /// A cell's value as text: counts as whole numbers, the rest as the value field shows them.
    static func text(_ value: Double?, _ result: Result, _ settings: PivotSettings, _ resolver: Resolver) -> String {
        guard let value else { return "" }
        guard settings.measure != .count, let field = result.valueField else { return Value.plain(value) }
        let shown = resolver.formatField(field)
        if settings.measure == .average, shown.type == .rating || shown.type == .number && shown.options.numberFormat?.decimals == nil {
            return Value.numberFormatter.string(from: value as NSNumber) ?? Value.plain(value)
        }
        return Value.number(value).display(for: shown)
    }

    /// The table as text with tabs, for a spreadsheet: a header row, a row per category, totals.
    static func copyText(_ result: Result, settings: PivotSettings, resolver: Resolver, rowName: String) -> String {
        var lines: [[String]] = [[rowName] + result.columns.map(\.label) + ["Total"]]
        for (i, row) in result.rows.enumerated() {
            lines.append([row.label] + result.cells[i].map { text($0.value, result, settings, resolver) } + [text(result.rowTotals[i].value, result, settings, resolver)])
        }
        lines.append(["Total"] + result.columnTotals.map { text($0.value, result, settings, resolver) } + [text(result.total.value, result, settings, resolver)])
        return lines.map { $0.joined(separator: "\t") }.joined(separator: "\n")
    }
}
