import Foundation

/// Everything in one Golle document: one or more tables, each with its own fields and records.
/// A value type, so undo is a snapshot and saving works on a consistent copy.
struct Database: Equatable {
    var tables: [DataTable] = []
    var settings = DatabaseSettings()
    /// Chart and number tiles on the database's dashboard.
    var dashboard: [DashboardTile] = []

    /// A new document: one table with a name and a notes field, ready to type into.
    static func blank() -> Database {
        Database(tables: [DataTable.blank(named: "Table 1")])
    }

    func tableIndex(_ id: DataTable.ID) -> Int? { tables.firstIndex { $0.id == id } }
    func table(_ id: DataTable.ID?) -> DataTable? { id.flatMap(tableIndex).map { tables[$0] } }

    /// Every attachment any record refers to: what a save must write.
    /// Including attachments only the history still refers to, so "Restore Old Value" finds its file.
    var referencedAttachments: [Attachment] {
        tables.flatMap { table in
            let fields = table.fields.filter { $0.type.isAttachment }.map(\.id)
            let current = table.records.flatMap { record in fields.flatMap { record[$0]?.attachments ?? [] } }
            let past = table.history.values.flatMap { changes in
                changes.flatMap { ($0.old?.attachments ?? []) + ($0.new?.attachments ?? []) }
            }
            return current + past
        }
    }
}

/// Look and feel of one database.
struct DatabaseSettings: Codable, Equatable {
    var accent = AccentChoice.orange
    var symbol = "tablecells"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accent = (try? c.decodeIfPresent(AccentChoice.self, forKey: .accent)) ?? .orange
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "tablecells"
    }
}

enum AccentChoice: String, Codable, CaseIterable, Identifiable {
    case orange, red, pink, purple, blue, teal, green, graphite, yellow, brown
    var id: String { rawValue }
}

struct DataTable: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var fields: [Field] = []
    var records: [Record] = []
    var views: [SavedView] = []
    var layouts: [FormLayout] = []
    var summaries: [SummaryItem] = []
    var colorRules: [ColorRule] = []
    /// Recent changes per record, newest last; at most `Change.limit` each.
    var history: [Record.ID: [Change]] = [:]

    static func blank(named name: String) -> DataTable {
        DataTable(name: name, fields: [Field(name: "Name", type: .text), Field(name: "Notes", type: .longText)])
    }

    func field(_ id: Field.ID) -> Field? { fields.first { $0.id == id } }
    func fieldIndex(_ id: Field.ID) -> Int? { fields.firstIndex { $0.id == id } }
    func recordIndex(_ id: Record.ID) -> Int? { records.firstIndex { $0.id == id } }
    func field(named name: String) -> Field? {
        fields.first { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    /// The field that names a record in lists and titles: the first text field, if any.
    /// Only stored fields: a computed one has no value in the record to show.
    var titleField: Field? { fields.first { $0.type == .text } ?? fields.first { !$0.type.isAttachment && $0.type != .link && !$0.type.isComputed && $0.type != .checklist } }

    func title(of record: Record) -> String {
        guard let field = titleField, let value = record.values[field.id] else { return "Untitled" }
        let text = value.display(for: field)
        return text.isEmpty ? "Untitled" : text
    }

    /// Settings saved alongside the table: views, layouts and summaries.
    var settings: TableSettings {
        get { TableSettings(views: views, layouts: layouts, summaries: summaries, colorRules: colorRules) }
        set { (views, layouts, summaries, colorRules) = (newValue.views, newValue.layouts, newValue.summaries, newValue.colorRules) }
    }

    /// The colour of the first colour rule a record matches.
    func color(of record: Record, _ resolver: Resolver) -> AccentChoice? {
        // A rule whose fields were all deleted has no conditions left, and would colour everything.
        colorRules.first { rule in
            rule.filter.rules.contains { field($0.fieldID) != nil } && rule.filter.matches(record, resolver)
        }?.color
    }

    /// The next number for an auto-number field.
    func nextNumber(for field: Field.ID) -> Double {
        (records.compactMap { $0[field]?.number }.max() ?? 0) + 1
    }
}

struct TableSettings: Codable, Equatable {
    var views: [SavedView] = []
    var layouts: [FormLayout] = []
    var summaries: [SummaryItem] = []
    var colorRules: [ColorRule] = []

    init(views: [SavedView] = [], layouts: [FormLayout] = [], summaries: [SummaryItem] = [], colorRules: [ColorRule] = []) {
        (self.views, self.layouts, self.summaries, self.colorRules) = (views, layouts, summaries, colorRules)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Item by item: one unreadable entry (from a newer Golle) mustn't drop the whole list.
        views = (try? c.decodeIfPresent(Lossy<SavedView>.self, forKey: .views))?.items ?? []
        layouts = (try? c.decodeIfPresent(Lossy<FormLayout>.self, forKey: .layouts))?.items ?? []
        summaries = (try? c.decodeIfPresent(Lossy<SummaryItem>.self, forKey: .summaries))?.items ?? []
        colorRules = (try? c.decodeIfPresent(Lossy<ColorRule>.self, forKey: .colorRules))?.items ?? []
    }
}

/// Records matching the filter get the colour, in every view. The first matching rule wins.
struct ColorRule: Codable, Equatable, Hashable, Identifiable {
    var id = UUID()
    var color: AccentChoice
    var filter = Filter()
}

struct SummaryItem: Codable, Equatable, Hashable, Identifiable {
    var id = UUID()
    var fieldID: Field.ID
    var kind: SummaryKind
}

struct Field: Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var type: FieldType
    var options = FieldOptions()

    /// The colour of a choice option: chosen, or by its place in the list (unknown values: none).
    func color(of choice: String) -> AccentChoice? {
        if let chosen = options.choiceColors[choice] { return chosen }
        guard let index = options.choices.firstIndex(of: choice) else { return nil }
        return AccentChoice.allCases[index % AccentChoice.allCases.count]
    }

    /// The value a new record starts with.
    var defaultValue: Value? {
        let text = options.defaultValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !type.isAutomatic else { return nil }
        if type.isDate, text.lowercased() == "today" { return .date(Calendar.current.startOfDay(for: Date())) }
        switch type {
        case .choice: return .choices([text])
        case .multiChoice: return .choices(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        case .image, .file, .link: return nil
        default: return Value.text(text).converted(to: type)
        }
    }
}

/// Settings that only some field types use. Stored as JSON, so new options don't need a schema change.
struct FieldOptions: Codable, Equatable, Hashable {
    /// The list for `.choice` and `.multiChoice` fields.
    var choices: [String] = []
    /// The table a `.link` field points into.
    var linkedTableID: UUID?
    /// The expression of a `.formula` field.
    var formula = ""
    /// How numbers show (number, formula and auto-number fields).
    var numberFormat: NumberFormat?
    /// What a new record starts with, as text: "today" for dates, "yes" for checkboxes, a choice, a number.
    var defaultValue = ""
    /// Colours of choice options, by option. Options without one get a colour by their position.
    var choiceColors: [String: AccentChoice] = [:]
    /// Long text with formatting (bold, lists, headings), stored as Markdown.
    var richText = true
    /// A date field that shows and edits the time of day too.
    var includesTime = false
    /// How a duration field reads and shows its values.
    var durationStyle = DurationStyle.hoursMinutesSeconds
    /// A rollup: the link field it looks through, the field of the linked records, and what it computes.
    var rollupLinkFieldID: UUID?
    var rollupFieldID: UUID?
    var rollupKind = RollupKind.count
    /// Rules: every record must have a value; no two records may have the same value. Broken rules
    /// are shown, not enforced: the user's data is never refused.
    var required = false
    var unique = false

    init(choices: [String] = [], linkedTableID: UUID? = nil, formula: String = "", numberFormat: NumberFormat? = nil, defaultValue: String = "") {
        self.choices = choices
        self.linkedTableID = linkedTableID
        self.formula = formula
        self.numberFormat = numberFormat
        self.defaultValue = defaultValue
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        choices = try c.decodeIfPresent([String].self, forKey: .choices) ?? []
        linkedTableID = try c.decodeIfPresent(UUID.self, forKey: .linkedTableID)
        formula = try c.decodeIfPresent(String.self, forKey: .formula) ?? ""
        numberFormat = try? c.decodeIfPresent(NumberFormat.self, forKey: .numberFormat)
        defaultValue = try c.decodeIfPresent(String.self, forKey: .defaultValue) ?? ""
        choiceColors = (try? c.decodeIfPresent([String: AccentChoice].self, forKey: .choiceColors)) ?? [:]
        richText = try c.decodeIfPresent(Bool.self, forKey: .richText) ?? true
        includesTime = try c.decodeIfPresent(Bool.self, forKey: .includesTime) ?? false
        durationStyle = (try? c.decodeIfPresent(DurationStyle.self, forKey: .durationStyle)) ?? .hoursMinutesSeconds
        rollupLinkFieldID = try c.decodeIfPresent(UUID.self, forKey: .rollupLinkFieldID)
        rollupFieldID = try c.decodeIfPresent(UUID.self, forKey: .rollupFieldID)
        rollupKind = (try? c.decodeIfPresent(RollupKind.self, forKey: .rollupKind)) ?? .count
        required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? false
        unique = try c.decodeIfPresent(Bool.self, forKey: .unique) ?? false
    }
}

/// How a duration is typed and shown: "1:02:30" and "45:12" (minutes and seconds), or "1:30"
/// (hours and minutes).
enum DurationStyle: String, Codable, CaseIterable, Identifiable {
    case hoursMinutesSeconds, hoursMinutes
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hoursMinutesSeconds: "Minutes and seconds (45:12, 1:02:30)"
        case .hoursMinutes: "Hours and minutes (1:30)"
        }
    }
}

/// What a rollup field computes over the linked records.
enum RollupKind: String, Codable, CaseIterable, Identifiable {
    case count, sum, average, minimum, maximum, list
    var id: String { rawValue }
    var label: String {
        switch self {
        case .count: "Number of linked records"
        case .sum: "Sum"
        case .average: "Average"
        case .minimum: "Minimum"
        case .maximum: "Maximum"
        case .list: "List of values"
        }
    }
    /// Whether it needs a field of the linked records (counting doesn't).
    var needsField: Bool { self != .count }
}

struct Record: Identifiable, Equatable {
    var id = UUID()
    var created = Date.stamp()
    var modified = Date.stamp()
    var values: [Field.ID: Value] = [:]

    subscript(field: Field.ID) -> Value? {
        get { values[field] }
        set { values[field] = newValue?.isEmpty == true ? nil : newValue }
    }
}

extension Date {
    /// Now, to the millisecond: the file stores Unix time, and whole milliseconds survive that exactly.
    static func stamp() -> Date {
        Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded() / 1000)
    }
}

/// One edit of one field, for a record's history.
struct Change: Equatable, Identifiable {
    /// Set in Settings; 0 keeps no history.
    static var limit: Int { Preferences.historyLimit }

    var id = UUID()
    var time = Date.stamp()
    var fieldID: Field.ID
    var old: Value?
    var new: Value?
}

extension DataTable {
    /// Notes a change in a record's history, or extends the last one when `continuing` (typing in
    /// one field makes one entry, like one undo step).
    mutating func recordChange(_ record: Record.ID, field: Field.ID, old: Value?, new: Value?, continuing: Bool) {
        let limit = Change.limit
        // History off: new changes aren't noted; what was kept before stays.
        guard limit > 0 else { return }
        var changes = history[record] ?? []
        if continuing, let last = changes.last, last.fieldID == field {
            changes[changes.count - 1].new = new
            changes[changes.count - 1].time = .stamp()
            // Typed back to where it started: no change after all.
            if changes[changes.count - 1].old == new { changes.removeLast() }
        } else {
            changes.append(Change(fieldID: field, old: old, new: new))
        }
        if changes.count > limit { changes.removeFirst(changes.count - limit) }
        history[record] = changes.isEmpty ? nil : changes
    }
}

/// Decodes an array item by item, skipping the items that can't be read.
struct Lossy<Element: Decodable>: Decodable {
    var items: [Element] = []

    private struct Skip: Decodable {}

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            if let item = try? container.decode(Element.self) { items.append(item) } else { _ = try? container.decode(Skip.self) }
        }
    }
}
