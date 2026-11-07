import SwiftUI

/// A choice option as a coloured capsule. The text keeps the normal text colour; the colour is in
/// the capsule, so it stays readable in light and dark mode.
struct ChoiceChip: View {
    let text: String
    let color: AccentChoice?

    var body: some View {
        let tint = color?.color ?? Color.gray
        Text(text)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.22), in: .capsule)
            .overlay { Capsule().strokeBorder(tint.opacity(0.55), lineWidth: 1) }
    }
}

/// The chips of a choice or multiple-choice value.
struct ChipsView: View {
    let field: Field
    let choices: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(choices, id: \.self) { ChoiceChip(text: $0, color: field.color(of: $0)) }
        }
    }
}

/// A table cell for a choice field: the chip, with a menu to change it.
struct ChoiceCell: View {
    let field: Field
    let value: Value?
    let set: (Value?) -> Void

    private var options: [String] {
        field.options.choices + (value?.choices ?? []).filter { !field.options.choices.contains($0) }
    }

    var body: some View {
        Menu {
            if field.type == .choice {
                Button("None") { set(nil) }
                Divider()
                ForEach(options, id: \.self) { option in
                    Button { set(.choices([option])) } label: {
                        if value?.choices.first == option { Label(option, systemImage: "checkmark") } else { Text(option) }
                    }
                }
            } else {
                ForEach(options, id: \.self) { option in
                    Toggle(option, isOn: Binding(
                        get: { value?.choices.contains(option) == true },
                        set: { on in
                            var current = value?.choices ?? []
                            if on { current.append(option) } else { current.removeAll { $0 == option } }
                            let ordered = field.options.choices.filter(current.contains) + current.filter { !field.options.choices.contains($0) }
                            set(ordered.isEmpty ? nil : .choices(ordered))
                        }
                    ))
                }
            }
        } label: {
            if let choices = value?.choices, !choices.isEmpty {
                ChipsView(field: field, choices: choices)
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: Checklists

/// A checklist in a form: tick items off, edit them, add and remove.
struct ChecklistEditor: View {
    @Binding var value: Value?
    @State private var newItem = ""
    @FocusState private var addingFocused: Bool

    private func addItem() {
        let text = newItem.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        update(items + [CheckItem(text: text)])
        newItem = ""
    }

    private var items: [CheckItem] { value?.checkItems ?? [] }

    private func update(_ items: [CheckItem]) {
        value = items.isEmpty ? nil : .checklist(items)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !items.isEmpty {
                ProgressView(value: Double(items.filter(\.done).count), total: Double(items.count))
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }
            ForEach(items) { item in
                HStack(spacing: 6) {
                    Toggle(item.text, isOn: Binding(
                        get: { item.done },
                        set: { done in update(items.map { $0.id == item.id ? CheckItem(id: $0.id, text: $0.text, done: done) : $0 }) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    TextField("Item", text: Binding(
                        get: { item.text },
                        set: { text in update(items.map { $0.id == item.id ? CheckItem(id: $0.id, text: text, done: $0.done) : $0 }) }
                    ))
                    .textFieldStyle(.plain)
                    .strikethrough(item.done)
                    .foregroundStyle(item.done ? .secondary : .primary)
                    Button { update(items.filter { $0.id != item.id }) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tertiary)
                        .help("Remove item")
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "plus.circle").foregroundStyle(.secondary)
                TextField("Add an item", text: $newItem)
                    .textFieldStyle(.plain)
                    .focused($addingFocused)
                    .onSubmit(addItem)
                    // Typed but not added with Return: added when the field is left, too.
                    .onChange(of: addingFocused) { _, now in if !now { addItem() } }
                    .onDisappear(perform: addItem)
            }
        }
    }
}

/// A checklist in a table cell or card: progress and "3/5".
struct ChecklistSummary: View {
    let items: [CheckItem]

    var body: some View {
        if !items.isEmpty {
            HStack(spacing: 6) {
                ProgressView(value: Double(items.filter(\.done).count), total: Double(items.count))
                    .progressViewStyle(.linear)
                    .frame(width: 44)
                Text("\(items.filter(\.done).count)/\(items.count)").monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: History

/// Recent changes of a record, newest first, each with Restore.
struct HistorySection: View {
    @ObservedObject var document: GolleDocument
    let table: DataTable
    let record: Record
    @State private var expanded = false

    var body: some View {
        let changes = table.history[record.id] ?? []
        if !changes.isEmpty {
            Section {
                DisclosureGroup(isExpanded: $expanded) {
                    ForEach(changes.reversed()) { change in
                        if let field = table.field(change.fieldID) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(field.name).fontWeight(.medium)
                                    Spacer()
                                    Text(change.time, format: .relative(presentation: .named)).foregroundStyle(.secondary).font(.caption)
                                }
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text(describe(change.old, field)).strikethrough(change.old != nil).foregroundStyle(.secondary)
                                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                                    Text(describe(change.new, field))
                                }
                                .font(.callout)
                                .lineLimit(2)
                                HStack {
                                    Spacer()
                                    // The field's type may have changed since: the old value follows it.
                                    let restored = change.old?.converted(to: field.type)
                                    Button("Restore Old Value") {
                                        document.setValue(restored, record: record.id, field: field.id, table: table.id)
                                    }
                                    .controlSize(.small)
                                    .disabled(record[field.id] == restored)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } label: {
                    Label("History (\(changes.count))", systemImage: "clock.arrow.circlepath")
                }
            } footer: {
                Text(Change.limit == 0 ? "History is off (Golle ▸ Settings); earlier changes stay." : "The last \(Change.limit) changes of each record are kept in the database (Golle ▸ Settings).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func describe(_ value: Value?, _ field: Field) -> String {
        guard let value else { return "empty" }
        switch value {
        case .links(let ids):
            let resolver = document.resolver(for: table)
            let names = ids.compactMap { resolver.lookup($0) }.map { $0.table.title(of: $0.record) }
            return names.isEmpty ? value.display(for: field) : names.joined(separator: ", ")
        case .text(let s) where field.type == .longText && field.options.richText:
            return Markdown.plain(s)
        default:
            return value.display(for: field)
        }
    }
}
