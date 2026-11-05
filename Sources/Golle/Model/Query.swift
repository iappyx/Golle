import Foundation

/// Search, filter and sort over a table's records. Kept apart from the views so the tests can reach it.
enum Query {
    /// The records a view shows: filtered, searched and sorted.
    static func visible(_ resolver: Resolver, view: SavedView, search: String, haystack: [Record.ID: String]? = nil) -> [Record] {
        var records = resolver.table.records
        if !view.filter.isEmpty { records = records.filter { view.filter.matches($0, resolver) } }
        if let haystack, !search.isEmpty {
            // Fast path: each record's text folded once (case and accents), then plain substring tests.
            let words = search.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }
            records = records.filter { record in
                guard let text = haystack[record.id] else { return false }
                return words.allSatisfy { text.contains($0) }
            }
        } else {
            records = self.search(records, resolver, for: search)
        }
        return sort(records, by: view.sort, resolver)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Every record's searchable text, folded, by record.
    static func haystack(_ resolver: Resolver) -> [Record.ID: String] {
        let fields = resolver.table.fields
        var result: [Record.ID: String] = [:]
        result.reserveCapacity(resolver.table.records.count)
        for record in resolver.table.records {
            let text = fields.map { field -> String in
                var text = resolver.text(record, field)
                if field.type == .longText, field.options.richText { text = Markdown.plain(text) }
                if field.type == .number || field.type == .formula, let n = resolver.value(record, field)?.number { text += " " + Value.plain(n) }
                return text
            }.joined(separator: "\n")
            result[record.id] = fold(text)
        }
        return result
    }

    /// Records with any field whose text contains every word of the search, ignoring case and accents.
    static func search(_ records: [Record], _ resolver: Resolver, for query: String) -> [Record] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return records }
        let fields = resolver.table.fields
        return records.filter { record in
            let haystack = fields.map { field -> String in
                let text = resolver.text(record, field)
                // Numbers are also found as typed, without thousands separators.
                if field.type == .number || field.type == .formula, let n = resolver.value(record, field)?.number {
                    return text + " " + Value.plain(n)
                }
                return text
            }.joined(separator: "\n")
            return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    static func sort(_ records: [Record], by keys: [SortKey], _ resolver: Resolver) -> [Record] {
        let keys = keys.compactMap { key in resolver.table.field(key.fieldID).map { (field: $0, ascending: key.ascending) } }
        guard !keys.isEmpty else { return records }
        // Resolve each sort value once, not once per comparison.
        let decorated = records.map { record in (record, keys.map { sortValue(record, $0.field, resolver) }) }
        return decorated.sorted { a, b in
            for (index, key) in keys.enumerated() {
                let x = a.1[index], y = b.1[index]
                var order = compare(x, y)
                // Empty cells stay at the bottom in both directions.
                if !key.ascending, x != nil, y != nil { order = order == .orderedAscending ? .orderedDescending : order == .orderedDescending ? .orderedAscending : .orderedSame }
                if order != .orderedSame { return order == .orderedAscending }
            }
            return false
        }.map(\.0)
    }

    private static func sortValue(_ record: Record, _ field: Field, _ resolver: Resolver) -> Value? {
        // Links (and lookups of them) by the titles they show.
        if field.type == .link || field.type == .lookup && resolver.lookupTarget(field)?.field.type == .link {
            let text = resolver.text(record, field)
            return text.isEmpty ? nil : .text(text)
        }
        return resolver.value(record, field)
    }

    /// Orders two values of the same field. Empty cells always sort last.
    static func compare(_ a: Value?, _ b: Value?) -> ComparisonResult {
        switch (a, b) {
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        case let (a?, b?):
            switch (a, b) {
            case let (.number(x), .number(y)): return x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame
            case let (.date(x), .date(y)): return x.compare(y)
            case let (.rating(x), .rating(y)): return x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame
            case let (.bool(x), .bool(y)): return x == y ? .orderedSame : (x ? .orderedAscending : .orderedDescending)
            default: return a.plainText.localizedStandardCompare(b.plainText)
            }
        }
    }
}

/// The sort state of the record table's column headers. Golle sorts the rows itself (formulas and
/// links need the whole database), so this only carries which field and which direction.
struct FieldComparator: SortComparator, Hashable {
    var fieldID: Field.ID
    var order: SortOrder = .forward

    func compare(_ lhs: Record, _ rhs: Record) -> ComparisonResult {
        let result = Query.compare(lhs[fieldID], rhs[fieldID])
        return order == .forward ? result : result == .orderedAscending ? .orderedDescending : result == .orderedDescending ? .orderedAscending : .orderedSame
    }

    init(fieldID: Field.ID, order: SortOrder = .forward) {
        self.fieldID = fieldID
        self.order = order
    }

    init(_ key: SortKey) { self.init(fieldID: key.fieldID, order: key.ascending ? .forward : .reverse) }
    var key: SortKey { SortKey(fieldID: fieldID, ascending: order == .forward) }
}
