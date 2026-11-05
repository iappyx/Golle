import Foundation

/// A custom form: fields and text labels placed freely on a page. Each table can have several.
struct FormLayout: Codable, Equatable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var width: Double = 640
    var height: Double = 720
    var items: [LayoutItem] = []

    init(id: UUID = UUID(), name: String, width: Double = 640, height: Double = 720, items: [LayoutItem] = []) {
        (self.id, self.name, self.width, self.height, self.items) = (id, name, width, height, items)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Form"
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 640
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? 720
        items = (try? c.decodeIfPresent(Lossy<LayoutItem>.self, forKey: .items))?.items ?? []
    }

    static let grid: Double = 8

    /// A starting point: every field stacked in one column, with room for long text and images.
    /// Ids are derived from the table and fields, so the automatic layout of a table is the same on
    /// every redraw: new ids would make SwiftUI rebuild every field and drop the keyboard focus.
    static func automatic(for table: DataTable, named name: String = "Form") -> FormLayout {
        var layout = FormLayout(id: table.id, name: name)
        var y = 24.0
        if table.titleField != nil {
            var title = LayoutItem(kind: .title, x: 24, y: y, width: 592, height: 40, showsLabel: false, fontSize: 24, bold: true)
            title.id = Self.derived(table.id, salt: 1)
            layout.items.append(title)
            y += 56
        }
        for field in table.fields {
            let height: Double = switch field.type {
            case .longText: 112
            case .image: 200
            case .link, .file: 72
            default: 48
            }
            var item = LayoutItem(kind: .field(field.id), x: 24, y: y, width: 592, height: height)
            item.id = field.id
            layout.items.append(item)
            y += height + 12
        }
        layout.height = max(480, y + 24)
        return layout
    }

    static let gap: Double = 12

    /// A stable id made from another one.
    static func derived(_ id: UUID, salt: UInt8) -> UUID {
        var bytes = id.uuid
        bytes.15 ^= salt
        return UUID(uuid: bytes)
    }

    /// After a drag: when the item was dropped onto others, its column is stacked again in the new
    /// order (by vertical middle), so dragging reorders. Dropped on free space, it stays where it is.
    /// `original` is where the item was before the drag.
    mutating func settle(_ id: LayoutItem.ID, from original: CGRect) {
        guard let moved = items.first(where: { $0.id == id }) else { return }
        let others = items.filter { $0.id != id }
        guard others.contains(where: { $0.frame.insetBy(dx: 1, dy: 1).intersects(moved.frame) }) else { return }
        // The column: items that share most of their width with the dropped item.
        func sharesColumn(_ item: LayoutItem) -> Bool {
            let overlap = min(item.frame.maxX, moved.frame.maxX) - max(item.frame.minX, moved.frame.minX)
            return overlap > 0.5 * min(item.width, moved.width)
        }
        func sideBySide(_ a: LayoutItem, _ b: LayoutItem) -> Bool {
            a.y < b.y + b.height && b.y < a.y + a.height && (a.x + a.width <= b.x || b.x + b.width <= a.x)
        }
        let candidates = others.filter(sharesColumn)
        // A wide item over side-by-side items moves whole rows, so the columns stay as they are.
        if candidates.contains(where: { a in candidates.contains { b in sideBySide(a, b) } }) {
            settleRows(moved, original: original)
            return
        }
        let column = items.filter { $0.id == id || sharesColumn($0) }
        let top = min(original.minY, column.filter { $0.id != id }.map(\.y).min() ?? original.minY)
        let ordered = column.sorted { a, b in
            // The dropped item counts by where it is now; the rest by where they are.
            a.frame.midY == b.frame.midY ? a.id == id : a.frame.midY < b.frame.midY
        }
        let xs = Set(column.filter { $0.id != id }.map(\.x))
        let columnX = xs.count == 1 ? xs.first : nil
        var y = top
        for item in ordered {
            guard let index = items.firstIndex(where: { $0.id == item.id }) else { continue }
            items[index].y = y
            // Line the dropped item up with its column when the column is aligned.
            if item.id == id, let x = columnX { items[index].x = x }
            y += item.height + Self.gap
        }
        height = max(height, y + 12)
    }

    /// Rows are items that overlap vertically. The dropped item becomes a row of its own where it
    /// was dropped, and the rows are stacked again keeping each row's own arrangement.
    private mutating func settleRows(_ moved: LayoutItem, original: CGRect) {
        var rows: [[LayoutItem]] = []
        for item in items.filter({ $0.id != moved.id }).sorted(by: { $0.y < $1.y }) {
            if let r = rows.indices.last, rows[r].contains(where: { item.y < $0.y + $0.height && $0.y < item.y + item.height }) {
                rows[r].append(item)
            } else {
                rows.append([item])
            }
        }
        let insertAt = rows.filter { row in (row.map(\.frame.midY).min() ?? 0) < moved.frame.midY }.count
        rows.insert([moved], at: insertAt)
        var y = min(original.minY, rows.compactMap { $0.map(\.y).min() }.min() ?? original.minY)
        for row in rows {
            let rowTop = row.map(\.y).min() ?? y
            let rowBottom = row.map { $0.y + $0.height }.max() ?? y
            for item in row {
                guard let index = items.firstIndex(where: { $0.id == item.id }) else { continue }
                items[index].y = y + (item.y - rowTop)
            }
            y += rowBottom - rowTop + Self.gap
        }
        height = max(height, y + 12)
    }
}

struct LayoutItem: Codable, Equatable, Hashable, Identifiable {
    enum Kind: Codable, Equatable, Hashable {
        /// An editable field.
        case field(UUID)
        /// Fixed text, such as a heading.
        case label(String)
        /// The record's title, large.
        case title
        /// A horizontal rule.
        case divider
    }

    var id = UUID()
    var kind: Kind
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var showsLabel = true
    var fontSize: Double = 13
    var bold = false

    var frame: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set { (x, y, width, height) = (newValue.minX, newValue.minY, newValue.width, newValue.height) }
    }

    /// Snaps the frame to the layout grid and keeps it on the page. When `resizing`, the item's
    /// corner stops at the page edge instead of the item moving.
    mutating func snap(within page: CGSize, resizing: Bool = false) {
        func round(_ v: Double) -> Double { (v / FormLayout.grid).rounded() * FormLayout.grid }
        if resizing {
            x = min(max(round(x), 0), page.width - 32)
            y = min(max(round(y), 0), page.height - 16)
            width = min(max(round(width), 32), page.width - x)
            height = min(max(round(height), 16), page.height - y)
            return
        }
        width = min(max(round(width), 32), page.width)
        height = min(max(round(height), 16), page.height)
        x = min(max(round(x), 0), page.width - width)
        y = min(max(round(y), 0), page.height - height)
    }
}
