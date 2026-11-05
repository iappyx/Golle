import SwiftUI

/// The records as a sortable grid, edited in place. One column per field; click a header to sort.
/// With grouping, records sit under collapsible group rows that show counts and totals.
struct RecordTable: View {
    @ObservedObject var document: GolleDocument
    let table: DataTable
    let rows: [Record]
    let resolver: Resolver
    let groupFields: [Field]
    /// The view's visible fields, as columns.
    let fields: [Field]
    @Binding var sort: [SortKey]
    /// Column order and widths, saved with the view.
    @Binding var columns: TableColumnCustomization<Row>
    @State private var collapsed = Set<String>()

    enum Row: Identifiable {
        case record(Record)
        case group(RecordGroup)

        var id: String {
            switch self {
            case .record(let r): r.id.uuidString
            case .group(let g): "group:" + g.id
            }
        }
    }

    private var groups: [RecordGroup] { Grouping.groups(rows, by: groupFields, resolver) }

    /// The record shown last (grouping changes the order on screen): Return there adds a record.
    private var lastShownID: Record.ID? {
        guard !groupFields.isEmpty else { return rows.last?.id }
        // The last record that can be seen: collapsed groups hide theirs.
        func last(_ groups: [RecordGroup]) -> Record.ID? {
            for group in groups.reversed() where !collapsed.contains(group.id) {
                if let id = group.subgroups.isEmpty ? group.records.last?.id : last(group.subgroups) { return id }
            }
            return nil
        }
        return last(groups)
    }

    private var selection: Binding<Set<String>> {
        Binding(
            get: { Set(document.selectedRecordIDs.map(\.uuidString)) },
            set: { ids in
                // Only a real change: writing back the same selection while the table is updating
                // makes it update again from inside itself.
                let new = Set(ids.compactMap(UUID.init(uuidString:)))
                if new != document.selectedRecordIDs { document.selectedRecordIDs = new }
            }
        )
    }

    var body: some View {
        Table(of: Row.self, selection: selection, sortOrder: sortOrder, columnCustomization: $columns) {
            TableColumnForEach(fields) { field in
                TableColumn(field.name, sortUsing: RowSort(fieldID: field.id)) { (row: Row) in
                    RowCell(document: document, table: table, field: field, row: row, resolver: resolver,
                            lastID: lastShownID, isFirst: field.id == fields.first?.id)
                }
                .width(min: 50, ideal: idealWidth(field))
                .customizationID(field.id.uuidString)
                // Which fields show is the view's "Fields" menu, so the header menu doesn't hide columns.
                .disabledCustomizationBehavior(.visibility)
            }
        } rows: {
            tableRows
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let records = Set(ids.compactMap(UUID.init(uuidString:)))
            if !records.isEmpty {
                Button("Duplicate") { document.duplicateRecords(records, in: table.id) }
                Button(records.count == 1 ? "Delete Record" : "Delete \(records.count) Records", role: .destructive) {
                    document.deleteRecords(records, from: table.id)
                }
            } else {
                Button("New Record") { document.addRecord(to: table.id) }
                if !collapsed.isEmpty { Button("Expand All Groups") { collapsed = [] } }
            }
        }
        .onDeleteCommand { document.deleteRecords(document.selectedRecordIDs, from: table.id) }
    }

    private var sortOrder: Binding<[RowSort]> {
        Binding(get: { sort.map { RowSort(fieldID: $0.fieldID, order: $0.ascending ? .forward : .reverse) } },
                set: { sort = $0.map { SortKey(fieldID: $0.fieldID, ascending: $0.order == .forward) } })
    }

    /// The column header's sort state. Golle sorts the rows itself (formulas, links and groups need
    /// the whole database), so this only carries which field and which direction.
    struct RowSort: SortComparator, Hashable {
        var fieldID: Field.ID
        var order: SortOrder = .forward
        func compare(_ lhs: Row, _ rhs: Row) -> ComparisonResult { .orderedSame }
    }

    @TableRowBuilder<Row>
    private var tableRows: some TableRowContent<Row> {
        if groupFields.isEmpty {
            ForEach(rows) { record in
                TableRow(Row.record(record))
            }
        } else {
            ForEach(groups) { group in
                groupRow(group)
            }
        }
    }

    private func groupRow(_ group: RecordGroup) -> some TableRowContent<Row> {
        DisclosureTableRow(Row.group(group), isExpanded: expanded(group.id)) {
            ForEach(group.subgroups) { sub in
                DisclosureTableRow(Row.group(sub), isExpanded: expanded(sub.id)) {
                    ForEach(sub.records) { record in
                        TableRow(Row.record(record))
                    }
                }
            }
            // With one level of grouping the records sit directly under the group.
            ForEach(group.subgroups.isEmpty ? group.records : []) { record in
                TableRow(Row.record(record))
            }
        }
    }

    private func expanded(_ id: String) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(id) }, set: { if $0 { collapsed.remove(id) } else { collapsed.insert(id) } })
    }

    private func idealWidth(_ field: Field) -> CGFloat {
        switch field.type {
        case .checkbox: 64
        case .rating, .number, .autoNumber, .duration, .color: 110
        case .date: field.options.includesTime ? 160 : 110
        case .progress: 140
        case .createdAt, .modifiedAt: 150
        case .longText: 260
        case .image: 70
        default: 170
        }
    }
}

/// One cell of the grouped or plain table.
private struct RowCell: View {
    @ObservedObject var document: GolleDocument
    let table: DataTable
    let field: Field
    let row: RecordTable.Row
    let resolver: Resolver
    let lastID: Record.ID?
    let isFirst: Bool

    var body: some View {
        switch row {
        case .record(let record):
            let problem = resolver.hasRules ? resolver.ruleProblem(record, field) : nil
            HStack(spacing: 4) {
                if isFirst, let color = table.color(of: record, resolver) {
                    RoundedRectangle(cornerRadius: 2).fill(color.color).frame(width: 4)
                        .help("Colour rule")
                }
                EditableCell(document: document, table: table, field: field, record: record, resolver: resolver,
                             isLast: record.id == lastID)
                if let problem {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("\(field.name): \(problem.message)")
                }
            }
            .background(problem == nil ? Color.clear : Color.orange.opacity(0.14), in: .rect(cornerRadius: 3))
        case .group(let group):
            GroupCell(table: table, field: field, group: group, resolver: resolver, isFirst: isFirst)
        }
    }
}

/// A group row: the group's name and count in the first column, totals under their fields.
private struct GroupCell: View {
    let table: DataTable
    let field: Field
    let group: RecordGroup
    let resolver: Resolver
    let isFirst: Bool

    var body: some View {
        if isFirst {
            HStack(spacing: 6) {
                Text(group.title).fontWeight(.semibold).lineLimit(1)
                Text("\(group.records.count)").foregroundStyle(.secondary).monospacedDigit()
            }
        } else if let item = table.summaries.first(where: { $0.fieldID == field.id }) {
            Text(item.kind.compute(group.records.map { resolver.value($0, field) }, field: resolver.formatField(field)))
                .foregroundStyle(.secondary)
                .fontWeight(.medium)
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: field.type.isNumeric || field.type == .formula || field.type == .rollup || field.type == .lookup ? .trailing : .leading)
                .help("\(item.kind.label) of \(field.name)")
        }
    }
}

/// A cell that edits in place where the type allows it; the rest show their value and are edited
/// in the inspector.
struct EditableCell: View {
    @ObservedObject var document: GolleDocument
    let table: DataTable
    let field: Field
    let record: Record
    let resolver: Resolver
    var isLast = false

    private var value: Value? { record[field.id] }

    private func set(_ value: Value?) {
        document.setValue(value, record: record.id, field: field.id, table: table.id)
    }

    var body: some View {
        switch field.type {
        case .text, .url, .email, .phone:
            TextCell(field: field, value: value?.text, commit: { set($0.isEmpty ? nil : .text($0)) },
                     submit: { if isLast { document.addRecord(to: table.id) } })
        case .barcode:
            TextCell(field: field, value: value?.text, commit: { set(Value.text($0).converted(to: .barcode)) },
                     submit: { if isLast { document.addRecord(to: table.id) } })
        case .number:
            NumberCell(field: field, value: value?.number) { set($0.map(Value.number)) }
        case .duration:
            DurationInput(field: field, value: Binding(get: { value }, set: set), plain: true)
        case .progress:
            HStack(spacing: 6) {
                ProgressView(value: min(max(value?.number ?? 0, 0), 100), total: 100)
                    .tint((value?.number ?? 0) >= 100 ? .green : .accentColor)
                    .frame(minWidth: 30)
                NumberCell(field: field, value: value?.number) { set($0.map { .number(min(max($0, 0), 100)) }) }
                    .frame(width: 48)
            }
        case .color:
            HStack(spacing: 6) {
                ColorPicker(field.name, selection: Binding(
                    get: { value?.text.flatMap(Color.init(cellHex:)) ?? .clear },
                    set: { set($0.hex.map(Value.text)) }
                ), supportsOpacity: false)
                .labelsHidden()
                Text(value?.text ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        case .checkbox:
            Toggle(field.name, isOn: Binding(get: { value?.bool ?? false }, set: { set($0 ? .bool(true) : nil) }))
                .labelsHidden()
                .toggleStyle(.checkbox)
        case .rating:
            RatingView(rating: value?.rating ?? 0) { set($0 > 0 ? .rating($0) : nil) }
                .font(.caption)
        case .choice, .multiChoice:
            ChoiceCell(field: field, value: value, set: set)
        case .link:
            LinkCell(document: document, table: table, field: field, record: record, resolver: resolver, set: set)
        case .date:
            if let date = value?.date {
                DatePicker(field.name, selection: Binding(get: { date }, set: { set(.date($0)) }),
                           displayedComponents: field.options.includesTime ? [.date, .hourAndMinute] : .date)
                    .labelsHidden()
                    .datePickerStyle(.field)
            } else {
                Button { set(.date(FieldEditorRow.newDate(for: field))) } label: {
                    Image(systemName: "plus.circle").foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Add today's date")
            }
        default:
            CellView(document: document, field: field, record: record, resolver: resolver)
        }
    }
}

/// A text cell. Typing stays in the cell and is saved when editing ends (Tab, Return, click away):
/// saving every keystroke redraws the whole table, and fast typing then loses the cell's focus.
private struct TextCell: View {
    let field: Field
    let value: String?
    let commit: (String) -> Void
    let submit: () -> Void
    @State private var draft = ""
    /// The value the draft started from.
    @State private var base = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(field.name, text: $draft)
            .labelsHidden()
            .textFieldStyle(.plain)
            .foregroundStyle(field.type == .url ? AnyShapeStyle(.link) : AnyShapeStyle(.primary))
            .focused($focused)
            .onSubmit {
                save()
                submit()
            }
            .onAppear { draft = value ?? ""; base = draft }
            // A change from elsewhere (undo) shows, unless something was typed here meanwhile: an
            // untouched draft would otherwise write the old value back when the cell is left.
            .onChange(of: value) { _, new in
                if !focused || draft == base { draft = new ?? "" }
                base = new ?? ""
            }
            .onChange(of: focused) { _, isFocused in if !isFocused { save() } }
            .onDisappear { if focused { save() } }
    }

    private func save() {
        if draft != (value ?? "") { commit(draft) }
    }
}

/// A number cell: shows the field's format, edits the plain number.
private struct NumberCell: View {
    let field: Field
    let value: Double?
    let commit: (Double?) -> Void
    @State private var draft = ""
    @State private var base = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .trailing) {
            // The formatted value shows until the cell is being edited.
            Text(value.map { Value.number($0).display(for: field) } ?? "")
                .monospacedDigit()
                .opacity(focused ? 0 : 1)
                .allowsHitTesting(false)
            TextField(field.name, text: $draft)
                .labelsHidden()
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .focused($focused)
                .opacity(focused ? 1 : 0.011)
                .onSubmit(save)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .onAppear { draft = value.map(Value.plain) ?? ""; base = draft }
        .onChange(of: value) { _, new in
            if !focused || draft == base { draft = new.map(Value.plain) ?? "" }
            base = new.map(Value.plain) ?? ""
        }
        .onChange(of: focused) { _, isFocused in if !isFocused { save() } }
        .onDisappear { if focused { save() } }
    }

    private func save() {
        guard draft != (value.map(Value.plain) ?? "") else { return }
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { commit(nil); return }
        // Shown the way it is stored ("12.50" becomes "12.5"), so the draft matches the value and
        // follows an undo made while the cell is still focused.
        if let n = Value.parseNumber(trimmed) { commit(n); draft = Value.plain(n) } else { draft = value.map(Value.plain) ?? "" }
    }
}

/// A read-only cell.
struct CellView: View {
    @ObservedObject var document: GolleDocument
    let field: Field
    let record: Record
    let resolver: Resolver

    private var value: Value? { record[field.id] }

    var body: some View {
        switch field.type {
        case .checkbox:
            Image(systemName: value?.bool == true ? "checkmark.square.fill" : "square")
                .foregroundStyle(value?.bool == true ? Color.accentColor : .secondary)
        case .rating:
            RatingView(rating: value?.rating ?? 0).font(.caption)
        case .number, .autoNumber, .duration:
            Text(value?.display(for: field) ?? "").monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .progress:
            if let n = value?.number { ProgressBar(percent: n) }
        case .color:
            if let hex = value?.text { ColorSwatch(hex: hex) }
        case .email, .phone:
            Text(value?.text ?? "").foregroundStyle(.link).lineLimit(1)
        case .lookup:
            LookupView(document: document, field: field, record: record, resolver: resolver)
        case .rollup:
            Text(resolver.text(record, field)).monospacedDigit().lineLimit(1)
                .frame(maxWidth: .infinity, alignment: resolver.value(record, field)?.number != nil ? .trailing : .leading)
        case .longText:
            let text = value?.text ?? ""
            Text((field.options.richText ? Markdown.plain(text) : text).replacingOccurrences(of: "\n", with: " ")).lineLimit(1)
        case .checklist:
            ChecklistSummary(items: value?.checkItems ?? [])
        case .choice, .multiChoice:
            ChipsView(field: field, choices: value?.choices ?? [])
        case .url:
            Text(value?.text ?? "").foregroundStyle(.link).lineLimit(1)
        case .image:
            HStack(spacing: 2) {
                ForEach((value?.attachments ?? []).prefix(3)) { attachment in
                    if let image = document.thumbnail(attachment, size: 64) {
                        Image(nsImage: image).resizable().scaledToFill().frame(width: 18, height: 18).clipShape(.rect(cornerRadius: 3))
                    }
                }
            }
        case .file:
            let files = value?.attachments ?? []
            if !files.isEmpty {
                Label(files.map(\.name).joined(separator: ", "), systemImage: "paperclip").lineLimit(1)
            }
        case .location:
            if let place = value?.place {
                Label(Value.location(place).display(for: field), systemImage: place.hasCoordinates ? "mappin.circle.fill" : "mappin.circle")
                    .lineLimit(1)
            }
        case .formula:
            let computed = resolver.formulaValue(record, field)
            if let error = computed.error {
                Text("⚠︎").foregroundStyle(.orange).help(error)
            } else if case .number? = computed.value {
                Text(computed.value!.display(for: field)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            } else if case .bool(let b)? = computed.value {
                Image(systemName: b ? "checkmark.square.fill" : "square").foregroundStyle(b ? Color.accentColor : .secondary)
            } else {
                Text(computed.value?.display(for: field) ?? "").lineLimit(1)
            }
        case .link, .createdAt, .modifiedAt:
            Text(resolver.text(record, field)).lineLimit(1).foregroundStyle(field.type == .link ? .primary : .secondary)
        default:
            Text(value?.display(for: field) ?? "").lineLimit(1)
        }
    }
}

struct RatingView: View {
    let rating: Int
    var onChange: ((Int) -> Void)?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...Value.maxRating, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .foregroundStyle(star <= rating ? Color.orange : Color.secondary.opacity(0.5))
                    .onTapGesture {
                        // Tapping the current rating clears it.
                        onChange?(star == rating ? 0 : star)
                    }
            }
        }
    }
}

/// A link cell: the linked records' names; click to add, remove or make linked records.
private struct LinkCell: View {
    @ObservedObject var document: GolleDocument
    let table: DataTable
    let field: Field
    let record: Record
    let resolver: Resolver
    let set: (Value?) -> Void
    @State private var picking = false

    /// As in the form: a link field without a table to link to can't link anything yet.
    private var target: DataTable? { field.options.linkedTableID.flatMap(document.database.table) }

    /// The value as stored now: each pick adds to the latest links, even when the cell hasn't
    /// been redrawn since the previous pick.
    private var stored: Value? {
        guard let t = document.database.tableIndex(table.id), let r = document.database.tables[t].recordIndex(record.id) else { return nil }
        return document.database.tables[t].records[r][field.id]
    }

    var body: some View {
        Button { picking = true } label: {
            HStack(spacing: 4) {
                Text(resolver.text(record, field)).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(target == nil)
        .help(target.map { "Link \($0.name) records" } ?? "Choose a table for this field in Edit Fields")
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            if let target {
                LinkPicker(document: document, target: target, record: record, resolver: resolver,
                           value: Binding(get: { stored }, set: set)) { picking = false }
            }
        }
    }
}
