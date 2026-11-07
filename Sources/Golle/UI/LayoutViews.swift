import SwiftUI

/// Form mode: one record at a time on a custom layout, with previous/next.
struct LayoutBrowser: View {
    @ObservedObject var document: GolleDocument
    let table: DataTable
    let view: SavedView
    let rows: [Record]
    let resolver: Resolver
    let editLayout: (FormLayout.ID) -> Void

    private var layout: FormLayout {
        table.layouts.first { $0.id == view.layoutID } ?? table.layouts.first ?? FormLayout.automatic(for: table, named: "Automatic")
    }

    /// The first selected record in the order shown (a selection is a set, without an order).
    private var current: Record? {
        let selected = document.selectedRecordIDs
        if !selected.isEmpty, let record = rows.first(where: { selected.contains($0.id) }) { return record }
        // An edit put the record outside the view's filter: it stays shown (jumping to another one
        // while typing would lose the typing).
        if let id = selected.first, selected.count == 1, let record = table.records.first(where: { $0.id == id }) { return record }
        return rows.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Menu {
                    ForEach(table.layouts) { item in
                        Button(item.name) { document.updateCurrentView("Choose Layout") { $0.layoutID = item.id } }
                    }
                    if table.layouts.isEmpty { Text("Automatic") }
                    Divider()
                    Button("New Layout") {
                        if let id = document.addLayout(to: table.id) {
                            document.updateCurrentView("Choose Layout") { $0.layoutID = id }
                            editLayout(id)
                        }
                    }
                } label: {
                    Label(layout.name, systemImage: "rectangle.and.pencil.and.ellipsis")
                }
                .frame(maxWidth: 200)
                Button("Edit Layout…") {
                    if table.layouts.contains(where: { $0.id == layout.id }) {
                        editLayout(layout.id)
                    } else if let id = document.addLayout(to: table.id) {
                        document.updateCurrentView("Choose Layout") { $0.layoutID = id }
                        editLayout(id)
                    }
                }
                Spacer()
                if let current, let index = rows.firstIndex(where: { $0.id == current.id }) {
                    Text("\(index + 1) of \(rows.count)").monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                    ControlGroup {
                        Button { select(index - 1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0)
                            .help("Previous record (⌘↑)")
                        Button { select(index + 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index + 1 >= rows.count)
                            .help("Next record (⌘↓)")
                    }
                    .fixedSize()
                    .background {
                        // ⌘↑ and ⌘↓ go to the start and end of text while typing; only otherwise do
                        // they step through the records.
                        RecordStepKeys { up in select(up ? index - 1 : index + 1) }
                    }
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
            Divider()
            if let current {
                ScrollView([.horizontal, .vertical]) {
                    LayoutCanvas(layout: layout) { item in
                        LiveItem(document: document, table: table, record: current, resolver: resolver, item: item)
                    }
                    // Fresh editors for each record, so typing, addresses and drafts never carry over.
                    .id(current.id)
                    .padding(24)
                }
                .background(Color(nsColor: .underPageBackgroundColor))
            } else {
                ContentUnavailableView {
                    Label(table.records.isEmpty ? "No Records" : "No Matching Records", systemImage: "tray")
                } actions: {
                    Button("New Record") { document.addRecord(to: table.id) }
                }
            }
        }
        // The record shown is the selected one; when the selection is hidden (by the filter), the
        // record shown becomes the selection, so the inspector shows the same one.
        .onAppear(perform: syncSelection)
        .onChange(of: document.selectedRecordIDs) { _, _ in syncSelection() }
        .onChange(of: current?.id) { _, _ in syncSelection() }
    }

    /// Form mode shows one record: the selection is that record, and only that one (a selection
    /// of several from table mode would leave the inspector, Delete and Duplicate acting on others).
    private func syncSelection() {
        if let current, document.selectedRecordIDs != [current.id] { document.selectedRecordIDs = [current.id] }
    }

    private func select(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        document.selectedRecordIDs = [rows[index].id]
    }
}

/// A page with items placed by their frames.
struct LayoutCanvas<Item: View>: View {
    let layout: FormLayout
    /// Drawn above the others (the item being edited).
    var raised: LayoutItem.ID? = nil
    @ViewBuilder let content: (LayoutItem) -> Item

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color(nsColor: .textBackgroundColor))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
            ForEach(layout.items) { item in
                content(item)
                    .frame(width: item.width, height: item.height, alignment: .topLeading)
                    .offset(x: item.x, y: item.y)
                    .zIndex(item.id == raised ? 1 : 0)
            }
        }
        .frame(width: layout.width, height: layout.height, alignment: .topLeading)
    }
}

/// One item of a layout, editable.
private struct LiveItem: View {
    @ObservedObject var document: GolleDocument
    let table: DataTable
    let record: Record
    let resolver: Resolver
    let item: LayoutItem

    var body: some View {
        switch item.kind {
        case .title:
            Text(table.title(of: record))
                .font(.system(size: item.fontSize, weight: item.bold ? .bold : .regular))
                .lineLimit(2)
        case .label(let text):
            Text(text)
                .font(.system(size: item.fontSize, weight: item.bold ? .bold : .regular))
        case .divider:
            Divider().frame(maxHeight: .infinity)
        case .field(let id):
            if let field = table.field(id) {
                VStack(alignment: .leading, spacing: 3) {
                    if item.showsLabel && field.type != .checkbox {
                        Text(field.name).font(.caption).foregroundStyle(.secondary)
                    }
                    FieldInput(document: document, table: table, record: record, field: field, resolver: resolver, showsLabel: false)
                        .font(.system(size: item.fontSize, weight: item.bold ? .semibold : .regular))
                        .textFieldStyle(.roundedBorder)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// A static rendering of an item, for printing.
struct PrintedItem: View {
    let document: GolleDocument
    let table: DataTable
    let record: Record
    let resolver: Resolver
    let item: LayoutItem

    var body: some View {
        switch item.kind {
        case .title:
            Text(table.title(of: record)).font(.system(size: item.fontSize, weight: item.bold ? .bold : .regular)).lineLimit(2)
        case .label(let text):
            Text(text).font(.system(size: item.fontSize, weight: item.bold ? .bold : .regular))
        case .divider:
            Rectangle().fill(.gray.opacity(0.5)).frame(height: 1).frame(maxHeight: .infinity)
        case .field(let id):
            if let field = table.field(id) {
                VStack(alignment: .leading, spacing: 2) {
                    if item.showsLabel { Text(field.name).font(.system(size: 9)).foregroundStyle(.gray) }
                    value(field)
                        .font(.system(size: item.fontSize, weight: item.bold ? .semibold : .regular))
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private func value(_ field: Field) -> some View {
        switch field.type {
        case .image:
            HStack(spacing: 4) {
                ForEach(record[field.id]?.attachments ?? []) { attachment in
                    if let image = document.image(attachment) {
                        Image(nsImage: image).resizable().scaledToFit()
                    }
                }
            }
        case .checkbox:
            Label(field.name, systemImage: record[field.id]?.bool == true ? "checkmark.square" : "square")
        case .rating:
            Text(String(repeating: "★", count: record[field.id]?.rating ?? 0) + String(repeating: "☆", count: Value.maxRating - (record[field.id]?.rating ?? 0)))
        case .longText where field.options.richText:
            if let formatted = try? AttributedString(markdown: record[field.id]?.text ?? "", options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(formatted)
            } else {
                Text(resolver.readable(record, field))
            }
        default:
            Text(resolver.readable(record, field))
        }
    }
}

// MARK: Editor

/// Designs a layout: drag items around, resize them by their corner, and set how each looks.
struct LayoutEditor: View {
    @ObservedObject var document: GolleDocument
    let tableID: DataTable.ID
    let layoutID: FormLayout.ID
    /// The sheet's size: as large as fits the document window.
    var size = CGSize(width: 1120, height: 720)
    @Environment(\.dismiss) private var dismiss

    @State private var selection: LayoutItem.ID?
    /// The item being dragged and where it was: a drag that was cancelled (and never ended) is not
    /// taken for the start of the next one.
    @State private var dragStart: (item: LayoutItem.ID, frame: CGRect, at: CGPoint)?
    @State private var gestureKey = UUID()

    private var table: DataTable? { document.database.table(tableID) }
    private var layout: FormLayout? { table?.layouts.first { $0.id == layoutID } }

    var body: some View {
        if let table, let layout {
            VStack(spacing: 0) {
                // Plain columns: HSplitView doesn't fill a sheet and collapses to a strip.
                HStack(spacing: 0) {
                    palette(table, layout)
                        .frame(width: 210)
                    Divider()
                    ScrollView([.horizontal, .vertical]) {
                        canvas(table, layout).padding(24)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
                    Divider()
                    inspector(table, layout)
                        .frame(width: 250)
                        .frame(maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)
                Divider()
                HStack {
                    SheetUndoButtons(document: document)
                    Button("Delete Layout", role: .destructive) {
                        document.deleteLayout(layoutID, from: tableID)
                        dismiss()
                    }
                    Spacer()
                    Text("Drag to move · drop onto other items to reorder · drag the corner to resize")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
            .frame(width: size.width, height: size.height)
        } else {
            VStack {
                ContentUnavailableView("Layout Not Found", systemImage: "rectangle.dashed")
                Button("Close") { dismiss() }
            }
            .frame(width: 400, height: 300)
        }
    }

    private func update(_ layout: FormLayout, _ action: String = "Change Layout", coalesce: String? = nil) {
        document.updateLayout(layout, in: tableID, actionName: action, coalesce: coalesce)
    }

    // MARK: Palette

    private func palette(_ table: DataTable, _ layout: FormLayout) -> some View {
        List {
            Section("Fields") {
                ForEach(table.fields) { field in
                    let placed = layout.items.contains { $0.kind == .field(field.id) }
                    Button { add(.field(field.id), height: field.type == .longText || field.type == .image ? 112 : 48, to: layout) } label: {
                        Label(field.name, systemImage: field.type.symbol)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(placed ? .secondary : .primary)
                    .help(placed ? "Already on the layout; click to add again" : "Add to the layout")
                }
            }
            Section("Decoration") {
                Button { add(.title, height: 40, to: layout, fontSize: 24, bold: true, label: false) } label: { Label("Record Title", systemImage: "textformat.size") }
                    .buttonStyle(.plain)
                Button { add(.label("Heading"), height: 32, to: layout, fontSize: 17, bold: true, label: false) } label: { Label("Text", systemImage: "character.textbox") }
                    .buttonStyle(.plain)
                Button { add(.divider, height: 16, to: layout, label: false) } label: { Label("Line", systemImage: "minus") }
                    .buttonStyle(.plain)
            }
            Section("Page") {
                TextField("Name", text: Binding(get: { layout.name }, set: { name in
                    var l = layout
                    l.name = name
                    update(l, "Rename Layout", coalesce: "layout-name-\(layout.id)")
                }))
                Stepper("Width \(String(Int(layout.width)))", value: Binding(get: { layout.width }, set: { w in
                    var l = layout
                    l.width = w
                    update(l, "Resize Page", coalesce: "layout-size-\(layout.id)")
                }), in: 320...1600, step: 40)
                Stepper("Height \(String(Int(layout.height)))", value: Binding(get: { layout.height }, set: { h in
                    var l = layout
                    l.height = h
                    update(l, "Resize Page", coalesce: "layout-size-\(layout.id)")
                }), in: 240...3200, step: 40)
                Button("Reset to Automatic") {
                    var fresh = FormLayout.automatic(for: table, named: layout.name)
                    fresh.id = layout.id
                    update(fresh, "Reset Layout")
                }
            }
        }
    }

    private func add(_ kind: LayoutItem.Kind, height: Double, to layout: FormLayout, fontSize: Double = 13, bold: Bool = false, label: Bool = true) {
        var l = layout
        let bottom = l.items.map { $0.y + $0.height }.max() ?? 0
        var item = LayoutItem(kind: kind, x: 24, y: bottom + 12, width: min(592, l.width - 48), height: height,
                              showsLabel: label, fontSize: fontSize, bold: bold)
        if item.y + item.height > l.height { l.height = item.y + item.height + 24 }
        item.snap(within: CGSize(width: l.width, height: l.height))
        l.items.append(item)
        update(l, "Add to Layout")
        selection = item.id
    }

    // MARK: Canvas

    private func canvas(_ table: DataTable, _ layout: FormLayout) -> some View {
        LayoutCanvas(layout: layout, raised: selection) { item in
            let selected = selection == item.id
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(selected ? 0.12 : 0.05))
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: selected ? [] : [4, 3]))
                placeholder(item, table)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if selected {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2)
                        .padding(3)
                        .background(Color.accentColor, in: .rect(cornerRadius: 3))
                        .foregroundStyle(.white)
                        .gesture(drag(item, layout, resize: true))
                }
            }
            .contentShape(.rect)
            .onTapGesture { selection = item.id }
            .gesture(drag(item, layout, resize: false))
        }
        .coordinateSpace(.named(Self.page))
        .onTapGesture { selection = nil }
    }

    private static let page = "layout-page"

    @ViewBuilder
    private func placeholder(_ item: LayoutItem, _ table: DataTable) -> some View {
        let font = Font.system(size: item.fontSize, weight: item.bold ? .bold : .regular)
        switch item.kind {
        case .title: Text("Record Title").font(font)
        case .label(let text): Text(text).font(font)
        case .divider: Divider().frame(maxHeight: .infinity)
        case .field(let id):
            VStack(alignment: .leading, spacing: 2) {
                if item.showsLabel { Text(table.field(id)?.name ?? "Deleted field").font(.caption).foregroundStyle(.secondary) }
                Label(table.field(id)?.type.label ?? "", systemImage: table.field(id)?.type.symbol ?? "questionmark")
                    .font(font).foregroundStyle(.tertiary)
            }
        }
    }

    private func drag(_ item: LayoutItem, _ layout: FormLayout, resize: Bool) -> some Gesture {
        // Measured on the page, not on the item: the item moves during the drag, and measuring in its
        // own coordinates would feed every step back into the next.
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.page))
            .onChanged { value in
                if dragStart?.item != item.id || dragStart?.at != value.startLocation {
                    dragStart = (item.id, item.frame, value.startLocation)
                    gestureKey = UUID()
                    selection = item.id
                }
                guard let start = dragStart?.frame, var l = self.layout, let index = l.items.firstIndex(where: { $0.id == item.id }) else { return }
                var moved = l.items[index]
                if resize {
                    moved.width = start.width + value.translation.width
                    moved.height = start.height + value.translation.height
                } else {
                    moved.x = start.minX + value.translation.width
                    moved.y = start.minY + value.translation.height
                }
                moved.snap(within: CGSize(width: l.width, height: l.height), resizing: resize)
                l.items[index] = moved
                update(l, resize ? "Resize" : "Move", coalesce: "drag-\(gestureKey)")
            }
            .onEnded { _ in
                if !resize, let start = dragStart?.frame, var l = self.layout {
                    l.settle(item.id, from: start)
                    update(l, "Move", coalesce: "drag-\(gestureKey)")
                }
                dragStart = nil
            }
    }

    // MARK: Inspector

    @ViewBuilder
    private func inspector(_ table: DataTable, _ layout: FormLayout) -> some View {
        if let id = selection, let index = layout.items.firstIndex(where: { $0.id == id }) {
            let item = layout.items[index]
            Form {
                Section(itemTitle(item, table)) {
                    if case .label(let text) = item.kind {
                        TextField("Text", text: Binding(get: { text }, set: { t in
                            var l = layout
                            l.items[index].kind = .label(t)
                            update(l, "Edit Text", coalesce: "item-text-\(id)")
                        }))
                    }
                    if case .field = item.kind {
                        Toggle("Show Label", isOn: Binding(get: { item.showsLabel }, set: { on in
                            var l = layout
                            l.items[index].showsLabel = on
                            update(l)
                        }))
                    }
                    if item.kind != .divider {
                        Stepper("Text Size \(String(Int(item.fontSize)))", value: Binding(get: { item.fontSize }, set: { size in
                            var l = layout
                            l.items[index].fontSize = size
                            update(l, "Text Size", coalesce: "item-size-\(id)")
                        }), in: 9...48)
                        Toggle("Bold", isOn: Binding(get: { item.bold }, set: { on in
                            var l = layout
                            l.items[index].bold = on
                            update(l)
                        }))
                    }
                }
                Section("Position") {
                    LabeledContent("X, Y") { Text(verbatim: "\(Int(item.x)), \(Int(item.y))").monospacedDigit() }
                    LabeledContent("Size") { Text(verbatim: "\(Int(item.width)) × \(Int(item.height))").monospacedDigit() }
                    Button("Full Width") {
                        var l = layout
                        l.items[index].x = 24
                        l.items[index].width = l.width - 48
                        update(l)
                    }
                }
                Section {
                    Button("Remove from Layout", role: .destructive) {
                        var l = layout
                        l.items.remove(at: index)
                        update(l, "Remove from Layout")
                        selection = nil
                    }
                    // No Delete-key shortcut: it would fire while typing in the text fields here.
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("Nothing Selected", systemImage: "cursorarrow.click",
                                   description: Text("Click an item on the page to change it, or add fields from the list."))
        }
    }

    private func itemTitle(_ item: LayoutItem, _ table: DataTable) -> String {
        switch item.kind {
        case .field(let id): table.field(id)?.name ?? "Field"
        case .label: "Text"
        case .title: "Record Title"
        case .divider: "Line"
        }
    }
}

/// ⌘↑ and ⌘↓ for the window this sits in, unless a text field or text view is being edited.
/// (A button shortcut would take the keys before the text could.)
struct RecordStepKeys: NSViewRepresentable {
    let step: (_ up: Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator = context.coordinator] event in
            guard let coordinator, let view = coordinator.view, let window = view.window, event.window === window,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function]) == .command,
                  event.keyCode == 126 || event.keyCode == 125,
                  !(window.firstResponder is NSText) else { return event }
            coordinator.step(event.keyCode == 126)
            return nil
        }
        context.coordinator.step = step
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { context.coordinator.step = step }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.monitor.map(NSEvent.removeMonitor)
        coordinator.monitor = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var view: NSView?
        var monitor: Any?
        var step: (Bool) -> Void = { _ in }
    }
}
