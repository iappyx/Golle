import SwiftUI

/// Colour rules of a table: records that match a rule get its colour in every view.
struct ColorRulesSheet: View {
    @ObservedObject var document: GolleDocument
    let tableID: DataTable.ID
    @Environment(\.dismiss) private var dismiss

    private var table: DataTable? { document.database.table(tableID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Colour Rules").font(.title3.bold())
                Text("Records that match a rule get its colour in the table, gallery, board, calendar and map. The first matching rule wins.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            Divider()
            if let table {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(table.colorRules.enumerated()), id: \.element.id) { index, rule in
                            ruleBox(rule, index: index, table: table)
                        }
                        Button {
                            guard let field = table.fields.first else { return }
                            let used = Set(table.colorRules.map(\.color))
                            let color = AccentChoice.allCases.first { !used.contains($0) } ?? .red
                            let rule = ColorRule(color: color, filter: Filter(rules: [FilterRule(fieldID: field.id, op: FilterOperator.operators(for: field.type)[0])]))
                            document.setColorRules(table.colorRules + [rule], in: tableID)
                        } label: {
                            Label("Add Colour Rule", systemImage: "plus.circle")
                        }
                        .disabled(table.fields.isEmpty)
                    }
                    .padding(16)
                }
            }
            Divider()
            HStack {
                SheetUndoButtons(document: document)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 720, height: 520)
    }

    private func ruleBox(_ rule: ColorRule, index: Int, table: DataTable) -> some View {
        func update(_ change: (inout ColorRule) -> Void) {
            var rules = table.colorRules
            guard rules.indices.contains(index) else { return }
            change(&rules[index])
            document.setColorRules(rules, in: tableID)
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(AccentChoice.allCases) { color in
                        Circle().fill(color.color).frame(width: 16, height: 16)
                            .overlay { if rule.color == color { Circle().strokeBorder(.white, lineWidth: 2).padding(2) } }
                            .onTapGesture { update { $0.color = color } }
                            .help(color.label)
                    }
                }
                Text("when records match")
                Picker("Match", selection: Binding(get: { rule.filter.match }, set: { m in update { $0.filter.match = m } })) {
                    Text("all").tag(Filter.Match.all)
                    Text("any").tag(Filter.Match.any)
                }
                .labelsHidden()
                .fixedSize()
                Text("of:")
                Spacer()
                Button { move(index, by: -1, table) } label: { Image(systemName: "arrow.up") }
                    .disabled(index == 0).help("Check this rule earlier")
                Button { move(index, by: 1, table) } label: { Image(systemName: "arrow.down") }
                    .disabled(index == table.colorRules.count - 1).help("Check this rule later")
                Button(role: .destructive) {
                    document.setColorRules(table.colorRules.filter { $0.id != rule.id }, in: tableID)
                } label: { Image(systemName: "trash") }
                .help("Delete rule")
            }
            .buttonStyle(.borderless)
            if rule.filter.rules.isEmpty {
                // Without conditions a rule colours nothing; offer a way to add one again.
                Button {
                    guard let field = table.fields.first else { return }
                    update { $0.filter.rules = [FilterRule(fieldID: field.id, op: FilterOperator.operators(for: field.type)[0])] }
                } label: { Label("Add Condition", systemImage: "plus.circle") }
                .buttonStyle(.borderless)
            }
            ForEach(rule.filter.rules) { condition in
                RuleRow(table: table, rule: condition,
                        change: { new in update { r in r.filter.rules = r.filter.rules.map { $0.id == condition.id ? new : $0 } } },
                        remove: { update { r in r.filter.rules.removeAll { $0.id == condition.id } } },
                        add: {
                            guard let field = table.fields.first else { return }
                            update { r in
                                let i = (r.filter.rules.firstIndex { $0.id == condition.id } ?? r.filter.rules.count - 1) + 1
                                r.filter.rules.insert(FilterRule(fieldID: field.id, op: FilterOperator.operators(for: field.type)[0]), at: i)
                            }
                        })
            }
        }
        .controlSize(.small)
        .padding(10)
        .background(rule.color.color.opacity(0.12), in: .rect(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(rule.color.color.opacity(0.5)) }
    }

    private func move(_ index: Int, by offset: Int, _ table: DataTable) {
        var rules = table.colorRules
        let target = index + offset
        guard rules.indices.contains(index), rules.indices.contains(target) else { return }
        rules.swapAt(index, target)
        document.setColorRules(rules, in: tableID)
    }
}

/// Finds records that read the same in the chosen fields and merges them.
struct DuplicatesSheet: View {
    @ObservedObject var document: GolleDocument
    let tableID: DataTable.ID
    @Environment(\.dismiss) private var dismiss
    @State private var keyFields = Set<Field.ID>()

    private var table: DataTable? { document.database.table(tableID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let table {
                let resolver = document.resolver(for: table)
                let ordered = table.fields.filter { keyFields.contains($0.id) }.map(\.id)
                let groups = Duplicates.find(in: table, fields: ordered, resolver)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Find Duplicates").font(.title3.bold())
                    Text("Records count as duplicates when these fields read the same (ignoring case, accents and extra spaces):")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    FlowingToggles(fields: table.fields.filter { !$0.type.isAttachment && !$0.type.isAutomatic }, selection: $keyFields)
                }
                .padding(16)
                Divider()
                if groups.isEmpty {
                    ContentUnavailableView(keyFields.isEmpty ? "Choose Fields to Compare" : "No Duplicates",
                                           systemImage: keyFields.isEmpty ? "checklist" : "checkmark.circle",
                                           description: Text(keyFields.isEmpty ? "" : "Every record is unique in these fields."))
                        .frame(maxHeight: .infinity)
                } else {
                    List {
                        ForEach(groups, id: \.self) { group in
                            Section {
                                ForEach(Array(group.enumerated()), id: \.element) { index, id in
                                    if let record = table.records.first(where: { $0.id == id }) {
                                        HStack {
                                            Image(systemName: index == 0 ? "star.fill" : "arrow.turn.down.right")
                                                .foregroundStyle(index == 0 ? Color.accentColor : .secondary)
                                                .frame(width: 16)
                                                .help(index == 0 ? "Kept" : "Merged into the first")
                                            Text(table.title(of: record)).fontWeight(index == 0 ? .semibold : .regular)
                                            Text(summary(record, table, resolver)).foregroundStyle(.secondary).lineLimit(1)
                                            Spacer()
                                            Text("filled \(record.values.count)").font(.caption).foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                            } header: {
                                HStack {
                                    Text("\(group.count) records")
                                    Spacer()
                                    Button("Merge") { document.mergeDuplicates([group], in: tableID) }
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                }
                Divider()
                HStack {
                    SheetUndoButtons(document: document)
                    Text("Merging keeps the first record, fills its empty fields from the others and combines choices, files and links.")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button("Merge All (\(groups.count))") { document.mergeDuplicates(groups, in: tableID) }
                        .disabled(groups.isEmpty)
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
        }
        .frame(width: 720, height: 560)
        .onAppear {
            if keyFields.isEmpty, let title = table?.titleField?.id { keyFields = [title] }
        }
    }

    private func summary(_ record: Record, _ table: DataTable, _ resolver: Resolver) -> String {
        table.fields.filter { $0.id != table.titleField?.id && !$0.type.isAttachment && $0.type != .longText }
            .prefix(4).map { resolver.text(record, $0) }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Field toggles that wrap onto several lines.
private struct FlowingToggles: View {
    let fields: [Field]
    @Binding var selection: Set<Field.ID>

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 4) {
            ForEach(fields) { field in
                Toggle(field.name, isOn: Binding(
                    get: { selection.contains(field.id) },
                    set: { if $0 { selection.insert(field.id) } else { selection.remove(field.id) } }
                ))
                .toggleStyle(.checkbox)
                .lineLimit(1)
            }
        }
    }
}
