import Foundation

/// Records grouped by up to two fields, for grouped tables and galleries.
struct RecordGroup: Identifiable {
    /// Unique across the view: the path of group keys.
    let id: String
    let field: Field
    let title: String
    var records: [Record]
    var subgroups: [RecordGroup]
}

enum Grouping {
    /// Groups records by the first field, then each group by the second. Records keep their order
    /// within a group; groups are ordered by value, with "No value" last.
    static func groups(_ records: [Record], by fields: [Field], _ resolver: Resolver, parent: String = "") -> [RecordGroup] {
        guard let field = fields.first else { return [] }
        var order: [String] = []
        var members: [String: [Record]] = [:]
        var sortValues: [String: Value?] = [:]
        for record in records {
            let (key, sortValue) = self.key(record, field, resolver)
            if members[key] == nil {
                order.append(key)
                sortValues[key] = sortValue
            }
            members[key, default: []].append(record)
        }
        let sorted = order.sorted { a, b in
            let x = sortValues[a] ?? nil, y = sortValues[b] ?? nil
            let result = Query.compare(x, y)
            return result == .orderedSame ? a.localizedStandardCompare(b) == .orderedAscending : result == .orderedAscending
        }
        let rest = Array(fields.dropFirst())
        return sorted.map { key in
            // A separator no typed value contains, so "AC/DC" and "AC" › "DC" stay apart.
            let id = parent + "\u{1F}" + key
            let records = members[key] ?? []
            return RecordGroup(id: id, field: field, title: key.isEmpty ? "No \(field.name)" : key, records: records,
                               subgroups: groups(records, by: rest, resolver, parent: id))
        }
    }

    /// The group a record falls in: dates by month, everything else by how the cell reads.
    static func key(_ record: Record, _ field: Field, _ resolver: Resolver) -> (String, Value?) {
        let value = resolver.value(record, field)
        if field.type.isDate, let date = value?.date {
            let month = Calendar.current.dateInterval(of: .month, for: date)?.start ?? date
            return (month.formatted(.dateTime.month(.wide).year()), .date(month))
        }
        if field.type == .checkbox { return (value?.bool == true ? "Yes" : "No", .bool(value?.bool == true)) }
        if field.type == .rating, let r = value?.rating, r > 0 { return (String(repeating: "★", count: r), .rating(-r)) }
        let text = resolver.text(record, field)
        return (text, text.isEmpty ? nil : (value?.number.map(Value.number) ?? .text(text)))
    }

    /// Every record id in a group and its subgroups.
    static func flatten(_ groups: [RecordGroup]) -> [Record] {
        groups.flatMap(\.records)
    }
}

// MARK: Duplicates

enum Duplicates {
    /// Groups of records whose chosen fields read the same, ignoring case, accents and extra spaces.
    /// Records with all those fields empty are left out.
    static func find(in table: DataTable, fields: [Field.ID], _ resolver: Resolver) -> [[Record.ID]] {
        let keyFields = fields.compactMap(table.field)
        guard !keyFields.isEmpty else { return [] }
        var order: [String] = []
        var groups: [String: [Record.ID]] = [:]
        for record in table.records {
            let parts = keyFields.map { normalize(resolver.text(record, $0)) }
            guard parts.contains(where: { !$0.isEmpty }) else { continue }
            let key = parts.joined(separator: "\u{1F}")
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(record.id)
        }
        return order.compactMap { groups[$0] }.filter { $0.count > 1 }
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Keeps the first record of each group and folds the others into it.
    static func merge(_ groups: [[Record.ID]], in tableID: DataTable.ID, database db: inout Database) {
        guard let t = db.tableIndex(tableID) else { return }
        var replaced: [UUID: UUID] = [:]
        for group in groups {
            guard let keepID = group.first, var keep = db.tables[t].records.first(where: { $0.id == keepID }) else { continue }
            for otherID in group.dropFirst() {
                guard let other = db.tables[t].records.first(where: { $0.id == otherID }) else { continue }
                for field in db.tables[t].fields where !field.type.isComputed {
                    guard let incoming = other[field.id] else { continue }
                    switch (keep[field.id], incoming) {
                    case (nil, _):
                        keep[field.id] = incoming
                    case let (.choices(a)?, .choices(b)) where field.type == .multiChoice:
                        keep[field.id] = .choices(a + b.filter { !a.contains($0) })
                    case let (.attachments(a)?, .attachments(b)):
                        keep[field.id] = .attachments(a + b.filter { item in !a.contains { $0.id == item.id } })
                    case let (.links(a)?, .links(b)):
                        keep[field.id] = .links(a + b.filter { !a.contains($0) })
                    default:
                        break
                    }
                }
                keep.created = min(keep.created, other.created)
                replaced[otherID] = keepID
            }
            keep.modified = .stamp()
            if let index = db.tables[t].recordIndex(keepID) { db.tables[t].records[index] = keep }
        }
        db.tables[t].records.removeAll { replaced[$0.id] != nil }
        // Links anywhere that pointed at a removed record now point at the one kept.
        for ti in db.tables.indices {
            for field in db.tables[ti].fields where field.type == .link && field.options.linkedTableID == tableID {
                for r in db.tables[ti].records.indices {
                    guard let links = db.tables[ti].records[r][field.id]?.links, links.contains(where: { replaced[$0] != nil }) else { continue }
                    var seen = Set<UUID>()
                    let moved = links.map { replaced[$0] ?? $0 }.filter { seen.insert($0).inserted && $0 != db.tables[ti].records[r].id }
                    db.tables[ti].records[r][field.id] = .links(moved)
                }
            }
        }
    }
}

// MARK: Duplicating a table

extension DataTable {
    /// A copy with new ids throughout. Links within the table point at the copied records; links to
    /// other tables stay as they are. Attachments are shared (they are only stored once).
    func duplicated() -> DataTable {
        var copy = self
        copy.id = UUID()
        var fieldMap: [UUID: UUID] = [:]
        var recordMap: [UUID: UUID] = [:]
        copy.fields = fields.map { field in
            var f = field
            f.id = UUID()
            fieldMap[field.id] = f.id
            if f.type == .link, f.options.linkedTableID == id { f.options.linkedTableID = copy.id }
            return f
        }
        for record in records { recordMap[record.id] = UUID() }
        func field(_ id: UUID) -> UUID { fieldMap[id] ?? id }
        // A rollup through this table's own fields follows the copies (other tables' fields stay).
        for f in copy.fields.indices where copy.fields[f].type == .rollup || copy.fields[f].type == .lookup {
            copy.fields[f].options.rollupLinkFieldID = copy.fields[f].options.rollupLinkFieldID.map(field)
            copy.fields[f].options.rollupFieldID = copy.fields[f].options.rollupFieldID.map(field)
        }
        func remap(_ filter: Filter) -> Filter {
            var f = filter
            f.rules = f.rules.map { var r = $0; r.id = UUID(); r.fieldID = field(r.fieldID); return r }
            return f
        }
        copy.records = records.map { record in
            var r = Record(id: recordMap[record.id]!, created: record.created, modified: record.modified)
            for (key, value) in record.values {
                guard let original = self.field(key) else { continue }
                if case .links(let ids) = value, original.options.linkedTableID == id {
                    r.values[field(key)] = .links(ids.map { recordMap[$0] ?? $0 })
                } else {
                    r.values[field(key)] = value
                }
            }
            return r
        }
        var layoutMap: [UUID: UUID] = [:]
        copy.layouts = layouts.map { layout in
            var l = layout
            l.id = UUID()
            layoutMap[layout.id] = l.id
            l.items = l.items.map { item in
                var i = item
                i.id = UUID()
                if case .field(let f) = i.kind { i.kind = .field(field(f)) }
                return i
            }
            return l
        }
        copy.views = views.map { view in
            var v = view
            v.id = UUID()
            v.filter = remap(view.filter)
            v.sort = view.sort.map { SortKey(fieldID: field($0.fieldID), ascending: $0.ascending) }
            v.groupBy = view.groupBy.map(field)
            v.boardFieldID = view.boardFieldID.map(field)
            v.dateFieldID = view.dateFieldID.map(field)
            v.locationFieldID = view.locationFieldID.map(field)
            v.layoutID = view.layoutID.flatMap { layoutMap[$0] }
            v.hiddenFieldIDs = view.hiddenFieldIDs.map(field)
            v.chart.categoryFieldID = view.chart.categoryFieldID.map(field)
            v.chart.valueFieldID = view.chart.valueFieldID.map(field)
            // Column order and widths are saved by field id.
            if let data = view.columnData, var json = String(data: data, encoding: .utf8) {
                for (old, new) in fieldMap { json = json.replacingOccurrences(of: old.uuidString, with: new.uuidString) }
                v.columnData = Data(json.utf8)
            }
            return v
        }
        copy.summaries = summaries.map { SummaryItem(fieldID: field($0.fieldID), kind: $0.kind) }
        copy.colorRules = colorRules.map { ColorRule(color: $0.color, filter: remap($0.filter)) }
        return copy
    }
}
