import Foundation

/// CSV reading and writing (RFC 4180, plus what spreadsheets really produce).
enum CSV {
    /// Splits CSV text into rows of cells. Quoted cells may hold delimiters, quotes ("") and newlines.
    /// The delimiter is guessed from the first line: comma, semicolon or tab.
    static func parse(_ text: String, delimiter: Character? = nil) -> [[String]] {
        var text = text
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let delimiter = delimiter ?? guessDelimiter(text)
        var rows: [[String]] = []
        var row: [String] = []
        var cell = ""
        var quoted = false
        var iterator = text.makeIterator()
        var pending: Character? = nil

        func endCell() { row.append(cell); cell = "" }
        func endRow() {
            endCell()
            // Spreadsheets often end with rows of empty cells (",,,,"): those are no rows.
            if row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { rows.append(row) }
            row = []
        }

        while let c = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { cell.append("\"") } else { quoted = false; pending = next }
                    } else { quoted = false }
                } else {
                    cell.append(c)
                }
            } else if c == "\"" && cell.isEmpty {
                quoted = true
            } else if c == delimiter {
                endCell()
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                endRow()
            } else {
                cell.append(c)
            }
        }
        if !cell.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    static func guessDelimiter(_ text: String) -> Character {
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r\n" && $0 != "\r" }
        let counts: [(Character, Int)] = [(",", 0), (";", 0), ("\t", 0)].map { d, _ in (d, firstLine.filter { $0 == d }.count) }
        return counts.max { $0.1 < $1.1 }.flatMap { $0.1 > 0 ? $0.0 : nil } ?? ","
    }

    static func write(_ rows: [[String]], separator: Character = ",") -> String {
        rows.map { row in
            row.map { cell in
                cell.contains(where: { $0 == separator || $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" || $0 == ";" || $0 == "\t" })
                    ? "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                    : cell
            }.joined(separator: String(separator))
        }.joined(separator: "\r\n") + "\r\n"
    }

    /// Reads a text file in UTF-8, or the encodings spreadsheets on Windows and old Macs write.
    static func read(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let text = String(data: data, encoding: .utf8) { return text }
        // UTF-16 only with its byte-order mark: any even-length file "decodes" as UTF-16 otherwise.
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let text = String(data: data, encoding: .utf16) { return text }
        for encoding: String.Encoding in [.windowsCP1252, .macOSRoman] {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }
}

/// Turning CSV rows into fields and records.
enum Importer {
    /// The field type that fits every non-empty value of a column.
    static func guessType(_ values: [String]) -> FieldType {
        let filled = values.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !filled.isEmpty else { return .text }
        if filled.allSatisfy({ Value.parseNumber($0) != nil && !$0.contains(where: { $0 == "/" }) }) { return .number }
        let yesNo: Set = ["yes", "no", "true", "false", "y", "n", "ja", "nee", "x", "✓"]
        if filled.allSatisfy({ yesNo.contains($0.lowercased()) }) && Set(filled.map { $0.lowercased() }).count <= 2 { return .checkbox }
        // "1:02:30": hours, minutes and seconds (two parts could just as well be a time of day).
        // Before dates: the date detector would read it as a time today.
        if filled.allSatisfy({ $0.range(of: #"^\d+:[0-5]\d:[0-5]\d$"#, options: .regularExpression) != nil }) { return .duration }
        let order = dateOrder(filled)
        if filled.allSatisfy({ Value.parseDate($0, order: order) != nil && $0.count <= 30 && $0.contains(where: \.isNumber) }) { return .date }
        if filled.allSatisfy({ $0.hasPrefix("http://") || $0.hasPrefix("https://") || $0.hasPrefix("www.") }) { return .url }
        if filled.allSatisfy(Value.emailIsValid) { return .email }
        if filled.allSatisfy({ $0.hasPrefix("#") && Value.parseColor($0) != nil }) { return .color }
        if filled.contains(where: { $0.contains("\n") || $0.count > 120 }) { return .longText }
        let distinct = Set(filled)
        if distinct.count <= 12 && filled.count >= distinct.count * 2 && distinct.allSatisfy({ $0.count <= 40 }) { return .choice }
        return .text
    }

    /// Whether a column of numeric dates puts the day or the month first: any value with a first
    /// part above 12 means day first, a second part above 12 means month first; else this Mac's order.
    static func dateOrder(_ values: [String]) -> Value.DateOrder {
        var dayFirst = false, monthFirst = false
        for value in values {
            guard let parts = Value.dateParts(Value.splitTime(value).date), String(parts[0]).count < 4 else { continue }
            if parts[0] > 12 { dayFirst = true }
            if parts[1] > 12 { monthFirst = true }
        }
        if dayFirst != monthFirst { return dayFirst ? .dayMonthYear : .monthDayYear }
        return Value.localeDateOrder
    }

    /// One record per row. `columns` maps a column index to the field it fills.
    static func records(_ rows: [[String]], columns: [(index: Int, field: Field)]) -> [Record] {
        // One date order per column, so "03/04" and "03/14" in the same column agree.
        var orders: [Int: Value.DateOrder] = [:]
        for (index, field) in columns where field.type == .date {
            orders[index] = dateOrder(rows.map { index < $0.count ? $0[index] : "" })
        }
        // A row whose imported cells are all empty adds no record.
        return rows.compactMap { row -> Record? in
            var record = Record()
            var filled = false
            for (index, field) in columns where index < row.count {
                let cell = row[index]
                guard !cell.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                filled = true
                let value: Value? = switch field.type {
                case .multiChoice: .choices(cell.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
                case .choice: .choices([cell.trimmingCharacters(in: .whitespaces)])
                case .date: Value.parseDate(cell, order: orders[index]).map(Value.date)
                case .duration: Value.parseDuration(cell, field.options.durationStyle).map(Value.number)
                case .image, .file, .link, .formula, .rollup, .lookup, .createdAt, .modifiedAt: nil
                default: Value.text(cell).converted(to: field.type)
                }
                record[field.id] = value
            }
            return filled ? record : nil
        }
    }

    /// A new field for a column, with its choice list filled in from the values.
    static func field(named name: String, type: FieldType, values: [String]) -> Field {
        var field = Field(name: name, type: type)
        // Dates with a time of day keep showing it.
        if type == .date, values.contains(where: { Value.splitTime($0).time.map { $0 != (0, 0, 0) } ?? false }) {
            field.options.includesTime = true
        }
        if type == .choice || type == .multiChoice {
            var seen = Set<String>()
            let parts = type == .multiChoice
                ? values.flatMap { $0.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces) } }
                : values.map { $0.trimmingCharacters(in: .whitespaces) }
            field.options.choices = parts.filter { !$0.isEmpty && seen.insert($0).inserted }
        }
        return field
    }
}

/// CSV and JSON export.
enum Exporter {
    /// The records as CSV, one column per field, with a header row. Values are written plainly
    /// (ISO dates, unformatted numbers) so spreadsheets read them back.
    /// With semicolons, numbers get a decimal comma ("12,99"): that is what Excel expects where
    /// semicolon files are used, and import reads it back.
    static func csv(_ records: [Record], resolver: Resolver, separator: Character = ",") -> String {
        let fields = resolver.table.fields
        var rows = [fields.map(\.name)]
        let decimalComma = separator == ";"
        for record in records {
            rows.append(fields.map { field in
                let text = cell(record, field, resolver)
                // Only cells written as a plain number; durations, dates and formatted text stay.
                guard decimalComma, case .number(let n)? = resolver.value(record, field), text == Value.plain(n) else { return text }
                return text.replacingOccurrences(of: ".", with: ",")
            })
        }
        return CSV.write(rows, separator: separator)
    }

    static func cell(_ record: Record, _ field: Field, _ resolver: Resolver) -> String {
        switch field.type {
        case .link: return resolver.text(record, field)
        case .createdAt, .modifiedAt: return resolver.value(record, field).flatMap(\.date).map(dateTime) ?? ""
        case .date where field.options.includesTime: return record[field.id]?.date.map(dateTime) ?? ""
        // As they are typed ("1:02:30"), which import reads back.
        case .duration: return record[field.id]?.number.map { Value.formatDuration($0, field.options.durationStyle) } ?? ""
        case .rollup where rollupShowsDuration(field, resolver): return resolver.text(record, field)
        case .lookup: return resolver.text(record, field)
        case .formula, .rollup: return resolver.value(record, field)?.plainText ?? ""
        case .rating: return record[field.id].map { String($0.rating) } ?? ""
        default: return record[field.id]?.plainText ?? ""
        }
    }

    /// Local date and time, the way it is read back: "2024-03-05 14:30" (with seconds when there are any).
    static func dateTime(_ date: Date) -> String {
        let c = Value.gregorian.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let base = String(format: "%04d-%02d-%02d %02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
        return (c.second ?? 0) == 0 ? base : base + String(format: ":%02d", c.second ?? 0)
    }

    /// The table whose records a rollup works over: the one its link field points to, or the
    /// table of the "Linked From" field it goes through.
    static func rollupTable(_ field: Field, _ table: DataTable, _ database: Database) -> DataTable? {
        guard let linkID = field.options.rollupLinkFieldID else { return nil }
        // Only while the field it goes through is still a link (to this table, for "Linked From").
        if let link = table.field(linkID) { return link.type == .link ? database.table(link.options.linkedTableID ?? table.id) : nil }
        return database.tables.first { other in
            other.field(linkID).map { $0.type == .link && ($0.options.linkedTableID ?? other.id) == table.id } == true
        }
    }

    /// Whether a rollup adds up durations, so its number is a duration too.
    static func rollupShowsDuration(_ field: Field, _ resolver: Resolver) -> Bool {
        guard field.type == .rollup, [.sum, .average, .minimum, .maximum].contains(field.options.rollupKind),
              let target = Self.rollupTable(field, resolver.table, resolver.database),
              let shown = field.options.rollupFieldID.flatMap(target.field) else { return false }
        return shown.type == .duration
    }

    /// The whole database: every table with its fields and records. Linked records are written with
    /// their id and title, attachments by name, formulas with their computed value.
    static func json(_ database: Database) throws -> Data {
        let iso = ISO8601DateFormatter()
        var tables: [[String: Any]] = []
        for table in database.tables {
            let resolver = Resolver(database: database, table: table)
            let fields: [[String: Any]] = table.fields.map { field in
                var f: [String: Any] = ["id": field.id.uuidString, "name": field.name, "type": field.type.rawValue]
                if !field.options.choices.isEmpty { f["choices"] = field.options.choices }
                if let linked = field.options.linkedTableID { f["linkedTable"] = linked.uuidString }
                if !field.options.formula.isEmpty { f["formula"] = field.options.formula }
                return f
            }
            // Field names as keys; a repeated name gets a number, so no column overwrites another.
            var keys: [Field.ID: String] = [:]
            var used = Set<String>()
            for field in table.fields {
                var key = field.name, n = 2
                while used.contains(key) { key = "\(field.name) (\(n))"; n += 1 }
                used.insert(key)
                keys[field.id] = key
            }
            let records: [[String: Any]] = table.records.map { record in
                var values: [String: Any] = [:]
                for field in table.fields {
                    guard let value = resolver.value(record, field) else { continue }
                    values[keys[field.id] ?? field.name] = json(value, field: field, record: record, resolver: resolver, iso: iso)
                }
                return ["id": record.id.uuidString, "created": iso.string(from: record.created),
                        "modified": iso.string(from: record.modified), "values": values]
            }
            tables.append(["id": table.id.uuidString, "name": table.name, "fields": fields, "records": records])
        }
        let root: [String: Any] = ["format": "golle", "version": 1, "tables": tables]
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func json(_ value: Value, field: Field, record: Record, resolver: Resolver, iso: ISO8601DateFormatter) -> Any {
        switch value {
        case .text(let s): return s
        case .number(let n): return n.isFinite ? n : NSNull()
        case .bool(let b): return b
        case .date(let d): return iso.string(from: d)
        case .rating(let r): return r
        case .choices(let c): return field.type == .choice ? (c.first ?? "") : c
        case .attachments(let a): return a.map(\.name)
        case .checklist(let items):
            return items.map { ["text": $0.text, "done": $0.done] }
        case .location(let p):
            var place: [String: Any] = ["name": p.name]
            if let lat = p.latitude, let lon = p.longitude { place["latitude"] = lat; place["longitude"] = lon }
            return place
        case .links where field.type == .lookup:
            return resolver.text(record, field)
        case .links:
            return resolver.linkedRecords(record, field).map { ["id": $0.record.id.uuidString, "title": $0.table.title(of: $0.record)] }
        }
    }
}
