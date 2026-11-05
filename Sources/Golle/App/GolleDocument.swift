import AppKit
import ImageIO
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    /// An undo or redo changed a document's data.
    static let golleUndoRedo = Notification.Name("golleUndoRedo")
}

extension UTType {
    static let golleDatabase = UTType(exportedAs: "com.iappyx.golle.database", conformingTo: .package)
}

/// One open `.golledb` package:
///
///     database.sqlite            the data (database.sqlite.sealed + lock.json when password-locked)
///     Attachments/<id>.<ext>     images and files (sealed when locked)
///
/// Any other file in the package is kept on save, so an older Golle doesn't drop what a newer one added.
///
/// Every data change goes through `change(_:coalesce:_:)`, which snapshots the database for undo.
/// SwiftUI marks the document edited when an undo is registered, and autosaves in place (with Versions).
final class GolleDocument: ReferenceFileDocument {
    static var readableContentTypes: [UTType] { [.golleDatabase] }
    static let sealedName = "database.sqlite.sealed"
    static let attachmentsFolder = "Attachments"

    struct Snapshot {
        var database: Database
        var attachments: [String: FileWrapper]
        var lock: LockInfo?
        var key: SymmetricKey?
        /// A locked document that was never unlocked is written back exactly as it was read.
        var lockedPackage: FileWrapper?
        var otherFiles: [String: FileWrapper]
    }

    @Published private(set) var database: Database {
        didSet {
            revision &+= 1
            cache.removeAll(keepingCapacity: true)
        }
    }
    /// Goes up with every change, so computed results (visible rows, counts) can be reused until then.
    private(set) var revision = 0
    private var cache: [String: Any] = [:]

    /// A value computed once per revision of the database, e.g. the records a view shows.
    func memo<T>(_ key: String, _ make: () -> T) -> T {
        if let hit = cache[key] as? T { return hit }
        let value = make()
        cache[key] = value
        return value
    }

    /// The searchable text of a table's records, built once per change.
    func haystack(_ resolver: Resolver) -> [Record.ID: String] {
        memo("haystack-\(resolver.table.id)") { Query.haystack(resolver) }
    }

    /// Whether the window shows the dashboard instead of a table. Window state.
    @Published var showsDashboard = false

    // Window state, not saved.
    @Published var selectedTableID: DataTable.ID? { didSet { if oldValue != selectedTableID { selectedViewID = nil; resetWindowState() } } }
    @Published var selectedViewID: SavedView.ID? { didSet { if oldValue != selectedViewID { resetWindowState() } } }
    @Published var selectedRecordIDs = Set<Record.ID>() {
        // Moving to another record starts a new undo step, even in the same field.
        didSet { if oldValue != selectedRecordIDs { coalescingKey = nil } }
    }
    /// The unsaved view ("All Records") of each table: its filter, sort and mode.
    @Published var scratchViews: [DataTable.ID: SavedView] = [:]
    /// Records added in this view stay visible even when the filter would hide them.
    @Published var pinnedRecordIDs = Set<Record.ID>()

    @Published private(set) var isLocked = false
    private(set) var lockInfo: LockInfo?
    private var key: SymmetricKey?
    private var lockedPackage: FileWrapper?

    /// Each attachment file as stored (sealed when locked), by file name. Kept after a record stops
    /// using it, so undo can bring it back; only referenced files are saved.
    private var attachmentFiles: [String: FileWrapper] = [:]
    private let imageCache = NSCache<NSString, NSImage>()
    /// Package contents this version doesn't use, written back unchanged.
    private var otherFiles: [String: FileWrapper] = [:]

    weak var undoManager: UndoManager?
    /// Typing into one cell makes one undo step, not one per keystroke.
    private var coalescingKey: String?
    private var coalescedAt = Date.distantPast

    init(database: Database = .blank()) {
        self.database = database
        selectedTableID = database.tables.first?.id
        watchDayChange()
    }

    private var dayObserver: NSObjectProtocol?

    deinit { dayObserver.map(NotificationCenter.default.removeObserver) }

    /// "Today", "in the last 7 days" and TODAY() mean something else after midnight: what was
    /// computed for yesterday is computed again.
    private func watchDayChange() {
        dayObserver = NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.cache.removeAll()
            self.objectWillChange.send()
        }
    }

    convenience init(configuration: ReadConfiguration) throws {
        try self.init(file: configuration.file)
    }

    init(file: FileWrapper) throws {
        guard let files = file.fileWrappers else { throw CocoaError(.fileReadCorruptFile) }
        let known: Set = [DatabaseFile.sqliteName, Self.sealedName, Self.attachmentsFolder, LockInfo.fileName]
        otherFiles = files.filter { !known.contains($0.key) }
        attachmentFiles = files[Self.attachmentsFolder]?.fileWrappers ?? [:]
        if let lockData = files[LockInfo.fileName]?.regularFileContents {
            lockInfo = try JSONDecoder().decode(LockInfo.self, from: lockData)
            database = Database()
            isLocked = true
            lockedPackage = file
        } else {
            guard let bytes = files[DatabaseFile.sqliteName]?.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
            database = try DatabaseFile.decode(bytes)
            selectedTableID = database.tables.first?.id
        }
        watchDayChange()
    }

    func snapshot(contentType: UTType) throws -> Snapshot {
        // After a save, the next keystroke must register undo again, so the document turns edited.
        coalescingKey = nil
        return Snapshot(database: database, attachments: attachmentFiles, lock: lockInfo, key: key,
                        lockedPackage: lockedPackage, otherFiles: otherFiles)
    }

    func fileWrapper(snapshot: Snapshot, configuration: WriteConfiguration) throws -> FileWrapper {
        try Self.package(snapshot)
    }

    static func package(_ snapshot: Snapshot) throws -> FileWrapper {
        if let locked = snapshot.lockedPackage { return locked }
        var files = snapshot.otherFiles
        let bytes = try DatabaseFile.encode(snapshot.database)
        if let lock = snapshot.lock, let key = snapshot.key {
            files[sealedName] = regularFile(try LockInfo.seal(bytes, with: key), named: sealedName)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            files[LockInfo.fileName] = regularFile(try encoder.encode(lock), named: LockInfo.fileName)
        } else {
            files[DatabaseFile.sqliteName] = regularFile(bytes, named: DatabaseFile.sqliteName)
        }
        let referenced = Set(snapshot.database.referencedAttachments.map(\.fileName))
        let attachments = snapshot.attachments.filter { referenced.contains($0.key) }
        if !attachments.isEmpty {
            let folder = FileWrapper(directoryWithFileWrappers: attachments)
            folder.preferredFilename = attachmentsFolder
            files[attachmentsFolder] = folder
        }
        return FileWrapper(directoryWithFileWrappers: files)
    }

    func package() throws -> FileWrapper { try Self.package(try snapshot(contentType: .golleDatabase)) }

    private static func regularFile(_ data: Data, named name: String) -> FileWrapper {
        let file = FileWrapper(regularFileWithContents: data)
        file.preferredFilename = name
        return file
    }

    // MARK: Changes

    /// Applies a change with undo. Changes with the same `coalesce` key in a row share one undo step.
    /// `known`: the caller already checked that something changes, so the (slow, for big databases)
    /// comparison is skipped.
    func change(_ actionName: String, coalesce key: String? = nil, known: Bool = false, _ body: (inout Database) -> Void) {
        guard !isLocked else { return }
        var updated = database
        body(&updated)
        guard known || updated != database else { return }
        if let key, continues(key) {
            database = updated
            coalescedAt = Date()
            return
        }
        coalescingKey = key
        coalescedAt = Date()
        replace(with: updated, actionName: actionName)
    }

    /// Whether a change with this key joins the previous undo step: same target, and no pause of
    /// more than a couple of seconds (a pause starts a new step, like in TextEdit).
    func continues(_ key: String) -> Bool {
        key == coalescingKey && Date().timeIntervalSince(coalescedAt) < 2.5
    }

    private func replace(with new: Database, actionName: String) {
        let old = database
        database = new
        undoManager?.registerUndo(withTarget: self) { document in
            document.coalescingKey = nil
            // Editors that skip late copies of their own text must show this one.
            NotificationCenter.default.post(name: .golleUndoRedo, object: nil)
            document.replace(with: old, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        keepSelectionValid()
    }

    private func keepSelectionValid() {
        if selectedTableID.flatMap(database.tableIndex) == nil {
            selectedTableID = database.tables.first?.id
        }
        if let table = currentTable {
            if let view = selectedViewID, !table.views.contains(where: { $0.id == view }) { selectedViewID = nil }
            let ids = Set(table.records.map(\.id))
            if !selectedRecordIDs.isSubset(of: ids) { selectedRecordIDs.formIntersection(ids) }
        } else {
            selectedRecordIDs = []
        }
    }

    private func resetWindowState() {
        selectedRecordIDs = []
        pinnedRecordIDs = []
    }

    var currentTable: DataTable? { database.table(selectedTableID) }

    func resolver(for table: DataTable) -> Resolver { Resolver(database: database, table: table) }

    // MARK: Tables

    func addTable(_ table: DataTable? = nil, actionName: String = "Add Table") {
        let names = Set(database.tables.map(\.name))
        var table = table ?? DataTable.blank(named: "")
        if table.name.isEmpty || names.contains(table.name) {
            let base = table.name.isEmpty ? "Table" : table.name
            table.name = (1...).lazy.map { table.name.isEmpty ? "\(base) \($0)" : ($0 == 1 ? base : "\(base) \($0)") }.first { !names.contains($0) }!
        }
        change(actionName) { $0.tables.append(table) }
        selectedTableID = table.id
        showsDashboard = false
    }

    func renameTable(_ id: DataTable.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        change("Rename Table") { db in db.tableIndex(id).map { db.tables[$0].name = trimmed } }
    }

    func deleteTable(_ id: DataTable.ID) {
        change("Delete Table") { $0.tables.removeAll { $0.id == id } }
    }

    func moveTables(from source: IndexSet, to destination: Int) {
        change("Move Table") { $0.tables.move(fromOffsets: source, toOffset: destination) }
    }

    /// Moves a table to just before another (dragging in the sidebar).
    func moveTable(_ id: DataTable.ID, before target: DataTable.ID) {
        guard id != target, let from = database.tableIndex(id), let to = database.tableIndex(target) else { return }
        change("Move Table") { $0.tables.move(fromOffsets: [from], toOffset: to) }
    }

    /// A copy of a table with its fields, records, views, layouts, totals and colour rules.
    func duplicateTable(_ id: DataTable.ID) {
        guard let table = database.table(id) else { return }
        var copy = table.duplicated()
        copy.name = table.name + " copy"
        addTable(copy, actionName: "Duplicate Table")
    }

    func setColorRules(_ rules: [ColorRule], in tableID: DataTable.ID) {
        // Typing a rule's value is one undo step; adding, removing or recolouring a rule is its own.
        var key: String?
        if let old = database.table(tableID)?.colorRules, old.count == rules.count {
            let changed = zip(old, rules).filter { $0 != $1 }
            if changed.count == 1, let (a, b) = changed.first, a.id == b.id, a.color == b.color,
               let rule = Self.typedRule(a.filter, b.filter) { key = "colors-\(tableID)-\(rule)" }
        }
        change("Change Colour Rules", coalesce: key) { db in db.tableIndex(tableID).map { db.tables[$0].colorRules = rules } }
    }

    /// The rule whose value is being typed, when that is all that differs between two filters.
    static func typedRule(_ old: Filter, _ new: Filter) -> FilterRule.ID? {
        guard old.match == new.match, old.rules.count == new.rules.count else { return nil }
        let changed = zip(old.rules, new.rules).filter { $0 != $1 }
        guard changed.count == 1, let (a, b) = changed.first, a.id == b.id, a.fieldID == b.fieldID, a.op == b.op,
              isTyping(a.operand, b.operand) else { return nil }
        return a.id
    }

    /// What is being typed or dragged in a view, when that is all that changed; nil for a change
    /// that is a step of its own (sorting, another mode, grouping).
    private static func viewTypingAspect(_ old: SavedView, _ new: SavedView) -> String? {
        var probe = new
        probe.filter = old.filter
        if probe == old, let rule = typedRule(old.filter, new.filter) { return "filter-\(rule)" }
        probe = new
        probe.columnData = old.columnData
        if probe == old { return "columns" }
        return nil
    }

    // MARK: Fields

    @discardableResult
    func addField(to tableID: DataTable.ID, type: FieldType = .text) -> Field.ID? {
        guard let t = database.tableIndex(tableID) else { return nil }
        let names = Set(database.tables[t].fields.map(\.name))
        let name = (1...).lazy.map { $0 == 1 ? type.label : "\(type.label) \($0)" }.first { !names.contains($0) }!
        var field = Field(name: name, type: type)
        if type == .link { field.options.linkedTableID = database.tables.first { $0.id != tableID }?.id ?? tableID }
        change("Add Field") { db in
            db.tables[t].fields.append(field)
            if type == .autoNumber {
                for r in db.tables[t].records.indices { db.tables[t].records[r][field.id] = .number(Double(r + 1)) }
            }
        }
        return field.id
    }

    func updateField(_ field: Field, in tableID: DataTable.ID) {
        // Typing (a formula, a prefix, a default) is one undo step; other changes each get their own.
        let key = database.table(tableID)?.field(field.id).flatMap { Self.typingAspect(from: $0, to: field) }.map { "field-\(field.id)-\($0)" }
        change("Change Field", coalesce: key) { db in
            guard let t = db.tableIndex(tableID), let f = db.tables[t].fieldIndex(field.id) else { return }
            let old = db.tables[t].fields[f]
            var field = field
            if field.type == .link, field.options.linkedTableID == nil {
                field.options.linkedTableID = db.tables.first { $0.id != tableID }?.id ?? tableID
            }
            // A name must stay unique and not empty: formulas and exports refer to fields by name.
            let name = field.name.trimmingCharacters(in: .whitespaces)
            // Compared the way formulas find fields: "Café" and "cafe" are the same name.
            let taken = db.tables[t].fields.contains {
                $0.id != field.id && $0.name.trimmingCharacters(in: .whitespaces)
                    .compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }
            field.name = name.isEmpty || taken ? old.name : name
            db.tables[t].fields[f] = field
            if old.name != field.name {
                Formula.renameField(old.name, to: field.name, inTable: tableID, database: &db)
            }
            if old.type != field.type || old.options.linkedTableID != field.options.linkedTableID {
                // Values follow the new type where they can; the rest would be meaningless, so they go.
                for r in db.tables[t].records.indices {
                    var value = db.tables[t].records[r][field.id]?.converted(to: field.type)
                    if field.type == .link, old.options.linkedTableID != field.options.linkedTableID { value = nil }
                    db.tables[t].records[r][field.id] = value
                }
            }
            if field.type == .autoNumber {
                // After converting, so numbers already there are kept; the rest are numbered in order.
                var next = db.tables[t].nextNumber(for: field.id)
                for r in db.tables[t].records.indices where db.tables[t].records[r][field.id]?.number == nil {
                    db.tables[t].records[r][field.id] = .number(next)
                    next += 1
                }
            }
        }
    }

    /// The text property that differs between two versions of a field, if that is the only change.
    private static func typingAspect(from old: Field, to new: Field) -> String? {
        var probe = new
        probe.options.formula = old.options.formula
        if probe == old { return "formula" }
        // Typed, not picked: picking a date, stars or an option twice is two steps.
        probe = new
        probe.options.defaultValue = old.options.defaultValue
        if probe == old, ![.date, .checkbox, .choice, .rating].contains(new.type),
           isTyping(old.options.defaultValue, new.options.defaultValue) { return "default" }
        // Prefix, suffix and currency; a field without a format yet starts from the plain one.
        probe = new
        let a = old.options.numberFormat ?? NumberFormat(), b = new.options.numberFormat ?? NumberFormat()
        if a.style == b.style, a.decimals == b.decimals {
            probe.options.numberFormat = old.options.numberFormat
            if probe == old { return "format" }
        }
        return nil
    }

    /// Whether one text grew or shrank from the end of the other, as it does while typing.
    static func isTyping(_ old: String, _ new: String) -> Bool {
        old.hasPrefix(new) || new.hasPrefix(old)
    }

    /// Renames a choice option, in the field's list and in every record that has it.
    func renameChoice(_ old: String, to new: String, field fieldID: Field.ID, table tableID: DataTable.ID) {
        // Keyed by the option's place, not its name, so typing a new name is one undo step.
        let before = database.table(tableID)?.field(fieldID)?.options.choices
        let position = before?.firstIndex(of: old) ?? -1
        change("Rename Option", coalesce: "option-\(fieldID)-\(position)") { db in
            guard let t = db.tableIndex(tableID), let f = db.tables[t].fieldIndex(fieldID) else { return }
            var options = db.tables[t].fields[f].options
            guard let index = options.choices.firstIndex(of: old), !options.choices.contains(new) else { return }
            options.choices[index] = new
            if let color = options.choiceColors.removeValue(forKey: old) { options.choiceColors[new] = color }
            if options.defaultValue == old { options.defaultValue = new }
            db.tables[t].fields[f].options = options
            for r in db.tables[t].records.indices {
                guard let choices = db.tables[t].records[r][fieldID]?.choices, choices.contains(old) else { continue }
                // A record may already hold the new name too (an option removed earlier): keep it once.
                var seen = Set<String>()
                db.tables[t].records[r][fieldID] = .choices(choices.map { $0 == old ? new : $0 }.filter { seen.insert($0).inserted })
            }
            // Filters and colour rules that pick this option follow it.
            for v in db.tables[t].views.indices { Self.renameOperand(old, to: new, field: fieldID, in: &db.tables[t].views[v].filter) }
            for c in db.tables[t].colorRules.indices { Self.renameOperand(old, to: new, field: fieldID, in: &db.tables[t].colorRules[c].filter) }
        }
        // The window's All Records filter too, with its own undo, but only when the option really
        // was renamed just now.
        let after = database.table(tableID)?.field(fieldID)?.options.choices
        if after != before, after?.contains(new) == true, var scratch = scratchViews[tableID] {
            Self.renameOperand(old, to: new, field: fieldID, in: &scratch.filter)
            if scratch != scratchViews[tableID] { replaceScratch(scratch, for: tableID) }
        }
    }

    /// All Records' unsaved settings, with undo (and redo) of their own.
    private func replaceScratch(_ view: SavedView?, for tableID: DataTable.ID) {
        let previous = scratchViews[tableID]
        scratchViews[tableID] = view
        undoManager?.registerUndo(withTarget: self) { document in document.replaceScratch(previous, for: tableID) }
    }

    private static func renameOperand(_ old: String, to new: String, field: Field.ID, in filter: inout Filter) {
        for i in filter.rules.indices where filter.rules[i].fieldID == field && filter.rules[i].operand == old {
            filter.rules[i].operand = new
        }
    }

    func moveFields(in tableID: DataTable.ID, from source: IndexSet, to destination: Int) {
        change("Move Field") { db in db.tableIndex(tableID).map { db.tables[$0].fields.move(fromOffsets: source, toOffset: destination) } }
    }

    func deleteField(_ fieldID: Field.ID, from tableID: DataTable.ID) {
        change("Delete Field") { db in
            guard let t = db.tableIndex(tableID) else { return }
            db.tables[t].fields.removeAll { $0.id == fieldID }
            for r in db.tables[t].records.indices { db.tables[t].records[r].values[fieldID] = nil }
            db.tables[t].summaries.removeAll { $0.fieldID == fieldID }
            // A colour rule left without conditions would match every record.
            db.tables[t].colorRules = db.tables[t].colorRules.compactMap { rule in
                guard rule.filter.rules.contains(where: { $0.fieldID == fieldID }) else { return rule }
                var rule = rule
                rule.filter.rules.removeAll { $0.fieldID == fieldID }
                return rule.filter.rules.isEmpty ? nil : rule
            }
            for v in db.tables[t].views.indices {
                db.tables[t].views[v].filter.rules.removeAll { $0.fieldID == fieldID }
                db.tables[t].views[v].sort.removeAll { $0.fieldID == fieldID }
            }
            for l in db.tables[t].layouts.indices {
                db.tables[t].layouts[l].items.removeAll { $0.kind == .field(fieldID) }
            }
            // Rollups and lookups anywhere that went through or added up this field have nothing left to show.
            for t2 in db.tables.indices {
                for f in db.tables[t2].fields.indices where db.tables[t2].fields[f].type == .rollup || db.tables[t2].fields[f].type == .lookup {
                    if db.tables[t2].fields[f].options.rollupLinkFieldID == fieldID {
                        db.tables[t2].fields[f].options.rollupLinkFieldID = nil
                        db.tables[t2].fields[f].options.rollupFieldID = nil
                    }
                    if db.tables[t2].fields[f].options.rollupFieldID == fieldID { db.tables[t2].fields[f].options.rollupFieldID = nil }
                }
            }
        }
    }

    // MARK: Records

    /// A new record with the table's default values and next auto numbers, then `values` on top.
    static func newRecord(in table: DataTable, values: [Field.ID: Value] = [:]) -> Record {
        var record = Record()
        for field in table.fields {
            if field.type == .autoNumber { record[field.id] = .number(table.nextNumber(for: field.id)) }
            else if let value = field.defaultValue { record[field.id] = value }
        }
        for (field, value) in values { record[field] = value }
        return record
    }

    @discardableResult
    func addRecord(to tableID: DataTable.ID, values: [Field.ID: Value] = [:]) -> Record.ID? {
        guard let t = database.tableIndex(tableID) else { return nil }
        let record = Self.newRecord(in: database.tables[t], values: values)
        change("New Record") { $0.tables[t].records.append(record) }
        if tableID == selectedTableID {
            pinnedRecordIDs.insert(record.id)
            selectedRecordIDs = [record.id]
        }
        return record.id
    }

    func deleteRecords(_ ids: Set<Record.ID>, from tableID: DataTable.ID) {
        guard !ids.isEmpty else { return }
        change(ids.count == 1 ? "Delete Record" : "Delete Records") { db in
            db.tableIndex(tableID).map { db.tables[$0].records.removeAll { ids.contains($0.id) } }
        }
    }

    func duplicateRecords(_ ids: Set<Record.ID>, in tableID: DataTable.ID) {
        guard let t = database.tableIndex(tableID), !ids.isEmpty else { return }
        var copies: [Record] = []
        change("Duplicate") { db in
            let autoFields = db.tables[t].fields.filter { $0.type == .autoNumber }.map(\.id)
            var numbers = Dictionary(uniqueKeysWithValues: autoFields.map { ($0, db.tables[t].nextNumber(for: $0)) })
            var records: [Record] = []
            for record in db.tables[t].records {
                records.append(record)
                if ids.contains(record.id) {
                    var copy = Record(values: record.values)
                    // Auto numbers are never shared: the copy gets the next one.
                    for field in autoFields {
                        copy[field] = .number(numbers[field] ?? 1)
                        numbers[field] = (numbers[field] ?? 1) + 1
                    }
                    copies.append(copy)
                    records.append(copy)
                }
            }
            db.tables[t].records = records
        }
        pinnedRecordIDs.formUnion(copies.map(\.id))
        selectedRecordIDs = Set(copies.map(\.id))
    }

    func setValue(_ value: Value?, record recordID: Record.ID, field fieldID: Field.ID, table tableID: DataTable.ID) {
        guard let t = database.tableIndex(tableID), let r = database.tables[t].recordIndex(recordID) else { return }
        let old = database.tables[t].records[r][fieldID]
        let stored: Value? = value?.isEmpty == true ? nil : value
        guard old != stored else { return }
        let key = "cell-\(recordID)-\(fieldID)"
        // Typing on in the same cell extends the same history entry, as it extends the same undo step.
        let continuing = continues(key)
        change("Edit", coalesce: key, known: true) { db in
            db.tables[t].records[r][fieldID] = value
            db.tables[t].records[r].modified = .stamp()
            db.tables[t].recordChange(recordID, field: fieldID, old: old, new: stored, continuing: continuing)
        }
    }

    /// Moves a record's dates by whole days, keeping their time of day: the start and end together
    /// (dragging a timeline bar), or only the end (`moveStart` false: dragging its edge). An empty
    /// end counts from the start. One undo step.
    func shiftDates(record recordID: Record.ID, table tableID: DataTable.ID, start: Field.ID, end: Field.ID?, moveStart: Bool, byDays days: Int) {
        guard days != 0, let t = database.tableIndex(tableID), let r = database.tables[t].recordIndex(recordID),
              let startDate = database.tables[t].records[r][start]?.date else { return }
        let record = database.tables[t].records[r]
        // Moving leaves an empty end empty (the bar is one day long either way). Changing the end
        // counts from the end shown: an end before the start shows as the start.
        let fields: [Field.ID]
        if moveStart {
            fields = [start] + [end].compactMap { $0 }.filter { record[$0]?.date != nil }
        } else {
            fields = [end].compactMap { $0 }
        }
        guard !fields.isEmpty else { return }
        change(moveStart ? "Move Dates" : "Change End Date") { db in
            for field in fields {
                let old = db.tables[t].records[r][field]
                var base = old?.date ?? startDate
                let calendar = Calendar.current
                if !moveStart, calendar.startOfDay(for: base) < calendar.startOfDay(for: startDate) { base = startDate }
                guard let moved = Calendar.current.date(byAdding: .day, value: days, to: base) else { continue }
                let new = Value.date(moved)
                db.tables[t].records[r][field] = new
                db.tables[t].records[r].modified = .stamp()
                db.tables[t].recordChange(recordID, field: field, old: old, new: new, continuing: false)
            }
        }
    }

    /// Replaces text in the matched cells, each noted in its record's history. One undo step.
    func replaceText(_ matches: [FindReplace.Match], in tableID: DataTable.ID) {
        guard !matches.isEmpty else { return }
        change(matches.count == 1 ? "Replace" : "Replace \(matches.count)") { db in
            guard let t = db.tableIndex(tableID) else { return }
            for match in matches {
                guard let r = db.tables[t].recordIndex(match.record.id) else { continue }
                let old = db.tables[t].records[r][match.field.id]
                // Only where the cell still holds the text the match was found in.
                guard old?.text == match.old else { continue }
                let new = FindReplace.value(match.new, for: match.field)
                guard new != old else { continue }
                db.tables[t].records[r][match.field.id] = new
                db.tables[t].records[r].modified = .stamp()
                db.tables[t].recordChange(match.record.id, field: match.field.id, old: old, new: new, continuing: false)
            }
        }
    }

    /// Sets one field on many records at once (batch edit). One undo step.
    /// `typing`: changes from the batch form, where keystrokes join one undo step and one history
    /// entry. Drops on the board or calendar are each their own step.
    func setValue(_ value: Value?, records ids: Set<Record.ID>, field fieldID: Field.ID, table tableID: DataTable.ID, typing: Bool = false) {
        updateValues(records: ids, field: fieldID, table: tableID, typing: typing) { _ in value }
    }

    /// Changes one field of many records, each from its own current value (batch edit, adding or
    /// removing one option on records that differ). One undo step.
    func updateValues(records ids: Set<Record.ID>, field fieldID: Field.ID, table tableID: DataTable.ID, typing: Bool = false,
                      _ transform: (Value?) -> Value?) {
        let key = typing ? "batch-\(fieldID)-\(ids.map(\.uuidString).sorted().joined().hashValue)" : nil
        let continuing = key.map(continues) ?? false
        change(ids.count == 1 ? "Edit" : "Edit \(ids.count) Records", coalesce: key) { db in
            guard let t = db.tableIndex(tableID) else { return }
            for r in db.tables[t].records.indices where ids.contains(db.tables[t].records[r].id) {
                let old = db.tables[t].records[r][fieldID]
                let new = transform(old).flatMap { $0.isEmpty ? nil : $0 }
                guard old != new else { continue }
                db.tables[t].records[r][fieldID] = new
                db.tables[t].records[r].modified = .stamp()
                db.tables[t].recordChange(db.tables[t].records[r].id, field: fieldID, old: old, new: new, continuing: continuing)
            }
        }
    }

    /// Merges each group of duplicates into its first record: empty fields are filled from the
    /// others, choices, files and links are combined, and links to the removed records are moved
    /// to the kept one. One undo step.
    func mergeDuplicates(_ groups: [[Record.ID]], in tableID: DataTable.ID) {
        change(groups.count == 1 ? "Merge Records" : "Merge Duplicates") { db in
            Duplicates.merge(groups, in: tableID, database: &db)
        }
    }

    /// Adds records (from an import), creating any new fields first. One undo step.
    /// Imported records get the table's default values (for fields the import doesn't fill) and the
    /// next auto numbers, like records added by hand.
    func importRecords(_ records: [Record], newFields: [Field], into tableID: DataTable.ID, mapped: Set<Field.ID> = []) {
        change("Import") { db in
            guard let t = db.tableIndex(tableID) else { return }
            let existing = db.tables[t].fields
            db.tables[t].fields.append(contentsOf: newFields)
            let autoFields = existing.filter { $0.type == .autoNumber }.map(\.id)
            var used = Dictionary(uniqueKeysWithValues: autoFields.map { id in (id, Set(db.tables[t].records.compactMap { $0[id]?.number })) })
            // Numbers from the file are kept where they are free; the rest are numbered after them.
            var next = Dictionary(uniqueKeysWithValues: autoFields.map { id in
                (id, max(db.tables[t].nextNumber(for: id), (records.compactMap { $0[id]?.number }.max() ?? 0) + 1))
            })
            for var record in records {
                for id in autoFields {
                    if let n = record[id]?.number, used[id]?.contains(n) != true {
                        used[id]?.insert(n)
                    } else if let n = next[id] {
                        record[id] = .number(n)
                        next[id] = n + 1
                    }
                }
                // A blank cell in a column that was imported stays blank: the file says so.
                for field in existing where field.type != .autoNumber && !mapped.contains(field.id) && record[field.id] == nil {
                    if let value = field.defaultValue { record[field.id] = value }
                }
                db.tables[t].records.append(record)
            }
        }
    }

    // MARK: Views

    /// The view in the window: the selected saved view, or this table's unsaved one.
    var currentView: SavedView {
        guard let table = currentTable else { return SavedView(name: "All Records") }
        if let id = selectedViewID, let view = table.views.first(where: { $0.id == id }) { return view }
        return scratchViews[table.id] ?? SavedView(name: "All Records")
    }

    var isSavedView: Bool { selectedViewID != nil }

    func updateCurrentView(_ actionName: String = "Change View", _ body: (inout SavedView) -> Void) {
        guard let table = currentTable else { return }
        var view = currentView
        body(&view)
        guard view != currentView else { return }
        if let id = selectedViewID {
            let key = Self.viewTypingAspect(currentView, view).map { "view-\(id)-\($0)" }
            change(actionName, coalesce: key) { db in
                guard let t = db.tableIndex(table.id), let v = db.tables[t].views.firstIndex(where: { $0.id == id }) else { return }
                db.tables[t].views[v] = view
            }
        } else {
            scratchViews[table.id] = view
        }
    }

    /// Saves the current filter, sort and mode as a named view and shows it.
    func saveCurrentView(named name: String) {
        guard let table = currentTable else { return }
        var view = currentView
        view.id = UUID()
        view.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? "View" : name.trimmingCharacters(in: .whitespaces)
        change("Save View") { db in db.tableIndex(table.id).map { db.tables[$0].views.append(view) } }
        // Saved from All Records: it starts fresh. Undoing the save brings its filter and sort back
        // (and redo clears them again). Saved from another saved view, All Records stays as it is.
        let scratch = selectedViewID == nil ? nil : scratchViews[table.id]
        setScratch(scratch, for: table.id, from: selectedViewID, to: view.id)
    }

    /// All Records' unsaved settings and the selected view, with undo that restores both. The
    /// selection only moves when the window still shows `from` in that table: undo and redo don't
    /// pull the window away from another view or table opened since.
    private func setScratch(_ view: SavedView?, for tableID: DataTable.ID, from: SavedView.ID?, to: SavedView.ID?) {
        let previous = scratchViews[tableID]
        scratchViews[tableID] = view
        if selectedTableID == tableID, selectedViewID == from { selectedViewID = to }
        keepSelectionValid()
        undoManager?.registerUndo(withTarget: self) { document in
            document.setScratch(previous, for: tableID, from: to, to: from)
        }
    }

    func renameView(_ id: SavedView.ID, in tableID: DataTable.ID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        change("Rename View") { db in
            guard let t = db.tableIndex(tableID), let v = db.tables[t].views.firstIndex(where: { $0.id == id }) else { return }
            db.tables[t].views[v].name = trimmed
        }
    }

    func deleteView(_ id: SavedView.ID, in tableID: DataTable.ID) {
        change("Delete View") { db in db.tableIndex(tableID).map { db.tables[$0].views.removeAll { $0.id == id } } }
    }

    // MARK: Summaries

    func addSummary(field: Field.ID, kind: SummaryKind, in tableID: DataTable.ID) {
        change("Add Summary") { db in db.tableIndex(tableID).map { db.tables[$0].summaries.append(SummaryItem(fieldID: field, kind: kind)) } }
    }

    func setSummary(_ id: SummaryItem.ID, kind: SummaryKind, in tableID: DataTable.ID) {
        change("Change Summary") { db in
            guard let t = db.tableIndex(tableID), let s = db.tables[t].summaries.firstIndex(where: { $0.id == id }) else { return }
            db.tables[t].summaries[s].kind = kind
        }
    }

    func removeSummary(_ id: SummaryItem.ID, from tableID: DataTable.ID) {
        change("Remove Summary") { db in db.tableIndex(tableID).map { db.tables[$0].summaries.removeAll { $0.id == id } } }
    }

    // MARK: Layouts

    @discardableResult
    func addLayout(to tableID: DataTable.ID) -> FormLayout.ID? {
        guard let table = database.table(tableID) else { return nil }
        let names = Set(table.layouts.map(\.name))
        let name = (1...).lazy.map { $0 == 1 ? "Form" : "Form \($0)" }.first { !names.contains($0) }!
        var layout = FormLayout.automatic(for: table, named: name)
        // A stored layout gets its own ids (the automatic one reuses the table's and fields').
        layout.id = UUID()
        layout.items = layout.items.map { var item = $0; item.id = UUID(); return item }
        change("New Layout") { db in db.tableIndex(tableID).map { db.tables[$0].layouts.append(layout) } }
        return layout.id
    }

    /// Changes with the same `coalesce` key (one drag, one text edit) make one undo step.
    func updateLayout(_ layout: FormLayout, in tableID: DataTable.ID, actionName: String = "Change Layout", coalesce: String? = nil) {
        change(actionName, coalesce: coalesce) { db in
            guard let t = db.tableIndex(tableID), let l = db.tables[t].layouts.firstIndex(where: { $0.id == layout.id }) else { return }
            db.tables[t].layouts[l] = layout
        }
    }

    func deleteLayout(_ id: FormLayout.ID, from tableID: DataTable.ID) {
        change("Delete Layout") { db in db.tableIndex(tableID).map { db.tables[$0].layouts.removeAll { $0.id == id } } }
    }

    // MARK: Dashboard

    func addTile(_ tile: DashboardTile) {
        change("Add Tile") { $0.dashboard.append(tile) }
    }

    func updateTile(_ tile: DashboardTile) {
        change("Change Tile") { db in db.dashboard.firstIndex { $0.id == tile.id }.map { db.dashboard[$0] = tile } }
    }

    func removeTile(_ id: DashboardTile.ID) {
        change("Remove Tile") { $0.dashboard.removeAll { $0.id == id } }
    }

    func moveTile(_ id: DashboardTile.ID, by offset: Int) {
        change("Move Tile") { db in
            guard let i = db.dashboard.firstIndex(where: { $0.id == id }), db.dashboard.indices.contains(i + offset) else { return }
            db.dashboard.swapAt(i, i + offset)
        }
    }

    // MARK: Look

    func setAccent(_ accent: AccentChoice) {
        change("Change Colour") { $0.settings.accent = accent }
    }

    func setSymbol(_ symbol: String) {
        change("Change Icon") { $0.settings.symbol = symbol }
    }

    // MARK: Attachments

    /// Copies a file into the document. The record refers to it once its value is set.
    func importAttachment(from url: URL) throws -> Attachment {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        return addAttachment(data: data, name: url.lastPathComponent)
    }

    func addAttachment(data: Data, name: String) -> Attachment {
        let attachment = Attachment(name: name)
        attachmentFiles[attachment.fileName] = stored(data, name: attachment.fileName, key: key)
        return attachment
    }

    func attachmentData(_ attachment: Attachment) -> Data? {
        guard let file = attachmentFiles[attachment.fileName], let stored = file.regularFileContents else { return nil }
        return plain(stored, key: key)
    }

    /// A small version of an image for tables, cards and thumbnails: decoding full photos for every
    /// card would make big galleries slow.
    func thumbnail(_ attachment: Attachment, size: CGFloat = 400) -> NSImage? {
        let cacheKey = "\(attachment.fileName)@\(Int(size))" as NSString
        if let cached = imageCache.object(forKey: cacheKey) { return cached }
        guard let data = attachmentData(attachment), let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: size]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return image(attachment) }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        imageCache.setObject(image, forKey: cacheKey)
        return image
    }

    func image(_ attachment: Attachment) -> NSImage? {
        let cacheKey = attachment.fileName as NSString
        if let cached = imageCache.object(forKey: cacheKey) { return cached }
        guard let data = attachmentData(attachment), let image = NSImage(data: data) else { return nil }
        imageCache.setObject(image, forKey: cacheKey)
        return image
    }

    /// A copy outside the document, to open in another app or in Quick Look. Removed when Golle quits.
    func exportedURL(for attachment: Attachment) -> URL? {
        guard let data = attachmentData(attachment) else { return nil }
        let folder = Self.temporaryFolder.appendingPathComponent(attachment.id.uuidString, isDirectory: true)
        let safeName = attachment.name.replacingOccurrences(of: "/", with: "-")
        let url = folder.appendingPathComponent(safeName.isEmpty ? attachment.fileName : safeName)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard (try? data.write(to: url)) != nil else { return nil }
        }
        return url
    }

    static let temporaryFolder = FileManager.default.temporaryDirectory.appendingPathComponent("Golle", isDirectory: true)

    private func stored(_ data: Data, name: String, key: SymmetricKey?) -> FileWrapper {
        let sealed = key.flatMap { try? LockInfo.seal(data, with: $0) } ?? data
        return Self.regularFile(sealed, named: name)
    }

    private func plain(_ stored: Data, key: SymmetricKey?) -> Data? {
        guard let key else { return stored }
        return try? LockInfo.open(stored, with: key)
    }

    // MARK: Password lock

    var isEncrypted: Bool { lockInfo != nil }
    var rememberedForTouchID: Bool { lockInfo.map { KeyStore.has($0.id) } ?? false }

    func unlock(password: String) throws {
        guard let key = lockInfo?.key(for: password) else { throw LockError.wrongPassword }
        try unlock(with: key)
    }

    func unlockWithTouchID() async -> Bool {
        guard let info = lockInfo, let key = await KeyStore.load(info.id, reason: "unlock this database") else { return false }
        return await MainActor.run { (try? unlock(with: key)) != nil }
    }

    func unlock(with key: SymmetricKey) throws {
        guard isLocked, let info = lockInfo, info.verifies(key) else { throw LockError.wrongPassword }
        guard let sealed = lockedPackage?.fileWrappers?[Self.sealedName]?.regularFileContents,
              let bytes = try? LockInfo.open(sealed, with: key) else { throw LockError.damaged }
        database = try DatabaseFile.decode(bytes)
        self.key = key
        lockedPackage = nil
        isLocked = false
        selectedTableID = database.tables.first?.id
    }

    /// Sets or changes the password. Every file is sealed again with the new key on the next save.
    func setPassword(_ password: String, hint: String?, rememberWithTouchID: Bool) throws {
        guard !isLocked else { return }
        let (info, newKey) = try LockInfo.create(password: password, hint: hint)
        // Old keys stay in the Keychain: undoing a password change brings the old lock back, and
        // older versions of the file (macOS Versions) still use it.
        if rememberWithTouchID { KeyStore.save(newKey, for: info.id) }
        applyLock(info, key: newKey, actionName: lockInfo == nil ? "Set Password" : "Change Password")
    }

    func removePassword() {
        guard !isLocked, lockInfo != nil else { return }
        applyLock(nil, key: nil, actionName: "Remove Password")
    }

    private func applyLock(_ info: LockInfo?, key newKey: SymmetricKey?, actionName: String) {
        let old = (lockInfo, key)
        var rewrapped: [String: FileWrapper] = [:]
        for (name, file) in attachmentFiles {
            guard let content = file.regularFileContents, let data = plain(content, key: key) else { continue }
            rewrapped[name] = stored(data, name: name, key: newKey)
        }
        objectWillChange.send()
        lockInfo = info
        key = newKey
        attachmentFiles = rewrapped
        coalescingKey = nil
        undoManager?.registerUndo(withTarget: self) { document in document.applyLock(old.0, key: old.1, actionName: actionName) }
        undoManager?.setActionName(actionName)
    }
}
