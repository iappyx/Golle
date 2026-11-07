import Foundation

/// Copying records out of the table and pasting blocks of cells into it, as spreadsheets do: a
/// line per record, a tab between cells.
enum CellClipboard {
    // MARK: Copy

    /// The records as text: their cells as an export writes them (plain numbers, ISO dates), so
    /// pasting them back, here or in a spreadsheet, gives the same values.
    static func text(_ records: [Record], fields: [Field], resolver: Resolver) -> String {
        records.map { record in
            fields.map { quoted(Exporter.cell(record, $0, resolver)) }.joined(separator: "\t")
        }.joined(separator: "\n")
    }

    /// A cell holding a tab, line break or quote goes in quotes, the way spreadsheets write it.
    private static func quoted(_ cell: String) -> String {
        guard cell.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\"" }) else { return cell }
        return "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// What was last copied from the grid: the text put on the clipboard, and the cells' values
    /// with their types. Pasted back in the same database while the clipboard still holds that
    /// text, cells get the values themselves: photos, files, links, checklists and places too,
    /// which text can't carry.
    struct Copied {
        let text: String
        let cells: [[(type: FieldType, value: Value?)]]
        let database: ObjectIdentifier
    }

    @MainActor static var copied: Copied?

    static func cells(_ records: [Record], fields: [Field]) -> [[(type: FieldType, value: Value?)]] {
        records.map { record in fields.map { ($0.type, record[$0.id]) } }
    }

    // MARK: Paste

    /// Text from the clipboard as rows of cells. Unlike a CSV file, empty rows are kept: a column
    /// with gaps lands on the right records.
    static func grid(_ text: String) -> [[String]] {
        var text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        // Spreadsheets end a copied block with a line break.
        if text.hasSuffix("\n") { text.removeLast() }
        guard !text.isEmpty else { return [] }
        var rows: [[String]] = []
        var row: [String] = []
        var cell = ""
        var quoted = false
        var chars = Array(text)[...]
        while let c = chars.popFirst() {
            if quoted {
                if c == "\"" {
                    if chars.first == "\"" { cell.append("\""); chars.removeFirst() } else { quoted = false }
                } else {
                    cell.append(c)
                }
            } else if c == "\"" && cell.isEmpty {
                quoted = true
            } else if c == "\t" {
                row.append(cell); cell = ""
            } else if c == "\n" {
                row.append(cell); cell = ""
                rows.append(row); row = []
            } else {
                cell.append(c)
            }
        }
        row.append(cell)
        rows.append(row)
        return rows
    }

    /// Whether text holds more than one cell, and so is pasted into cells rather than into one.
    static func isBlock(_ text: String) -> Bool {
        var trimmed = text
        while trimmed.hasSuffix("\n") || trimmed.hasSuffix("\r") { trimmed.removeLast() }
        return trimmed.contains { $0 == "\t" || $0 == "\n" || $0 == "\r" }
    }

    /// What a paste changes: cells of existing records, new records for rows past the last one,
    /// and options new to choice fields.
    struct Paste {
        var updates: [(record: Record.ID, field: Field.ID, value: Value?)] = []
        var added: [[Field.ID: Value]] = []
        var newChoices: [Field.ID: [String]] = [:]
        /// Cells that couldn't be read as their field's type (text in a number field), left as they were.
        var skipped = 0
        /// Columns that can't be pasted into: formulas, automatic fields, files.
        var readOnly = 0

        var isEmpty: Bool { updates.isEmpty && added.isEmpty }
    }

    /// The fields that can be emptied (Delete, Cut): every field you fill in yourself, photos and
    /// files too. Formulas and automatic fields fill themselves.
    static func canClear(_ field: Field) -> Bool {
        ![.formula, .rollup, .lookup, .autoNumber, .createdAt, .modifiedAt].contains(field.type)
    }

    /// The fields a pasted value can be stored in.
    static func canPaste(into field: Field) -> Bool {
        ![.formula, .rollup, .lookup, .autoNumber, .createdAt, .modifiedAt, .image, .file].contains(field.type)
    }

    /// Where pasted cells go. `columns` are the fields in the order shown; the block starts in
    /// column `startColumn` and on `rows[0]`, and fills the rows after it (in the order shown), with
    /// new records for what is left. A first row of field names puts each column under its field.
    static func plan(_ grid: [[String]], table: DataTable, columns: [Field], startColumn: Int, rows: [Record.ID],
                     resolver: Resolver, values: [[(type: FieldType, value: Value?)]]? = nil) -> Paste {
        var paste = Paste()
        guard !grid.isEmpty else { return paste }
        var grid = grid
        // A header: every filled cell of the first row names a field, and there is more below it.
        // (Not for cells copied in Golle: those have none.)
        var targets: [Field?]
        let first = grid[0].map { $0.trimmingCharacters(in: .whitespaces) }
        let named = first.map { table.field(named: $0) }
        if values == nil, grid.count > 1, first.contains(where: { !$0.isEmpty }), zip(first, named).allSatisfy({ $0.isEmpty || $1 != nil }) {
            targets = named
            grid.removeFirst()
        } else {
            let width = grid.map(\.count).max() ?? 0
            targets = (0..<width).map { i in startColumn + i < columns.count ? columns[startColumn + i] : nil }
        }
        paste.readOnly = targets.compactMap { $0 }.filter { !canPaste(into: $0) }.count

        // One date order per column, as an import works it out.
        var orders: [Int: Value.DateOrder] = [:]
        for (i, field) in targets.enumerated() where field?.type == .date {
            orders[i] = Importer.dateOrder(grid.map { i < $0.count ? $0[i] : "" })
        }
        var known: [Field.ID: Set<String>] = [:]
        for field in targets.compactMap({ $0 }) where field.type == .choice || field.type == .multiChoice {
            known[field.id] = Set(field.options.choices)
        }

        for (r, cells) in grid.enumerated() {
            var values_: [Field.ID: Value] = [:]
            var cleared: [Field.ID] = []
            for (i, cell) in cells.enumerated() {
                guard i < targets.count, let field = targets[i] else { continue }
                // Copied in Golle into a field of the same type: the value itself (a photo, a link).
                if let values, r < values.count, i < values[r].count, values[r][i].type == field.type, canClear(field) {
                    if let value = values[r][i].value { values_[field.id] = value } else { cleared.append(field.id) }
                    if case .choices(let choices)? = values[r][i].value, field.type == .choice || field.type == .multiChoice {
                        for choice in choices where known[field.id]?.contains(choice) == false {
                            known[field.id]?.insert(choice)
                            paste.newChoices[field.id, default: []].append(choice)
                        }
                    }
                    continue
                }
                guard canPaste(into: field) else { continue }
                let text = cell.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { cleared.append(field.id); continue }
                guard let value = value(text, for: field, order: orders[i], resolver: resolver) else { paste.skipped += 1; continue }
                values_[field.id] = value
                // Choices not in the list yet are added to it.
                if case .choices(let choices) = value, field.type == .choice || field.type == .multiChoice {
                    for choice in choices where known[field.id]?.contains(choice) == false {
                        known[field.id]?.insert(choice)
                        paste.newChoices[field.id, default: []].append(choice)
                    }
                }
            }
            if r < rows.count {
                for (field, value) in values_ { paste.updates.append((rows[r], field, value)) }
                for field in cleared { paste.updates.append((rows[r], field, nil)) }
            } else if !values_.isEmpty {
                paste.added.append(values_)
            }
        }
        return paste
    }

    /// One pasted cell as a value of the field, or nil when it can't be one.
    static func value(_ text: String, for field: Field, order: Value.DateOrder?, resolver: Resolver) -> Value? {
        switch field.type {
        case .multiChoice:
            let parts = text.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : .choices(parts)
        case .choice:
            return .choices([text])
        case .date:
            return Value.parseDate(text, order: order).map(Value.date)
        case .duration:
            return Value.parseDuration(text, field.options.durationStyle).map(Value.number)
        case .link:
            // Linked records by name, as the cell shows them.
            guard let target = resolver.database.table(field.options.linkedTableID ?? resolver.table.id) else { return nil }
            let names = text.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            let ids = names.compactMap { name in target.records.first { target.title(of: $0).lowercased() == name }?.id }
            return ids.isEmpty ? nil : .links(ids)
        default:
            return Value.text(text).converted(to: field.type)
        }
    }
}
