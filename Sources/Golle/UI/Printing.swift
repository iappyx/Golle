import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Printing and PDF: pages are drawn with SwiftUI into a PDF, which is then printed or saved.
/// Lists print as a table of the records in view; form mode prints one record per page.
@MainActor
enum Printing {
    static var pageSize: CGSize {
        // Upright, whichever way Page Setup was last turned: callers turn it for landscape.
        let paper = NSPrintInfo.shared.paperSize
        return CGSize(width: min(paper.width, paper.height), height: max(paper.width, paper.height))
    }

    nonisolated static let margin: CGFloat = 36

    /// The PDF for what the window shows: the record list, or the selected records as forms.
    static func pdf(document: GolleDocument, records: [Record]) -> Data? {
        guard let table = document.currentTable else { return nil }
        let resolver = document.resolver(for: table)
        let view = document.currentView
        if view.mode == .layout {
            let layout = table.layouts.first { $0.id == view.layoutID } ?? table.layouts.first ?? FormLayout.automatic(for: table)
            let selected = records.filter { document.selectedRecordIDs.contains($0.id) }
            return formPDF(document: document, table: table, records: selected.isEmpty ? records : selected, layout: layout, resolver: resolver)
        }
        let title = document.isSavedView ? "\(table.name) — \(view.name)" : table.name
        return listPDF(table: table, title: title, records: records, resolver: resolver)
    }

    static func listPDF(table: DataTable, title: String, records: [Record], resolver: Resolver) -> Data? {
        // Wide tables print in landscape.
        let fields = table.fields.filter { $0.type != .image }
        let portrait = pageSize
        let size = fields.count > 6 ? CGSize(width: portrait.height, height: portrait.width) : portrait
        let rowHeight: CGFloat = 18
        let headerHeight: CGFloat = 56
        let perPage = max(1, Int((size.height - margin * 2 - headerHeight - 20) / rowHeight))
        let chunks = stride(from: 0, to: max(records.count, 1), by: perPage).map { Array(records[$0..<min($0 + perPage, records.count)]) }
        let pages = chunks.enumerated().map { index, chunk in
            AnyView(ListPage(table: table, fields: fields, title: title, records: chunk, resolver: resolver,
                             page: index + 1, pages: chunks.count, total: records.count, rowHeight: rowHeight))
        }
        return render(pages, size: size)
    }

    static func formPDF(document: GolleDocument, table: DataTable, records: [Record], layout: FormLayout, resolver: Resolver) -> Data? {
        let size = pageSize
        let scale = min(1, (size.width - margin * 2) / layout.width, (size.height - margin * 2) / layout.height)
        let pages = records.map { record in
            AnyView(
                ZStack(alignment: .topLeading) {
                    ForEach(layout.items) { item in
                        PrintedItem(document: document, table: table, record: record, resolver: resolver, item: item)
                            .frame(width: item.width, height: item.height, alignment: .topLeading)
                            .offset(x: item.x, y: item.y)
                    }
                }
                .frame(width: layout.width, height: layout.height, alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: size.width - margin * 2, height: size.height - margin * 2, alignment: .topLeading)
            )
        }
        return render(pages, size: size)
    }

    static func render(_ pages: [AnyView], size: CGSize, margin: CGFloat = Printing.margin) -> Data? {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        for page in pages {
            let renderer = ImageRenderer(content:
                page
                    .padding(margin)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .background(Color.white)
                    .environment(\.colorScheme, .light)
                    .foregroundStyle(.black)
            )
            renderer.render { _, draw in
                context.beginPDFPage(nil)
                draw(context)
                context.endPDFPage()
            }
        }
        context.closePDF()
        return data as Data
    }

    /// `exactSize`: print at 100%, for labels that must line up with the sheet.
    static func print(_ data: Data, title: String, exactSize: Bool = false) {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        if exactSize, let first = PDFDocument(data: data)?.page(at: 0) {
            info.paperSize = first.bounds(for: .mediaBox).size
            info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
        }
        guard let pdf = PDFDocument(data: data),
              let operation = pdf.printOperation(for: info, scalingMode: exactSize ? .pageScaleNone : .pageScaleToFit, autoRotate: !exactSize) else { return }
        operation.jobTitle = title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        // The document window, not a sheet that is closing.
        if let window = NSApp.mainWindow ?? NSApp.keyWindow {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }
}

private struct ListPage: View {
    let table: DataTable
    let fields: [Field]
    let title: String
    let records: [Record]
    let resolver: Resolver
    let page: Int
    let pages: Int
    let total: Int
    let rowHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 16, weight: .bold))
                Spacer()
                Text("\(total) records · \(Date().formatted(date: .abbreviated, time: .shortened)) · page \(page) of \(pages)")
                    .font(.system(size: 8)).foregroundStyle(.gray)
            }
            .padding(.bottom, 14)
            GeometryReader { geometry in
                let width = geometry.size.width / CGFloat(max(fields.count, 1))
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(fields) { field in
                            Text(field.name).font(.system(size: 8, weight: .semibold)).lineLimit(1)
                                .frame(width: width, alignment: .leading)
                        }
                    }
                    .frame(height: rowHeight)
                    Rectangle().fill(.gray).frame(height: 0.5)
                    ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                        HStack(spacing: 0) {
                            ForEach(fields) { field in
                                Text(cell(record, field)).font(.system(size: 8)).lineLimit(1)
                                    .padding(.trailing, 4)
                                    .frame(width: width, alignment: .leading)
                            }
                        }
                        .frame(height: rowHeight)
                        .background(index % 2 == 1 ? Color.gray.opacity(0.08) : .clear)
                    }
                }
            }
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

/// Saving exports through a save panel.
@MainActor
enum Exporting {
    static func save(_ data: Data, name: String, type: UTType) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic) } catch { NSAlert(error: error).runModal() }
    }

    static func exportCSV(document: GolleDocument, records: [Record]) {
        guard let table = document.currentTable else { return }
        let separator = Preferences.csvSeparator
        let csv = Exporter.csv(records, resolver: document.resolver(for: table), separator: separator.character)
        // A byte-order mark makes Excel read UTF-8 correctly.
        let data = Data(((Preferences.csvBOM ? "\u{FEFF}" : "") + csv).utf8)
        if separator == .tab {
            save(data, name: "\(baseName(document)).tsv", type: .tabSeparatedText)
        } else {
            save(data, name: "\(baseName(document)).csv", type: .commaSeparatedText)
        }
    }

    static func exportJSON(document: GolleDocument) {
        do {
            save(try Exporter.json(document.database), name: "\(document.currentTable?.name ?? "Database").json", type: .json)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    static func exportPDF(document: GolleDocument, records: [Record]) {
        guard let data = Printing.pdf(document: document, records: records) else { return }
        save(data, name: "\(baseName(document)).pdf", type: .pdf)
    }

    static func print(document: GolleDocument, records: [Record]) {
        guard let data = Printing.pdf(document: document, records: records) else { return }
        Printing.print(data, title: baseName(document))
    }

    static func exportExcel(document: GolleDocument, records: [Record]) {
        guard let table = document.currentTable else { return }
        do {
            let data = try Exporter.xlsx(records, resolver: document.resolver(for: table))
            save(data, name: "\(baseName(document)).xlsx", type: UTType(filenameExtension: "xlsx") ?? .data)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    static func chooseImportFile() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText] + [UTType(filenameExtension: "xlsx")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func baseName(_ document: GolleDocument) -> String {
        guard let table = document.currentTable else { return "Golle" }
        return document.isSavedView ? "\(table.name) - \(document.currentView.name)" : table.name
    }
}
