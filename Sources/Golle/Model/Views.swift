import Foundation

/// A named way of looking at a table: which records (filter), in what order (sort) and how (mode).
/// Saved views show in the sidebar under their table. "All Records" is an unsaved one per window.
struct SavedView: Codable, Equatable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var filter = Filter()
    var sort: [SortKey] = []
    var mode: ViewMode = .table
    /// The custom layout shown in `.layout` mode; nil means the first one.
    var layoutID: UUID?
    /// Up to two fields to group the table and gallery by.
    var groupBy: [Field.ID] = []
    /// The choice field whose options are the board's columns.
    var boardFieldID: Field.ID?
    /// The date field the calendar places records by.
    var dateFieldID: Field.ID?
    /// The location field the map shows.
    var locationFieldID: Field.ID?
    /// Fields hidden in this view (table columns and card lines).
    var hiddenFieldIDs: [Field.ID] = []
    /// Column order and widths of the table as an older Golle saved them (SwiftUI's own format);
    /// kept so the file reads back the same, no longer used.
    var columnData: Data?
    /// The table's column order: fields not in it follow in table order.
    var columnOrder: [Field.ID] = []
    /// The table's column widths, by field id.
    var columnWidths: [String: Double] = [:]
    var chart = ChartSettings()
    /// The summary table: rows and columns by fields, counts or totals in the cells.
    var summary = PivotSettings()
    /// The timeline: bars from the date field (`dateFieldID`, shared with the calendar) to this one.
    var endDateFieldID: Field.ID?
    var timelineScale = TimelineScale.week

    init(id: UUID = UUID(), name: String, filter: Filter = Filter(), sort: [SortKey] = [], mode: ViewMode = .table,
         layoutID: UUID? = nil, groupBy: [Field.ID] = []) {
        self.id = id
        self.name = name
        self.filter = filter
        self.sort = sort
        self.mode = mode
        self.layoutID = layoutID
        self.groupBy = groupBy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        filter = (try? c.decodeIfPresent(Filter.self, forKey: .filter)) ?? Filter()
        sort = try c.decodeIfPresent([SortKey].self, forKey: .sort) ?? []
        mode = (try? c.decodeIfPresent(ViewMode.self, forKey: .mode)) ?? .table
        layoutID = try c.decodeIfPresent(UUID.self, forKey: .layoutID)
        groupBy = try c.decodeIfPresent([UUID].self, forKey: .groupBy) ?? []
        boardFieldID = try c.decodeIfPresent(UUID.self, forKey: .boardFieldID)
        dateFieldID = try c.decodeIfPresent(UUID.self, forKey: .dateFieldID)
        locationFieldID = try c.decodeIfPresent(UUID.self, forKey: .locationFieldID)
        hiddenFieldIDs = try c.decodeIfPresent([UUID].self, forKey: .hiddenFieldIDs) ?? []
        columnData = try c.decodeIfPresent(Data.self, forKey: .columnData)
        columnOrder = try c.decodeIfPresent([UUID].self, forKey: .columnOrder) ?? []
        columnWidths = try c.decodeIfPresent([String: Double].self, forKey: .columnWidths) ?? [:]
        chart = (try? c.decodeIfPresent(ChartSettings.self, forKey: .chart)) ?? ChartSettings()
        summary = (try? c.decodeIfPresent(PivotSettings.self, forKey: .summary)) ?? PivotSettings()
        endDateFieldID = try c.decodeIfPresent(UUID.self, forKey: .endDateFieldID)
        timelineScale = (try? c.decodeIfPresent(TimelineScale.self, forKey: .timelineScale)) ?? .week
    }

    /// The timeline's end date: the chosen one (nil: bars of one day). Never the start field itself.
    func endDateField(in table: DataTable) -> Field? {
        guard let start = dateField(in: table) else { return nil }
        return endDateFieldID.flatMap(table.field).flatMap { $0.type.isDate && $0.id != start.id ? $0 : nil }
    }

    /// The table's fields this view shows, in table order.
    func visibleFields(_ table: DataTable) -> [Field] {
        let hidden = Set(hiddenFieldIDs)
        let fields = table.fields.filter { !hidden.contains($0.id) }
        return fields.isEmpty ? Array(table.fields.prefix(1)) : fields
    }

    /// The table's columns: the visible fields in the order arranged in this view; fields not
    /// arranged yet (new ones) come after, in table order.
    func columns(_ table: DataTable) -> [Field] {
        let fields = visibleFields(table)
        let rank = Dictionary(columnOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return fields.enumerated().sorted { a, b in
            switch (rank[a.element.id], rank[b.element.id]) {
            case let (x?, y?): x < y
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): a.offset < b.offset
            }
        }.map(\.element)
    }

    /// The board's field: the chosen one, else the first single-choice field.
    func boardField(in table: DataTable) -> Field? {
        boardFieldID.flatMap(table.field).flatMap { $0.type == .choice ? $0 : nil } ?? table.fields.first { $0.type == .choice }
    }

    func dateField(in table: DataTable) -> Field? {
        dateFieldID.flatMap(table.field).flatMap { $0.type.isDate ? $0 : nil } ?? table.fields.first { $0.type == .date } ?? table.fields.first { $0.type.isDate }
    }

    func locationField(in table: DataTable) -> Field? {
        locationFieldID.flatMap(table.field).flatMap { $0.type == .location ? $0 : nil } ?? table.fields.first { $0.type == .location }
    }
}

struct SortKey: Codable, Hashable {
    var fieldID: Field.ID
    var ascending = true
}

/// How much time a timeline shows per column.
enum TimelineScale: String, Codable, CaseIterable, Identifiable {
    case day, week, month
    var id: String { rawValue }
    var label: String {
        switch self {
        case .day: "Days"
        case .week: "Weeks"
        case .month: "Months"
        }
    }
    /// Points per day.
    var dayWidth: CGFloat {
        switch self {
        case .day: 32
        case .week: 14
        case .month: 4
        }
    }
}

enum ViewMode: String, Codable, CaseIterable, Identifiable {
    case table, gallery, layout, board, calendar, map, chart, timeline, summary
    var id: String { rawValue }
    /// What the view shows, for its toolbar button's tooltip.
    var hint: String {
        switch self {
        case .table: "Table: records as rows, edited in place"
        case .gallery: "Gallery: records as cards, with the first image as a cover"
        case .layout: "Form: one record at a time, on a layout you design"
        case .board: "Board: a column per option of a choice field"
        case .calendar: "Calendar: records on a month grid by a date field"
        case .timeline: "Timeline: bars from a start to an end date"
        case .summary: "Summary: records counted or added up by two fields, with totals"
        case .map: "Map: records with a location as pins"
        case .chart: "Chart: records counted, summed or averaged"
        }
    }

    var label: String {
        switch self {
        case .table: "Table"
        case .gallery: "Gallery"
        case .layout: "Form"
        case .board: "Board"
        case .calendar: "Calendar"
        case .timeline: "Timeline"
        case .summary: "Summary"
        case .map: "Map"
        case .chart: "Chart"
        }
    }
    var symbol: String {
        switch self {
        case .table: "tablecells"
        case .gallery: "square.grid.2x2"
        case .layout: "rectangle.and.pencil.and.ellipsis"
        case .board: "rectangle.split.3x1"
        case .calendar: "calendar"
        case .timeline: "calendar.day.timeline.left"
        case .summary: "sum"
        case .map: "map"
        case .chart: "chart.bar.xaxis"
        }
    }
}

// MARK: Filters

struct Filter: Codable, Equatable, Hashable {
    enum Match: String, Codable { case all, any }
    var match: Match = .all
    var rules: [FilterRule] = []

    init(match: Match = .all, rules: [FilterRule] = []) {
        self.match = match
        self.rules = rules
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        match = (try? c.decodeIfPresent(Match.self, forKey: .match)) ?? .all
        // A rule with an operator this version doesn't know is skipped, not the whole filter.
        rules = (try? c.decodeIfPresent(Lossy<FilterRule>.self, forKey: .rules))?.items ?? []
    }

    var isEmpty: Bool { rules.isEmpty }

    func matches(_ record: Record, _ resolver: Resolver) -> Bool {
        let active = rules.filter { resolver.table.field($0.fieldID) != nil }
        guard !active.isEmpty else { return true }
        switch match {
        case .all: return active.allSatisfy { $0.matches(record, resolver) }
        case .any: return active.contains { $0.matches(record, resolver) }
        }
    }
}

struct FilterRule: Codable, Equatable, Hashable, Identifiable {
    var id = UUID()
    var fieldID: Field.ID
    var op: FilterOperator
    /// Text for text rules, a number for number rules, an ISO date (yyyy-mm-dd) for date rules.
    var operand = ""

    func matches(_ record: Record, _ resolver: Resolver) -> Bool {
        guard let field = resolver.table.field(fieldID) else { return true }
        let value = resolver.value(record, field)
        switch op {
        case .isEmpty: return value == nil || value!.isEmpty
        case .isNotEmpty: return !(value == nil || value!.isEmpty)
        case .isChecked:
            if field.type == .checklist { let items = value?.checkItems ?? []; return !items.isEmpty && items.allSatisfy(\.done) }
            return value?.bool == true || (value?.number).map { $0 != 0 } == true
        case .isNotChecked:
            if field.type == .checklist { let items = value?.checkItems ?? []; return items.isEmpty || !items.allSatisfy(\.done) }
            return !(value?.bool == true || (value?.number).map { $0 != 0 } == true)
        default: break
        }
        let numericValue = value.flatMap(Self.number)
        let numeric = op.isOrdering
            || ((op == .equals || op == .notEquals) && (field.type.isNumeric
                || ((field.type == .formula || field.type == .rollup || field.type == .lookup) && value?.number != nil && Value.parseNumber(operand) != nil)))
        if numeric {
            // A duration rule is typed like the field: "3:30", "1h 30m".
            let target = field.type == .duration ? Value.parseDuration(operand, field.options.durationStyle) : Value.parseNumber(operand)
            guard let target, let n = numericValue else { return op == .notEquals }
            switch op {
            case .equals: return n == target
            case .notEquals: return n != target
            case .less: return n < target
            case .lessOrEqual: return n <= target
            case .greater: return n > target
            default: return n >= target
            }
        }
        if op.isDate || (value?.date != nil && field.type.isDate && (op == .equals || op == .notEquals)) {
            guard let date = value?.date else { return op == .notEquals }
            let calendar = Calendar.current
            let day = calendar.startOfDay(for: date)
            let today = calendar.startOfDay(for: Date())
            switch op {
            case .today: return day == today
            case .inLastDays, .inNextDays:
                guard let n = Int(operand.trimmingCharacters(in: .whitespaces)), n >= 0 else { return false }
                let days = calendar.dateComponents([.day], from: today, to: day).day ?? 0
                return op == .inLastDays ? (-n...0).contains(days) : (0...n).contains(days)
            default:
                guard let target = Value.parseDate(operand).map(calendar.startOfDay) else { return false }
                switch op {
                case .before: return day < target
                case .after: return day > target
                case .notEquals: return day != target
                default: return day == target
                }
            }
        }
        // Text rules compare what the cell shows, ignoring case and accents.
        let text = resolver.text(record, field)
        let needle = operand.trimmingCharacters(in: .whitespaces)
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        // For choice and link fields, "is" means one of the values is exactly this.
        // A lookup of several records "is" each of their values.
        let parts: [String]
        if field.type == .lookup, let target = resolver.lookupTarget(field), target.field.type != .multiChoice, target.field.type != .link {
            parts = resolver.lookupTexts(record, field)
        } else if field.type == .lookup, case .text? = value {
            // Several records' tags or links, each split up.
            parts = resolver.lookupTexts(record, field).flatMap { $0.components(separatedBy: ", ") }
        } else {
            parts = Self.parts(value, text: text)
        }
        switch op {
        case .contains: return needle.isEmpty || text.range(of: needle, options: options) != nil
        case .notContains: return needle.isEmpty || text.range(of: needle, options: options) == nil
        case .equals: return parts.contains { $0.compare(needle, options: options) == .orderedSame }
        case .notEquals: return !parts.contains { $0.compare(needle, options: options) == .orderedSame }
        case .beginsWith: return text.range(of: needle, options: options.union(.anchored)) != nil
        case .endsWith: return text.range(of: needle, options: options.union([.anchored, .backwards])) != nil
        default: return false
        }
    }

    private static func number(_ value: Value) -> Double? {
        switch value {
        case .number(let n): n
        case .rating(let r): Double(r)
        case .bool(let b): b ? 1 : 0
        case .text(let s): Value.parseNumber(s)
        default: nil
        }
    }

    private static func parts(_ value: Value?, text: String) -> [String] {
        if case .choices(let c)? = value { return c }
        if case .links? = value { return text.components(separatedBy: ", ") }
        return [text]
    }
}

enum FilterOperator: String, Codable, CaseIterable {
    case contains, notContains, equals, notEquals, beginsWith, endsWith
    case less, lessOrEqual, greater, greaterOrEqual
    case before, after, today, inLastDays, inNextDays
    case isChecked, isNotChecked
    case isEmpty, isNotEmpty

    /// Less/greater comparisons, which only make sense on numbers. (Equals is numeric on number fields.)
    var isOrdering: Bool { [.less, .lessOrEqual, .greater, .greaterOrEqual].contains(self) }
    var isDate: Bool { [.before, .after, .today, .inLastDays, .inNextDays].contains(self) }
    var needsOperand: Bool { ![.today, .isChecked, .isNotChecked, .isEmpty, .isNotEmpty].contains(self) }

    static func operators(for type: FieldType) -> [FilterOperator] {
        switch type {
        case .number, .rating, .autoNumber, .duration, .progress: [.equals, .notEquals, .less, .lessOrEqual, .greater, .greaterOrEqual, .isEmpty, .isNotEmpty]
        case .date: [.equals, .notEquals, .before, .after, .today, .inLastDays, .inNextDays, .isEmpty, .isNotEmpty]
        case .createdAt, .modifiedAt: [.equals, .notEquals, .before, .after, .today, .inLastDays, .inNextDays]
        case .location: [.contains, .notContains, .isEmpty, .isNotEmpty]
        case .checklist: [.contains, .notContains, .isChecked, .isNotChecked, .isEmpty, .isNotEmpty]
        case .checkbox: [.isChecked, .isNotChecked]
        case .choice, .multiChoice, .link: [.equals, .notEquals, .contains, .notContains, .isEmpty, .isNotEmpty]
        case .image, .file: [.contains, .notContains, .isEmpty, .isNotEmpty]
        case .formula, .rollup, .lookup: [.contains, .notContains, .equals, .notEquals, .less, .lessOrEqual, .greater, .greaterOrEqual, .isEmpty, .isNotEmpty]
        default: [.contains, .notContains, .equals, .notEquals, .beginsWith, .endsWith, .isEmpty, .isNotEmpty]
        }
    }

    func label(for type: FieldType) -> String {
        switch self {
        case .contains: type == .multiChoice || type == .link ? "includes text" : "contains"
        case .notContains: "does not contain"
        case .equals: type.isNumeric ? "=" : type.isDate ? "is on" : type == .multiChoice || type == .link ? "has" : "is"
        case .notEquals: type.isNumeric ? "≠" : type.isDate ? "is not on" : type == .multiChoice || type == .link ? "does not have" : "is not"
        case .beginsWith: "begins with"
        case .endsWith: "ends with"
        case .less: "<"
        case .lessOrEqual: "≤"
        case .greater: ">"
        case .greaterOrEqual: "≥"
        case .before: "is before"
        case .after: "is after"
        case .today: "is today"
        case .inLastDays: "is in the last (days)"
        case .inNextDays: "is in the next (days)"
        case .isChecked: type == .checklist ? "is all done" : "is checked"
        case .isNotChecked: type == .checklist ? "is not all done" : "is not checked"
        case .isEmpty: "is empty"
        case .isNotEmpty: "is not empty"
        }
    }
}

// MARK: Summaries

/// A total shown under the records: computed over the records in view.
enum SummaryKind: String, Codable, CaseIterable, Identifiable {
    case filled, empty, sum, average, minimum, maximum, checked, unique
    var id: String { rawValue }

    var label: String {
        switch self {
        case .filled: "Filled"
        case .empty: "Empty"
        case .sum: "Sum"
        case .average: "Average"
        case .minimum: "Minimum"
        case .maximum: "Maximum"
        case .checked: "Checked"
        case .unique: "Unique"
        }
    }

    static func kinds(for type: FieldType) -> [SummaryKind] {
        switch type {
        case .number, .rating, .formula, .rollup, .lookup, .duration, .progress: [.sum, .average, .minimum, .maximum, .filled, .empty]
        case .autoNumber: [.minimum, .maximum, .filled]
        case .date, .createdAt, .modifiedAt: [.minimum, .maximum, .filled, .empty]
        case .checkbox: [.checked, .empty]
        default: [.filled, .empty, .unique]
        }
    }

    /// The summary as text, or "—" when there is nothing to summarise.
    func compute(_ values: [Value?], field: Field) -> String {
        let present = values.compactMap { $0 }.filter { !$0.isEmpty }
        func numbers() -> [Double] {
            present.compactMap { v -> Double? in
                switch v {
                case .number(let n): n
                case .rating(let r): Double(r)
                default: nil
                }
            }
        }
        func format(_ n: Double) -> String {
            // Ratings average to fractions of a star; durations and percentages show as the field
            // does; other numbers use the field's format.
            switch field.type {
            case .rating: Value.numberFormatter.string(from: n as NSNumber) ?? String(n)
            case .duration, .progress: Value.number(n).display(for: field)
            default: field.options.numberFormat?.format(n) ?? Value.numberFormatter.string(from: n as NSNumber) ?? String(n)
            }
        }
        switch self {
        case .filled: return String(present.count)
        case .empty: return String(values.count - present.count)
        case .checked: return String(present.filter { $0.bool }.count)
        case .unique: return String(Set(present.map(\.plainText)).count)
        case .sum: return format(numbers().reduce(0, +))
        case .average:
            let n = numbers()
            return n.isEmpty ? "—" : format(n.reduce(0, +) / Double(n.count))
        case .minimum, .maximum:
            if field.type.isDate {
                let dates = present.compactMap(\.date)
                guard let d = self == .minimum ? dates.min() : dates.max() else { return "—" }
                return Value.date(d).display(for: field)
            }
            let n = numbers()
            guard let m = self == .minimum ? n.min() : n.max() else { return "—" }
            return format(m)
        }
    }
}

// MARK: Charts

/// What a chart shows: records counted (or a number field summed or averaged) per category,
/// or over time when the category is a date.
struct ChartSettings: Codable, Equatable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case bar, pie, line
        var id: String { rawValue }
        var label: String {
            switch self {
            case .bar: "Bar"
            case .pie: "Donut"
            case .line: "Line"
            }
        }
        var symbol: String {
            switch self {
            case .bar: "chart.bar"
            case .pie: "chart.pie"
            case .line: "chart.xyaxis.line"
            }
        }
    }

    enum Measure: String, Codable, CaseIterable, Identifiable {
        case count, sum, average
        var id: String { rawValue }
        var label: String {
            switch self {
            case .count: "Number of records"
            case .sum: "Sum of"
            case .average: "Average of"
            }
        }
    }

    enum DateUnit: String, Codable, CaseIterable, Identifiable {
        case day, week, month, year
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var component: Calendar.Component {
            switch self {
            case .day: .day
            case .week: .weekOfYear
            case .month: .month
            case .year: .year
            }
        }
    }

    var kind = Kind.bar
    /// The field records are grouped by; nil picks the first suitable one.
    var categoryFieldID: Field.ID?
    var measure = Measure.count
    /// The number field summed or averaged.
    var valueFieldID: Field.ID?
    var dateUnit = DateUnit.month

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .bar
        categoryFieldID = try c.decodeIfPresent(UUID.self, forKey: .categoryFieldID)
        measure = (try? c.decodeIfPresent(Measure.self, forKey: .measure)) ?? .count
        valueFieldID = try c.decodeIfPresent(UUID.self, forKey: .valueFieldID)
        dateUnit = (try? c.decodeIfPresent(DateUnit.self, forKey: .dateUnit)) ?? .month
    }

    /// Fields a chart can group by.
    static func categoryFields(_ table: DataTable) -> [Field] {
        table.fields.filter { [.choice, .multiChoice, .text, .checkbox, .rating, .link, .date, .createdAt, .modifiedAt, .number, .formula, .rollup, .lookup, .color, .progress].contains($0.type) }
    }

    func categoryField(_ table: DataTable) -> Field? {
        let fields = Self.categoryFields(table)
        return categoryFieldID.flatMap { id in fields.first { $0.id == id } }
            ?? fields.first { $0.type == .choice } ?? fields.first { $0.type == .multiChoice } ?? fields.first
    }

    func valueField(_ table: DataTable) -> Field? {
        guard measure != .count else { return nil }
        let numbers = table.fields.filter { ($0.type.isNumeric && $0.type != .autoNumber) || $0.type == .formula || $0.type == .rollup || $0.type == .lookup }
        return valueFieldID.flatMap { id in numbers.first { $0.id == id } } ?? numbers.first
    }
}

/// A tile on the dashboard: a chart or a single number, over a table (optionally through a saved
/// view's filter).
struct DashboardTile: Codable, Equatable, Hashable, Identifiable {
    enum Kind: String, Codable { case chart, number }

    var id = UUID()
    var title = ""
    var kind = Kind.chart
    var tableID: DataTable.ID
    /// A saved view whose filter applies; nil means all records.
    var viewID: SavedView.ID?
    var chart = ChartSettings()
    /// For number tiles: count when nil, else this summary of the field.
    var summary: SummaryKind?
    var fieldID: Field.ID?

    init(tableID: DataTable.ID, kind: Kind = .chart) {
        self.tableID = tableID
        self.kind = kind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .chart
        tableID = try c.decode(UUID.self, forKey: .tableID)
        viewID = try c.decodeIfPresent(UUID.self, forKey: .viewID)
        chart = (try? c.decodeIfPresent(ChartSettings.self, forKey: .chart)) ?? ChartSettings()
        summary = try? c.decodeIfPresent(SummaryKind.self, forKey: .summary)
        fieldID = try c.decodeIfPresent(UUID.self, forKey: .fieldID)
    }
}
