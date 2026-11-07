import SwiftUI

/// The summary view: a table of records counted, or a number field added up, by one field along
/// the rows and optionally another along the columns, with totals. A click on a cell selects its
/// records, so the inspector shows them.
struct PivotView: View {
    @ObservedObject var document: GolleDocument
    let table: DataTable
    let view: SavedView
    let rows: [Record]
    let resolver: Resolver
    @State private var selected: String?

    static let rowHeaderWidth: CGFloat = 200
    static let cellWidth: CGFloat = 120
    static let rowHeight: CGFloat = 28

    private var settings: PivotSettings { view.summary }

    private func update(_ body: (inout PivotSettings) -> Void) {
        document.updateCurrentView("Change Summary") { body(&$0.summary) }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            let key = "pivot-\(table.id)-\(settings.hashValue)-\(rows.map(\.id).hashValue)"
            if let result = document.memo(key, { Pivot.compute(rows, settings: settings, resolver) }), !result.rows.isEmpty {
                grid(result)
            } else {
                ContentUnavailableView("Nothing to Summarise", systemImage: "sum",
                                       description: Text(PivotSettings.axisFields(table).isEmpty ? "Add a choice, date or number field to summarise by." : "No records in view."))
                    .frame(maxHeight: .infinity)
            }
        }
    }

    // MARK: Controls

    private var controls: some View {
        let fields = PivotSettings.axisFields(table)
        let rowField = settings.rowField(table)
        let columnField = settings.columnField(table)
        return HStack(spacing: 10) {
            Picker("Rows", selection: Binding(get: { rowField?.id }, set: { id in update { $0.rowFieldID = id } })) {
                ForEach(fields) { Label($0.name, systemImage: $0.type.symbol).tag(Optional($0.id)) }
            }
            .fixedSize()
            if let rowField { step(for: rowField, rows: true) }
            Picker("Columns", selection: Binding(get: { columnField?.id }, set: { id in update { $0.columnFieldID = id } })) {
                Text("None").tag(Field.ID?.none)
                Divider()
                ForEach(fields.filter { $0.id != rowField?.id }) { Label($0.name, systemImage: $0.type.symbol).tag(Optional($0.id)) }
            }
            .fixedSize()
            if let columnField { step(for: columnField, rows: false) }
            Picker("Show", selection: Binding(get: { settings.measure }, set: { m in update { $0.measure = m } })) {
                ForEach(PivotSettings.Measure.allCases) { Text($0.label).tag($0) }
            }
            .fixedSize()
            if settings.measure != .count {
                let values = PivotSettings.valueFields(table)
                Picker("Field", selection: Binding(get: { settings.valueField(table)?.id }, set: { id in update { $0.valueFieldID = id } })) {
                    ForEach(values) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(values.isEmpty)
            }
            Spacer()
            Button {
                copy()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .help("Copy the table, to paste into Numbers or Excel")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// Dates by day, week, month or year; numbers each, or in steps of 10, 100 or 1000.
    @ViewBuilder
    private func step(for field: Field, rows: Bool) -> some View {
        if field.type.isDate {
            Picker("By", selection: Binding(get: { rows ? settings.rowDateUnit : settings.columnDateUnit }, set: { unit in
                update { if rows { $0.rowDateUnit = unit } else { $0.columnDateUnit = unit } }
            })) {
                ForEach(ChartSettings.DateUnit.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        } else if [.number, .formula, .rollup, .lookup, .progress, .duration].contains(field.type) {
            Picker("By", selection: Binding(get: { rows ? settings.rowStep : settings.columnStep }, set: { step in
                update { if rows { $0.rowStep = step } else { $0.columnStep = step } }
            })) {
                ForEach(PivotSettings.NumberStep.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    // MARK: Table

    private func grid(_ result: Pivot.Result) -> some View {
        let rowName = settings.rowField(table)?.name ?? ""
        let measureName = settings.measure == .count ? "Records" : "\(settings.measure.label) \(result.valueField?.name ?? "")"
        // The largest cell (not the totals), for the shading.
        let largest = result.cells.flatMap { $0 }.compactMap(\.value).max() ?? 0
        return ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .trailing, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    header(rowName, width: Self.rowHeaderWidth, leading: true)
                    ForEach(result.columns, id: \.self) { header($0.label, width: Self.cellWidth) }
                    header(result.columns.isEmpty ? measureName : "Total", width: Self.cellWidth, bold: !result.columns.isEmpty)
                }
                ForEach(Array(result.rows.enumerated()), id: \.element) { i, row in
                    GridRow {
                        label(row.label)
                        ForEach(Array(result.columns.enumerated()), id: \.element) { j, column in
                            cell(result.cells[i][j], id: "\(row.key)\u{1F}\(column.key)", result: result, largest: largest)
                        }
                        cell(result.rowTotals[i], id: "\(row.key)\u{1F}total", result: result, total: !result.columns.isEmpty)
                    }
                }
                GridRow {
                    label("Total", bold: true)
                    ForEach(Array(result.columns.enumerated()), id: \.element) { j, column in
                        cell(result.columnTotals[j], id: "total\u{1F}\(column.key)", result: result, total: true)
                    }
                    cell(result.total, id: "total", result: result, total: true)
                }
            }
            .padding(16)
        }
        .background(.background)
    }

    private func header(_ text: String, width: CGFloat, leading: Bool = false, bold: Bool = false) -> some View {
        Text(text)
            .font(.callout.weight(bold ? .bold : .semibold))
            .lineLimit(2)
            .multilineTextAlignment(leading ? .leading : .trailing)
            .padding(.horizontal, 8)
            .frame(width: width, height: Self.rowHeight + 8, alignment: leading ? .leading : .trailing)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.secondary.opacity(0.35)).frame(height: 1) }
    }

    private func label(_ text: String, bold: Bool = false) -> some View {
        Text(text)
            .fontWeight(bold ? .bold : .regular)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(width: Self.rowHeaderWidth, height: Self.rowHeight, alignment: .leading)
            .background(bold ? Color.secondary.opacity(0.08) : .clear)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 0.5) }
            .help(text)
    }

    private func cell(_ cell: Pivot.Cell, id: String, result: Pivot.Result, largest: Double = 0, total: Bool = false) -> some View {
        let text = Pivot.text(cell.value, result, settings, resolver)
        let shade = !total && largest > 0 ? (cell.value ?? 0) / largest * 0.28 : 0
        return Text(text)
            .fontWeight(total ? .semibold : .regular)
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(width: Self.cellWidth, height: Self.rowHeight, alignment: .trailing)
            .background {
                ZStack {
                    if total { Color.secondary.opacity(0.08) }
                    Color.accentColor.opacity(shade)
                }
            }
            .overlay(alignment: .bottom) { Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 0.5) }
            .overlay { if selected == id { Rectangle().strokeBorder(Color.accentColor, lineWidth: 2) } }
            .contentShape(.rect)
            // Its records selected, so the inspector shows them.
            .onTapGesture {
                selected = id
                document.selectedRecordIDs = Set(cell.records)
            }
            .help(cell.records.isEmpty ? "No records" : "\(cell.records.count) record\(cell.records.count == 1 ? "" : "s"): click to select")
    }

    private func copy() {
        guard let result = Pivot.compute(rows, settings: settings, resolver) else { return }
        let text = Pivot.copyText(result, settings: settings, resolver: resolver, rowName: settings.rowField(table)?.name ?? "")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
