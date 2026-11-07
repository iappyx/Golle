import SwiftUI

/// A month grid with each record on the day of a date field. Drag a record to another day to move it;
/// double-click a day to add a record on it.
struct CalendarView: View {
    @ObservedObject var document: GolleDocument
    let table: DataTable
    let view: SavedView
    let rows: [Record]
    let resolver: Resolver
    let editFields: () -> Void
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())!.start

    private let calendar = Calendar.current

    var body: some View {
        if let field = view.dateField(in: table) {
            VStack(spacing: 0) {
                header(field)
                Divider()
                grid(field)
            }
        } else {
            ContentUnavailableView {
                Label("No Date Field", systemImage: "calendar")
            } description: {
                Text("The calendar places records by a Date field. Add one to use the calendar.")
            } actions: {
                Button("Edit Fields…", action: editFields)
            }
        }
    }

    private func header(_ field: Field) -> some View {
        HStack {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }.help("Previous month")
            Button("Today") { month = calendar.dateInterval(of: .month, for: Date())!.start }
            Button { shift(1) } label: { Image(systemName: "chevron.right") }.help("Next month")
            Text(month.formatted(.dateTime.month(.wide).year())).font(.headline).lineLimit(1)
            Spacer()
            Picker("By", selection: Binding(get: { field.id }, set: { id in document.updateCurrentView("Change Calendar") { $0.dateFieldID = id } })) {
                ForEach(table.fields.filter { $0.type.isDate }) { Text($0.name).tag($0.id) }
            }
            .fixedSize()
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func shift(_ months: Int) {
        month = calendar.date(byAdding: .month, value: months, to: month) ?? month
    }

    /// Six weeks starting on the week that holds the 1st.
    private var days: [Date] {
        let weekday = calendar.component(.weekday, from: month)
        let lead = (weekday - calendar.firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -lead, to: month)!
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private func grid(_ field: Field) -> some View {
        var byDay: [Date: [Record]] = [:]
        for record in rows {
            if let date = resolver.value(record, field)?.date { byDay[calendar.startOfDay(for: date), default: []].append(record) }
        }
        let symbols = calendar.shortWeekdaySymbols
        let ordered = Array(symbols[(calendar.firstWeekday - 1)...] + symbols[..<(calendar.firstWeekday - 1)])
        let days = self.days
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(ordered, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
            }
            .padding(.vertical, 4)
            ForEach(0..<6, id: \.self) { week in
                HStack(spacing: 0) {
                    ForEach(days[(week * 7)..<(week * 7 + 7)], id: \.self) { day in
                        DayCell(document: document, table: table, field: field, day: day,
                                inMonth: calendar.isDate(day, equalTo: month, toGranularity: .month),
                                records: byDay[day] ?? [], resolver: resolver)
                    }
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DayCell: View {
    @ObservedObject var document: GolleDocument
    let table: DataTable
    let field: Field
    let day: Date
    let inMonth: Bool
    let records: [Record]
    let resolver: Resolver
    @State private var targeted = false
    @State private var showingAll = false

    private var isToday: Bool { Calendar.current.isDateInToday(day) }
    private var editable: Bool { field.type == .date }

    private func chip(_ record: Record) -> some View {
        let color = table.color(of: record, resolver)?.color ?? .accentColor
        let selected = document.selectedRecordIDs.contains(record.id)
        return Text(table.title(of: record))
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(selected ? 0.45 : 0.2), in: .rect(cornerRadius: 3))
            .contentShape(.rect)
            .onTapGesture { document.selectedRecordIDs = [record.id] }
            .modifier(DraggableIf(enabled: editable, id: record.id.uuidString))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(day.formatted(.dateTime.day()))
                .font(.caption.weight(isToday ? .bold : .regular))
                .foregroundStyle(isToday ? Color.white : inMonth ? Color.primary : Color.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(isToday ? Color.accentColor : .clear, in: .capsule)
            ForEach(records.prefix(4)) { record in chip(record) }
            if records.count > 4 {
                // The rest in a list: each one can be selected and dragged to another day.
                Button("\(records.count - 4) more") { showingAll = true }
                    .buttonStyle(.link)
                    .font(.caption2)
                    .popover(isPresented: $showingAll, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(day.formatted(date: .complete, time: .omitted)).font(.headline).padding(.bottom, 4)
                            ScrollView {
                                VStack(alignment: .leading, spacing: 3) { ForEach(records) { chip($0) } }
                            }
                            .frame(maxHeight: 320)
                        }
                        .padding(12)
                        .frame(width: 240)
                    }
            }
            Spacer(minLength: 0)
        }
        .padding(3)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        // In a short window the chips stay in their day (and clicks and drops on them too).
        .clipped()
        .background(targeted ? Color.accentColor.opacity(0.15) : inMonth ? Color.clear : Color.secondary.opacity(0.06))
        .overlay(alignment: .topLeading) { Rectangle().strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5) }
        .contentShape(.rect)
        .onTapGesture(count: 2) {
            if editable { document.addRecord(to: table.id, values: [field.id: .date(day)]) }
        }
        .dropDestination(for: String.self) { ids, _ in
            guard editable else { return false }
            let records = Set(ids.compactMap(UUID.init(uuidString:)))
            // Keep the time of day when moving to another day.
            for id in records {
                guard let record = table.records.first(where: { $0.id == id }) else { continue }
                var date = day
                if let old = record[field.id]?.date {
                    // Set the clock time on the new day (adding hours would shift it on daylight-saving days).
                    let time = Calendar.current.dateComponents([.hour, .minute, .second], from: old)
                    date = Calendar.current.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: day) ?? day
                }
                document.setValue(.date(date), record: id, field: field.id, table: table.id)
            }
            return !records.isEmpty
        } isTargeted: { targeted = $0 }
    }
}

/// Created and modified dates can't be moved, so their records aren't draggable.
private struct DraggableIf: ViewModifier {
    let enabled: Bool
    let id: String

    func body(content: Content) -> some View {
        if enabled { content.draggable(id) } else { content }
    }
}
