import SwiftUI

/// A sheet of labels or a card size: page size, grid, and where the first label starts. In points.
struct LabelFormat: Identifiable, Hashable {
    let id: String
    let name: String
    let page: CGSize
    let columns: Int
    let rows: Int
    let label: CGSize
    let top: CGFloat
    let left: CGFloat
    let gapX: CGFloat
    let gapY: CGFloat

    var perPage: Int { columns * rows }

    static func mm(_ v: Double) -> CGFloat { CGFloat(v * 72 / 25.4) }
    static func inch(_ v: Double) -> CGFloat { CGFloat(v * 72) }
    static let a4 = CGSize(width: mm(210), height: mm(297))
    static let letter = CGSize(width: inch(8.5), height: inch(11))

    static let all: [LabelFormat] = [
        LabelFormat(id: "L7160", name: "A4 · 21 labels (63.5 × 38.1 mm, Avery L7160)", page: a4, columns: 3, rows: 7,
                    label: CGSize(width: mm(63.5), height: mm(38.1)), top: mm(15.15), left: mm(7.25), gapX: mm(2.5), gapY: 0),
        LabelFormat(id: "L7163", name: "A4 · 14 labels (99.1 × 38.1 mm, Avery L7163)", page: a4, columns: 2, rows: 7,
                    label: CGSize(width: mm(99.1), height: mm(38.1)), top: mm(15.15), left: mm(4.65), gapX: mm(2.5), gapY: 0),
        LabelFormat(id: "L7165", name: "A4 · 8 labels (99.1 × 67.7 mm, Avery L7165)", page: a4, columns: 2, rows: 4,
                    label: CGSize(width: mm(99.1), height: mm(67.7)), top: mm(13.1), left: mm(4.65), gapX: mm(2.5), gapY: 0),
        LabelFormat(id: "L7651", name: "A4 · 65 mini labels (38.1 × 21.2 mm, Avery L7651)", page: a4, columns: 5, rows: 13,
                    label: CGSize(width: mm(38.1), height: mm(21.2)), top: mm(10.7), left: mm(4.75), gapX: mm(2.5), gapY: 0),
        LabelFormat(id: "5160", name: "Letter · 30 labels (2⅝ × 1 in, Avery 5160)", page: letter, columns: 3, rows: 10,
                    label: CGSize(width: inch(2.625), height: inch(1)), top: inch(0.5), left: inch(0.1875), gapX: inch(0.125), gapY: 0),
        LabelFormat(id: "5163", name: "Letter · 10 labels (4 × 2 in, Avery 5163)", page: letter, columns: 2, rows: 5,
                    label: CGSize(width: inch(4), height: inch(2)), top: inch(0.5), left: inch(0.15625), gapX: inch(0.1875), gapY: 0),
        LabelFormat(id: "card-3x5", name: "Index card 3 × 5 in (one per page)", page: CGSize(width: inch(5), height: inch(3)), columns: 1, rows: 1,
                    label: CGSize(width: inch(5), height: inch(3)), top: 0, left: 0, gapX: 0, gapY: 0),
        LabelFormat(id: "card-4x6", name: "Index card 4 × 6 in (one per page)", page: CGSize(width: inch(6), height: inch(4)), columns: 1, rows: 1,
                    label: CGSize(width: inch(6), height: inch(4)), top: 0, left: 0, gapX: 0, gapY: 0),
        LabelFormat(id: "card-a6", name: "Card A6 (one per page)", page: CGSize(width: mm(148), height: mm(105)), columns: 1, rows: 1,
                    label: CGSize(width: mm(148), height: mm(105)), top: 0, left: 0, gapX: 0, gapY: 0),
    ]
}

/// Prints the records in view on labels or cards.
struct LabelsSheet: View {
    @ObservedObject var document: GolleDocument
    let records: [Record]
    @Environment(\.dismiss) private var dismiss

    @AppStorage("labels.format") private var formatID = "L7160"
    @State private var fields: [Field.ID] = []
    @State private var showNames = false
    @State private var showImage = true
    @State private var fontSize: Double = 9
    @State private var skip = 0

    private var table: DataTable? { document.currentTable }
    private var format: LabelFormat { LabelFormat.all.first { $0.id == formatID } ?? LabelFormat.all[0] }
    private var isCard: Bool { format.perPage == 1 }
    /// The labels to skip, never a whole sheet or more (the format may have changed since).
    private var skipped: Int { isCard ? 0 : min(skip, format.perPage - 1) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Form {
                    Picker("Labels", selection: $formatID) {
                        ForEach(LabelFormat.all) { Text($0.name).tag($0.id) }
                    }
                    if !isCard {
                        Stepper("Skip first \(skip) label\(skip == 1 ? "" : "s")", value: $skip, in: 0...(format.perPage - 1))
                            .help("For a sheet that is partly used already")
                    }
                    Stepper("Text size \(Int(fontSize)) pt", value: $fontSize, in: 6...24)
                    Toggle("Field names", isOn: $showNames)
                    if table?.fields.contains(where: { $0.type == .image }) == true {
                        Toggle("Image", isOn: $showImage)
                    }
                    if let table {
                        Section("Fields (the first one is bold)") {
                            List {
                                ForEach(table.fields.filter { !$0.type.isAttachment }) { field in
                                    Toggle(field.name, isOn: Binding(
                                        get: { fields.contains(field.id) },
                                        set: { on in if on { fields.append(field.id) } else { fields.removeAll { $0 == field.id } } }
                                    ))
                                }
                            }
                            .frame(height: 170)
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(width: 360)
                VStack {
                    Text("\(records.count) records · \(pageCount) page\(pageCount == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                    preview
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(12)
            Divider()
            HStack {
                Text("Print at 100% (no scaling) so the labels line up with the sheet.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save PDF…") { if let data = pdf() { Exporting.save(data, name: "\(table?.name ?? "Labels") labels.pdf", type: .pdf) } }
                Button("Print…") {
                    if let data = pdf() {
                        let title = "\(table?.name ?? "Golle") labels"
                        dismiss()
                        // After the sheet has gone: the print panel opens on the document window.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { Printing.print(data, title: title, exactSize: true) }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 900, height: 600)
        .onChange(of: formatID) { _, _ in skip = skipped }
        .onAppear {
            if fields.isEmpty, let table {
                fields = Array(table.fields.filter { !$0.type.isAttachment && $0.type != .longText && !$0.type.isComputed }.prefix(3).map(\.id))
            }
        }
    }

    private var pageCount: Int { max(1, Int(ceil(Double(records.count + skipped) / Double(format.perPage)))) }

    private var preview: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / format.page.width, geometry.size.height / format.page.height)
            page(0)
                .frame(width: format.page.width, height: format.page.height)
                .background(Color.white)
                .environment(\.colorScheme, .light)
                .scaleEffect(scale, anchor: .topLeading)
                // The scaled page's own size, anchored at its top left (scaling doesn't change layout size).
                .frame(width: format.page.width * scale, height: format.page.height * scale, alignment: .topLeading)
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// One page: labels placed on the sheet's grid.
    private func page(_ index: Int) -> some View {
        let lead = skipped
        let start = index * format.perPage - (index == 0 ? 0 : lead)
        return ZStack(alignment: .topLeading) {
            ForEach(0..<format.perPage, id: \.self) { slot in
                let recordIndex = index == 0 ? slot - lead : start + slot
                if recordIndex >= 0, recordIndex < records.count, let table {
                    let column = slot % format.columns, row = slot / format.columns
                    LabelContent(document: document, table: table, record: records[recordIndex], fields: fields.compactMap(table.field),
                                 showNames: showNames, showImage: showImage, fontSize: fontSize, isCard: isCard)
                        .frame(width: format.label.width, height: format.label.height, alignment: .topLeading)
                        .clipped()
                        .offset(x: format.left + CGFloat(column) * (format.label.width + format.gapX),
                                y: format.top + CGFloat(row) * (format.label.height + format.gapY))
                }
            }
        }
        .frame(width: format.page.width, height: format.page.height, alignment: .topLeading)
    }

    private func pdf() -> Data? {
        let pages = (0..<pageCount).map { AnyView(page($0)) }
        return Printing.render(pages, size: format.page, margin: 0)
    }
}

private struct LabelContent: View {
    let document: GolleDocument
    let table: DataTable
    let record: Record
    let fields: [Field]
    let showNames: Bool
    let showImage: Bool
    let fontSize: Double
    let isCard: Bool

    var body: some View {
        let resolver = Resolver(database: document.database, table: table)
        HStack(alignment: .top, spacing: 6) {
            if showImage, let field = table.fields.first(where: { $0.type == .image }),
               let attachment = record[field.id]?.attachments.first, let image = document.thumbnail(attachment) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: isCard ? 120 : 48)
            }
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(fields.enumerated()), id: \.element.id) { index, field in
                    let text = field.type == .longText && field.options.richText ? Markdown.plain(resolver.text(record, field)) : resolver.text(record, field)
                    if !text.isEmpty {
                        Text(showNames ? "\(field.name): \(text)" : text)
                            .font(.system(size: index == 0 ? fontSize * 1.25 : fontSize, weight: index == 0 ? .bold : .regular))
                            .lineLimit(isCard ? 4 : 2)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.black)
        .padding(isCard ? 18 : 6)
    }
}
