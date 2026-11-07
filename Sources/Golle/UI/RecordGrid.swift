import SwiftUI
import UniformTypeIdentifiers

/// The records as a spreadsheet: a cell cursor moved with the arrow keys, blocks of cells selected
/// by dragging or with ⇧, typing to edit, and copy, cut, paste, clear and fill down on the block.
/// Whole rows are chosen from the row numbers. The first column stays put while scrolling sideways.
struct RecordGrid: View {
    @ObservedObject var document: GolleDocument
    let table: DataTable
    let view: SavedView
    let rows: [Record]
    let resolver: Resolver

    @State private var selection: GridSelection?
    @State private var editing: GridPoint?
    /// What was typed to start editing: it replaces the cell's text.
    @State private var seed: String?
    /// Editing in the cell as text; otherwise the field's own editor opens over the cell.
    @State private var editsAsText = true
    /// A new one each time editing starts: editing the same cell again gets a fresh editor (one
    /// left over from before has already finished, and would not save).
    @State private var editSession = UUID()
    /// The cell's text editor has the keyboard. Until it has, keys typed come to the grid and are
    /// kept for it; after, the grid (which sees keys first) lets them through.
    @State private var editorFocused = false
    @State private var collapsed = Set<String>()
    @StateObject private var scroll = GridScroll()
    @State private var position = ScrollPosition()
    @FocusState private var focused: Bool
    @State private var lastClick: (point: GridPoint, time: TimeInterval)?
    /// The mouse is down: dragging extends the selection.
    @State private var press: Press?
    /// Column widths while a column's edge is dragged.
    @State private var liveWidths: [Field.ID: Double] = [:]
    /// The selection changed by the mouse: the grid doesn't scroll to it (a cell that is partly
    /// out of view would move away under the pointer, and the second click of a double-click land
    /// on another cell).
    @State private var byMouse = false

    struct Press {
        var onNumbers: Bool
        var moved = false
        /// Where it started: a press from a drag that was cancelled (and never ended) is not
        /// taken for the next one.
        var start: CGPoint = .zero
    }

    static let rowHeight: CGFloat = 26
    static let headerHeight: CGFloat = 28
    static let numberWidth: CGFloat = 44

    // MARK: Layout

    /// One line of the grid: a record, or a group's title with its totals.
    enum Line: Identifiable {
        case record(Record, number: Int)
        case group(RecordGroup, depth: Int)
        var id: String {
            switch self {
            case .record(let r, _): r.id.uuidString
            case .group(let g, _): "group:" + g.id
            }
        }
    }

    /// Where everything is: fixed row heights and the columns' widths, so a point is a cell.
    struct Layout {
        let columns: [Field]
        let widths: [CGFloat]
        /// Each column's left edge; the first sits after the row numbers and stays put.
        let offsets: [CGFloat]
        let lines: [Line]
        /// The records in the order shown (without those in collapsed groups).
        let order: [Record.ID]
        let lineOf: [Record.ID: Int]
        var columnIDs: [Field.ID] { columns.map(\.id) }
        var pinnedWidth: CGFloat { RecordGrid.numberWidth + (widths.first ?? 0) }
        var totalWidth: CGFloat { RecordGrid.numberWidth + widths.reduce(0, +) }
    }

    private func layout() -> Layout {
        let columns = view.columns(table)
        let widths = columns.map { CGFloat(liveWidths[$0.id] ?? GridColumns.width($0, in: view)) }
        var offsets: [CGFloat] = []
        var x = Self.numberWidth
        for w in widths { offsets.append(x); x += w }
        var lines: [Line] = []
        var number = 0
        let groupFields = view.groupBy.compactMap(table.field)
        if groupFields.isEmpty {
            for record in rows { number += 1; lines.append(.record(record, number: number)) }
        } else {
            func add(_ groups: [RecordGroup], depth: Int) {
                for group in groups {
                    lines.append(.group(group, depth: depth))
                    guard !collapsed.contains(group.id) else { continue }
                    if group.subgroups.isEmpty {
                        for record in group.records { number += 1; lines.append(.record(record, number: number)) }
                    } else {
                        add(group.subgroups, depth: depth + 1)
                    }
                }
            }
            add(Grouping.groups(rows, by: groupFields, resolver), depth: 0)
        }
        var order: [Record.ID] = []
        var lineOf: [Record.ID: Int] = [:]
        for (i, line) in lines.enumerated() {
            if case .record(let r, _) = line { order.append(r.id); lineOf[r.id] = i }
        }
        return Layout(columns: columns, widths: widths, offsets: offsets, lines: lines, order: order, lineOf: lineOf)
    }

    // MARK: Body

    var body: some View {
        let layout = layout()
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(layout.lines) { line in
                        switch line {
                        case .record(let record, let number):
                            recordRow(record, number: number, layout: layout)
                        case .group(let group, let depth):
                            groupRow(group, depth: depth, layout: layout)
                        }
                    }
                } header: {
                    header(layout)
                }
            }
            .frame(width: layout.totalWidth, alignment: .leading)
            .coordinateSpace(name: "grid")
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGRect.self) { geometry in
            CGRect(x: geometry.contentOffset.x + geometry.contentInsets.leading, y: geometry.contentOffset.y + geometry.contentInsets.top,
                   width: geometry.containerSize.width - geometry.contentInsets.leading - geometry.contentInsets.trailing,
                   height: geometry.containerSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom)
        } action: { _, visible in
            scroll.update(visible)
        }
        .onScrollGeometryChange(for: EdgeInsets.self) { $0.contentInsets } action: { _, insets in scroll.insets = insets }
        .background(.background)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: [.down, .repeat]) { press in key(press, layout: layout) }
        .onCopyCommand { copy(layout).map { [NSItemProvider(object: $0 as NSString)] } ?? [] }
        .onCutCommand {
            let text = copy(layout)
            clear(layout)
            return text.map { [NSItemProvider(object: $0 as NSString)] } ?? []
        }
        .onPasteCommand(of: [.plainText, .utf8PlainText, .tabSeparatedText, .utf8TabSeparatedText, .fileURL, .image, .png, .tiff, .jpeg]) { _ in
            let board = NSPasteboard.general
            // Files or an image pasted on a photo or file cell are added to it.
            if let cursor = selection?.cursor, table.field(cursor.field)?.type.isAttachment == true {
                let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
                let image = urls.isEmpty ? NSImage(pasteboard: board) : nil
                if !urls.isEmpty || image != nil {
                    attach(urls: urls, images: image.map { [$0] } ?? [], to: cursor)
                    return
                }
            }
            if let text = board.string(forType: .string) { paste(text, layout: layout) }
        }
        .onDeleteCommand { delete(layout) }
        .onCommand(#selector(NSResponder.selectAll(_:))) { selection = GridSelection.all(order: layout.order, columns: layout.columnIDs) }
        .onChange(of: selection) { _, new in
            publish(new, layout: layout)
            if let editing, editing != new?.cursor { self.editing = nil }
            if byMouse { byMouse = false } else if let cursor = new?.cursor { reveal(cursor, layout: layout) }
        }
        .onChange(of: document.selectedRecordIDs) { _, ids in follow(ids, layout: layout) }
        // The cursor's record gone (deleted from a menu, filtered out): no cursor left behind on it.
        .onChange(of: layout.order) { _, order in
            if let cursor = selection?.cursor, !order.contains(cursor.record) { selection = nil }
        }
        .onAppear { follow(document.selectedRecordIDs, layout: layout) }
    }

    // MARK: Rows

    private func recordRow(_ record: Record, number: Int, layout: Layout) -> some View {
        let shaded = number.isMultiple(of: 2)
        let rowSelected = selection.map { sel in
            sel.wholeRows && (sel.extraRows.contains(record.id) || sel.contains(GridPoint(record: record.id, field: layout.columnIDs.first ?? UUID()), order: layout.order, columns: layout.columnIDs))
        } ?? false
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                Color.clear.frame(width: layout.pinnedWidth)
                ForEach(Array(layout.columns.enumerated().dropFirst()), id: \.element.id) { i, field in
                    cell(record, field, width: layout.widths[i], shaded: shaded, layout: layout)
                }
            }
            GridPinned(scroll: scroll) {
                HStack(spacing: 0) {
                    Text("\(number)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(rowSelected ? Color.accentColor : .secondary)
                        .frame(width: Self.numberWidth, height: Self.rowHeight)
                        .background(rowSelected ? AnyShapeStyle(Color.accentColor.opacity(0.18)) : AnyShapeStyle(.bar))
                        .overlay(alignment: .trailing) { GridLine(vertical: true) }
                    if let first = layout.columns.first {
                        cell(record, first, width: layout.widths[0], shaded: shaded, layout: layout, first: true)
                            .overlay(alignment: .trailing) { Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 1) }
                    }
                }
            }
        }
        .frame(width: layout.totalWidth, height: Self.rowHeight, alignment: .leading)
        .contentShape(.rect)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("grid"))
            .onChanged { value in
                if press == nil || press?.start != value.startLocation { press = nil; mouseDown(at: value.startLocation, layout: layout) }
                if hypot(value.translation.width, value.translation.height) > 3 { press?.moved = true }
                if press?.moved == true { dragged(to: value.location, layout: layout) }
            }
            .onEnded { value in
                let moved = press?.moved ?? false
                press = nil
                if !moved { clicked(at: value.startLocation, layout: layout) }
            })
        .contextMenu { menu(for: record, layout: layout) }
    }

    private func cell(_ record: Record, _ field: Field, width: CGFloat, shaded: Bool, layout: Layout, first: Bool = false) -> some View {
        let point = GridPoint(record: record.id, field: field.id)
        let selected = selection?.contains(point, order: layout.order, columns: layout.columnIDs) ?? false
        let isCursor = selection?.cursor == point && editing != point
        let problem = resolver.hasRules ? resolver.ruleProblem(record, field) : nil
        return HStack(spacing: 4) {
            if first, let color = table.color(of: record, resolver) {
                RoundedRectangle(cornerRadius: 2).fill(color.color).frame(width: 4).padding(.vertical, 4)
            }
            if editing == point, editsAsText {
                editor(record, field, layout: layout)
            } else {
                CellView(document: document, field: field, record: record, resolver: resolver)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let problem {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
                    .help("\(field.name): \(problem.message)")
            }
        }
        .padding(.horizontal, 6)
        .frame(width: width, height: Self.rowHeight, alignment: .leading)
        .background {
            ZStack {
                Rectangle().fill(.background)
                if shaded { Color.secondary.opacity(0.05) }
                if problem != nil { Color.orange.opacity(0.14) }
                if selected { Color.accentColor.opacity(0.16) }
            }
        }
        .overlay(alignment: .trailing) { GridLine(vertical: true) }
        .overlay(alignment: .bottom) { GridLine(vertical: false) }
        .overlay { if isCursor { Rectangle().strokeBorder(Color.accentColor, lineWidth: 2) } }
        .clipped()
        // On the cell itself, not on what it shows: an empty files, colour or place cell shows
        // nothing at all, and a popover needs something to point at.
        .popover(isPresented: popoverBinding(point), arrowEdge: .bottom) {
            // The field's own editor, as in the form: pickers, long text, files, places.
            GridPopoverEditor(document: document, table: table, recordID: record.id, field: field,
                              resolver: resolver, typed: seed, close: {
                                  editing = nil
                                  focused = true
                              })
                .padding(12)
                .frame(width: Self.popoverWidth(field))
                // The popover takes the keyboard when it opens: typed text goes into it, not the grid.
                .background(TakesKeyboard())
        }
        // Scrolled out of view with its editor open: the editor is gone, so editing ends.
        .onDisappear { if editing == point, !editsAsText { editing = nil } }
        // Files and images dropped on a photo or file cell are added to it.
        .dropDestination(for: URL.self) { urls, _ in
            guard field.type.isAttachment else { return false }
            attach(urls: urls.filter(\.isFileURL), images: [], to: point)
            return true
        }
    }

    private func popoverBinding(_ point: GridPoint) -> Binding<Bool> {
        Binding(get: { editing == point && !editsAsText }, set: { shown in
            if !shown, editing == point {
                editing = nil
                refocusUnlessTyping()
            }
        })
    }

    /// The grid takes the keyboard back, unless a text field or text view elsewhere has just
    /// taken it (a click in the inspector or the search field closed the editor).
    private func refocusUnlessTyping() {
        DispatchQueue.main.async {
            let responder = NSApp.keyWindow?.firstResponder
            if responder is NSText || responder is NSTextField { return }
            focused = true
        }
    }

    private func currentRecord(_ id: Record.ID) -> Record? {
        document.database.table(table.id)?.records.first { $0.id == id }
    }

    static func popoverWidth(_ field: Field) -> CGFloat {
        switch field.type {
        case .longText, .image, .file, .location, .checklist: 380
        case .link: 340
        default: 280
        }
    }

    /// Files (and pasted images) added to a photo or file cell.
    private func attach(urls: [URL], images: [NSImage], to point: GridPoint) {
        guard let field = table.field(point.field), field.type.isAttachment else { return }
        var added: [Attachment] = []
        for url in urls {
            if field.type == .image, let type = UTType(filenameExtension: url.pathExtension), !type.conforms(to: .image) { continue }
            if let attachment = try? document.importAttachment(from: url) { added.append(attachment) }
        }
        for image in images {
            if let png = AttachmentEditor.png(image) { added.append(document.addAttachment(data: png, name: "Pasted Image.png")) }
        }
        guard !added.isEmpty else { NSSound.beep(); return }
        let existing = currentRecord(point.record)?[field.id]?.attachments ?? []
        document.setValue(.attachments(existing + added), record: point.record, field: field.id, table: table.id)
    }

    private func groupRow(_ group: RecordGroup, depth: Int, layout: Layout) -> some View {
        let isCollapsed = collapsed.contains(group.id)
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                Color.clear.frame(width: layout.pinnedWidth)
                ForEach(Array(layout.columns.enumerated().dropFirst()), id: \.element.id) { i, field in
                    groupTotal(group, field).frame(width: layout.widths[i], height: Self.rowHeight)
                }
            }
            GridPinned(scroll: scroll) {
                Button {
                    if isCollapsed { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.caption.weight(.bold)).frame(width: 12)
                        Text(group.title).fontWeight(.semibold).lineLimit(1)
                        Text("\(group.records.count)").foregroundStyle(.secondary).monospacedDigit()
                        Spacer(minLength: 0)
                        if let first = layout.columns.first, table.summaries.contains(where: { $0.fieldID == first.id }) {
                            groupTotal(group, first).fixedSize()
                        }
                    }
                    .padding(.leading, 8 + CGFloat(depth) * 14)
                    .padding(.trailing, 6)
                    .frame(width: layout.pinnedWidth, height: Self.rowHeight, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .background(.background)
                .overlay(alignment: .trailing) { Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 1) }
            }
        }
        .frame(width: layout.totalWidth, height: Self.rowHeight, alignment: .leading)
        .background(Color.secondary.opacity(0.1))
        .overlay(alignment: .bottom) { GridLine(vertical: false) }
    }

    @ViewBuilder
    private func groupTotal(_ group: RecordGroup, _ field: Field) -> some View {
        if let item = table.summaries.first(where: { $0.fieldID == field.id }) {
            Text(item.kind.compute(group.records.map { resolver.value($0, field) }, field: resolver.formatField(field)))
                .foregroundStyle(.secondary)
                .fontWeight(.medium)
                .monospacedDigit()
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: Self.alignsRight(field) ? .trailing : .leading)
                .help("\(item.kind.label) of \(field.name)")
        } else {
            Color.clear
        }
    }

    static func alignsRight(_ field: Field) -> Bool {
        field.type.isNumeric || field.type == .duration || field.type == .formula || field.type == .rollup || field.type == .lookup
    }

    // MARK: Header

    private func header(_ layout: Layout) -> some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                Color.clear.frame(width: layout.pinnedWidth)
                ForEach(Array(layout.columns.enumerated().dropFirst()), id: \.element.id) { i, field in
                    GridHeaderCell(field: field, width: layout.widths[i], sort: view.sort, columns: layout.columnIDs,
                                   actions: headerActions(field, layout: layout))
                }
            }
            GridPinned(scroll: scroll) {
                HStack(spacing: 0) {
                    // The corner selects everything.
                    Button { selection = GridSelection.all(order: layout.order, columns: layout.columnIDs); focused = true } label: {
                        Color.clear.frame(width: Self.numberWidth, height: Self.headerHeight).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Select all cells (⌘A)")
                    .overlay(alignment: .trailing) { GridLine(vertical: true) }
                    if let first = layout.columns.first {
                        GridHeaderCell(field: first, width: layout.widths[0], sort: view.sort, columns: layout.columnIDs,
                                       actions: headerActions(first, layout: layout))
                            .overlay(alignment: .trailing) { Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 1) }
                    }
                }
                .background(.bar)
            }
        }
        .frame(width: layout.totalWidth, height: Self.headerHeight, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { GridLine(vertical: false) }
    }

    private func headerActions(_ field: Field, layout: Layout) -> GridHeaderCell.Actions {
        GridHeaderCell.Actions(
            sort: { adding in document.updateCurrentView("Sort") { $0.sort = GridColumns.sorting($0.sort, by: field.id, adding: adding) } },
            sortDirection: { ascending in document.updateCurrentView("Sort") { $0.sort = [SortKey(fieldID: field.id, ascending: ascending)] } },
            group: { document.updateCurrentView("Group") { $0.groupBy = [field.id] } },
            hide: { document.updateCurrentView("Hide Field") { $0.hiddenFieldIDs.append(field.id) } },
            resize: { width in liveWidths[field.id] = width },
            resized: { width in
                liveWidths[field.id] = nil
                document.updateCurrentView("Resize Column") { $0.columnWidths[field.id.uuidString] = width }
            },
            move: { moved, target in
                guard moved != target else { return }
                document.updateCurrentView("Move Column") { $0.columnOrder = GridColumns.moving(moved, before: target, in: layout.columnIDs) }
            },
            selectColumn: {
                guard let top = layout.order.first, let bottom = layout.order.last else { return }
                var column = GridSelection(GridPoint(record: top, field: field.id))
                column.cursor = GridPoint(record: bottom, field: field.id)
                selection = column
                focused = true
            },
            width: { CGFloat(GridColumns.width(field, in: view)) }
        )
    }

    // MARK: Editing

    /// The editor in the cell being edited: text for most types, the field's own control for
    /// choices, links, colours and ratings.
    private func editor(_ record: Record, _ field: Field, layout: Layout) -> some View {
        GridTextEditor(text: seed ?? Exporter.cell(record, field, resolver), alignment: Self.alignsRight(field) ? .trailing : .leading) { text, move in
            finishEditing(record, field, text: text, move: move, layout: layout)
        } pasteBlock: { block in
            editing = nil
            paste(block, layout: layout)
        } focusChanged: { editorFocused = $0 }
        .id(editSession)
    }

    /// The types typed straight into the cell. A date is too when typing starts it; Return or a
    /// double-click on a date opens the date picker.
    static func editsAsText(_ type: FieldType, typed: Bool) -> Bool {
        type.isTextLike || [.number, .duration, .progress].contains(type) || (type == .date && typed)
    }

    /// Starts editing the cursor's cell, with what was typed (or the cell's value).
    private func beginEditing(_ point: GridPoint, seed typed: String? = nil, layout: Layout) {
        guard let field = table.field(point.field), let record = rows.first(where: { $0.id == point.record }) else { return }
        switch field.type {
        case .formula, .rollup, .lookup, .autoNumber, .createdAt, .modifiedAt:
            NSSound.beep()
        case .checkbox:
            document.setValue(record[field.id]?.bool == true ? nil : .bool(true), record: record.id, field: field.id, table: table.id)
        case .rating where typed.flatMap(Int.init).map { (0...Value.maxRating).contains($0) } == true:
            let stars = Int(typed!)!
            document.setValue(stars > 0 ? .rating(stars) : nil, record: record.id, field: field.id, table: table.id)
        default:
            let asText = Self.editsAsText(field.type, typed: typed != nil)
            // Long text keeps what was typed too: it goes into its editor.
            seed = asText || field.type == .longText ? typed : nil
            editsAsText = asText
            editSession = UUID()
            editorFocused = false
            editing = point
        }
    }

    /// Saves what was typed and moves on; `text` nil means cancelled (Escape).
    private func finishEditing(_ record: Record, _ field: Field, text: String?, move: GridTextEditor.Move, layout: Layout) {
        // Still editing this cell, or already somewhere else (a click on another cell ends the
        // editing first): what was typed is saved either way, but only Return, Tab and the arrows
        // move on from here.
        let current = editing == GridPoint(record: record.id, field: field.id)
        // Moving on from here (Return, Tab) scrolls to where the cursor goes.
        byMouse = false
        if current {
            editing = nil
            seed = nil
        }
        if let text {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                document.setValue(nil, record: record.id, field: field.id, table: table.id)
            } else if let value = CellClipboard.value(trimmed, for: field, order: nil, resolver: resolver) {
                document.setValue(value, record: record.id, field: field.id, table: table.id)
            } else {
                // Not something this field can hold ("abc" in a number field): the value stays.
                NSSound.beep()
            }
        }
        guard current else { return }
        // Back to the grid after a key (Return, Tab, an arrow, Escape); not when editing ended by
        // a click elsewhere: the field clicked keeps the keyboard.
        if move != .none || text == nil { focused = true } else { refocusUnlessTyping() }
        guard let selection else { return }
        switch move {
        case .none: break
        case .down:
            // Return in the last row adds a record.
            if layout.order.last == record.id, text != nil {
                if let id = document.addRecord(to: table.id) {
                    self.selection = GridSelection(GridPoint(record: id, field: field.id))
                }
            } else {
                self.selection = selection.moved(rows: 1, columns: 0, extend: false, order: layout.order, columns: layout.columnIDs)
            }
        case .up: self.selection = selection.moved(rows: -1, columns: 0, extend: false, order: layout.order, columns: layout.columnIDs)
        case .right: self.selection = selection.moved(rows: 0, columns: 1, extend: false, order: layout.order, columns: layout.columnIDs)
        case .left: self.selection = selection.moved(rows: 0, columns: -1, extend: false, order: layout.order, columns: layout.columnIDs)
        }
    }

    // MARK: Mouse

    private enum Spot {
        case number(Record.ID)
        case cell(GridPoint)
    }

    /// What is under a point of the grid (in its own coordinates, header included).
    private func spot(at point: CGPoint, layout: Layout, clamp: Bool = false) -> Spot? {
        let rawLine = Int(((point.y - Self.headerHeight) / Self.rowHeight).rounded(.down))
        // Dragging past the top or bottom keeps to the first or last record.
        func record(_ line: Int) -> Record.ID? {
            guard !layout.lines.isEmpty else { return nil }
            let l = clamp ? min(max(line, 0), layout.lines.count - 1) : line
            guard layout.lines.indices.contains(l) else { return nil }
            if case .record(let r, _) = layout.lines[l] { return r.id }
            guard clamp else { return nil }
            // A group's line while dragging: the nearest record below it, else above.
            for i in l..<layout.lines.count { if case .record(let r, _) = layout.lines[i] { return r.id } }
            for i in stride(from: l, through: 0, by: -1) { if case .record(let r, _) = layout.lines[i] { return r.id } }
            return nil
        }
        guard let recordID = record(rawLine), !layout.columns.isEmpty else { return nil }
        let x = point.x
        if x < scroll.visible.minX + Self.numberWidth { return clamp ? .cell(GridPoint(record: recordID, field: layout.columnIDs[0])) : .number(recordID) }
        if x < scroll.visible.minX + layout.pinnedWidth { return .cell(GridPoint(record: recordID, field: layout.columnIDs[0])) }
        let index = layout.offsets.lastIndex { $0 <= x } ?? 0
        return .cell(GridPoint(record: recordID, field: layout.columnIDs[max(1, min(index, layout.columns.count - 1))]))
    }

    private func mouseDown(at location: CGPoint, layout: Layout) {
        guard let spot = spot(at: location, layout: layout) else { return }
        // A click in the cell being edited is the editor's: it keeps the keyboard.
        if case .cell(let point) = spot, point == editing {
            press = Press(onNumbers: false, start: location)
            return
        }
        let before = selection
        defer { if selection != before { byMouse = true } }
        let keys = NSEvent.modifierFlags
        focused = true
        switch spot {
        case .number(let id):
            press = Press(onNumbers: true, start: location)
            let point = GridPoint(record: id, field: layout.columnIDs.first ?? UUID())
            if keys.contains(.command), var sel = selection, sel.wholeRows {
                if sel.extraRows.contains(id) { sel.extraRows.remove(id) } else { sel.extraRows.insert(id) }
                selection = sel
            } else if keys.contains(.shift), var sel = selection {
                sel.wholeRows = true
                sel.cursor = point
                selection = sel
            } else {
                selection = GridSelection(point, wholeRows: true)
            }
        case .cell(let point):
            press = Press(onNumbers: false, start: location)
            if editing != nil, editing != point { editing = nil }
            if keys.contains(.shift), let sel = selection {
                selection = sel.extended(to: point)
            } else if selection != GridSelection(point) {
                selection = GridSelection(point)
            }
        }
    }

    private func dragged(to location: CGPoint, layout: Layout) {
        guard let press, var sel = selection, let spot = spot(at: location, layout: layout, clamp: true) else { return }
        if press.onNumbers {
            if case .cell(let point) = spot { sel.cursor = GridPoint(record: point.record, field: sel.cursor.field) }
        } else if case .cell(let point) = spot {
            sel = sel.extended(to: point)
        }
        if sel != selection {
            byMouse = true
            selection = sel
        }
    }

    /// A click without dragging: a checkbox toggles, a second click on the same cell edits it.
    private func clicked(at location: CGPoint, layout: Layout) {
        guard case .cell(let point)? = spot(at: location, layout: layout), !NSEvent.modifierFlags.contains(.shift) else { return }
        // Clicks in the cell being edited are the editor's (placing the cursor, selecting a word).
        if editing == point { return }
        let now = ProcessInfo.processInfo.systemUptime
        let field = table.field(point.field)
        if field?.type == .checkbox {
            beginEditing(point, layout: layout)
        } else if let last = lastClick, last.point == point, now - last.time < NSEvent.doubleClickInterval {
            beginEditing(point, layout: layout)
        }
        lastClick = (point, now)
    }

    // MARK: Keyboard

    private func key(_ press: KeyPress, layout: Layout) -> KeyPress.Result {
        // Moved by the keyboard: scrolled into view.
        byMouse = false
        // A field's editor open over the cell (it has the keyboard itself once clicked or when it
        // holds text): Escape closes it, an arrow or Tab closes it and moves on; other keys are its own.
        if editing != nil, !editsAsText {
            if press.key == .escape { editing = nil; return .handled }
            guard [.upArrow, .downArrow, .leftArrow, .rightArrow, .tab].contains(press.key) else { return .ignored }
            editing = nil
        }
        // Typed before the cell's editor has the keyboard (it takes it a moment later): kept.
        if editing != nil, editsAsText {
            guard !editorFocused else { return .ignored }
            if !press.modifiers.contains(.command), !press.modifiers.contains(.control), !press.characters.isEmpty,
               press.characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && ($0.value < 0xF700 || $0.value > 0xF8FF) }) {
                seed = (seed ?? "") + press.characters
                return .handled
            }
            return .ignored
        }
        guard editing == nil else { return .ignored }
        let shift = press.modifiers.contains(.shift)
        let command = press.modifiers.contains(.command)
        guard let sel = selection else {
            // The first key press picks the first cell.
            if [.upArrow, .downArrow, .leftArrow, .rightArrow, .tab, .return].contains(press.key),
               let first = layout.order.first, let column = layout.columnIDs.first {
                selection = GridSelection(GridPoint(record: first, field: column))
                return .handled
            }
            return .ignored
        }
        func move(_ dr: Int, _ dc: Int, extend: Bool) -> KeyPress.Result {
            selection = sel.moved(rows: dr, columns: dc, extend: extend, order: layout.order, columns: layout.columnIDs)
            return .handled
        }
        // ⌘ and an arrow: to the edge.
        let far = command ? 1_000_000 : 1
        switch press.key {
        case .upArrow: return move(-far, 0, extend: shift)
        case .downArrow: return move(far, 0, extend: shift)
        case .leftArrow: return move(0, -far, extend: shift)
        case .rightArrow: return move(0, far, extend: shift)
        case .tab: return move(0, shift ? -1 : 1, extend: false)
        case .return:
            beginEditing(sel.cursor, layout: layout)
            return .handled
        case .escape:
            selection = GridSelection(sel.cursor)
            return .handled
        case .space where table.field(sel.cursor.field)?.type == .checkbox:
            toggleChecks(sel, layout: layout)
            return .handled
        case .delete, .deleteForward:
            delete(layout)
            return .handled
        default:
            break
        }
        // Typing starts editing with what was typed.
        guard !command, !press.modifiers.contains(.control), let char = press.characters.first,
              !char.isNewline, char.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              press.characters.unicodeScalars.allSatisfy({ $0.value < 0xF700 || $0.value > 0xF8FF }) else { return .ignored }
        beginEditing(sel.cursor, seed: press.characters, layout: layout)
        return .handled
    }

    /// Space on checkboxes: all of them in the block on, or off when they all are.
    private func toggleChecks(_ sel: GridSelection, layout: Layout) {
        let block = sel.block(order: layout.order, columns: layout.columnIDs)
        let boxes = block.fields.compactMap(table.field).filter { $0.type == .checkbox }
        let records = rows.filter { block.records.contains($0.id) }
        let allOn = records.allSatisfy { r in boxes.allSatisfy { r[$0.id]?.bool == true } }
        var paste = CellClipboard.Paste()
        for record in records { for box in boxes { paste.updates.append((record.id, box.id, allOn ? nil : .bool(true))) } }
        document.paste(paste, into: table.id, actionName: allOn ? "Uncheck" : "Check")
    }

    // MARK: Block commands

    private func copy(_ layout: Layout) -> String? {
        guard let sel = selection else { return nil }
        let block = sel.block(order: layout.order, columns: layout.columnIDs)
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let fields = block.fields.compactMap(table.field)
        guard !block.records.isEmpty, !fields.isEmpty else { return nil }
        let records = block.records.compactMap { byID[$0] }
        let text = CellClipboard.text(records, fields: fields, resolver: resolver)
        CellClipboard.copied = CellClipboard.Copied(text: text, cells: CellClipboard.cells(records, fields: fields), database: ObjectIdentifier(document))
        return text
    }

    private func clear(_ layout: Layout) {
        guard let sel = selection else { return }
        let block = sel.block(order: layout.order, columns: layout.columnIDs)
        document.clearCells(records: block.records, fields: block.fields, table: table.id)
    }

    /// Delete: whole rows chosen from the row numbers are deleted; cells are emptied.
    private func delete(_ layout: Layout) {
        guard let sel = selection else { return }
        if sel.wholeRows {
            let block = sel.block(order: layout.order, columns: layout.columnIDs)
            document.deleteRecords(Set(block.records), from: table.id)
            selection = nil
        } else {
            clear(layout)
        }
    }

    /// Pastes at the block's top left: over the records shown from there, with new records for
    /// what is left. One value over a block goes into every cell of it.
    private func paste(_ text: String, layout: Layout) {
        var grid = CellClipboard.grid(text)
        guard !grid.isEmpty else { return }
        // Copied in this database and still what the clipboard holds: the values themselves.
        var values = CellClipboard.copied.flatMap { $0.text == text && $0.database == ObjectIdentifier(document) ? $0.cells : nil }
        let block = selection?.block(order: layout.order, columns: layout.columnIDs)
        let top = block?.records.first
        let left = block?.fields.first.flatMap(layout.columnIDs.firstIndex) ?? 0
        var targets: [Record.ID]
        if grid.count == 1, grid[0].count == 1, let block, block.records.count * block.fields.count > 1 {
            grid = Array(repeating: Array(repeating: grid[0][0], count: block.fields.count), count: block.records.count)
            values = values.map { v in Array(repeating: Array(repeating: v[0][0], count: block.fields.count), count: block.records.count) }
            targets = block.records
        } else {
            targets = top.flatMap { id in layout.order.firstIndex(of: id).map { Array(layout.order[$0...]) } } ?? []
        }
        let plan = CellClipboard.plan(grid, table: table, columns: layout.columns, startColumn: left, rows: targets, resolver: resolver, values: values)
        guard !plan.isEmpty else { NSSound.beep(); return }
        let pasted = document.paste(plan, into: table.id)
        // The pasted cells selected.
        if let first = pasted.first, let last = pasted.last {
            let width = grid.map(\.count).max() ?? 1
            let right = min(left + width - 1, layout.columns.count - 1)
            var sel = GridSelection(GridPoint(record: first, field: layout.columnIDs[left]))
            sel.cursor = GridPoint(record: last, field: layout.columnIDs[right])
            selection = sel
        }
    }

    // MARK: Context menu

    @ViewBuilder
    private func menu(for record: Record, layout: Layout) -> some View {
        let inSelection = selection.map { $0.block(order: layout.order, columns: layout.columnIDs).records.contains(record.id) } ?? false
        let records = inSelection ? Set(selection!.block(order: layout.order, columns: layout.columnIDs).records) : [record.id]
        Button("Copy") {
            if !inSelection { selectRow(record, layout: layout) }
            if let text = copy(layout) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
        Button("Paste") {
            if !inSelection { selectRow(record, layout: layout) }
            if let text = NSPasteboard.general.string(forType: .string) { paste(text, layout: layout) }
        }
        if inSelection, records.count > 1 {
            Button("Fill Down") {
                let block = selection!.block(order: layout.order, columns: layout.columnIDs)
                document.fillDown(fields: block.fields, records: block.records, table: table.id)
            }
        }
        Button("Clear") {
            if !inSelection { selectRow(record, layout: layout) }
            clear(layout)
        }
        Divider()
        Button("New Record") { document.addRecord(to: table.id) }
        Button(records.count == 1 ? "Duplicate Record" : "Duplicate \(records.count) Records") {
            document.duplicateRecords(records, in: table.id)
        }
        Button(records.count == 1 ? "Delete Record" : "Delete \(records.count) Records", role: .destructive) {
            document.deleteRecords(records, from: table.id)
        }
        if !collapsed.isEmpty {
            Divider()
            Button("Expand All Groups") { collapsed = [] }
        }
    }

    private func selectRow(_ record: Record, layout: Layout) {
        selection = GridSelection(GridPoint(record: record.id, field: selection?.cursor.field ?? layout.columnIDs.first ?? UUID()))
    }

    // MARK: Selection and scrolling

    /// The selection for the rest of the window: the inspector shows its records, Fill Down
    /// in the menu fills its block.
    private func publish(_ sel: GridSelection?, layout: Layout) {
        let block = sel?.block(order: layout.order, columns: layout.columnIDs) ?? (records: [], fields: [])
        let ids = Set(block.records)
        document.cellBlock = sel == nil ? nil : (table.id, block.records, block.fields)
        if ids != document.selectedRecordIDs { document.selectedRecordIDs = ids }
    }

    /// Records selected elsewhere (a new record, the gallery, a link in the inspector): the cursor
    /// goes to them, in the column it was in.
    private func follow(_ ids: Set<Record.ID>, layout: Layout) {
        let current = Set(selection?.block(order: layout.order, columns: layout.columnIDs).records ?? [])
        guard ids != current else { return }
        byMouse = false
        guard let first = layout.order.first(where: ids.contains), let column = selection?.cursor.field ?? layout.columnIDs.first else {
            if ids.isEmpty, selection != nil { selection = nil }
            return
        }
        var sel = GridSelection(GridPoint(record: first, field: layout.columnIDs.contains(column) ? column : layout.columnIDs[0]))
        if ids.count > 1 {
            sel.wholeRows = true
            sel.extraRows = ids.subtracting([first])
        }
        selection = sel
    }

    /// Scrolls so the cursor's cell can be seen.
    private func reveal(_ point: GridPoint, layout: Layout) {
        guard let line = layout.lineOf[point.record], let column = layout.columnIDs.firstIndex(of: point.field) else { return }
        let visible = scroll.visible
        guard visible.width > 0, visible.height > 0 else { return }
        var x = visible.minX, y = visible.minY
        let top = Self.headerHeight + CGFloat(line) * Self.rowHeight
        // The header covers the top of what can be seen.
        if top < visible.minY + Self.headerHeight { y = top - Self.headerHeight }
        if top + Self.rowHeight > visible.maxY { y = top + Self.rowHeight - visible.height }
        if column > 0 {
            let left = layout.offsets[column], right = left + layout.widths[column]
            // The pinned first column covers the left of what can be seen.
            if left < visible.minX + layout.pinnedWidth { x = left - layout.pinnedWidth }
            if right > visible.maxX { x = right - visible.width }
        }
        guard x != visible.minX || y != visible.minY else { return }
        position.scrollTo(x: max(x, 0) - scroll.insets.leading, y: max(y, 0) - scroll.insets.top)
    }
}

/// Where the grid is scrolled to: only what stays put (the first column, the header) follows it.
final class GridScroll: ObservableObject {
    /// What can be seen, in the grid's coordinates.
    @Published private(set) var visible = CGRect.zero
    var insets = EdgeInsets()

    func update(_ rect: CGRect) {
        let rect = CGRect(x: max(0, rect.minX), y: max(0, rect.minY), width: max(0, rect.width), height: max(0, rect.height))
        if rect != visible { visible = rect }
    }
}

/// Content that stays at the left edge while the grid scrolls sideways.
private struct GridPinned<Content: View>: View {
    @ObservedObject var scroll: GridScroll
    @ViewBuilder let content: Content

    var body: some View {
        content.padding(.leading, scroll.visible.minX)
    }
}

/// A hairline between cells.
private struct GridLine: View {
    let vertical: Bool
    var body: some View {
        Rectangle().fill(Color.secondary.opacity(0.18)).frame(width: vertical ? 0.5 : nil, height: vertical ? nil : 0.5)
    }
}

/// A column's header: click to sort, drag to move, drag its edge to resize, right-click for more.
private struct GridHeaderCell: View {
    let field: Field
    let width: CGFloat
    let sort: [SortKey]
    let columns: [Field.ID]
    let actions: Actions
    @State private var startWidth: CGFloat?
    @State private var targeted = false

    struct Actions {
        var sort: (_ adding: Bool) -> Void
        var sortDirection: (_ ascending: Bool) -> Void
        var group: () -> Void
        var hide: () -> Void
        var resize: (Double) -> Void
        var resized: (Double) -> Void
        var move: (_ field: Field.ID, _ before: Field.ID) -> Void
        var selectColumn: () -> Void
        var width: () -> CGFloat
    }

    var body: some View {
        let key = sort.firstIndex { $0.fieldID == field.id }
        HStack(spacing: 4) {
            Image(systemName: field.type.symbol).font(.caption2).foregroundStyle(.tertiary)
            Text(field.name).fontWeight(.medium).lineLimit(1)
            Spacer(minLength: 0)
            if let key {
                Image(systemName: sort[key].ascending ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                if sort.count > 1 { Text("\(key + 1)").font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .frame(width: width, height: RecordGrid.headerHeight, alignment: .leading)
        .background(targeted ? Color.accentColor.opacity(0.18) : .clear)
        .contentShape(.rect)
        .onTapGesture { actions.sort(NSEvent.modifierFlags.contains(.shift)) }
        .help("\(field.name): click to sort, ⇧-click to sort by it too; drag to move the column")
        .draggable(field.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let moved = items.first.flatMap(UUID.init(uuidString:)), columns.contains(moved) else { return false }
            actions.move(moved, field.id)
            return true
        } isTargeted: { targeted = $0 }
        .overlay(alignment: .trailing) {
            // The edge: drag to resize.
            Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 0.5)
                .frame(width: 8)
                .contentShape(.rect)
                .pointerStyle(.frameResize(position: .trailing))
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = startWidth ?? width
                        if startWidth == nil { startWidth = width }
                        actions.resize(max(GridColumns.minWidth, start + value.translation.width))
                    }
                    .onEnded { value in
                        let start = startWidth ?? width
                        startWidth = nil
                        actions.resized(max(GridColumns.minWidth, start + value.translation.width))
                    })
                .offset(x: 4)
        }
        .contextMenu {
            Button("Select Column") { actions.selectColumn() }
            Divider()
            Button("Sort Ascending") { actions.sortDirection(true) }
            Button("Sort Descending") { actions.sortDirection(false) }
            Button("Group by \(field.name)") { actions.group() }
            Divider()
            Button("Hide \(field.name)") { actions.hide() }
        }
    }
}

/// The text editor in a cell: Return saves and goes down, Tab right (⇧-Tab left), ↑ and ↓ save and
/// move, Escape leaves the value as it was. Clicking elsewhere saves.
struct GridTextEditor: View {
    let text: String
    var alignment: TextAlignment = .leading
    let finish: (_ text: String?, _ move: Move) -> Void
    var pasteBlock: (String) -> Void = { _ in }
    var focusChanged: (Bool) -> Void = { _ in }
    @State private var draft = ""
    @State private var done = false
    /// The text cursor, placed after the text: a field selects all of its text when it gets focus,
    /// and the next key typed would then replace what was typed to start editing.
    @State private var caret: TextSelection?
    @FocusState private var focused: Bool

    enum Move { case none, down, up, right, left }

    var body: some View {
        TextField("", text: $draft, selection: $caret)
            .labelsHidden()
            .textFieldStyle(.plain)
            .multilineTextAlignment(alignment)
            .focused($focused)
            .onAppear {
                draft = text
                // Once it is on screen, so the focus sticks; then the cursor after the text.
                DispatchQueue.main.async {
                    focused = true
                    DispatchQueue.main.async { caret = TextSelection(insertionPoint: draft.endIndex) }
                }
            }
            .onSubmit { end(draft, .down) }
            .onKeyPress(.tab, phases: .down) { press in
                end(draft, press.modifiers.contains(.shift) ? .left : .right)
                return .handled
            }
            .onKeyPress(.upArrow) { end(draft, .up); return .handled }
            .onKeyPress(.downArrow) { end(draft, .down); return .handled }
            .onKeyPress(.escape) { end(nil, .none); return .handled }
            .onChange(of: draft) { old, new in
                // A block of cells pasted into the cell: pasted into the grid from here instead.
                if let block = CellPasting.block(old: old, new: new) {
                    done = true
                    pasteBlock(block)
                }
            }
            // Keys typed before it had the keyboard arrive as a longer text.
            .onChange(of: text) { _, new in if !focused { draft = new } }
            .onChange(of: focused) { was, now in
                focusChanged(now)
                if was && !now { end(draft, .none) }
            }
            .onDisappear { end(draft, .none) }
    }

    private func end(_ text: String?, _ move: Move) {
        guard !done else { return }
        done = true
        finish(text, move)
    }
}

/// The editor over a cell. Long text gets the keyboard at once, with the cursor after the text
/// and what was typed to open it; colours are swatches and a hex code (the system colour panel
/// would close the popover); the other types are the form's editor for the field. Values are read
/// from the document as it is now, so quick picks one after another add up.
private struct GridPopoverEditor: View {
    @ObservedObject var document: GolleDocument
    let table: DataTable
    let recordID: Record.ID
    let field: Field
    let resolver: Resolver
    let typed: String?
    let close: () -> Void
    @FocusState private var focused: Bool
    /// Plain long text being typed: saved when typing pauses and when the editor closes, not on
    /// every key (each save redraws the table).
    @State private var draft: String?
    /// What was saved last, to tell an undo (the value changes to something else) from our own save.
    @State private var saved: String?

    private var record: Record? { document.database.table(table.id)?.records.first { $0.id == recordID } }

    private var value: Binding<Value?> {
        Binding(get: { record?[field.id] }, set: { document.setValue($0, record: recordID, field: field.id, table: table.id) })
    }

    private var text: Binding<String> {
        Binding(get: { record?[field.id]?.text ?? "" }, set: { new in
            document.setValue(new.isEmpty ? nil : .text(new), record: recordID, field: field.id, table: table.id)
        })
    }

    private func savePlain() {
        guard let draft, draft != (record?[field.id]?.text ?? "") else { return }
        saved = draft
        text.wrappedValue = draft
    }

    var body: some View {
        editor
            // A popover is a window of its own, without the database's undo: ⌘Z and ⇧⌘Z reach it here.
            .background {
                SheetUndoButtons(document: document).frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            }
    }

    @ViewBuilder
    private var editor: some View {
        if let record {
            if field.type == .longText, field.options.richText {
                RichTextEditor(markdown: text, minHeight: 140, focusOnAppear: true, typed: typed, onEscape: close)
            } else if field.type == .longText {
                TextEditor(text: Binding(get: { draft ?? "" }, set: { draft = $0 }))
                    .font(.body)
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
                    .padding(2)
                    .background(.background.secondary, in: .rect(cornerRadius: 4))
                    .focused($focused)
                    .onKeyPress(.escape) { savePlain(); close(); return .handled }
                    .onAppear {
                        draft = (record[field.id]?.text ?? "") + (typed ?? "")
                        DispatchQueue.main.async { focused = true }
                    }
                    .task(id: draft) {
                        try? await Task.sleep(for: .milliseconds(600))
                        guard !Task.isCancelled else { return }
                        savePlain()
                    }
                    .onDisappear(perform: savePlain)
                    // Undone or changed elsewhere: the editor shows it.
                    .onChange(of: record[field.id]?.text) { _, new in
                        if new != saved, new != draft { draft = new ?? ""; saved = new }
                    }
            } else if field.type == .color {
                ColorSwatches(value: value)
            } else {
                FieldEditorRow(document: document, field: field, record: record, resolver: resolver, showsLabel: false, value: value)
            }
        }
    }
}

/// Colours to pick from, and a hex code for any other.
private struct ColorSwatches: View {
    @Binding var value: Value?
    @State private var hex = ""
    static let colors = ["#E5484D", "#F76B15", "#FFC53D", "#46A758", "#12A594", "#0090FF", "#3E63DD", "#8E4EC6",
                         "#D6409F", "#8D8D8D", "#202020", "#FFFFFF"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 8), count: 6), spacing: 8) {
                ForEach(Self.colors, id: \.self) { color in
                    Button { value = .text(color) } label: {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(cellHex: color) ?? .clear)
                            .frame(width: 28, height: 28)
                            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(value?.text == color ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: value?.text == color ? 2 : 1) }
                    }
                    .buttonStyle(.plain)
                    .help(color)
                }
            }
            HStack {
                TextField("Hex", text: $hex, prompt: Text("#RRGGBB"))
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .onSubmit { if let c = Value.text(hex).converted(to: .color) { value = c } else { NSSound.beep() } }
                Button("Clear") { value = nil }.disabled(value == nil)
            }
        }
        .onAppear { hex = value?.text ?? "" }
        .onChange(of: value) { _, new in hex = new?.text ?? "" }
    }
}

/// Makes the window it is in take the keyboard as soon as it shows (a popover opened from the
/// keyboard otherwise leaves the keys with the window under it).
private struct TakesKeyboard: NSViewRepresentable {
    final class View: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { window.makeKey() }
        }
    }
    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ view: View, context: Context) {}
}
