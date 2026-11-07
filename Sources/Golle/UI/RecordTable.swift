import SwiftUI

/// A cell that edits in place where the type allows it; the rest show their value and are edited
/// in the inspector.
struct EditableCell: View {
    @ObservedObject var document: GolleDocument
    let table: DataTable
    let field: Field
    let record: Record
    let resolver: Resolver
    var isLast = false
    @Environment(\.cellActions) private var cellActions

    private var value: Value? { record[field.id] }

    private func set(_ value: Value?) {
        cellActions?.focused(record.id, field.id)
        document.setValue(value, record: record.id, field: field.id, table: table.id)
    }

    private var focus: () -> Void { { cellActions?.focused(record.id, field.id) } }
    private var pasteBlock: ((String) -> Void)? {
        cellActions.map { actions in { text in actions.pasteBlock(record.id, field.id, text) } }
    }

    var body: some View {
        switch field.type {
        case .text, .url, .email, .phone:
            TextCell(field: field, value: value?.text, commit: { set($0.isEmpty ? nil : .text($0)) },
                     submit: { if isLast { document.addRecord(to: table.id) } }, focus: focus, pasteBlock: pasteBlock)
        case .barcode:
            TextCell(field: field, value: value?.text, commit: { set(Value.text($0).converted(to: .barcode)) },
                     submit: { if isLast { document.addRecord(to: table.id) } }, focus: focus, pasteBlock: pasteBlock)
        case .number:
            NumberCell(field: field, value: value?.number, commit: { set($0.map(Value.number)) }, focus: focus, pasteBlock: pasteBlock)
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
    var focus: () -> Void = {}
    /// Pastes a block of cells from here; without it, a pasted block stays in this cell on one line.
    var pasteBlock: ((String) -> Void)?
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
            .onChange(of: focused) { _, isFocused in if isFocused { focus() } else { save() } }
            .onChange(of: draft) { old, new in
                if let block = CellPasting.block(old: old, new: new) {
                    draft = old
                    if let pasteBlock { pasteBlock(block) } else { draft = CellPasting.oneLine(new) }
                }
            }
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
    var focus: () -> Void = {}
    var pasteBlock: ((String) -> Void)?
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
        .onChange(of: focused) { _, isFocused in if isFocused { focus() } else { save() } }
        .onChange(of: draft) { old, new in
            if let block = CellPasting.block(old: old, new: new) {
                draft = old
                if let pasteBlock { pasteBlock(block) } else { draft = CellPasting.oneLine(new) }
            }
        }
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

/// What the table does when a cell is clicked into or a block of cells is pasted into one.
struct CellActions {
    /// A cell was clicked into or changed: pasting into the table starts in its column.
    var focused: (Record.ID, Field.ID) -> Void
    /// A block of cells (tabs, lines) was pasted into a cell being edited.
    var pasteBlock: (Record.ID, Field.ID, String) -> Void
}

extension EnvironmentValues {
    @Entry var cellActions: CellActions? = nil
}

/// Telling a pasted block from typing: a cell's text can only get a tab or a line break by pasting
/// (Tab and Return move on).
enum CellPasting {
    /// The pasted block, when the new text has one the old didn't: the clipboard as it is when it
    /// is what was pasted, else the new text.
    static func block(old: String, new: String) -> String? {
        guard CellClipboard.isBlock(new), !CellClipboard.isBlock(old) else { return nil }
        if let clip = NSPasteboard.general.string(forType: .string), CellClipboard.isBlock(clip) {
            var trimmed = clip
            while trimmed.hasSuffix("\n") || trimmed.hasSuffix("\r") { trimmed.removeLast() }
            if new.contains(trimmed) { return clip }
        }
        return new
    }

    /// Text for one cell: tabs and line breaks become spaces.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0 == "\t" || $0 == "\n" || $0 == "\r" }).joined(separator: " ")
    }
}
