import Foundation

/// Reads and writes the SQLite file inside a `.golledb` package.
///
/// Layout (format 1):
///   tables(id, name, position, settings JSON)  settings: saved views, layouts, summaries
///   fields(id, table_id, name, type, options JSON, position)
///   records(id, table_id, created, modified, position)
///   cells(record_id, field_id, value)       one row per non-empty cell
///   meta(key, value)                         "format", "app-version", "settings" (theme JSON)
/// Cells are stored per field rather than as SQL columns, so adding, renaming, retyping or removing a
/// field never rewrites a table.
enum DatabaseFile {
    static let format = 1
    static let sqliteName = "database.sqlite"

    static let schema = """
    CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
    CREATE TABLE tables(id TEXT PRIMARY KEY, name TEXT NOT NULL, position INTEGER NOT NULL, settings TEXT NOT NULL DEFAULT '{}');
    CREATE TABLE fields(
        id TEXT PRIMARY KEY,
        table_id TEXT NOT NULL REFERENCES tables(id) ON DELETE CASCADE,
        name TEXT NOT NULL, type TEXT NOT NULL, options TEXT NOT NULL DEFAULT '{}',
        position INTEGER NOT NULL);
    CREATE TABLE records(
        id TEXT PRIMARY KEY,
        table_id TEXT NOT NULL REFERENCES tables(id) ON DELETE CASCADE,
        created REAL NOT NULL, modified REAL NOT NULL, position INTEGER NOT NULL);
    CREATE TABLE cells(
        record_id TEXT NOT NULL REFERENCES records(id) ON DELETE CASCADE,
        field_id TEXT NOT NULL REFERENCES fields(id) ON DELETE CASCADE,
        value,
        PRIMARY KEY(record_id, field_id)) WITHOUT ROWID;
    CREATE TABLE history(
        record_id TEXT NOT NULL, field_id TEXT NOT NULL, time REAL NOT NULL,
        old, new, position INTEGER NOT NULL, id TEXT);
    CREATE INDEX history_by_record ON history(record_id, position);
    CREATE INDEX fields_by_table ON fields(table_id, position);
    CREATE INDEX records_by_table ON records(table_id, position);
    """

    // MARK: Writing

    static func encode(_ database: Database) throws -> Data {
        let sql = try SQLite()
        try sql.execute(schema)
        try sql.transaction {
            let meta = try sql.prepare("INSERT INTO meta VALUES (?, ?)")
            try meta.run([.text("format"), .text(String(format))])
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
            try meta.run([.text("app-version"), .text(version)])
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            try meta.run([.text("settings"), .text(String(decoding: try encoder.encode(database.settings), as: UTF8.self))])
            if !database.dashboard.isEmpty {
                try meta.run([.text("dashboard"), .text(String(decoding: try encoder.encode(database.dashboard), as: UTF8.self))])
            }
            let insertChange = try sql.prepare("INSERT INTO history VALUES (?, ?, ?, ?, ?, ?, ?)")
            for table in database.tables {
                let live = Set(table.records.map(\.id))
                let fields = Set(table.fields.map(\.id))
                for (record, changes) in table.history.sorted(by: { $0.key.uuidString < $1.key.uuidString }) where live.contains(record) {
                    for (position, change) in changes.enumerated() where fields.contains(change.fieldID) {
                        try insertChange.run([.text(record.uuidString), .text(change.fieldID.uuidString), .real(change.time.timeIntervalSince1970),
                                              change.old.map(sqlValue) ?? .null, change.new.map(sqlValue) ?? .null, .integer(Int64(position)),
                                              .text(change.id.uuidString)])
                    }
                }
            }

            let insertTable = try sql.prepare("INSERT INTO tables VALUES (?, ?, ?, ?)")
            let insertField = try sql.prepare("INSERT INTO fields VALUES (?, ?, ?, ?, ?, ?)")
            let insertRecord = try sql.prepare("INSERT INTO records VALUES (?, ?, ?, ?, ?)")
            let insertCell = try sql.prepare("INSERT INTO cells VALUES (?, ?, ?)")

            for (tablePosition, table) in database.tables.enumerated() {
                let tableID = table.id.uuidString
                let settings = String(decoding: try encoder.encode(table.settings), as: UTF8.self)
                try insertTable.run([.text(tableID), .text(table.name), .integer(Int64(tablePosition)), .text(settings)])
                for (position, field) in table.fields.enumerated() {
                    let options = String(decoding: try encoder.encode(field.options), as: UTF8.self)
                    try insertField.run([.text(field.id.uuidString), .text(tableID), .text(field.name),
                                         .text(field.type.rawValue), .text(options), .integer(Int64(position))])
                }
                for (position, record) in table.records.enumerated() {
                    let recordID = record.id.uuidString
                    try insertRecord.run([.text(recordID), .text(tableID), .real(record.created.timeIntervalSince1970),
                                          .real(record.modified.timeIntervalSince1970), .integer(Int64(position))])
                    for field in table.fields where !field.type.isComputed {
                        guard let value = record[field.id], !value.isEmpty else { continue }
                        try insertCell.run([.text(recordID), .text(field.id.uuidString), sqlValue(value)])
                    }
                }
            }
        }
        try sql.execute("VACUUM")
        return try sql.serialize()
    }

    static func sqlValue(_ value: Value) -> SQLValue {
        switch value {
        case .text(let s): .text(s)
        case .number(let n): .real(n)
        case .date(let d): .real(d.timeIntervalSince1970)
        case .bool(let b): .integer(b ? 1 : 0)
        case .rating(let r): .integer(Int64(r))
        case .choices(let c): json(c)
        case .attachments(let a): json(a)
        case .links(let l): json(l.map(\.uuidString))
        case .location(let p): json(p)
        case .checklist(let items): json(items)
        }
    }

    private static func json<T: Encodable>(_ value: T) -> SQLValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return .text(String(decoding: (try? encoder.encode(value)) ?? Data("[]".utf8), as: UTF8.self))
    }

    // MARK: Reading

    static func decode(_ bytes: Data) throws -> Database {
        let sql = try SQLite(bytes: bytes)
        guard let formatText = try sql.scalarText("SELECT value FROM meta WHERE key = 'format'"),
              let fileFormat = Int(formatText) else {
            throw SQLiteError(description: "This is not a Golle database.")
        }
        guard fileFormat <= format else {
            throw SQLiteError(description: "This database was made by a newer version of Golle. Update Golle to open it.")
        }

        var database = Database()
        if let settings = try sql.scalarText("SELECT value FROM meta WHERE key = 'settings'") {
            database.settings = (try? JSONDecoder().decode(DatabaseSettings.self, from: Data(settings.utf8))) ?? DatabaseSettings()
        }
        var tablesByID: [String: Int] = [:]
        var fieldsByID: [String: (table: Int, field: Field)] = [:]
        var recordsByID: [String: (table: Int, index: Int)] = [:]

        let tables = try sql.prepare("SELECT id, name, settings FROM tables ORDER BY position")
        while try tables.step() {
            guard let id = tables.text(0).flatMap(UUID.init(uuidString:)) else { continue }
            tablesByID[id.uuidString] = database.tables.count
            var table = DataTable(id: id, name: tables.text(1) ?? "Table")
            if let settings = tables.text(2).flatMap({ try? JSONDecoder().decode(TableSettings.self, from: Data($0.utf8)) }) {
                table.settings = settings
            }
            database.tables.append(table)
        }

        let fields = try sql.prepare("SELECT id, table_id, name, type, options FROM fields ORDER BY position")
        while try fields.step() {
            guard let id = fields.text(0).flatMap(UUID.init(uuidString:)),
                  let table = fields.text(1).flatMap({ tablesByID[$0] }) else { continue }
            // A type from a newer version reads as text, so its values still show.
            let type = fields.text(3).flatMap(FieldType.init(rawValue:)) ?? .text
            let options = fields.text(4).flatMap { try? JSONDecoder().decode(FieldOptions.self, from: Data($0.utf8)) } ?? FieldOptions()
            let field = Field(id: id, name: fields.text(2) ?? "Field", type: type, options: options)
            database.tables[table].fields.append(field)
            fieldsByID[id.uuidString] = (table, field)
        }

        let records = try sql.prepare("SELECT id, table_id, created, modified FROM records ORDER BY position")
        while try records.step() {
            guard let id = records.text(0).flatMap(UUID.init(uuidString:)),
                  let table = records.text(1).flatMap({ tablesByID[$0] }) else { continue }
            let record = Record(id: id, created: Date(timeIntervalSince1970: records.double(2)),
                                modified: Date(timeIntervalSince1970: records.double(3)))
            recordsByID[id.uuidString] = (table, database.tables[table].records.count)
            database.tables[table].records.append(record)
        }

        if let dashboard = try sql.scalarText("SELECT value FROM meta WHERE key = 'dashboard'") {
            database.dashboard = (try? JSONDecoder().decode([DashboardTile].self, from: Data(dashboard.utf8))) ?? []
        }
        // Files from before history existed have no history table.
        if (try? sql.scalarText("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'history'")) != nil {
            let changes = try sql.prepare("SELECT record_id, field_id, time, old, new, id FROM history ORDER BY record_id, position")
            while try changes.step() {
                guard let record = changes.text(0).flatMap({ recordsByID[$0] }),
                      let field = changes.text(1).flatMap({ fieldsByID[$0] }), field.table == record.table else { continue }
                let id = database.tables[record.table].records[record.index].id
                let change = Change(id: changes.text(5).flatMap(UUID.init(uuidString:)) ?? UUID(),
                                    time: Date(timeIntervalSince1970: changes.double(2)), fieldID: field.field.id,
                                    old: value(changes.value(3), for: field.field.type), new: value(changes.value(4), for: field.field.type))
                database.tables[record.table].history[id, default: []].append(change)
            }
        }

        let cells = try sql.prepare("SELECT record_id, field_id, value FROM cells")
        while try cells.step() {
            guard let record = cells.text(0).flatMap({ recordsByID[$0] }),
                  let field = cells.text(1).flatMap({ fieldsByID[$0] }),
                  field.table == record.table,
                  let value = value(cells.value(2), for: field.field.type) else { continue }
            database.tables[record.table].records[record.index].values[field.field.id] = value
        }
        return database
    }

    static func value(_ stored: SQLValue, for type: FieldType) -> Value? {
        let value: Value?
        switch (type, stored) {
        case (_, .null): value = nil
        case (.text, .text(let s)), (.longText, .text(let s)), (.url, .text(let s)): value = .text(s)
        case (.number, .real(let d)): value = .number(d)
        case (.number, .integer(let i)): value = .number(Double(i))
        case (.date, .real(let d)): value = .date(Date(timeIntervalSince1970: d))
        case (.date, .integer(let i)): value = .date(Date(timeIntervalSince1970: Double(i)))
        case (.checkbox, .integer(let i)): value = .bool(i != 0)
        case (.rating, .integer(let i)): value = .rating(Int(i))
        case (.choice, .text(let s)), (.multiChoice, .text(let s)):
            value = (try? JSONDecoder().decode([String].self, from: Data(s.utf8))).map(Value.choices) ?? .choices([s])
        case (.image, .text(let s)), (.file, .text(let s)):
            value = (try? JSONDecoder().decode([Attachment].self, from: Data(s.utf8))).map(Value.attachments)
        case (.link, .text(let s)):
            value = (try? JSONDecoder().decode([String].self, from: Data(s.utf8))).map { .links($0.compactMap(UUID.init(uuidString:))) }
        case (.location, .text(let s)):
            value = (try? JSONDecoder().decode(Place.self, from: Data(s.utf8))).map(Value.location) ?? .location(Place(name: s))
        case (.checklist, .text(let s)):
            value = (try? JSONDecoder().decode([CheckItem].self, from: Data(s.utf8))).map(Value.checklist) ?? Value.text(s).converted(to: .checklist)
        case (.autoNumber, .real(let d)): value = .number(d)
        case (.autoNumber, .integer(let i)): value = .number(Double(i))
        case (.formula, _), (.createdAt, _), (.modifiedAt, _): value = nil
        // Anything else was stored by a different type: convert it rather than drop it.
        case (_, .text(let s)): value = Value.text(s).converted(to: type)
        case (_, .real(let d)): value = Value.number(d).converted(to: type)
        case (_, .integer(let i)): value = Value.number(Double(i)).converted(to: type)
        }
        return value?.isEmpty == true ? nil : value
    }
}
