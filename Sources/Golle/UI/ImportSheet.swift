import SwiftUI

/// Imports a CSV file into a new table or the current one, column by column.
struct ImportSheet: View {
    @ObservedObject var document: GolleDocument
    let url: URL
    @Environment(\.dismiss) private var dismiss

    @State private var rows: [[String]] = []
    /// A semicolon CSV writes decimals with a comma: "1,250" is one and a quarter.
    @State private var decimalSeparator: String?
    @State private var error: String?
    @State private var hasHeader = true
    @State private var intoNewTable = true
    @State private var tableName = ""
    /// For a new table: the type of each column, nil to skip it.
    @State private var types: [FieldType?] = []
    /// For the current table: the field each column fills, nil to skip it; `newField` makes one.
    @State private var targets: [UUID?] = []
    private static let newField = UUID()

    private var columnCount: Int { rows.map(\.count).max() ?? 0 }
    private var dataRows: [[String]] { hasHeader ? Array(rows.dropFirst()) : rows }
    private var current: DataTable? { document.currentTable }

    private func header(_ index: Int) -> String {
        if hasHeader, let first = rows.first, index < first.count, !first[index].trimmingCharacters(in: .whitespaces).isEmpty {
            return first[index].trimmingCharacters(in: .whitespaces)
        }
        return "Column \(index + 1)"
    }

    private func values(_ index: Int) -> [String] { dataRows.map { index < $0.count ? $0[index] : "" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import “\(url.lastPathComponent)”").font(.title3.bold())
            if let error {
                Text(error).foregroundStyle(.red)
            } else {
                HStack {
                    Toggle("First row holds field names", isOn: $hasHeader)
                    Spacer()
                    Text("\(dataRows.count) records").foregroundStyle(.secondary)
                }
                Picker("Import into", selection: $intoNewTable) {
                    Text("A new table").tag(true)
                    if let current { Text("“\(current.name)”").tag(false) }
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                if intoNewTable {
                    TextField("Table name", text: $tableName)
                }
                Table((0..<columnCount).map(ColumnIndex.init)) {
                    TableColumn("Column") { column in Text(header(column.id)).fontWeight(.medium) }
                    TableColumn("Sample") { column in
                        Text(values(column.id).first { !$0.isEmpty } ?? "").foregroundStyle(.secondary).lineLimit(1)
                    }
                    TableColumn(intoNewTable ? "Import as" : "Into field") { column in
                        if intoNewTable { typePicker(column.id) } else { targetPicker(column.id) }
                    }
                    .width(min: 180)
                }
                .frame(minHeight: 220)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") { runImport(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(error != nil || dataRows.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 640, height: 520)
        .onAppear(perform: load)
        .onChange(of: hasHeader) { _, _ in guess() }
    }

    private func typePicker(_ index: Int) -> some View {
        Picker("Type", selection: Binding(get: { index < types.count ? types[index] : nil }, set: { if index < types.count { types[index] = $0 } })) {
            Text("Skip").tag(FieldType?.none)
            Divider()
            ForEach(FieldType.allCases.filter { !$0.isAttachment && $0 != .link && !$0.isComputed }) { type in
                Label(type.label, systemImage: type.symbol).tag(FieldType?.some(type))
            }
        }
        .labelsHidden()
    }

    private func targetPicker(_ index: Int) -> some View {
        Picker("Field", selection: Binding(get: { index < targets.count ? targets[index] : nil }, set: { if index < targets.count { targets[index] = $0 } })) {
            Text("Skip").tag(UUID?.none)
            Text("New Field").tag(UUID?.some(Self.newField))
            Divider()
            ForEach(current?.fields.filter { !$0.type.isAttachment && $0.type != .link && !$0.type.isComputed } ?? []) { field in
                Label(field.name, systemImage: field.type.symbol).tag(UUID?.some(field.id))
            }
        }
        .labelsHidden()
    }

    private func load() {
        do {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if url.pathExtension.lowercased() == "xlsx" {
                rows = try XLSX.read(url)
                decimalSeparator = nil
            } else {
                let text = try CSV.read(url)
                rows = CSV.parse(text)
                decimalSeparator = CSV.guessDelimiter(text) == ";" ? "," : nil
            }
            if rows.isEmpty { error = "The file holds no rows." }
        } catch {
            self.error = "Could not read the file: \(error.localizedDescription)"
        }
        tableName = url.deletingPathExtension().lastPathComponent
        intoNewTable = true
        guess()
    }

    private func guess() {
        types = Value.$decimalSeparator.withValue(decimalSeparator) { (0..<columnCount).map { Importer.guessType(values($0)) } }
        targets = (0..<columnCount).map { index in
            current?.field(named: header(index)).map(\.id) ?? Self.newField
        }
    }

    /// A field name not used yet: repeated column names get a number (formulas and exports go by name).
    private func freeName(_ name: String, taken: inout Set<String>) -> String {
        var candidate = name, n = 2
        while taken.contains(candidate.lowercased()) { candidate = "\(name) \(n)"; n += 1 }
        taken.insert(candidate.lowercased())
        return candidate
    }

    private func runImport() {
        Value.$decimalSeparator.withValue(decimalSeparator) { importRows() }
    }

    private func importRows() {
        let rows = dataRows
        if intoNewTable {
            var columns: [(index: Int, field: Field)] = []
            var taken = Set<String>()
            for index in 0..<columnCount {
                guard index < types.count, let type = types[index] else { continue }
                columns.append((index, Importer.field(named: freeName(header(index), taken: &taken), type: type, values: values(index))))
            }
            var table = DataTable(name: tableName.trimmingCharacters(in: .whitespaces).isEmpty ? "Imported" : tableName)
            table.fields = columns.map(\.field)
            table.records = Importer.records(rows, columns: columns)
            document.addTable(table, actionName: "Import")
        } else if let current {
            var columns: [(index: Int, field: Field)] = []
            var newFields: [Field] = []
            var taken = Set(current.fields.map { $0.name.lowercased() })
            for index in 0..<columnCount {
                guard index < targets.count, let target = targets[index] else { continue }
                if target == Self.newField {
                    let field = Importer.field(named: freeName(header(index), taken: &taken), type: Importer.guessType(values(index)), values: values(index))
                    newFields.append(field)
                    columns.append((index, field))
                } else if let field = current.field(target) {
                    columns.append((index, field))
                }
            }
            document.importRecords(Importer.records(rows, columns: columns), newFields: newFields, into: current.id,
                                   mapped: Set(columns.map(\.field.id)))
        }
    }
}

private struct ColumnIndex: Identifiable {
    let id: Int
}
