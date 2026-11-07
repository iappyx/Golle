import Foundation

/// A cell of the table: a record and a field.
struct GridPoint: Hashable {
    var record: Record.ID
    var field: Field.ID
}

/// The cells selected in the table: a block from the anchor (where the selection started) to the
/// cursor (where it is now), or whole rows chosen from the row numbers. Kept by record and field,
/// not by position, so a selection stays with its records when they are sorted or filtered.
struct GridSelection: Equatable {
    var anchor: GridPoint
    var cursor: GridPoint
    /// Chosen from the row numbers: every column of the rows.
    var wholeRows = false
    /// Rows added one by one with ⌘ on the row numbers, beside the block.
    var extraRows: Set<Record.ID> = []

    init(_ point: GridPoint, wholeRows: Bool = false) {
        anchor = point
        cursor = point
        self.wholeRows = wholeRows
    }

    /// The rows and columns between anchor and cursor, as positions in `order` and `columns`.
    /// nil when the cursor's record or field is gone.
    func ranges(order: [Record.ID], columns: [Field.ID]) -> (rows: ClosedRange<Int>, columns: ClosedRange<Int>)? {
        guard let r1 = order.firstIndex(of: cursor.record) else { return nil }
        let r0 = order.firstIndex(of: anchor.record) ?? r1
        let c1 = columns.firstIndex(of: cursor.field) ?? 0
        let c0 = columns.firstIndex(of: anchor.field) ?? c1
        guard !columns.isEmpty else { return nil }
        let cols = wholeRows ? 0...(columns.count - 1) : min(c0, c1)...max(c0, c1)
        return (min(r0, r1)...max(r0, r1), cols)
    }

    /// The selected records, in order, and the selected fields, in order.
    func block(order: [Record.ID], columns: [Field.ID]) -> (records: [Record.ID], fields: [Field.ID]) {
        guard let (rows, cols) = ranges(order: order, columns: columns) else { return ([], []) }
        let inBlock = Set(order[rows])
        let records = order.filter { inBlock.contains($0) || extraRows.contains($0) }
        return (records, Array(columns[cols]))
    }

    /// Whether a cell is in the selection.
    func contains(_ point: GridPoint, order: [Record.ID], columns: [Field.ID]) -> Bool {
        if wholeRows && extraRows.contains(point.record) { return true }
        guard let (rows, cols) = ranges(order: order, columns: columns),
              let r = order.firstIndex(of: point.record), let c = columns.firstIndex(of: point.field) else { return false }
        return rows.contains(r) && cols.contains(c)
    }

    /// More than one cell.
    func isBlock(order: [Record.ID], columns: [Field.ID]) -> Bool {
        guard let (rows, cols) = ranges(order: order, columns: columns) else { return false }
        return rows.count > 1 || cols.count > 1 || !extraRows.isEmpty
    }

    /// The cursor moved by rows and columns, kept inside the table. With `extend` the anchor
    /// stays (⇧ and an arrow); without, the selection is the one cell moved to.
    func moved(rows dr: Int, columns dc: Int, extend: Bool, order: [Record.ID], columns: [Field.ID]) -> GridSelection {
        guard !order.isEmpty, !columns.isEmpty else { return self }
        let r = order.firstIndex(of: cursor.record) ?? 0
        let c = columns.firstIndex(of: cursor.field) ?? 0
        let point = GridPoint(record: order[min(max(r + dr, 0), order.count - 1)], field: columns[min(max(c + dc, 0), columns.count - 1)])
        if extend {
            var next = self
            next.cursor = point
            next.extraRows = []
            return next
        }
        return GridSelection(point)
    }

    /// The selection extended to a cell (⇧-click, dragging).
    func extended(to point: GridPoint) -> GridSelection {
        var next = self
        next.cursor = point
        return next
    }

    /// Every cell of the table.
    static func all(order: [Record.ID], columns: [Field.ID]) -> GridSelection? {
        guard let first = order.first, let last = order.last, let left = columns.first, let right = columns.last else { return nil }
        var all = GridSelection(GridPoint(record: first, field: left))
        all.cursor = GridPoint(record: last, field: right)
        return all
    }
}

/// How the table's columns are laid out: their order and widths, saved per view.
enum GridColumns {
    static let defaultWidths: [FieldType: Double] = [
        .checkbox: 64, .rating: 110, .number: 110, .autoNumber: 90, .duration: 100, .color: 110,
        .date: 110, .progress: 140, .createdAt: 150, .modifiedAt: 150, .longText: 260, .image: 70,
    ]
    static let minWidth: Double = 44

    static func width(_ field: Field, in view: SavedView) -> Double {
        if let saved = view.columnWidths[field.id.uuidString] { return max(saved, minWidth) }
        if field.type == .date, field.options.includesTime { return 160 }
        return defaultWidths[field.type] ?? 170
    }

    /// A column moved before another one (or to the end), as a new saved order.
    static func moving(_ field: Field.ID, before target: Field.ID?, in columns: [Field.ID]) -> [Field.ID] {
        var order = columns.filter { $0 != field }
        if let target, let i = order.firstIndex(of: target) { order.insert(field, at: i) } else { order.append(field) }
        return order
    }

    /// The sort after clicking a column's header: by it, ascending; clicked again, descending. With
    /// ⇧ it is added after the sorts already there (or turned around there).
    static func sorting(_ sort: [SortKey], by field: Field.ID, adding: Bool) -> [SortKey] {
        if let i = sort.firstIndex(where: { $0.fieldID == field }) {
            var next = adding ? sort : [sort[i]]
            let j = adding ? i : 0
            next[j].ascending.toggle()
            return next
        }
        return adding ? sort + [SortKey(fieldID: field)] : [SortKey(fieldID: field)]
    }
}
