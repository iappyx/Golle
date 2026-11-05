import SwiftUI

/// A sheet to add, rename, retype, reorder and remove the fields of a table.
struct FieldEditor: View {
    @ObservedObject var document: GolleDocument
    let tableID: DataTable.ID
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Field.ID?

    private var table: DataTable? { document.database.table(tableID) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // The + and − bar sits under the list, not in its margin: the list's rows reach
                // under its margin and would take the clicks.
                VStack(spacing: 0) {
                    List(selection: $selection) {
                        ForEach(table?.fields ?? []) { field in
                            Label(field.name, systemImage: field.type.symbol).tag(field.id)
                        }
                        .onMove { document.moveFields(in: tableID, from: $0, to: $1) }
                    }
                    Divider()
                    HStack(spacing: 2) {
                        Menu {
                            ForEach(Array(FieldType.groups.enumerated()), id: \.offset) { index, group in
                                if index > 0 { Divider() }
                                ForEach(group) { type in
                                    Button { add(type) } label: {
                                        Label(type.label, systemImage: type.symbol)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "plus").frame(width: 24, height: 22).contentShape(.rect)
                        }
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Add Field")
                        Button {
                            if let id = selection { document.deleteField(id, from: tableID); selection = nil }
                        } label: {
                            Image(systemName: "minus").frame(width: 24, height: 22).contentShape(.rect)
                        }
                        .disabled(selection == nil)
                        .help("Delete Field")
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
                .frame(width: 220)
                Divider()

                Group {
                    if let id = selection, let table, let field = table.field(id) {
                        FieldDetail(document: document, table: table, field: field) { document.updateField($0, in: tableID) }
                            .id(field.id)
                    } else {
                        ContentUnavailableView("Select a Field", systemImage: "slider.horizontal.3",
                                               description: Text("Drag fields to change their order."))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            Divider()
            HStack {
                SheetUndoButtons(document: document)
                Text("Deleting a field deletes its values in every record. Undo brings them back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 700, height: 500)
        .onAppear { selection = table?.fields.first?.id }
    }

    private func add(_ type: FieldType) {
        guard let id = document.addField(to: tableID, type: type) else { return }
        selection = id
        // The menu's action runs while the menu is still closing, and the list can then write its
        // old selection back (none, or another field), so "−" would be greyed out or act on that
        // field. Select the new field again once the list has its row.
        DispatchQueue.main.async { selection = id }
    }
}

private struct FieldDetail: View {
    @ObservedObject var document: GolleDocument
    let table: DataTable
    let field: Field
    let update: (Field) -> Void
    @State private var choicesText = ""
    @State private var formula = ""
    @State private var showHelp = false
    @State private var name = ""
    /// The stored name the draft started from: when the draft still equals it, it follows changes
    /// made elsewhere (undo), even while focused.
    @State private var nameBase = ""
    @FocusState private var nameFocused: Bool

    /// The field as stored now (the `field` a closure captured may be older).
    private var current: Field? { document.database.table(table.id)?.field(field.id) }

    var body: some View {
        Form {
            // Renamed once, when typing is done: each half-typed name would otherwise be applied to
            // the formulas that use the field.
            TextField("Name", text: $name)
                .focused($nameFocused)
                .onSubmit(commitName)
                .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
                .onChange(of: field.name) { _, stored in
                    if !nameFocused || name == nameBase { name = stored }
                    nameBase = stored
                }
            Picker("Type", selection: Binding(get: { field.type }, set: { type in
                var f = field
                f.type = type
                update(f)
            })) {
                ForEach(Array(FieldType.groups.enumerated()), id: \.offset) { index, group in
                    if index > 0 { Divider() }
                    ForEach(group) { type in
                        Label(type.label, systemImage: type.symbol).tag(type)
                    }
                }
            }
            if field.type.usesChoices {
                OptionsSection(field: field, update: update, rename: { old, new in
                    document.renameChoice(old, to: new, field: field.id, table: table.id)
                })
            }
            if field.type == .longText {
                Toggle("Formatted text (bold, lists, headings)", isOn: Binding(get: { field.options.richText }, set: { on in
                    var f = field
                    f.options.richText = on
                    update(f)
                }))
            }
            if field.type == .link {
                Picker("Links to", selection: Binding(get: { field.options.linkedTableID ?? table.id }, set: { id in
                    var f = field
                    f.options.linkedTableID = id
                    update(f)
                })) {
                    ForEach(document.database.tables) { Text($0.name).tag($0.id) }
                }
                Text("Records in the other table show where they are linked from.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if field.type == .date {
                Toggle("Include time", isOn: Binding(get: { field.options.includesTime }, set: { on in update { $0.options.includesTime = on } }))
                Text(field.options.includesTime ? "Shows and edits the date and the time of day." : "Shows the date only. Times already in the field are kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if field.type == .duration {
                Picker("Type as", selection: Binding(get: { field.options.durationStyle }, set: { style in update { $0.options.durationStyle = style } })) {
                    ForEach(DurationStyle.allCases) { Text($0.label).tag($0) }
                }
                Text("You can also type \"1h 30m\" or \"90 min\". Durations add up in totals and charts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if field.type == .progress {
                Text("A percentage from 0 to 100, shown as a bar.").font(.caption).foregroundStyle(.secondary)
            }
            if field.type == .barcode {
                Text("Spaces and dashes are left out. EAN, UPC and ISBN codes are checked for typing mistakes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if field.type == .rollup {
                rollupSection
            }
            if field.type == .lookup {
                lookupSection
            }
            if field.type == .formula {
                formulaSection
            }
            if field.type == .number || field.type == .formula || field.type == .autoNumber || field.type == .rollup {
                formatSection
            }
            if !field.type.isAutomatic && !field.type.isAttachment && field.type != .link {
                defaultSection
            }
            if field.type == .autoNumber {
                Text("New records get the next number. Numbers are never reused within the table.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if field.type.canBeRequired || field.type.canBeUnique {
                rulesSection
            }
        }
        .formStyle(.grouped)
        .onAppear {
            choicesText = field.options.choices.joined(separator: "\n")
            formula = field.options.formula
            name = field.name
            nameBase = field.name
        }
        .onDisappear(perform: commitName)
        // Undo changes the stored formula; the editor follows, so it doesn't write the old text back.
        .onChange(of: field.options.formula) { _, stored in if stored != formula { formula = stored } }
    }

    private func commitName() {
        guard var f = current else { return }
        if name != f.name {
            f.name = name
            update(f)
        }
        // A name that is empty or taken is refused; show the one that is kept.
        name = current?.name ?? name
        nameBase = name
    }

    @ViewBuilder
    private var formulaSection: some View {
        Section {
            TextEditor(text: $formula)
                .font(.body.monospaced())
                .frame(minHeight: 70)
                .onChange(of: formula) { _, text in
                    guard var f = current, text != f.options.formula else { return }
                    f.options.formula = text
                    update(f)
                }
            HStack {
                Menu("Insert Field") {
                    ForEach(table.fields.filter { $0.id != field.id }) { other in
                        Button(other.name) { formula += "{\(other.name)}" }
                    }
                }
                .fixedSize()
                Spacer()
                Button(showHelp ? "Hide Functions" : "Functions…") { showHelp.toggle() }
                    .buttonStyle(.link)
            }
            switch Formula.parse(formula) {
            case .failure(let error):
                Label(error.message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            case .success:
                if let record = table.records.first {
                    let result = document.resolver(for: table).formulaValue(record, field)
                    LabeledContent("First record") {
                        if let error = result.error {
                            Text(error).foregroundStyle(.orange)
                        } else {
                            Text(result.value?.display(for: field) ?? "—")
                        }
                    }
                }
            }
            if showHelp {
                Grid(alignment: .leading, verticalSpacing: 4) {
                    ForEach(Formula.help, id: \.0) { item in
                        GridRow {
                            Text(item.0).font(.caption.monospaced())
                            Text(item.1).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Formula")
        } footer: {
            Text("Refer to fields in braces, like {Price} * {Quantity}.").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Rollup

    /// The links a rollup can go through: this table's link fields, and other tables' link fields
    /// that point here ("Linked From").
    private var rollupLinks: [(id: Field.ID, name: String)] {
        let own = table.fields.filter { $0.type == .link }.map { ($0.id, $0.name) }
        let from = document.database.tables.filter { $0.id != table.id }.flatMap { other in
            other.fields.filter { $0.type == .link && $0.options.linkedTableID == table.id }.map { ($0.id, "\(other.name) (Linked From, via \($0.name))") }
        }
        return own + from
    }

    private var rollupTarget: DataTable? { Exporter.rollupTable(field, table, document.database) }

    /// The fields of the linked table that this kind of rollup can use.
    private func rollupFields(_ target: DataTable) -> [Field] {
        target.fields.filter { Self.usable($0.id, in: target, kind: field.options.rollupKind) }
    }

    @ViewBuilder
    private var rollupSection: some View {
        Section {
            if rollupLinks.isEmpty {
                Text("A rollup works through a Linked Records field, in this table or one that links here. Add one first.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("Through", selection: Binding(get: { field.options.rollupLinkFieldID }, set: { id in
                    update { $0.options.rollupLinkFieldID = id; $0.options.rollupFieldID = nil }
                })) {
                    Text("Choose a link field").tag(UUID?.none)
                    ForEach(rollupLinks, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker("Show", selection: Binding(get: { field.options.rollupKind }, set: { kind in update { f in
                    f.options.rollupKind = kind
                    // Keep the field when the new kind can use it.
                    if let target = rollupTarget, let id = f.options.rollupFieldID, !Self.usable(id, in: target, kind: kind) {
                        f.options.rollupFieldID = nil
                    }
                } })) {
                    ForEach(RollupKind.allCases) { Text($0.label).tag($0) }
                }
                if field.options.rollupKind.needsField, let target = rollupTarget {
                    Picker("Of", selection: Binding(get: { field.options.rollupFieldID }, set: { id in update { $0.options.rollupFieldID = id } })) {
                        Text("Choose a field of \(target.name)").tag(UUID?.none)
                        ForEach(rollupFields(target)) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
            }
        } header: {
            Text("Rollup")
        } footer: {
            Text("Counts or adds up the records this record links to, like the number of albums of an artist or the total length of an album's tracks.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Lookup

    @ViewBuilder
    private var lookupSection: some View {
        Section {
            if rollupLinks.isEmpty {
                Text("A lookup works through a Linked Records field, in this table or one that links here. Add one first.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("Through", selection: Binding(get: { field.options.rollupLinkFieldID }, set: { id in
                    update { $0.options.rollupLinkFieldID = id; $0.options.rollupFieldID = nil }
                })) {
                    Text("Choose a link field").tag(UUID?.none)
                    ForEach(rollupLinks, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                }
                if let target = rollupTarget {
                    Picker("Show", selection: Binding(get: { field.options.rollupFieldID }, set: { id in update { $0.options.rollupFieldID = id } })) {
                        Text("Choose a field of \(target.name)").tag(UUID?.none)
                        ForEach(target.fields.filter { $0.id != field.id }) { Label($0.name, systemImage: $0.type.symbol).tag(Optional($0.id)) }
                    }
                }
                let resolver = document.resolver(for: table)
                if let record = table.records.first(where: { !resolver.lookupTexts($0, field).isEmpty }) {
                    LabeledContent(table.title(of: record)) {
                        Text(resolver.text(record, field)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        } header: {
            Text("Lookup")
        } footer: {
            Text("Shows a field of the linked records, like the country of an album's artist. It changes when they change, and sorts, filters and adds up like that field.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Rules

    @ViewBuilder
    private var rulesSection: some View {
        Section {
            if field.type.canBeRequired {
                Toggle("Required", isOn: Binding(get: { field.options.required }, set: { on in update { $0.options.required = on } }))
            }
            if field.type.canBeUnique {
                Toggle("Unique: no two records the same", isOn: Binding(get: { field.options.unique }, set: { on in update { $0.options.unique = on } }))
            }
            if field.options.required || field.options.unique {
                let resolver = document.resolver(for: table)
                let problems = table.records.compactMap { resolver.ruleProblem($0, field) }
                let missing = problems.filter { $0 == .missing }.count
                let duplicates = problems.count - missing
                if problems.isEmpty {
                    Label("Every record follows the rules.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                } else {
                    if missing > 0 {
                        Label("\(missing) record\(missing == 1 ? " is" : "s are") empty", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    if duplicates > 0 {
                        Label("\(duplicates) records share a value with another", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
            }
        } header: {
            Text("Rules")
        } footer: {
            Text("Records that break a rule are marked in the table and the record form, and counted under the records. Nothing is refused: you can fix them when it suits you.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    static func usable(_ id: Field.ID, in target: DataTable, kind: RollupKind) -> Bool {
        guard let f = target.field(id) else { return false }
        switch kind {
        case .count: return false
        case .sum, .average: return (f.type.isNumeric && f.type != .autoNumber) || f.type == .formula || f.type == .rollup || f.type == .lookup || f.type == .checkbox
        case .minimum, .maximum: return f.type.isNumeric || f.type.isDate || f.type == .formula || f.type == .rollup || f.type == .lookup
        case .list: return !f.type.isAttachment
        }
    }

    private func update(_ change: (inout Field) -> Void) {
        var f = field
        change(&f)
        if f != field { update(f) }
    }

    private var format: NumberFormat { field.options.numberFormat ?? NumberFormat() }

    @ViewBuilder
    private var formatSection: some View {
        Section {
            if field.type != .autoNumber {
                Picker("Style", selection: Binding(get: { format.style }, set: { style in update { $0.options.numberFormat = { var f = format; f.style = style; return f }() } })) {
                    ForEach(NumberFormat.Style.allCases) { Text($0.label).tag($0) }
                }
                if format.style == .currency {
                    TextField("Currency code", text: Binding(get: { format.currency }, set: { code in
                        update { $0.options.numberFormat = { var f = format; f.currency = code.uppercased(); return f }() }
                    }), prompt: Text("EUR"))
                }
                Toggle("Fixed decimals", isOn: Binding(get: { format.decimals != nil }, set: { on in
                    update { $0.options.numberFormat = { var f = format; f.decimals = on ? 2 : nil; return f }() }
                }))
                if let decimals = format.decimals {
                    Stepper("Decimals: \(decimals)", value: Binding(get: { decimals }, set: { d in
                        update { $0.options.numberFormat = { var f = format; f.decimals = d; return f }() }
                    }), in: 0...6)
                }
            }
            TextField("Before the number", text: Binding(get: { format.prefix }, set: { text in
                update { $0.options.numberFormat = { var f = format; f.prefix = text; return f }() }
            }), prompt: Text(field.type == .autoNumber ? "INV-" : "none"))
            TextField("After the number", text: Binding(get: { format.suffix }, set: { text in
                update { $0.options.numberFormat = { var f = format; f.suffix = text; return f }() }
            }), prompt: Text("kg, cm, pcs"))
            LabeledContent("Example") { Text(format.format(field.type == .autoNumber ? 42 : 1234.5)).monospacedDigit() }
        } header: {
            Text("Display")
        }
    }

    @ViewBuilder
    private var defaultSection: some View {
        let text = Binding(get: { field.options.defaultValue }, set: { value in update { $0.options.defaultValue = value } })
        Section {
            switch field.type {
            case .date:
                Toggle("Today's date", isOn: Binding(get: { field.options.defaultValue == "today" }, set: { on in update { $0.options.defaultValue = on ? "today" : "" } }))
            case .checkbox:
                Toggle("Checked", isOn: Binding(get: { field.options.defaultValue == "yes" }, set: { on in update { $0.options.defaultValue = on ? "yes" : "" } }))
            case .choice:
                Picker("Option", selection: text) {
                    Text("None").tag("")
                    ForEach(field.options.choices, id: \.self) { Text($0).tag($0) }
                }
            case .rating:
                LabeledContent("Stars") {
                    RatingView(rating: Int(field.options.defaultValue) ?? 0) { stars in update { $0.options.defaultValue = stars > 0 ? String(stars) : "" } }
                }
            case .multiChoice:
                TextField("Options", text: text, prompt: Text("comma-separated"))
            default:
                TextField("Value", text: text, prompt: Text("empty"))
            }
        } header: {
            Text("New Records Start With")
        }
    }

    static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// Undo and Redo inside a sheet. A sheet is its own window, which doesn't share the document's undo
/// manager, so Edit ▸ Undo is greyed out there; these buttons (⌘Z, ⇧⌘Z) reach the document directly.
struct SheetUndoButtons: View {
    @ObservedObject var document: GolleDocument

    var body: some View {
        HStack(spacing: 4) {
            Button { document.undoManager?.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command)
                .help("Undo (⌘Z)")
            Button { document.undoManager?.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .help("Redo (⇧⌘Z)")
        }
    }
}


/// The options of a choice field: rename, colour, reorder, add and remove.
private struct OptionsSection: View {
    let field: Field
    let update: (Field) -> Void
    let rename: (String, String) -> Void
    @State private var newOption = ""

    private func change(_ body: (inout FieldOptions) -> Void) {
        var f = field
        body(&f.options)
        update(f)
    }

    var body: some View {
        Section {
            // Rows belong to their option, not their place: removing or moving one never hands a
            // half-typed name to the option that moves into its place.
            ForEach(Array(field.options.choices.enumerated()), id: \.element) { index, option in
                HStack(spacing: 8) {
                    Menu {
                        ForEach(AccentChoice.allCases) { color in
                            Button { change { $0.choiceColors[option] = color } } label: {
                                Label(color.label, systemImage: field.color(of: option) == color ? "checkmark.circle.fill" : "circle.fill")
                            }
                        }
                    } label: {
                        Circle().fill(field.color(of: option)?.color ?? .gray).frame(width: 14, height: 14)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Colour")
                    OptionName(option: option, choices: field.options.choices, rename: rename)
                    Button { change { o in if index > 0 { o.choices.swapAt(index, index - 1) } } } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless).disabled(index == 0).help("Move up")
                    Button { change { o in if index + 1 < o.choices.count { o.choices.swapAt(index, index + 1) } } } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless).disabled(index + 1 == field.options.choices.count).help("Move down")
                    Button { change { o in
                        o.choices.remove(at: index)
                        o.choiceColors[option] = nil
                        if o.defaultValue == option { o.defaultValue = "" }
                    } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Remove option")
                }
            }
            HStack {
                TextField("New option", text: $newOption)
                    .labelsHidden()
                    .onSubmit(add)
                Button("Add", action: add).disabled(newOption.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Options")
        } footer: {
            Text("Renaming an option renames it in every record too.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func add() {
        let text = newOption.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !field.options.choices.contains(text) else { return }
        change { $0.choices.append(text) }
        newOption = ""
    }
}

/// One option's name. Renamed when typing is done, so the half-typed names in between never
/// meet values that records still hold (from an option removed earlier) and merge with them.
private struct OptionName: View {
    let option: String
    let choices: [String]
    let rename: (String, String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Option", text: $text)
            .labelsHidden()
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, now in if !now { commit() } }
            .onChange(of: option) { _, stored in if !focused { text = stored } }
            .onAppear { text = option }
            .onDisappear(perform: commit)
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed != option, !choices.contains(trimmed) { rename(option, trimmed) }
        else { text = option }
    }
}
