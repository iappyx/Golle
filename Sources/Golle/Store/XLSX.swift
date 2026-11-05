import Foundation

/// Excel workbooks (.xlsx): writing one sheet, reading the first sheet.
///
/// An .xlsx is a zip of XML files. Golle writes the minimum Excel and Numbers need and zips it with
/// the system's `zip`; reading unzips with `unzip`. Both tools ship with macOS.
enum XLSX {
    enum Cell: Equatable {
        case empty
        case text(String)
        case number(Double)
        case date(Date)
        /// A date with its time of day shown.
        case dateTime(Date)
        /// Seconds, shown as [h]:mm:ss.
        case duration(Double)
        case bool(Bool)
    }

    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    // MARK: Writing

    static func write(_ rows: [[Cell]], sheetName: String) throws -> Data {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("golle-xlsx-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files: [String: String] = [
            "[Content_Types].xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
            <Default Extension="xml" ContentType="application/xml"/>
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
            <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
            <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
            </Types>
            """,
            "_rels/.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
            </Relationships>
            """,
            "xl/workbook.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
            <sheets><sheet name="\(escape(safeSheetName(sheetName)))" sheetId="1" r:id="rId1"/></sheets>
            </workbook>
            """,
            "xl/_rels/workbook.xml.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
            </Relationships>
            """,
            // Style 0: normal. 1: bold (the header). 2: date (built-in format 14).
            "xl/styles.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
            <fonts count="2"><font><sz val="12"/><name val="Calibri"/></font><font><b/><sz val="12"/><name val="Calibri"/></font></fonts>
            <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
            <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
            <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
            <cellXfs count="5"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/><xf numFmtId="14" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="22" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="46" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs>
            </styleSheet>
            """,
            "xl/worksheets/sheet1.xml": sheet(rows),
        ]
        for (path, content) in files {
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
        }
        let output = folder.appendingPathComponent("out.xlsx")
        // -X leaves out Mac extended attributes; [Content_Types].xml must be at the root of the zip.
        try run("/usr/bin/zip", ["-X", "-q", "-r", output.path, "[Content_Types].xml", "_rels", "xl"], in: folder)
        return try Data(contentsOf: output)
    }

    private static func sheet(_ rows: [[Cell]]) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
        """
        for (r, row) in rows.enumerated() {
            xml += "<row r=\"\(r + 1)\">"
            for (c, cell) in row.enumerated() {
                let ref = column(c) + String(r + 1)
                let header = r == 0 ? " s=\"1\"" : ""
                switch cell {
                case .empty: continue
                case .text(let s):
                    xml += "<c r=\"\(ref)\" t=\"inlineStr\"\(header)><is><t xml:space=\"preserve\">\(escape(s))</t></is></c>"
                case .number(let n):
                    xml += "<c r=\"\(ref)\"\(header)><v>\(Value.plain(n))</v></c>"
                case .bool(let b):
                    xml += "<c r=\"\(ref)\" t=\"b\"\(header)><v>\(b ? 1 : 0)</v></c>"
                case .date(let d):
                    xml += "<c r=\"\(ref)\" s=\"2\"><v>\(Value.plain(serial(d)))</v></c>"
                case .dateTime(let d):
                    xml += "<c r=\"\(ref)\" s=\"3\"><v>\(Value.plain(serial(d)))</v></c>"
                case .duration(let seconds):
                    xml += "<c r=\"\(ref)\" s=\"4\"><v>\(Value.plain((seconds / 86_400 * 1_000_000).rounded() / 1_000_000))</v></c>"
                }
            }
            xml += "</row>"
        }
        return xml + "</sheetData></worksheet>"
    }

    /// A, B, …, Z, AA, AB, …
    static func column(_ index: Int) -> String {
        var n = index + 1
        var name = ""
        while n > 0 {
            let r = (n - 1) % 26
            name = String(UnicodeScalar(65 + r)!) + name
            n = (n - 1) / 26
        }
        return name
    }

    static func columnIndex(_ reference: String) -> Int {
        reference.prefix { $0.isLetter }.uppercased().unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 } - 1
    }

    /// A sheet name Excel accepts: none of : \\ / ? * [ ], not empty, at most 31 characters, and not
    /// starting or ending with an apostrophe.
    static func safeSheetName(_ name: String) -> String {
        let edges = CharacterSet(charactersIn: "'").union(.whitespaces)
        var clean = String(name.map { ":\\/?*[]".contains($0) ? "-" : $0 }).trimmingCharacters(in: edges)
        // Excel counts UTF-16 units (an emoji is two).
        while clean.utf16.count > 31 { clean.removeLast() }
        clean = clean.trimmingCharacters(in: edges)
        // "History" is reserved by Excel.
        if clean.caseInsensitiveCompare("History") == .orderedSame { clean += " 1" }
        return clean.isEmpty ? "Sheet1" : clean
    }

    /// Excel counts days from 30 December 1899, in local time.
    static func serial(_ date: Date) -> Double {
        let c = Value.gregorian.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let local = utc.date(from: c) ?? date
        let base = utc.date(from: DateComponents(year: 1899, month: 12, day: 30))!
        return (local.timeIntervalSince(base) / 86_400 * 1_000_000).rounded() / 1_000_000
    }

    static func date(fromSerial serial: Double) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let base = utc.date(from: DateComponents(year: 1899, month: 12, day: 30))!
        let moment = base.addingTimeInterval((serial * 86_400).rounded())
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: moment)
        return Value.gregorian.date(from: c) ?? moment
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\n", "\t", "\r": out.unicodeScalars.append(scalar)
            default:
                // Control characters aren't allowed in XML.
                if scalar.value >= 0x20 { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }

    // MARK: Reading

    /// The first sheet as rows of text: numbers plain, dates as yyyy-mm-dd (with time when there is one).
    static func read(_ url: URL) throws -> [[String]] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("golle-xlsx-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try run("/usr/bin/unzip", ["-qq", "-o", url.path, "-d", folder.path], in: folder)
        func xml(_ path: String) -> SheetNode? {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(path)) else { return nil }
            return XMLTree.parse(data)
        }
        guard let workbook = xml("xl/workbook.xml") else { throw Failure(errorDescription: "This is not an Excel workbook.") }
        // The first sheet's file, through the workbook's relationships.
        var sheetPath = "xl/worksheets/sheet1.xml"
        if let first = workbook.all("sheet").first, let rid = first.attributes["r:id"],
           let rels = xml("xl/_rels/workbook.xml.rels"),
           let target = rels.all("Relationship").first(where: { $0.attributes["Id"] == rid })?.attributes["Target"] {
            sheetPath = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
        }
        guard let sheet = xml(sheetPath) else { throw Failure(errorDescription: "The workbook has no sheet Golle can read.") }
        let shared = xml("xl/sharedStrings.xml")?.all("si").map(richText) ?? []
        let styles = self.timeStyles(xml("xl/styles.xml"))
        // Workbooks from older Mac Excel count days from 1904.
        let offset = ["1", "true"].contains(workbook.first("workbookPr")?.attributes["date1904"] ?? "") ? 1462.0 : 0

        var rows: [[String]] = []
        for row in sheet.all("row") {
            var cells: [String] = []
            for (position, cell) in row.children.filter({ $0.name == "c" }).enumerated() {
                let index = cell.attributes["r"].map(columnIndex) ?? position
                while cells.count < index { cells.append("") }
                let raw = cell.first("v")?.text ?? ""
                let text: String
                switch cell.attributes["t"] {
                case "s": text = Int(raw).flatMap { shared.indices.contains($0) ? shared[$0] : nil } ?? ""
                case "inlineStr": text = cell.first("is").map(richText) ?? ""
                case "b": text = raw == "1" ? "Yes" : "No"
                case "str", "e": text = raw
                default:
                    let kind = cell.attributes["s"].flatMap(Int.init).flatMap { styles[$0] }
                    if let kind, let n = Double(raw), n.isFinite {
                        switch kind {
                        case .date:
                            let date = date(fromSerial: n + offset)
                            // Local time, written without a zone, which is how it is read back.
                            text = n == n.rounded() ? date.formatted(Value.isoDay) : localDateTime.string(from: date)
                        case .time:
                            // A time of day, without the date Excel keeps under it (30 Dec 1899).
                            let seconds = Int(((n - n.rounded(.down)) * 86_400).rounded()) % 86_400
                            text = seconds % 60 == 0
                                ? String(format: "%02d:%02d", seconds / 3600, seconds / 60 % 60)
                                : String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
                        case .duration:
                            // Elapsed time ([h]:mm): hours that go past 24.
                            let seconds = Int((abs(n) * 86_400).rounded())
                            text = (n < 0 ? "-" : "") + String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
                        }
                    } else {
                        text = Double(raw).map(Value.plain) ?? raw
                    }
                }
                if cells.count == index { cells.append(text) } else { cells[index] = text }
            }
            rows.append(cells)
        }
        // Trailing empty rows are left out.
        while let last = rows.last, last.allSatisfy({ $0.isEmpty }) { rows.removeLast() }
        return rows
    }

    private static let localDateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    /// The text of a string item, without the reading hints (`rPh`) Excel adds to Japanese text.
    private static func richText(_ item: SheetNode) -> String {
        item.children.map { child in
            switch child.name {
            case "t": child.text
            case "r": child.children.filter { $0.name == "t" }.map(\.text).joined()
            default: ""
            }
        }.joined()
    }

    enum TimeKind { case date, time, duration }

    /// Cell styles that show dates or elapsed times, by index.
    private static func timeStyles(_ styles: SheetNode?) -> [Int: TimeKind] {
        guard let styles else { return [:] }
        var custom: [Int: String] = [:]
        for format in styles.all("numFmt") {
            if let id = format.attributes["numFmtId"].flatMap(Int.init) { custom[id] = format.attributes["formatCode"] ?? "" }
        }
        // 14–17 and 22: dates; 18–21: times of day; 45–47: mm:ss, [h]:mm:ss and mm:ss.0, which
        // are durations; 27–36 and 50–58: the East Asian date formats.
        let builtInDates = Set([14, 15, 16, 17, 22]).union(27...36).union(50...58)
        let builtInTimes = Set(18...21), builtInDurations = Set(45...47)
        guard let xfs = styles.first("cellXfs") else { return [:] }
        var result: [Int: TimeKind] = [:]
        for (index, xf) in xfs.children.filter({ $0.name == "xf" }).enumerated() {
            guard let id = xf.attributes["numFmtId"].flatMap(Int.init) else { continue }
            if builtInDates.contains(id) { result[index] = .date; continue }
            if builtInDurations.contains(id) { result[index] = .duration; continue }
            if builtInTimes.contains(id) { result[index] = .time; continue }
            if let code = custom[id]?.lowercased() {
                let unquoted = code.replacingOccurrences(of: "\"[^\"]*\"", with: "", options: .regularExpression)
                // [h], [m] or [s]: elapsed time.
                if unquoted.range(of: #"\[(h+|m+|s+)\]"#, options: .regularExpression) != nil { result[index] = .duration; continue }
                // Colours and conditions aside, d/m/y means a date.
                let bare = unquoted.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
                if bare.contains("d") || bare.contains("y") { result[index] = .date }
                else if bare.contains("h") || bare.contains("s") { result[index] = .time }
                else if bare.contains("m") && !bare.contains("0") { result[index] = .date }
            }
        }
        return result
    }

    private static func run(_ tool: String, _ arguments: [String], in folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(errorDescription: "\((tool as NSString).lastPathComponent) failed (\(process.terminationStatus)).")
        }
    }
}

/// A minimal XML tree, enough for spreadsheet files.
final class SheetNode {
    let name: String
    let attributes: [String: String]
    var children: [SheetNode] = []
    var text = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    func first(_ name: String) -> SheetNode? {
        for child in children {
            if child.name == name { return child }
            if let found = child.first(name) { return found }
        }
        return nil
    }

    func all(_ name: String) -> [SheetNode] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.all(name) }
    }
}

enum XMLTree {
    static func parse(_ data: Data) -> SheetNode? {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        return parser.parse() ? builder.root : nil
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: SheetNode?
        var stack: [SheetNode] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            // Spreadsheet files sometimes prefix every tag ("x:row"); keep the local name.
            let local = name.split(separator: ":").last.map(String.init) ?? name
            let element = SheetNode(name: local, attributes: attributes)
            stack.last?.children.append(element)
            if root == nil { root = element }
            stack.append(element)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            stack.removeLast()
        }
    }
}

extension Exporter {
    /// The records as an Excel sheet, with numbers, dates and checkboxes as real Excel values.
    static func xlsx(_ records: [Record], resolver: Resolver) throws -> Data {
        let fields = resolver.table.fields
        var rows: [[XLSX.Cell]] = [fields.map { .text($0.name) }]
        for record in records {
            rows.append(fields.map { field in
                let value = resolver.value(record, field)
                switch (field.type, value) {
                case (_, nil): return .empty
                case (.duration, .number(let n)?): return n.isFinite ? .duration(n) : .empty
                case (.rollup, .number(let n)?) where Self.rollupShowsDuration(field, resolver):
                    return n.isFinite ? .duration(n) : .empty
                case (.lookup, .number(let n)?) where resolver.formatField(field).type == .duration:
                    return n.isFinite ? .duration(n) : .empty
                case (_, .number(let n)?): return n.isFinite ? .number(n) : .empty
                case (_, .rating(let r)?): return .number(Double(r))
                // Date fields without a time show the day only, so that is what Excel gets; the others
                // (and created and modified) keep the time.
                case (.date, .date(let d)?) where !field.options.includesTime: return .date(Calendar.current.startOfDay(for: d))
                case (_, .date(let d)?): return .dateTime(d)
                case (_, .bool(let b)?): return .bool(b)
                default:
                    let text = field.type == .formula || field.type == .rollup ? (value?.plainText ?? "") : resolver.text(record, field)
                    return text.isEmpty ? .empty : .text(text)
                }
            })
        }
        return try XLSX.write(rows, sheetName: resolver.table.name)
    }
}
