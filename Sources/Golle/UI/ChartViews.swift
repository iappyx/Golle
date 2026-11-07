import Charts
import SwiftUI

/// The categorical chart colours: eight hues in a fixed order that stays tellable apart for colour-
/// blind readers, with separate steps for light and dark mode. A category keeps its slot (its place
/// in the field's option order), never its rank; past eight, categories fold into a gray "Other".
enum ChartPalette {
    static let light = ["2a78d6", "eb6834", "1baf7a", "eda100", "e87ba4", "008300", "6250d6", "e34948"]
    static let dark = ["3987e5", "d95926", "199e70", "c98500", "d55181", "008300", "9085e9", "e66767"]
    static let otherLight = "9a9994", otherDark = "6f6e69"

    static func color(_ slot: Int?, _ scheme: ColorScheme) -> Color {
        guard let slot else { return Color(hex: scheme == .dark ? otherDark : otherLight) }
        return Color(hex: (scheme == .dark ? dark : light)[slot % 8])
    }
}

extension Color {
    init(hex: String) {
        let value = UInt32(hex, radix: 16) ?? 0
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

/// A bar, donut or line chart of `ChartData` points, with a hover tooltip.
struct RecordChart: View {
    let points: [ChartPoint]
    let settings: ChartSettings
    let measureName: String
    let valueField: Field?
    /// The average over all records (each once), for the middle of a donut of averages.
    var overall: Double?
    var compact = false
    @Environment(\.colorScheme) private var scheme
    @State private var selectedLabel: String?
    @State private var selectedDate: Date?
    @State private var selectedAngle: Double?

    private func format(_ value: Double) -> String {
        if settings.measure == .count { return Value.numberFormatter.string(from: value as NSNumber) ?? "\(value)" }
        if let field = valueField { return Value.number(value).display(for: field) }
        return Value.numberFormatter.string(from: value as NSNumber) ?? "\(value)"
    }

    var body: some View {
        if points.isEmpty || points.allSatisfy({ $0.value == 0 && $0.count == 0 }) {
            ContentUnavailableView("Nothing to Chart", systemImage: settings.kind.symbol,
                                   description: Text("No records have a value to chart here."))
        } else {
            switch settings.kind {
            case .bar: bars
            case .pie: donut
            case .line: line
            }
        }
    }

    // MARK: Bars

    /// Many or long category names read better as horizontal bars.
    private var horizontal: Bool { points.count > 6 || points.contains { $0.label.count > 12 } }

    private var bars: some View {
        let color = ChartPalette.color(0, scheme)
        return Chart(points) { point in
            if horizontal {
                BarMark(x: .value(measureName, point.value), y: .value("Category", point.label), height: .ratio(0.7))
                    .foregroundStyle(color.opacity(selectedLabel == nil || selectedLabel == point.label ? 1 : 0.45))
                    .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4))
                    .annotation(position: .trailing, spacing: 4) {
                        if !compact || points.count <= 8 {
                            Text(format(point.value)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
            } else {
                BarMark(x: .value("Category", point.label), y: .value(measureName, point.value), width: .ratio(0.7))
                    .foregroundStyle(color.opacity(selectedLabel == nil || selectedLabel == point.label ? 1 : 0.45))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
            }
            if let selectedLabel, selectedLabel == point.label {
                if horizontal {
                    RuleMark(y: .value("Category", point.label)).foregroundStyle(.clear)
                        .annotation(position: .overlay, alignment: .center) { tooltip(point) }
                } else {
                    RuleMark(x: .value("Category", point.label)).foregroundStyle(.clear)
                        .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) { tooltip(point) }
                }
            }
        }
        .modifier(CategorySelection(horizontal: horizontal, selection: $selectedLabel))
        .chartXAxis { recessiveAxis(numeric: horizontal) }
        .chartYAxis { recessiveAxis(numeric: !horizontal) }
    }

    // MARK: Donut

    private var donut: some View {
        let sum = points.map(\.value).reduce(0, +)
        // For averages the middle shows the average over all records, not a sum of averages.
        let total = settings.measure == .average ? overall ?? 0 : sum
        let selected = selectedPoint(angle: selectedAngle)
        return HStack(alignment: .center, spacing: 16) {
            Chart(points) { point in
                SectorMark(angle: .value(measureName, point.value), innerRadius: .ratio(0.62), angularInset: 1.5)
                    .cornerRadius(3)
                    .foregroundStyle(ChartPalette.color(point.slot, scheme))
                    .opacity(selected == nil || selected?.label == point.label ? 1 : 0.4)
            }
            .chartAngleSelection(value: $selectedAngle)
            .chartBackground { proxy in
                GeometryReader { geometry in
                    if let frame = proxy.plotFrame {
                        let rect = geometry[frame]
                        VStack(spacing: 2) {
                            Text(selected.map { format($0.value) } ?? format(total)).font(compact ? .title3.bold() : .title2.bold()).monospacedDigit()
                            Text(selected?.label ?? (settings.measure == .average ? "overall" : "total")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(width: rect.width * 0.55)
                        .position(x: rect.midX, y: rect.midY)
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            // Identity is never colour alone: a legend with every category and its share.
            VStack(alignment: .leading, spacing: 4) {
                ForEach(points) { point in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(ChartPalette.color(point.slot, scheme)).frame(width: 10, height: 10)
                        Text(point.label).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(sum > 0 && settings.measure != .average ? "\(Int((point.value / sum * 100).rounded()))%" : format(point.value))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.caption)
                    .opacity(selected == nil || selected?.label == point.label ? 1 : 0.5)
                }
            }
            .frame(maxWidth: compact ? 150 : 220)
        }
    }

    private func selectedPoint(angle: Double?) -> ChartPoint? {
        guard let angle else { return nil }
        var running = 0.0
        for point in points {
            running += point.value
            if angle <= running { return point }
        }
        return nil
    }

    // MARK: Line

    private var line: some View {
        let color = ChartPalette.color(0, scheme)
        let unit = settings.dateUnit.component
        let nearest = selectedDate.flatMap { date in points.min { abs(($0.date ?? .distantPast).timeIntervalSince(date)) < abs(($1.date ?? .distantPast).timeIntervalSince(date)) } }
        return Chart {
            ForEach(points) { point in
                if let date = point.date {
                    LineMark(x: .value("Date", date, unit: unit), y: .value(measureName, point.value))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        // Straight segments: curves suggest values between the steps that aren't there.
                        .interpolationMethod(.linear)
                    if points.count <= 40 {
                        PointMark(x: .value("Date", date, unit: unit), y: .value(measureName, point.value))
                            .foregroundStyle(color)
                            .symbolSize(40)
                    }
                }
            }
            if let nearest, let date = nearest.date {
                RuleMark(x: .value("Date", date, unit: unit))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) { tooltip(nearest) }
                PointMark(x: .value("Date", date, unit: unit), y: .value(measureName, nearest.value))
                    .foregroundStyle(color)
                    .symbolSize(90)
            }
        }
        .chartXSelection(value: $selectedDate)
        .chartXAxis { recessiveAxis(numeric: false) }
        .chartYAxis { recessiveAxis(numeric: true) }
    }

    // MARK: Pieces

    private func tooltip(_ point: ChartPoint) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(point.label).font(.caption.weight(.semibold))
            Text("\(measureName): \(format(point.value))").font(.caption).monospacedDigit()
            if settings.measure != .count { Text("\(point.count) records").font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(6)
        .background(.regularMaterial, in: .rect(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)) }
    }

    @AxisContentBuilder
    private func recessiveAxis(numeric: Bool) -> some AxisContent {
        AxisMarks { _ in
            if numeric { AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2)) }
            AxisValueLabel().foregroundStyle(.secondary)
        }
    }
}

/// Hover selection on the category axis, whichever way the bars run.
private struct CategorySelection: ViewModifier {
    let horizontal: Bool
    @Binding var selection: String?

    func body(content: Content) -> some View {
        if horizontal { content.chartYSelection(value: $selection) } else { content.chartXSelection(value: $selection) }
    }
}

/// The values behind a chart, as a table (for reading exact numbers, and for screen readers).
struct ChartDataTable: View {
    let points: [ChartPoint]
    let measureName: String
    let format: (Double) -> String

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
            GridRow {
                Text("Category").fontWeight(.medium)
                Text(measureName).fontWeight(.medium).gridColumnAlignment(.trailing)
                Text("Records").fontWeight(.medium).gridColumnAlignment(.trailing)
            }
            Divider()
            ForEach(points) { point in
                GridRow {
                    Text(point.label).lineLimit(1)
                    Text(format(point.value)).monospacedDigit()
                    Text("\(point.count)").monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
    }
}

/// Chart type, category, measure and date step.
struct ChartControls: View {
    let table: DataTable
    @Binding var settings: ChartSettings

    var body: some View {
        let category = settings.categoryField(table)
        HStack(spacing: 10) {
            // A button per kind, each with its own tooltip (segments of a picker share one).
            ControlGroup {
                ForEach(ChartSettings.Kind.allCases) { kind in
                    Toggle(isOn: Binding(get: { settings.kind == kind }, set: { if $0 { settings.kind = kind } })) {
                        Label(kind.label, systemImage: kind.symbol)
                    }
                    .toggleStyle(.button)
                    .help(kind.label)
                }
            }
            .labelStyle(.iconOnly)
            .fixedSize()
            Picker("By", selection: Binding(get: { category?.id }, set: { settings.categoryFieldID = $0 })) {
                ForEach(ChartSettings.categoryFields(table)) { Label($0.name, systemImage: $0.type.symbol).tag(Optional($0.id)) }
            }
            .fixedSize()
            if category?.type.isDate == true {
                Picker("Per", selection: $settings.dateUnit) {
                    ForEach(ChartSettings.DateUnit.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
            }
            Picker("Show", selection: $settings.measure) {
                ForEach(ChartSettings.Measure.allCases) { Text($0.label).tag($0) }
            }
            .fixedSize()
            if settings.measure != .count {
                let numbers = table.fields.filter { ($0.type.isNumeric && $0.type != .autoNumber) || $0.type == .formula || $0.type == .rollup || $0.type == .lookup }
                Picker("Field", selection: Binding(get: { settings.valueField(table)?.id }, set: { settings.valueFieldID = $0 })) {
                    ForEach(numbers) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

extension ChartSettings {
    func title(_ table: DataTable) -> String {
        let field = categoryField(table)
        if let field, field.type.isDate {
            let what = measure == .count ? table.name : "\(measure == .sum ? "" : "Average ")\(valueField(table)?.name ?? "value")"
            return "\(what) per \(dateUnit.rawValue) · \(field.name)"
        }
        let by = field?.name ?? "—"
        switch measure {
        case .count: return "\(table.name) by \(by)"
        case .sum: return "\(valueField(table)?.name ?? "Total") by \(by)"
        case .average: return "Average \(valueField(table)?.name ?? "value") by \(by)"
        }
    }

    func measureName(_ table: DataTable) -> String {
        measure == .count ? "Records" : "\(measure == .sum ? "Sum" : "Average") of \(valueField(table)?.name ?? "—")"
    }
}

/// The Chart view mode: controls above, the chart, and its numbers below.
struct ChartModeView: View {
    @ObservedObject var document: GolleDocument
    let table: DataTable
    let view: SavedView
    let rows: [Record]
    let resolver: Resolver
    @State private var showData = false

    var body: some View {
        let settings = view.chart
        let points = ChartData.points(rows, settings: settings, resolver)
        let valueField = settings.valueField(table)
        VStack(spacing: 0) {
            HStack {
                ChartControls(table: table, settings: Binding(get: { view.chart }, set: { new in document.updateCurrentView("Change Chart") { $0.chart = new } }))
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.title(table)).font(.title3.bold())
                    Text("\(settings.measureName(table)) · \(rows.count) records").foregroundStyle(.secondary)
                }
                RecordChart(points: points, settings: settings, measureName: settings.measureName(table), valueField: valueField,
                            overall: settings.measure == .average ? ChartData.measure(rows, settings: settings, resolver) : nil)
                    .frame(minHeight: 260, maxHeight: .infinity)
                DisclosureGroup("Data", isExpanded: $showData) {
                    ScrollView {
                        ChartDataTable(points: points, measureName: settings.measureName(table)) { value in
                            settings.measure == .count ? "\(Int(value))" : (valueField.map { Value.number(value).display(for: $0) } ?? "\(value)")
                        }
                        .padding(.top, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: Dashboard

/// Charts and numbers from any table on one page.
struct DashboardView: View {
    @ObservedObject var document: GolleDocument
    @State private var editing: DashboardTile?

    var body: some View {
        Group {
            if document.database.dashboard.isEmpty {
                ContentUnavailableView {
                    Label("Dashboard", systemImage: "square.grid.2x2")
                } description: {
                    Text("Put charts and numbers from any table on one page.")
                } actions: {
                    Button("Add Chart") { newTile(.chart) }
                    Button("Add Number") { newTile(.number) }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16)], spacing: 16) {
                        ForEach(document.database.dashboard) { tile in
                            TileView(document: document, tile: tile)
                                .contextMenu {
                                    Button("Edit…") { editing = tile }
                                    Button("Move Earlier") { document.moveTile(tile.id, by: -1) }
                                    Button("Move Later") { document.moveTile(tile.id, by: 1) }
                                    Divider()
                                    Button("Remove", role: .destructive) { document.removeTile(tile.id) }
                                }
                                // Beside the chart's own clicks (which pick a bar or a slice), not under them.
                                .simultaneousGesture(TapGesture(count: 2).onEnded { editing = tile })
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle("Dashboard")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("Chart") { newTile(.chart) }
                    Button("Number") { newTile(.number) }
                } label: { Label("Add Tile", systemImage: "plus") }
                .help("Add a chart or a number")
            }
        }
        .sheet(item: $editing) { tile in
            TileEditor(document: document, tile: tile, isNew: !document.database.dashboard.contains { $0.id == tile.id })
        }
    }

    private func newTile(_ kind: DashboardTile.Kind) {
        guard let table = document.database.tables.first else { return }
        editing = DashboardTile(tableID: table.id, kind: kind)
    }
}

private struct TileView: View {
    @ObservedObject var document: GolleDocument
    let tile: DashboardTile

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let table = document.database.table(tile.tableID) {
                let resolver = document.resolver(for: table)
                let view = tile.viewID.flatMap { id in table.views.first { $0.id == id } }
                let records = document.memo("tile-\(tile.hashValue)") {
                    view.map { v in table.records.filter { v.filter.matches($0, resolver) } } ?? table.records
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title(table)).font(.headline).lineLimit(1)
                    Text(subtitle(table, view)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                switch tile.kind {
                case .chart:
                    let points = document.memo("tile-points-\(tile.hashValue)") { ChartData.points(records, settings: tile.chart, resolver) }
                    RecordChart(points: points, settings: tile.chart, measureName: tile.chart.measureName(table),
                                valueField: tile.chart.valueField(table),
                                overall: tile.chart.measure == .average ? ChartData.measure(records, settings: tile.chart, resolver) : nil,
                                compact: true)
                        .frame(height: 220)
                case .number:
                    Text(ChartData.number(records, tile: tile, resolver))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
                }
            } else {
                ContentUnavailableView("Table Removed", systemImage: "questionmark.square.dashed")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.15)) }
    }

    private func title(_ table: DataTable) -> String {
        if !tile.title.isEmpty { return tile.title }
        switch tile.kind {
        case .chart: return tile.chart.title(table)
        case .number:
            guard let kind = tile.summary, let field = tile.fieldID.flatMap(table.field) else { return "Number of \(table.name)" }
            return "\(kind.label) of \(field.name)"
        }
    }

    private func subtitle(_ table: DataTable, _ view: SavedView?) -> String {
        [table.name, view?.name].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Adding or changing a tile.
private struct TileEditor: View {
    @ObservedObject var document: GolleDocument
    @State var tile: DashboardTile
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Kind", selection: $tile.kind) {
                    Text("Chart").tag(DashboardTile.Kind.chart)
                    Text("Number").tag(DashboardTile.Kind.number)
                }
                .pickerStyle(.segmented)
                TextField("Title", text: $tile.title, prompt: Text("Automatic"))
                Picker("Table", selection: Binding(get: { tile.tableID }, set: { id in
                    tile.tableID = id
                    tile.viewID = nil
                    tile.chart = ChartSettings()
                    tile.fieldID = nil
                })) {
                    ForEach(document.database.tables) { Text($0.name).tag($0.id) }
                }
                if let table = document.database.table(tile.tableID) {
                    Picker("Records", selection: $tile.viewID) {
                        Text("All Records").tag(SavedView.ID?.none)
                        ForEach(table.views) { Text($0.name).tag(Optional($0.id)) }
                    }
                    if tile.kind == .chart {
                        ChartControls(table: table, settings: $tile.chart)
                            .controlSize(.small)
                    } else {
                        Picker("Show", selection: Binding(get: { tile.summary.map(\.rawValue) ?? "count" }, set: { raw in
                            tile.summary = SummaryKind(rawValue: raw)
                            // Keep the field only if it suits the new summary (no "Sum of Name").
                            if let kind = tile.summary {
                                let current = tile.fieldID.flatMap(table.field)
                                if current.map({ !SummaryKind.kinds(for: $0.type).contains(kind) }) ?? true {
                                    tile.fieldID = table.fields.first { SummaryKind.kinds(for: $0.type).contains(kind) }?.id
                                }
                            }
                        })) {
                            Text("Number of records").tag("count")
                            ForEach(SummaryKind.allCases) { Text($0.label + " of").tag($0.rawValue) }
                        }
                        if let kind = tile.summary {
                            Picker("Field", selection: $tile.fieldID) {
                                ForEach(table.fields.filter { SummaryKind.kinds(for: $0.type).contains(kind) }) { Text($0.name).tag(Optional($0.id)) }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Done") {
                    if isNew { document.addTile(tile) } else { document.updateTile(tile) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 620, height: 420)
    }
}
