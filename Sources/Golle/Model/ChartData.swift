import Foundation

/// The numbers behind a chart: one point per category (or per date step for a line).
struct ChartPoint: Identifiable, Equatable {
    var id: String { label }
    /// Unique within a chart: charts tell their categories apart by it.
    var label: String
    var value: Double
    /// For line charts: the start of the date step.
    var date: Date?
    /// The categorical colour slot (0–7), fixed by the category, never by its rank; nil folds into
    /// "Other" (shown gray).
    var slot: Int?
    var count: Int
}

enum ChartData {
    /// At most this many categories get their own colour; the rest fold into "Other".
    static let maxSlots = 8

    static func points(_ records: [Record], settings: ChartSettings, _ resolver: Resolver) -> [ChartPoint] {
        let table = resolver.table
        guard let category = settings.categoryField(table) else { return [] }

        func measure(_ group: [Record]) -> Double { Self.measure(group, settings: settings, resolver) }

        // Over time: one point per day, week, month or year, in order, including empty steps.
        if category.type.isDate {
            let calendar = Calendar.current
            var buckets: [Date: [Record]] = [:]
            for record in records {
                guard let date = resolver.value(record, category)?.date,
                      let start = calendar.dateInterval(of: settings.dateUnit.component, for: date)?.start else { continue }
                buckets[start, default: []].append(record)
            }
            guard let first = buckets.keys.min(), let last = buckets.keys.max() else { return [] }
            var points: [ChartPoint] = []
            var step = first
            // Long spans with a short unit would make thousands of points; cap at 400.
            while step <= last, points.count < 400 {
                let group = buckets[step] ?? []
                points.append(ChartPoint(label: label(step, settings.dateUnit), value: measure(group), date: step, slot: 0, count: group.count))
                // From the start of the next step: where a day starts at 01:00 (daylight saving at
                // midnight), adding a day would stay at 01:00 and miss every following bucket.
                guard let next = calendar.date(byAdding: settings.dateUnit.component, value: 1, to: step),
                      let start = calendar.dateInterval(of: settings.dateUnit.component, for: next)?.start, start > step else { break }
                step = start
            }
            return points
        }

        // Categories: a multiple-choice record counts once under each of its options.
        var groups: [String: [Record]] = [:]
        var order: [String] = []
        for record in records {
            let keys: [String]
            if category.type == .multiChoice {
                keys = record[category.id]?.choices ?? []
            } else {
                keys = [Grouping.key(record, category, resolver).0]
            }
            for key in (keys.isEmpty ? [""] : keys) {
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(record)
            }
        }
        // Stable order: a choice field's own option order, else by value (never by size).
        let options = category.options.choices
        let sorted: [String]
        if category.type.usesChoices {
            sorted = options.filter { groups[$0] != nil } + order.filter { !options.contains($0) && !$0.isEmpty }.sorted() + (groups[""] != nil ? [""] : [])
        } else {
            sorted = order.sorted { a, b in
                if a.isEmpty != b.isEmpty { return !a.isEmpty }
                if let x = Double(a), let y = Double(b) { return x < y }
                return a.localizedStandardCompare(b) == .orderedAscending
            }
        }
        // Records without a value; named so it can't be mistaken for an option of that name.
        let emptyLabel = groups["No \(category.name)"] == nil ? "No \(category.name)" : "(No \(category.name))"
        var points = sorted.enumerated().map { index, key in
            ChartPoint(label: key.isEmpty ? emptyLabel : key, value: measure(groups[key] ?? []), slot: nil, count: groups[key]?.count ?? 0)
        }
        // Colour slots follow the category's place in the stable order; past eight, "Other".
        if points.count > maxSlots {
            let kept = Array(points.prefix(maxSlots - 1))
            // Each record once, even when a multiple choice puts it in several of the folded categories.
            var seen = Set<Record.ID>()
            let restRecords = sorted.dropFirst(maxSlots - 1).flatMap { groups[$0] ?? [] }.filter { seen.insert($0.id).inserted }
            // Named so it can't be mistaken for an option that is called "Other" itself.
            let otherLabel = kept.contains { $0.label == "Other" } ? "Other Categories" : "Other"
            // Each record once: a multiple choice in two folded categories isn't counted twice.
            let other = ChartPoint(label: otherLabel, value: measure(restRecords), slot: nil, count: restRecords.count)
            points = kept + [other]
            for i in kept.indices { points[i].slot = i }
        } else {
            for i in points.indices { points[i].slot = i }
        }
        return points
    }

    /// The count, sum or average of a group of records. Averages count only records with a number.
    static func measure(_ group: [Record], settings: ChartSettings, _ resolver: Resolver) -> Double {
        guard let field = settings.valueField(resolver.table), settings.measure != .count else { return Double(group.count) }
        let numbers = group.compactMap { record -> Double? in
            switch resolver.value(record, field) {
            case .number(let n)?: n
            case .rating(let r)?: Double(r)
            default: nil
            }
        }
        if settings.measure == .sum { return numbers.reduce(0, +) }
        return numbers.isEmpty ? 0 : numbers.reduce(0, +) / Double(numbers.count)
    }

    static func label(_ date: Date, _ unit: ChartSettings.DateUnit) -> String {
        switch unit {
        case .day: date.formatted(.dateTime.day().month(.abbreviated).year())
        // With the year: weeks of different years must never share a label.
        case .week: "Week of " + date.formatted(.dateTime.day().month(.abbreviated).year())
        case .month: date.formatted(.dateTime.month(.abbreviated).year())
        case .year: date.formatted(.dateTime.year())
        }
    }

    /// A number tile: count, or a summary of a field.
    static func number(_ records: [Record], tile: DashboardTile, _ resolver: Resolver) -> String {
        guard let kind = tile.summary, let field = tile.fieldID.flatMap(resolver.table.field) else {
            return Value.numberFormatter.string(from: records.count as NSNumber) ?? String(records.count)
        }
        return kind.compute(records.map { resolver.value($0, field) }, field: resolver.formatField(field))
    }
}
