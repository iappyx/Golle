import SwiftUI

/// Cards in columns, one per option of a choice field. Drag a card to another column to change it.
struct BoardView: View {
    @ObservedObject var document: GolleDocument
    let table: DataTable
    let view: SavedView
    let rows: [Record]
    let resolver: Resolver
    let editFields: () -> Void

    var body: some View {
        if let field = view.boardField(in: table) {
            VStack(spacing: 0) {
                HStack {
                    Picker("Columns by", selection: Binding(get: { field.id }, set: { id in document.updateCurrentView("Change Board") { $0.boardFieldID = id } })) {
                        ForEach(table.fields.filter { $0.type == .choice }) { Text($0.name).tag($0.id) }
                    }
                    .fixedSize()
                    Spacer()
                    Text("Drag cards between columns").foregroundStyle(.secondary).lineLimit(1)
                }
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
                Divider()
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(columns(field), id: \.self) { choice in
                            BoardColumn(document: document, table: table, field: field, choice: choice,
                                        records: rows.filter { ($0[field.id]?.choices.first ?? "") == choice }, resolver: resolver,
                                        visible: view.visibleFields(table))
                        }
                    }
                    .padding(12)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        } else {
            ContentUnavailableView {
                Label("No Choice Field", systemImage: "rectangle.split.3x1")
            } description: {
                Text("A board shows a column for each option of a Choice field. Add one to use the board.")
            } actions: {
                Button("Edit Fields…", action: editFields)
            }
        }
    }

    /// The field's options, any other values in use, and "" for records without a value.
    private func columns(_ field: Field) -> [String] {
        let used = rows.compactMap { $0[field.id]?.choices.first }
        var seen = Set<String>()
        return (field.options.choices + used).filter { seen.insert($0).inserted } + [""]
    }
}

private struct BoardColumn: View {
    @ObservedObject var document: GolleDocument
    let table: DataTable
    let field: Field
    let choice: String
    let records: [Record]
    let resolver: Resolver
    var visible: [Field] = []
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if choice.isEmpty {
                    Text("No \(field.name)").font(.headline).lineLimit(1)
                } else {
                    Circle().fill(field.color(of: choice)?.color ?? .gray).frame(width: 10, height: 10)
                    Text(choice).font(.headline).lineLimit(1)
                }
                Text("\(records.count)").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button {
                    document.addRecord(to: table.id, values: choice.isEmpty ? [:] : [field.id: .choices([choice])])
                } label: { Image(systemName: "plus").frame(width: 22, height: 22).contentShape(.rect) }
                .buttonStyle(.borderless)
                .help("New record in \(choice.isEmpty ? "this column" : choice)")
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(records) { record in
                        BoardCard(document: document, table: table, record: record, resolver: resolver, skip: field.id, visible: visible)
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .padding(10)
        .frame(width: 260)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(targeted ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08), in: .rect(cornerRadius: 10))
        .dropDestination(for: String.self) { ids, _ in
            let records = Set(ids.compactMap(UUID.init(uuidString:)))
            guard !records.isEmpty else { return false }
            document.setValue(choice.isEmpty ? nil : .choices([choice]), records: records, field: field.id, table: table.id)
            return true
        } isTargeted: { targeted = $0 }
    }
}

/// A record as a small card: colour, title and a few fields.
struct BoardCard: View {
    @ObservedObject var document: GolleDocument
    let table: DataTable
    let record: Record
    let resolver: Resolver
    var skip: Field.ID?
    var visible: [Field] = []

    private var details: [Field] {
        Array((visible.isEmpty ? table.fields : visible).filter {
            $0.id != table.titleField?.id && $0.id != skip && $0.type != .longText && !$0.type.isAttachment
                && !$0.type.isComputed && $0.type != .autoNumber
        }.prefix(3))
    }

    var body: some View {
        let selected = document.selectedRecordIDs.contains(record.id)
        let color = table.color(of: record, resolver)
        HStack(spacing: 0) {
            if let color { Rectangle().fill(color.color).frame(width: 4) }
            VStack(alignment: .leading, spacing: 3) {
                Text(table.title(of: record)).fontWeight(.medium).lineLimit(2)
                ForEach(details) { field in
                    let text = resolver.text(record, field)
                    if field.type == .rating, let r = record[field.id]?.rating, r > 0 {
                        RatingView(rating: r).font(.caption2)
                    } else if field.type.usesChoices, let choices = record[field.id]?.choices, !choices.isEmpty {
                        ChipsView(field: field, choices: Array(choices.prefix(3)))
                    } else if field.type == .checklist, let items = record[field.id]?.checkItems, !items.isEmpty {
                        ChecklistSummary(items: items).font(.caption)
                    } else if field.type != .checkbox, !text.isEmpty {
                        Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(8)
            Spacer(minLength: 0)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 6))
        .clipShape(.rect(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: selected ? 2 : 1) }
        .contentShape(.rect)
        .onTapGesture { document.selectedRecordIDs = [record.id] }
        .draggable(record.id.uuidString) {
            Text(table.title(of: record)).padding(6).background(.background, in: .rect(cornerRadius: 6))
        }
        .contextMenu {
            Button("Duplicate") { document.duplicateRecords([record.id], in: table.id) }
            Button("Delete", role: .destructive) { document.deleteRecords([record.id], from: table.id) }
        }
    }
}
