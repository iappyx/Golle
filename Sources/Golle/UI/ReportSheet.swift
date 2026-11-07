import PDFKit
import SwiftUI

/// What a report prints: columns, grouping and totals.
struct ReportOptions: Equatable {
    var title = ""
    var fields: [Field.ID] = []
    var groupBy: [Field.ID] = []
    /// The table's totals (the ones under the records) per group and for everything.
    var totals = true
    var counts = true
    var pagePerGroup = false
    var landscape = false
}

/// A grouped report: a header per group, the records as rows, totals under each group and at the
/// end, cut into pages. Drawn with SwiftUI into a PDF, like the other printouts.
@MainActor
enum Report {
    enum Line {
        case group(title: String, count: Int, depth: Int)
        case record(Record, shaded: Bool)
        /// Totals of a group (depth) or of everything (nil).
        case totals([Record], depth: Int?)
        case gap
        case pageBreak

        var height: CGFloat {
            switch self {
            case .group(_, _, let depth): depth == 0 ? 24 : 20
            case .record: 16
            case .totals: 18
            case .gap: 8
            case .pageBreak: 0
            }
        }
    }

    static func lines(_ records: [Record], groupFields: [Field], options: ReportOptions, resolver: Resolver) -> [Line] {
        guard !groupFields.isEmpty else {
            var lines = records.enumerated().map { Line.record($1, shaded: $0 % 2 == 1) }
            if options.totals { lines.append(.totals(records, depth: nil)) }
            return lines
        }
        var lines: [Line] = []
        func add(_ groups: [RecordGroup], depth: Int) {
            for (index, group) in groups.enumerated() {
                if depth == 0, options.pagePerGroup, index > 0 { lines.append(.pageBreak) }
                lines.append(.group(title: group.title, count: group.records.count, depth: depth))
                if group.subgroups.isEmpty {
                    lines += group.records.enumerated().map { Line.record($1, shaded: $0 % 2 == 1) }
                } else {
                    add(group.subgroups, depth: depth + 1)
                }
                if options.totals { lines.append(.totals(group.records, depth: depth)) }
                lines.append(.gap)
            }
        }
        add(Grouping.groups(records, by: groupFields, resolver), depth: 0)
        if options.totals { lines.append(.totals(records, depth: nil)) }
        return lines
    }

    /// The lines cut into pages that fit `height`; a group title never ends a page.
    static func pages(_ lines: [Line], height: CGFloat) -> [[Line]] {
        var pages: [[Line]] = [[]]
        var used: CGFloat = 0
        for line in lines {
            if case .pageBreak = line {
                if !pages[pages.count - 1].isEmpty { pages.append([]); used = 0 }
                continue
            }
            if case .gap = line, pages[pages.count - 1].isEmpty { continue }
            if used + line.height > height, !pages[pages.count - 1].isEmpty {
                // No gap at the top of a page.
                if case .gap = line { continue }
                // Take a dangling group title along to the new page, and a group's last record
                // along with its totals.
                var carried: [Line] = []
                if case .totals = line, let last = pages[pages.count - 1].last, case .record = last, pages[pages.count - 1].count > 1 {
                    carried.append(pages[pages.count - 1].removeLast())
                }
                while let last = pages[pages.count - 1].last, case .group = last {
                    carried.insert(pages[pages.count - 1].removeLast(), at: 0)
                }
                pages.append(carried)
                used = carried.reduce(0) { $0 + $1.height }
            }
            pages[pages.count - 1].append(line)
            used += line.height
        }
        return pages.filter { !$0.isEmpty }.isEmpty ? [[]] : pages.filter { !$0.isEmpty }
    }

    static func pdf(table: DataTable, records: [Record], options: ReportOptions, resolver: Resolver) -> Data? {
        let portrait = Printing.pageSize
        let size = options.landscape ? CGSize(width: portrait.height, height: portrait.width) : portrait
        let fields = options.fields.compactMap(table.field).filter { $0.type != .image }
        let groupFields = options.groupBy.compactMap(table.field)
        let lines = self.lines(records, groupFields: groupFields, options: options, resolver: resolver)
        let titleHeight: CGFloat = 44, columnsHeight: CGFloat = 18, footer: CGFloat = 16
        let pages = self.pages(lines, height: size.height - Printing.margin * 2 - titleHeight - columnsHeight - footer)
        let printed = Date()
        let views = pages.enumerated().map { index, lines in
            AnyView(ReportPage(table: table, fields: fields, lines: lines, options: options, resolver: resolver,
                               page: index + 1, pages: pages.count, total: records.count, printed: printed,
                               titleHeight: titleHeight, columnsHeight: columnsHeight))
        }
        return Printing.render(views, size: size)
    }

    /// Relative column widths: long text gets more room, checkboxes and numbers less.
    static func weight(_ field: Field) -> CGFloat {
        switch field.type {
        case .longText: 2.2
        case .text, .link, .lookup, .multiChoice, .location: 1.5
        case .checkbox: 0.45
        case .number: field.options.numberFormat?.style == .currency ? 1.1 : 0.8
        case .duration, .rating, .autoNumber, .progress, .rollup: 0.8
        case .date, .createdAt, .modifiedAt: field.options.includesTime || field.type != .date ? 1.2 : 0.9
        default: 1
        }
    }

    static func alignsRight(_ field: Field) -> Bool {
        field.type.isNumeric || field.type == .rollup
    }
}

private struct ReportPage: View {
    let table: DataTable
    let fields: [Field]
    let lines: [Report.Line]
    let options: ReportOptions
    let resolver: Resolver
    let page: Int
    let pages: Int
    let total: Int
    let printed: Date
    let titleHeight: CGFloat
    let columnsHeight: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let weights = fields.map(Report.weight)
            let sum = max(weights.reduce(0, +), 0.01)
            let widths = weights.map { geometry.size.width * $0 / sum }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(options.title).font(.system(size: 16, weight: .bold)).lineLimit(1)
                    Spacer()
                    Text("\(total) record\(total == 1 ? "" : "s")").font(.system(size: 8)).foregroundStyle(.gray)
                }
                .frame(height: titleHeight, alignment: .top)
                HStack(spacing: 0) {
                    ForEach(Array(fields.enumerated()), id: \.element.id) { i, field in
                        Text(field.name).font(.system(size: 8, weight: .semibold)).lineLimit(1)
                            .padding(.trailing, 4)
                            .frame(width: widths[i], alignment: Report.alignsRight(field) ? .trailing : .leading)
                    }
                }
                .frame(height: columnsHeight)
                Rectangle().fill(.gray).frame(height: 0.5)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    lineView(line, widths: widths)
                        .frame(height: line.height)
                }
                Spacer(minLength: 0)
                HStack {
                    Text(printed.formatted(date: .abbreviated, time: .shortened))
                    Spacer()
                    Text("Page \(page) of \(pages)")
                }
                .font(.system(size: 7))
                .foregroundStyle(.gray)
            }
        }
    }

    @ViewBuilder
    private func lineView(_ line: Report.Line, widths: [CGFloat]) -> some View {
        switch line {
        case .group(let title, let count, let depth):
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(title).font(.system(size: depth == 0 ? 11 : 9.5, weight: .bold)).lineLimit(1)
                if options.counts {
                    Text("\(count)").font(.system(size: 8)).foregroundStyle(.gray)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 10)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 2)
            .overlay(alignment: .bottom) { if depth == 0 { Rectangle().fill(.gray.opacity(0.6)).frame(height: 0.5) } }
        case .record(let record, let shaded):
            HStack(spacing: 0) {
                ForEach(Array(fields.enumerated()), id: \.element.id) { i, field in
                    Text(cell(record, field)).font(.system(size: 8)).lineLimit(1)
                        .padding(.trailing, 4)
                        .frame(width: widths[i], alignment: Report.alignsRight(field) ? .trailing : .leading)
                }
            }
            .frame(maxHeight: .infinity)
            .background(shaded ? Color.gray.opacity(0.08) : .clear)
        case .totals(let records, let depth):
            HStack(spacing: 0) {
                ForEach(Array(fields.enumerated()), id: \.element.id) { i, field in
                    Group {
                        if let item = table.summaries.first(where: { $0.fieldID == field.id }) {
                            // A total may be wider than its column: it runs into the empty one beside it.
                            // In the first column it keeps the "Total" label in front of it.
                            let total = item.kind.compute(records.map { resolver.value($0, field) }, field: resolver.formatField(field))
                            Text(i == 0 && depth == nil ? "Total  " + total : total)
                                .fontWeight(.semibold)
                                .fixedSize()
                        } else if i == 0 {
                            Text(depth == nil ? "Total" : "")
                                .fontWeight(.semibold)
                        } else {
                            Text("")
                        }
                    }
                    .font(.system(size: 8))
                    .lineLimit(1)
                    .padding(.trailing, 4)
                    .frame(width: widths[i], alignment: Report.alignsRight(field) ? .trailing : .leading)
                }
            }
            .frame(maxHeight: .infinity)
            .overlay(alignment: .top) { Rectangle().fill(.gray.opacity(depth == nil ? 0.8 : 0.4)).frame(height: depth == nil ? 1 : 0.5) }
        case .gap, .pageBreak:
            Color.clear
        }
    }

    private func cell(_ record: Record, _ field: Field) -> String {
        switch field.type {
        case .checkbox: record[field.id]?.bool == true ? "✓" : ""
        case .longText: resolver.readable(record, field).replacingOccurrences(of: "\n", with: " ")
        default: resolver.text(record, field)
        }
    }
}

/// Print Report: pick columns, grouping and totals, see the pages, then print or save a PDF.
struct ReportSheet: View {
    @ObservedObject var document: GolleDocument
    let records: [Record]
    @Environment(\.dismiss) private var dismiss

    @State private var options = ReportOptions()
    @State private var pdf: Data?

    private var table: DataTable? { document.currentTable }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if let table { settings(table).frame(width: 300) }
                Divider()
                PDFPreview(data: pdf)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.gray.opacity(0.15))
            }
            Divider()
            HStack {
                Text("\(records.count) record\(records.count == 1 ? "" : "s") in view").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save PDF…") {
                    // As set now, even if the preview hasn't caught up with the last change.
                    render()
                    if let pdf { Exporting.save(pdf, name: "\(fileName).pdf", type: .pdf) }
                }
                .disabled(pdf == nil)
                Button("Print…") {
                    render()
                    if let pdf {
                        let title = options.title
                        dismiss()
                        // After the sheet has gone: the print panel opens on the window.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { Printing.print(pdf, title: title) }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pdf == nil)
            }
            .padding(12)
        }
        .frame(width: 980, height: 680)
        .onAppear(perform: start)
        // Drawn again a moment after the last change, not on every keystroke of the title.
        .task(id: options) {
            guard pdf != nil else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            render()
        }
    }

    /// The title as a file name: never empty, hidden, or with a slash or colon in it.
    private var fileName: String {
        let name = options.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return name.isEmpty ? (table?.name ?? "Report") : name
    }

    private func start() {
        guard let table else { return }
        let view = document.currentView
        options.title = document.isSavedView ? "\(table.name) — \(view.name)" : table.name
        // The view's fields that fit on a line, at most eight (more can be ticked).
        let short = view.visibleFields(table).filter { ![.image, .file, .longText, .checklist, .location].contains($0.type) }
        // Fields with a total always: that is what the totals rows are for.
        let totalled = Set(table.summaries.map(\.fieldID))
        let chosen = Set(short.filter { !totalled.contains($0.id) }.prefix(8).map(\.id)).union(short.filter { totalled.contains($0.id) }.map(\.id))
        options.fields = short.map(\.id).filter(chosen.contains)
        options.groupBy = view.groupBy.filter { table.field($0) != nil }
        if options.groupBy.isEmpty, let choice = table.fields.first(where: { $0.type == .choice }) { options.groupBy = [choice.id] }
        options.landscape = options.fields.count > 6
        render()
    }

    private func render() {
        guard let table else { return }
        pdf = Report.pdf(table: table, records: records, options: options, resolver: document.resolver(for: table))
    }

    private func settings(_ table: DataTable) -> some View {
        let groupable = table.fields.filter { $0.type != .longText && !$0.type.isAttachment && $0.type != .autoNumber }
        return Form {
            TextField("Title", text: $options.title)
            Section("Group by") {
                Picker("Group by", selection: groupBinding(0)) {
                    Text("Don't group").tag(Field.ID?.none)
                    ForEach(groupable) { Text($0.name).tag(Field.ID?.some($0.id)) }
                }
                if !options.groupBy.isEmpty {
                    Picker("Then by", selection: groupBinding(1)) {
                        Text("Nothing").tag(Field.ID?.none)
                        ForEach(groupable.filter { $0.id != options.groupBy.first }) { Text($0.name).tag(Field.ID?.some($0.id)) }
                    }
                    Toggle("Number of records per group", isOn: $options.counts)
                    Toggle("Each group on a new page", isOn: $options.pagePerGroup)
                }
            }
            Section {
                Toggle("Totals", isOn: $options.totals)
            } footer: {
                Text(table.summaries.isEmpty
                     ? "This table has no totals yet: add them with the Σ button under the records."
                     : "The totals under the records (" + table.summaries.compactMap { s in table.field(s.fieldID).map { "\(s.kind.label.lowercased()) of \($0.name)" } }.joined(separator: ", ") + "), per group and for all.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Columns") {
                ForEach(table.fields.filter { $0.type != .image }) { field in
                    Toggle(isOn: Binding(
                        get: { options.fields.contains(field.id) },
                        set: { on in
                            if on {
                                // In table order.
                                let chosen = Set(options.fields + [field.id])
                                options.fields = table.fields.map(\.id).filter(chosen.contains)
                            } else {
                                options.fields.removeAll { $0 == field.id }
                            }
                        }
                    )) { Label(field.name, systemImage: field.type.symbol) }
                }
            }
            Section("Page") {
                Picker("Orientation", selection: $options.landscape) {
                    Text("Portrait").tag(false)
                    Text("Landscape").tag(true)
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
    }

    private func groupBinding(_ level: Int) -> Binding<Field.ID?> {
        Binding(
            get: { options.groupBy.count > level ? options.groupBy[level] : nil },
            set: { id in
                var groups = Array(options.groupBy.prefix(level))
                if let id { groups.append(id) }
                if level == 0, let second = options.groupBy.dropFirst().first, second != id, id != nil { groups.append(second) }
                options.groupBy = groups
            }
        )
    }
}

/// The report's pages, scrollable.
private struct PDFPreview: NSViewRepresentable {
    let data: Data?

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .clear
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        guard context.coordinator.shown != data else { return }
        context.coordinator.shown = data
        // Drawn again after a change: stay on the page being looked at.
        let page = view.currentPage.flatMap { view.document?.index(for: $0) }
        view.document = data.flatMap(PDFDocument.init(data:))
        if let page, let document = view.document, page < document.pageCount, let target = document.page(at: page) {
            view.go(to: target)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var shown: Data?
    }
}
