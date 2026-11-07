import SwiftUI

/// Records as bars on a time line (a Gantt chart): from a start date to an end date, one row per
/// record, grouped like the table. Drag a bar to move it, drag its right edge to change the end.
struct TimelineView: View {
    @ObservedObject var document: GolleDocument
    let table: DataTable
    let view: SavedView
    let rows: [Record]
    let resolver: Resolver
    let editFields: () -> Void

    /// Where the chart is scrolled. Kept apart, so scrolling redraws only what stays put (the names,
    /// the header) and the grid, not every bar.
    @StateObject private var scroll = TimelineScroll()
    @State private var position = ScrollPosition()
    @GestureState private var drag: Drag?

    static let rowHeight: CGFloat = 28
    static let labelWidth: CGFloat = 210
    static let headerHeight: CGFloat = 40

    private let calendar = Calendar.current

    struct Drag: Equatable {
        let record: Record.ID
        /// Moving the whole bar, or only its end.
        let resizing: Bool
        var days: Int
    }

    /// One line: a group's title, or a record's bar.
    enum Line: Identifiable {
        case group(id: String, title: String, count: Int, depth: Int)
        case item(Item)
        var id: String {
            switch self {
            case .group(let id, _, _, _): "g" + id
            case .item(let item): item.record.id.uuidString
            }
        }
    }

    struct Item {
        let record: Record
        /// Days, at the start of each.
        let start: Date
        let end: Date
        let depth: Int
    }

    var body: some View {
        if let start = view.dateField(in: table) {
            let end = view.endDateField(in: table)
            let key = "timeline-\(table.id)-\(start.id)-\(end?.id.uuidString ?? "")-\(view.groupBy)-\(view.timelineScale)-\(rows.map(\.id).hashValue)"
            let (lines, range) = document.memo(key) { () -> ([Line], ClosedRange<Date>) in
                let lines = self.lines(start: start, end: end)
                return (lines, self.range(lines))
            }
            VStack(spacing: 0) {
                header(start: start, end: end, unscheduled: rows.count - lines.filter { if case .item = $0 { true } else { false } }.count, range: range)
                Divider()
                chart(lines, range: range, start: start, end: end)
            }
        } else {
            ContentUnavailableView {
                Label("No Date Field", systemImage: "calendar.day.timeline.left")
            } description: {
                Text("The timeline shows records from a start date to an end date. Add a Date field to use it.")
            } actions: {
                Button("Edit Fields…", action: editFields)
            }
        }
    }

    // MARK: Data

    private func lines(start: Field, end: Field?) -> [Line] {
        func item(_ record: Record, depth: Int) -> Item? {
            guard let s = resolver.value(record, start)?.date else { return nil }
            let first = calendar.startOfDay(for: s)
            let e = end.flatMap { resolver.value(record, $0)?.date }.map(calendar.startOfDay) ?? first
            return Item(record: record, start: first, end: max(first, e), depth: depth)
        }
        let groupFields = view.groupBy.compactMap(table.field)
        guard !groupFields.isEmpty else { return rows.compactMap { item($0, depth: 0) }.map(Line.item) }
        func flatten(_ groups: [RecordGroup], depth: Int) -> [Line] {
            groups.flatMap { group -> [Line] in
                let items = group.subgroups.isEmpty ? group.records.compactMap { item($0, depth: depth + 1) }.map(Line.item) : flatten(group.subgroups, depth: depth + 1)
                // Counted by the bars shown; a group with none is left out.
                let count = items.filter { if case .item = $0 { true } else { false } }.count
                guard count > 0 else { return [] }
                return [.group(id: group.id, title: group.title, count: count, depth: depth)] + items
            }
        }
        return flatten(Grouping.groups(rows, by: groupFields, resolver), depth: 0)
    }

    /// The days shown: every bar and today, with some room around them, from the start of a week or month.
    private func range(_ lines: [Line]) -> ClosedRange<Date> {
        let today = calendar.startOfDay(for: Date())
        // Within 30 years either side of today: a typo like 0202 or 3025 shouldn't push the real
        // bars miles away.
        let earliest = calendar.date(byAdding: .year, value: -30, to: today) ?? today
        let latest = calendar.date(byAdding: .year, value: 30, to: today) ?? today
        var first = today, last = today
        for case .item(let item) in lines {
            first = min(first, max(item.start, earliest))
            last = max(last, min(item.end, latest))
        }
        let pad = view.timelineScale == .day ? 7 : view.timelineScale == .week ? 21 : 60
        first = calendar.date(byAdding: .day, value: -pad, to: first) ?? first
        last = calendar.date(byAdding: .day, value: pad, to: last) ?? last
        let unit: Calendar.Component = view.timelineScale == .month ? .month : .weekOfYear
        first = calendar.dateInterval(of: unit, for: first)?.start ?? first
        return first...max(first, last)
    }

    private func days(from a: Date, to b: Date) -> Int {
        calendar.dateComponents([.day], from: a, to: b).day ?? 0
    }

    private var dayWidth: CGFloat { view.timelineScale.dayWidth }

    // MARK: Header

    private func header(start: Field, end: Field?, unscheduled: Int, range: ClosedRange<Date>) -> some View {
        let dates = table.fields.filter { $0.type.isDate }
        return HStack {
            Picker("From", selection: Binding(get: { start.id }, set: { id in
                document.updateCurrentView("Change Timeline") { v in
                    v.dateFieldID = id
                    if v.endDateFieldID == id { v.endDateFieldID = nil }
                }
            })) {
                ForEach(dates) { Text($0.name).tag($0.id) }
            }
            .fixedSize()
            Picker("To", selection: Binding(get: { end?.id }, set: { id in document.updateCurrentView("Change Timeline") { $0.endDateFieldID = id } })) {
                Text("One day").tag(Field.ID?.none)
                ForEach(dates.filter { $0.id != start.id }) { Text($0.name).tag(Field.ID?.some($0.id)) }
            }
            .fixedSize()
            Picker("Scale", selection: Binding(get: { view.timelineScale }, set: { scale in
                document.updateCurrentView("Change Timeline") { $0.timelineScale = scale }
            })) {
                ForEach(TimelineScale.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button("Today") { scrollToToday(range) }
            Spacer()
            if unscheduled > 0 {
                Text("\(unscheduled) without \(start.name)").foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func scrollToToday(_ range: ClosedRange<Date>) {
        let x = CGFloat(days(from: range.lowerBound, to: calendar.startOfDay(for: Date()))) * dayWidth
        // Today a third of the way into the bars that can be seen.
        let bars = max(scroll.width - Self.labelWidth, 200)
        let target = max(-scroll.inset, x - bars / 3 - scroll.inset)
        scroll.placed = target + scroll.inset
        position.scrollTo(x: target)
    }

    // MARK: Chart

    private func chart(_ lines: [Line], range: ClosedRange<Date>, start: Field, end: Field?) -> some View {
        let totalDays = days(from: range.lowerBound, to: range.upperBound) + 1
        let width = Self.labelWidth + CGFloat(totalDays) * dayWidth
        // Created and modified dates can't be moved; a fixed end still lets the start move.
        let movable = start.type == .date
        let end = end?.type == .date ? end : nil
        let resizable = movable && end != nil
        return ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(lines) { line in
                        row(line, range: range, start: start, end: end, movable: movable, resizable: resizable)
                    }
                    if lines.isEmpty {
                        Pinned(scroll: scroll) {
                            Text("No records in view have \(start.name).")
                                .foregroundStyle(.secondary)
                                .padding()
                        }
                    }
                } header: {
                    TimelineHeader(range: range, scale: view.timelineScale, labelWidth: Self.labelWidth, scroll: scroll)
                        .frame(width: width, height: Self.headerHeight)
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .scrollPosition($position)
        // The scroll view reaches under the sidebar and the inspector: what can be seen starts after
        // the leading inset.
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x + $0.contentInsets.leading } action: { _, x in
            if scroll.x != max(0, x) { scroll.x = max(0, x) }
        }
        // Today is placed again while the window is still being laid out (the insets and width
        // arrive late), but not once the chart has been scrolled by hand.
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentInsets.leading } action: { _, inset in
            scroll.inset = inset
            if scroll.untouched { scrollToToday(range) }
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.width - $0.contentInsets.leading - $0.contentInsets.trailing } action: { _, w in
            if scroll.width != w {
                scroll.width = w
                if scroll.untouched { scrollToToday(range) }
            }
        }
        // Once the insets are known.
        .onAppear { DispatchQueue.main.async { scrollToToday(range) } }
        // A new scale shows today again. Otherwise (a bar moved past the edge, a date changed)
        // only while not scrolled by hand; scrolled, what is in view stays in view.
        .onChange(of: RangeKey(range: range, scale: view.timelineScale)) { old, new in
            if old.scale != new.scale || scroll.untouched {
                scrollToToday(new.range)
            } else if old.range.lowerBound != new.range.lowerBound {
                let shift = CGFloat(days(from: new.range.lowerBound, to: old.range.lowerBound)) * dayWidth
                position.scrollTo(x: max(0, scroll.x + shift) - scroll.inset)
            }
        }
    }

    @ViewBuilder
    private func row(_ line: Line, range: ClosedRange<Date>, start: Field, end: Field?, movable: Bool, resizable: Bool) -> some View {
        switch line {
        case .group(_, let title, let count, let depth):
            Pinned(scroll: scroll) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.semibold).lineLimit(1)
                    Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
                }
                .padding(.leading, 10 + CGFloat(depth) * 14)
                .frame(width: Self.labelWidth, height: Self.rowHeight, alignment: .leading)
                .background(.background.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08))
        case .item(let item):
            let selected = document.selectedRecordIDs.contains(item.record.id)
            ZStack(alignment: .topLeading) {
                TimelineGrid(range: range, scale: view.timelineScale, labelWidth: Self.labelWidth, scroll: scroll)
                bar(item, range: range, start: start, end: end, movable: movable, resizable: resizable, selected: selected)
                Pinned(scroll: scroll) {
                    Text(table.title(of: item.record))
                        .lineLimit(1)
                        .padding(.leading, 10 + CGFloat(item.depth) * 14)
                        .padding(.trailing, 6)
                        .frame(width: Self.labelWidth, height: Self.rowHeight, alignment: .leading)
                        // Solid under the highlight: bars scrolled past go behind the names.
                        .background { if selected { Color.accentColor.opacity(0.18) } }
                        .background(.background)
                        .overlay(alignment: .trailing) { Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 0.5) }
                        .contentShape(.rect)
                        .onTapGesture { document.selectedRecordIDs = [item.record.id] }
                }
            }
            .frame(height: Self.rowHeight)
        }
    }

    private func bar(_ item: Item, range: ClosedRange<Date>, start: Field, end: Field?, movable: Bool, resizable: Bool, selected: Bool) -> some View {
        let color = table.color(of: item.record, resolver)?.color ?? .accentColor
        let dragging = drag?.record == item.record.id ? drag : nil
        let move = dragging.map { $0.resizing ? 0 : $0.days } ?? 0
        let grow = dragging.map { $0.resizing ? $0.days : 0 } ?? 0
        let length = max(1, days(from: item.start, to: item.end) + 1 + grow)
        let x = Self.labelWidth + CGFloat(days(from: range.lowerBound, to: item.start) + move) * dayWidth
        let w = max(CGFloat(length) * dayWidth - 2, 6)
        let label = Self.dates(item.start, calendar.date(byAdding: .day, value: length - 1, to: item.start) ?? item.end)
        return ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 5)
                .fill(color.opacity(selected ? 0.85 : 0.55))
                .overlay { if selected { RoundedRectangle(cornerRadius: 5).strokeBorder(color, lineWidth: 1.5) } }
            if resizable {
                // The right edge: drag to change the end date.
                // At most a quarter of the bar: a short bar can still be moved.
                Rectangle().fill(Color.white.opacity(0.001)).frame(width: min(8, w / 4))
                    .pointerStyle(.frameResize(position: .trailing))
                    .gesture(dragGesture(item, resizing: true, start: start, end: end))
            }
        }
        .frame(width: w, height: Self.rowHeight - 8)
        .overlay(alignment: .leading) {
            // Inside a wide bar, after a narrow one.
            Text(label)
                .font(.caption)
                .foregroundStyle(w > 90 ? Color.white : Color.secondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.leading, 6)
                .offset(x: w > 90 ? 0 : w)
                .allowsHitTesting(false)
        }
        .contentShape(.rect)
        .onTapGesture { document.selectedRecordIDs = [item.record.id] }
        .gesture(movable ? dragGesture(item, resizing: false, start: start, end: end) : nil)
        .help("\(table.title(of: item.record)): \(label)")
        .offset(x: x + 1, y: 4)
    }

    private func dragGesture(_ item: Item, resizing: Bool, start: Field, end: Field?) -> some Gesture {
        // Measured on the screen: the bar moves with the pointer, so its own coordinates would too.
        func days(_ value: DragGesture.Value) -> Int {
            let days = Int((value.translation.width / dayWidth).rounded())
            // The end can't go before the start.
            return resizing ? max(days, -self.days(from: item.start, to: item.end)) : days
        }
        return DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .updating($drag) { value, drag, _ in
                drag = Drag(record: item.record.id, resizing: resizing, days: days(value))
            }
            .onChanged { _ in
                if document.selectedRecordIDs != [item.record.id] { document.selectedRecordIDs = [item.record.id] }
            }
            .onEnded { value in
                let days = days(value)
                if days != 0 {
                    document.shiftDates(record: item.record.id, table: table.id, start: start.id, end: end?.id, moveStart: !resizing, byDays: days)
                }
            }
    }

    struct RangeKey: Equatable {
        let range: ClosedRange<Date>
        let scale: TimelineScale
    }

    /// "5 Mar" or "5 – 12 Mar 2026".
    static func dates(_ a: Date, _ b: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(a, inSameDayAs: b) { return a.formatted(.dateTime.day().month(.abbreviated)) }
        return a.formatted(.dateTime.day().month(.abbreviated)) + " – " + b.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

/// Where the timeline is scrolled to, and how much of it can be seen.
final class TimelineScroll: ObservableObject {
    /// The left edge of what can be seen, in the chart's coordinates.
    @Published var x: CGFloat = 0
    /// The width that can be seen (without what the sidebar and inspector cover).
    @Published var width: CGFloat = 800
    /// How far the scroll view reaches under the sidebar.
    var inset: CGFloat = 0
    /// Where "today" last scrolled to, in the same coordinates as `x`.
    var placed: CGFloat?

    /// Not scrolled since today was placed (or never placed).
    var untouched: Bool { placed.map { abs($0 - x) < 2 } ?? true }

    /// The part of the chart to draw: what can be seen, and a screen either side.
    var window: ClosedRange<CGFloat> {
        // The width can be zero or less before the window is laid out.
        let w = width.isFinite ? max(width, 400) : 800
        let left = x.isFinite ? max(0, x) : 0
        return max(0, left - w)...(left + 2 * w)
    }
}

/// Content that stays at the left edge while the chart scrolls sideways.
private struct Pinned<Content: View>: View {
    @ObservedObject var scroll: TimelineScroll
    @ViewBuilder let content: Content

    var body: some View {
        content.padding(.leading, scroll.x)
    }
}

/// The days of a range drawn only in a window of it: a timeline can be far wider than anything a
/// canvas can draw at once.
private struct TimelineMetrics {
    let range: ClosedRange<Date>
    let scale: TimelineScale
    let labelWidth: CGFloat
    let calendar = Calendar.current

    var dayWidth: CGFloat { scale.dayWidth }

    /// In the chart's coordinates.
    func x(_ date: Date) -> CGFloat {
        labelWidth + CGFloat(calendar.dateComponents([.day], from: range.lowerBound, to: date).day ?? 0) * dayWidth
    }

    /// The first and last day in a window, clamped to the range.
    func days(in window: ClosedRange<CGFloat>) -> ClosedRange<Date> {
        func day(_ x: CGFloat) -> Date {
            let n = Int(((x - labelWidth) / dayWidth).rounded(.down))
            return calendar.date(byAdding: .day, value: n, to: range.lowerBound) ?? range.lowerBound
        }
        let first = max(range.lowerBound, day(window.lowerBound))
        return first...max(first, min(range.upperBound, day(window.upperBound)))
    }

    /// Each start of a unit (day, week, month, year) from before the first day to the last.
    func starts(of unit: Calendar.Component, in days: ClosedRange<Date>, _ body: (Date) -> Void) {
        var date = calendar.dateInterval(of: unit, for: days.lowerBound)?.start ?? days.lowerBound
        while date <= days.upperBound {
            body(date)
            guard let next = calendar.date(byAdding: unit, value: 1, to: date), next > date else { return }
            date = next
        }
    }
}

/// The dates above the bars: months (or years) on top, days, weeks or months under them.
private struct TimelineHeader: View {
    let range: ClosedRange<Date>
    let scale: TimelineScale
    let labelWidth: CGFloat
    @ObservedObject var scroll: TimelineScroll

    var body: some View {
        let metrics = TimelineMetrics(range: range, scale: scale, labelWidth: labelWidth)
        let window = scroll.window
        let scrollX = scroll.x
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                // Drawn from the window's left edge.
                context.translateBy(x: -window.lowerBound, y: 0)
                let calendar = metrics.calendar
                let days = metrics.days(in: window)
                let coarse: Calendar.Component = scale == .month ? .year : .month
                let fine: Calendar.Component = scale == .day ? .day : scale == .week ? .weekOfYear : .month
                metrics.starts(of: coarse, in: days) { date in
                    // The month stays readable beside the names while its start is scrolled past.
                    let next = calendar.date(byAdding: coarse, value: 1, to: date) ?? date
                    let left = min(max(metrics.x(date), labelWidth + scrollX), metrics.x(next) - 120)
                    let text = scale == .month ? date.formatted(.dateTime.year()) : date.formatted(.dateTime.month(.wide).year())
                    context.draw(Text(text).font(.caption.weight(.semibold)), at: CGPoint(x: left + 6, y: 11), anchor: .leading)
                    var line = Path()
                    line.move(to: CGPoint(x: metrics.x(date), y: 0))
                    line.addLine(to: CGPoint(x: metrics.x(date), y: size.height))
                    context.stroke(line, with: .color(.secondary.opacity(0.35)), lineWidth: 0.5)
                }
                let today = calendar.startOfDay(for: Date())
                metrics.starts(of: fine, in: days) { date in
                    let text: String
                    switch scale {
                    case .day: text = date.formatted(.dateTime.day())
                    case .week: text = date.formatted(.dateTime.day().month(.abbreviated))
                    case .month: text = date.formatted(.dateTime.month(.abbreviated))
                    }
                    let isToday = scale == .day && calendar.isDate(date, inSameDayAs: today)
                    let label = Text(text).font(.caption2).foregroundStyle(isToday ? Color.accentColor : Color.secondary)
                    if scale == .day {
                        context.draw(label, at: CGPoint(x: metrics.x(date) + metrics.dayWidth / 2, y: 30), anchor: .center)
                    } else {
                        context.draw(label, at: CGPoint(x: metrics.x(date) + 4, y: 30), anchor: .leading)
                    }
                }
            }
            .frame(width: window.upperBound - window.lowerBound)
            .padding(.leading, window.lowerBound)
            // The corner above the names stays put.
            Rectangle().fill(.bar)
                .frame(width: labelWidth, height: TimelineView.headerHeight)
                .overlay(alignment: .trailing) { Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 0.5) }
                .padding(.leading, scrollX)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// The lines behind a row's bar: one per week or month, weekends shaded by the day, and today.
private struct TimelineGrid: View {
    let range: ClosedRange<Date>
    let scale: TimelineScale
    let labelWidth: CGFloat
    @ObservedObject var scroll: TimelineScroll

    var body: some View {
        let metrics = TimelineMetrics(range: range, scale: scale, labelWidth: labelWidth)
        let window = scroll.window
        Canvas { context, size in
            context.translateBy(x: -window.lowerBound, y: 0)
            let calendar = metrics.calendar
            let days = metrics.days(in: window)
            if scale == .day {
                metrics.starts(of: .day, in: days) { day in
                    if calendar.isDateInWeekend(day) {
                        context.fill(Path(CGRect(x: metrics.x(day), y: 0, width: metrics.dayWidth, height: size.height)), with: .color(.secondary.opacity(0.06)))
                    }
                }
            }
            metrics.starts(of: scale == .month ? .month : .weekOfYear, in: days) { date in
                var line = Path()
                line.move(to: CGPoint(x: metrics.x(date), y: 0))
                line.addLine(to: CGPoint(x: metrics.x(date), y: size.height))
                context.stroke(line, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
            }
            let today = metrics.x(calendar.startOfDay(for: Date())) + metrics.dayWidth / 2
            var line = Path()
            line.move(to: CGPoint(x: today, y: 0))
            line.addLine(to: CGPoint(x: today, y: size.height))
            context.stroke(line, with: .color(.red.opacity(0.6)), lineWidth: 1)
            var bottom = Path()
            bottom.move(to: CGPoint(x: max(labelWidth, window.lowerBound), y: size.height - 0.25))
            bottom.addLine(to: CGPoint(x: window.upperBound, y: size.height - 0.25))
            context.stroke(bottom, with: .color(.secondary.opacity(0.1)), lineWidth: 0.5)
        }
        .frame(width: window.upperBound - window.lowerBound)
        .padding(.leading, window.lowerBound)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
