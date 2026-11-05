import Foundation

/// The kinds of field a table can have. The raw value is what the file stores, so never rename one.
enum FieldType: String, CaseIterable, Identifiable, Codable {
    case text, longText, number, date, checkbox, choice, multiChoice, rating, url, image, file, link, formula
    case location, autoNumber, createdAt, modifiedAt, checklist
    case duration, email, phone, rollup, progress, barcode, color
    case lookup

    var id: String { rawValue }

    var label: String {
        switch self {
        case .text: "Text"
        case .longText: "Long Text"
        case .number: "Number"
        case .date: "Date"
        case .checkbox: "Checkbox"
        case .choice: "Choice"
        case .multiChoice: "Multiple Choice"
        case .rating: "Rating"
        case .url: "Web Link"
        case .image: "Image"
        case .file: "File"
        case .link: "Linked Records"
        case .formula: "Formula"
        case .location: "Location"
        case .autoNumber: "Auto Number"
        case .createdAt: "Created"
        case .modifiedAt: "Modified"
        case .checklist: "Checklist"
        case .duration: "Duration"
        case .email: "Email"
        case .phone: "Phone"
        case .rollup: "Rollup"
        case .lookup: "Lookup"
        case .progress: "Progress"
        case .barcode: "Barcode / ISBN"
        case .color: "Colour"
        }
    }

    var symbol: String {
        switch self {
        case .text: "textformat"
        case .longText: "text.alignleft"
        case .number: "number"
        case .date: "calendar"
        case .checkbox: "checkmark.square"
        case .choice: "list.bullet.circle"
        case .multiChoice: "checklist"
        case .rating: "star"
        case .url: "link"
        case .image: "photo"
        case .file: "paperclip"
        case .link: "arrow.left.arrow.right"
        case .formula: "function"
        case .location: "mappin.and.ellipse"
        case .autoNumber: "number.circle"
        case .createdAt: "calendar.badge.plus"
        case .modifiedAt: "calendar.badge.clock"
        case .checklist: "checklist.checked"
        case .duration: "timer"
        case .email: "envelope"
        case .phone: "phone"
        case .rollup: "sum"
        case .lookup: "arrow.turn.down.right"
        case .progress: "chart.bar.fill"
        case .barcode: "barcode"
        case .color: "paintpalette"
        }
    }

    var usesChoices: Bool { self == .choice || self == .multiChoice }
    var isAttachment: Bool { self == .image || self == .file }
    /// Fields whose values are calculated, not typed in.
    var isComputed: Bool { self == .formula || self == .rollup || self == .lookup || self == .createdAt || self == .modifiedAt }
    /// Filled in by Golle, not typed: computed values and auto numbers.
    var isAutomatic: Bool { isComputed || self == .autoNumber }
    /// Holds dates, for filters, calendars and grouping.
    var isDate: Bool { self == .date || self == .createdAt || self == .modifiedAt }
    /// Holds numbers, for filters and totals.
    var isNumeric: Bool { [.number, .rating, .autoNumber, .duration, .progress].contains(self) }
    /// Holds text the user types (one line).
    var isTextLike: Bool { [.text, .url, .email, .phone, .barcode].contains(self) }
    /// Whether a record can be required to have a value. (Computed and automatic fields fill
    /// themselves; an unchecked checkbox is an answer too.)
    var canBeRequired: Bool { !isAutomatic && self != .checkbox }
    /// Whether values can be required to differ between records.
    var canBeUnique: Bool { isTextLike || [.number, .date, .duration, .formula, .lookup].contains(self) }
    /// Types grouped for the "Add Field" menu.
    static let groups: [[FieldType]] = [
        [.text, .longText, .number, .duration, .date, .checkbox],
        [.choice, .multiChoice, .rating, .progress, .checklist],
        [.email, .phone, .url, .barcode, .color],
        [.image, .file, .location],
        [.link, .lookup, .rollup, .formula],
        [.autoNumber, .createdAt, .modifiedAt],
    ]
}

/// One line of a checklist field.
struct CheckItem: Codable, Hashable, Identifiable {
    var id = UUID()
    var text: String
    var done = false
}

/// A place: a name or address, and its coordinates once found on the map.
struct Place: Codable, Hashable {
    var name: String
    var latitude: Double?
    var longitude: Double?

    var hasCoordinates: Bool { latitude != nil && longitude != nil }
}

/// How a number field shows its values. The stored value is always the plain number.
struct NumberFormat: Codable, Hashable {
    enum Style: String, Codable, CaseIterable, Identifiable {
        case plain, grouped, currency, percent
        var id: String { rawValue }
        var label: String {
            switch self {
            case .plain: "Plain (1234.5)"
            case .grouped: "Thousands (1,234.5)"
            case .currency: "Currency"
            case .percent: "Percent (25 → 25%)"
            }
        }
    }

    var style = Style.plain
    /// Fixed number of decimals; nil shows as many as the value has.
    var decimals: Int?
    var currency = Preferences.currency
    var prefix = ""
    var suffix = ""

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = (try? c.decodeIfPresent(Style.self, forKey: .style)) ?? .plain
        decimals = try c.decodeIfPresent(Int.self, forKey: .decimals)
        currency = try c.decodeIfPresent(String.self, forKey: .currency) ?? Preferences.currency
        prefix = try c.decodeIfPresent(String.self, forKey: .prefix) ?? ""
        suffix = try c.decodeIfPresent(String.self, forKey: .suffix) ?? ""
    }

    func format(_ n: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = style == .currency ? .currency : .decimal
        f.usesGroupingSeparator = style == .grouped || style == .currency
        if style == .currency { f.currencyCode = currency }
        if let decimals {
            f.minimumFractionDigits = decimals
            f.maximumFractionDigits = decimals
        } else {
            f.minimumFractionDigits = style == .currency ? 2 : 0
            f.maximumFractionDigits = style == .currency ? 2 : 6
        }
        let body = f.string(from: n as NSNumber) ?? String(n)
        let percent = style == .percent ? "%" : ""
        let suffix = self.suffix.isEmpty ? "" : (self.suffix.first?.isLetter == true ? " " : "") + self.suffix
        return prefix + body + percent + suffix
    }
}

/// A file kept in the document package, under `Attachments/<id>.<extension>`.
struct Attachment: Codable, Hashable, Identifiable {
    var id = UUID()
    /// The original file name, shown to the user.
    var name: String

    var fileName: String {
        let ext = (name as NSString).pathExtension.lowercased()
        return ext.isEmpty ? id.uuidString : "\(id.uuidString).\(ext)"
    }

    var isImage: Bool {
        ["png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp"].contains((name as NSString).pathExtension.lowercased())
    }
}

/// One cell. Which case a field holds follows from its type; `converted(to:)` handles type changes.
enum Value: Equatable, Hashable {
    case text(String)
    case number(Double)
    case date(Date)
    case bool(Bool)
    case choices([String])
    case rating(Int)
    case attachments([Attachment])
    /// Records in another table (or this one), by id.
    case links([UUID])
    case location(Place)
    case checklist([CheckItem])

    static let maxRating = 5

    var isEmpty: Bool {
        switch self {
        case .text(let s): s.isEmpty
        case .choices(let c): c.isEmpty
        case .bool(let b): !b
        case .rating(let r): r <= 0
        case .attachments(let a): a.isEmpty
        case .links(let l): l.isEmpty
        case .number(let n): n.isNaN
        case .location(let p): p.name.isEmpty && !p.hasCoordinates
        case .checklist(let items): items.isEmpty
        case .date: false
        }
    }

    var text: String? { if case .text(let s) = self { s } else { nil } }
    var number: Double? { if case .number(let n) = self { n } else { nil } }
    var date: Date? { if case .date(let d) = self { d } else { nil } }
    var bool: Bool { if case .bool(let b) = self { b } else { false } }
    var choices: [String] { if case .choices(let c) = self { c } else { [] } }
    var rating: Int { if case .rating(let r) = self { r } else { 0 } }
    var attachments: [Attachment] { if case .attachments(let a) = self { a } else { [] } }
    var links: [UUID] { if case .links(let l) = self { l } else { [] } }
    var place: Place? { if case .location(let p) = self { p } else { nil } }
    var checkItems: [CheckItem] { if case .checklist(let c) = self { c } else { [] } }

    /// Text shown in tables. Linked records need the database for their names: use `Resolver.text`.
    func display(for field: Field) -> String {
        switch self {
        case .text(let s): s
        case .number(let n):
            switch field.type {
            case .duration: Self.formatDuration(n, field.options.durationStyle)
            case .progress: (Self.numberFormatter.string(from: n as NSNumber) ?? String(n)) + "%"
            default: field.options.numberFormat?.format(n) ?? Self.numberFormatter.string(from: n as NSNumber) ?? String(n)
            }
        case .date(let d):
            field.type == .createdAt || field.type == .modifiedAt || field.options.includesTime
                ? d.formatted(date: .abbreviated, time: .shortened)
                : d.formatted(date: .abbreviated, time: .omitted)
        case .bool(let b): b ? "Yes" : "No"
        case .choices(let c): c.joined(separator: ", ")
        case .rating(let r): String(repeating: "★", count: r)
        case .attachments(let a): a.map(\.name).joined(separator: ", ")
        case .links(let l): l.count == 1 ? "1 record" : "\(l.count) records"
        case .location(let p): p.name.isEmpty ? Self.coordinates(p) : p.name
        case .checklist(let items): "\(items.filter(\.done).count)/\(items.count) done"
        }
    }

    static func coordinates(_ p: Place) -> String {
        guard let lat = p.latitude, let lon = p.longitude else { return "" }
        return String(format: "%.5f, %.5f", lat, lon)
    }

    /// The value as the given field type would hold it, or nil when nothing sensible carries over.
    func converted(to type: FieldType) -> Value? {
        let plain = plainText
        let result: Value?
        switch type {
        case .text, .longText, .url, .email, .phone:
            if case .links = self { result = nil } else { result = .text(plain) }
        case .barcode:
            // Digits (and an ISBN-10's final X); spaces and dashes are how people write them.
            let code = Self.cleanBarcode(plain)
            result = code.isEmpty ? nil : .text(code)
        case .color:
            result = Self.parseColor(plain).map(Value.text)
        case .duration:
            switch self {
            // A plain number counts minutes, as when it is typed.
            case .number(let n): result = n.isFinite && n >= 0 ? .number((n * 60).rounded()) : nil
            default: result = Self.parseDuration(plain, .hoursMinutesSeconds).map(Value.number)
            }
        case .progress:
            let n: Double? = if case .number(let n) = self { n } else { Self.parseNumber(plain) }
            result = n.flatMap { $0.isFinite ? .number(min(max($0, 0), 100)) : nil }
        case .location:
            if case .location = self { result = self } else { result = plain.isEmpty ? nil : .location(Place(name: plain)) }
        case .autoNumber:
            switch self {
            case .number(let n): result = .number(n.rounded())
            default: result = Self.parseNumber(plain).map { .number($0.rounded()) }
            }
        case .number:
            switch self {
            case .number: result = self
            case .bool(let b): result = .number(b ? 1 : 0)
            case .rating(let r): result = .number(Double(r))
            default: result = Self.parseNumber(plain).map(Value.number)
            }
        case .date:
            switch self {
            case .date: result = self
            default: result = Self.parseDate(plain).map(Value.date)
            }
        case .checkbox:
            switch self {
            case .bool: result = self
            case .number(let n): result = .bool(n != 0)
            default: result = .bool(["yes", "true", "1", "x", "✓", "y", "ja", "on"].contains(plain.lowercased().trimmingCharacters(in: .whitespaces)))
            }
        case .choice:
            result = plain.isEmpty ? nil : .choices([self.choices.first ?? plain])
        case .multiChoice:
            if case .choices = self { result = self }
            else { result = .choices(plain.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }) }
        case .rating:
            switch self {
            case .rating: result = self
            case .number(let n): result = n.isFinite ? .rating(Int(min(max(n.rounded(), 0), Double(Self.maxRating)))) : nil
            default:
                let stars = plain.filter { $0 == "★" }.count
                result = stars > 0 ? .rating(min(stars, Self.maxRating)) : Self.parseNumber(plain).map { .rating(Int(min(max($0.rounded(), 0), Double(Self.maxRating)))) }
            }
        case .image, .file:
            if case .attachments = self { result = self } else { result = nil }
        case .link:
            if case .links = self { result = self } else { result = nil }
        case .checklist:
            if case .checklist = self { result = self }
            else {
                result = .checklist(plain.split(whereSeparator: \.isNewline).map { line in
                    let text = line.trimmingCharacters(in: .whitespaces)
                    let done = text.hasPrefix("[x]") || text.hasPrefix("[X]") || text.hasPrefix("✓")
                    let clean = text.replacingOccurrences(of: #"^(\[[ xX]\]|✓|-)\s*"#, with: "", options: .regularExpression)
                    return CheckItem(text: clean, done: done)
                }.filter { !$0.text.isEmpty })
            }
        case .formula, .rollup, .lookup, .createdAt, .modifiedAt:
            result = nil
        }
        return result?.isEmpty == true ? nil : result
    }

    /// Text without display formatting: numbers unformatted, dates in ISO form.
    var plainText: String {
        switch self {
        case .text(let s): s
        case .number(let n): Self.plain(n)
        case .date(let d): d.formatted(Value.isoDay)
        case .bool(let b): b ? "Yes" : "No"
        case .choices(let c): c.joined(separator: ", ")
        case .rating(let r): String(r)
        case .attachments(let a): a.map(\.name).joined(separator: ", ")
        case .links: ""
        case .location(let p): p.name.isEmpty ? Self.coordinates(p) : p.name
        case .checklist(let items): items.map { ($0.done ? "[x] " : "[ ] ") + $0.text }.joined(separator: "\n")
        }
    }

    /// The decimal mark a file being read uses, when it is known: a semicolon CSV writes "1,250" for
    /// one and a quarter. nil leaves it to this Mac's region.
    @TaskLocal static var decimalSeparator: String?

    static func plain(_ n: Double) -> String {
        n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
    }

    /// A number from text as people type it: "12.5", "1.250,50", "€ 12,50", "$1,200", "12 kg", "25%".
    /// Codes, times and phone numbers ("A1", "12:30", "+31 6 1234") are not numbers, and neither are
    /// infinity or NaN.
    static func parseNumber(_ text: String) -> Double? {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        // Plain numbers ("12", "-3.5", "1e6"); but "1.250" is ambiguous and goes the long way, so it
        // reads the same as "€ 1.250" does.
        if t.range(of: #"^[-+]?0[xX]"#, options: .regularExpression) != nil { return nil }
        if let n = Double(t),
           t.range(of: #"^[-+]?\d{1,3}\.\d{3}$"#, options: .regularExpression) == nil { return n.isFinite ? n : nil }
        // A currency sign before or after, a unit or percent sign after.
        let currency: Set<Character> = ["€", "$", "£", "¥", "₹", "₽", "¢"]
        while let first = t.first, currency.contains(first) { t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces) }
        while let last = t.last, currency.contains(last) { t = String(t.dropLast()).trimmingCharacters(in: .whitespaces) }
        if let unit = t.range(of: #"(?<=\d)\s*([A-Za-z]{1,5}|%)$"#, options: .regularExpression) { t = String(t[..<unit.lowerBound]) }
        var sign = 1.0
        if t.hasPrefix("-") || t.hasPrefix("−") { sign = -1; t.removeFirst() } else if t.hasPrefix("+") { t.removeFirst() }
        // Digits with optional thousands groups and decimals.
        guard t.range(of: #"^(\d{1,3}([.,' ]\d{3})+|\d+)([.,]\d+)?$"#, options: .regularExpression) != nil else { return nil }
        let dots = t.filter { $0 == "." }.count, commas = t.filter { $0 == "," }.count
        var decimal: Character?
        if dots > 0 && commas > 0 {
            decimal = t.lastIndex(of: ".")! > t.lastIndex(of: ",")! ? "." : ","
        } else if dots + commas == 1 {
            let sep: Character = dots == 1 ? "." : ","
            let parts = t.split(separator: sep, omittingEmptySubsequences: false)
            let before = parts.first ?? "", after = parts.last?.count ?? 0
            // "1.250" is ambiguous: the locale decides; "1.25" or "1,5" is a decimal, and so are
            // "0,125" and "1234,567" (no thousands group starts with 0 or has four digits).
            if after == 3, !before.hasPrefix("0"), before.count <= 3 {
                decimal = String(sep) == (Value.decimalSeparator ?? Locale.current.decimalSeparator ?? ".") ? sep : nil
            } else { decimal = sep }
        } else if dots + commas > 1 {
            // Only thousands groups ("1.250.000"); "1.250.5" is not a number.
            let sep: Character = dots > 0 ? "." : ","
            guard t.split(separator: sep, omittingEmptySubsequences: false).dropFirst().allSatisfy({ (group: Substring) in group.count == 3 }) else { return nil }
            decimal = nil
        }
        var plain = ""
        for c in t where c.isNumber || c == decimal { plain.append(c == decimal ? "." : c) }
        guard let n = Double(plain), n.isFinite else { return nil }
        return sign * n
    }

    // MARK: Durations, colours, barcodes

    /// A duration in seconds from text: "1:02:30", "45:12" (or "1:30" as hours and minutes, in that
    /// style), "1h 30m", "90 min", "2 uur", or a plain number (minutes; hours in the hours style).
    static func parseDuration(_ text: String, _ style: DurationStyle) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty, !t.hasPrefix("-") else { return nil }
        // Clock style.
        let parts = t.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2 || parts.count == 3 {
            let numbers = parts.map { Double($0.replacingOccurrences(of: ",", with: ".")) }
            guard numbers.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
            let n = numbers.map { $0! }
            // Every part after the first is under 60.
            guard n.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
            if n.count == 3 { return n[0] * 3600 + n[1] * 60 + n[2] }
            return style == .hoursMinutes ? n[0] * 3600 + n[1] * 60 : n[0] * 60 + n[1]
        }
        // Units: "1h 30m 10s", "90 min", "2 hours", "1,5 uur".
        let pattern = #"(\d+(?:[.,]\d+)?)\s*(h|hr|hrs|hour|hours|u|uur|m|min|mins|minute|minutes|minuut|minuten|s|sec|secs|second|seconds|seconde|seconden)\b"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let ns = t as NSString
            let matches = regex.matches(in: t, range: NSRange(location: 0, length: ns.length))
            let covered = matches.reduce(0) { $0 + $1.range.length }
            if !matches.isEmpty, covered >= ns.replacingOccurrences(of: " ", with: "").count - matches.count {
                var total = 0.0
                for m in matches {
                    guard let value = Double(ns.substring(with: m.range(at: 1)).replacingOccurrences(of: ",", with: ".")) else { return nil }
                    let unit = ns.substring(with: m.range(at: 2))
                    total += value * (unit.hasPrefix("h") || unit.hasPrefix("u") ? 3600 : unit.hasPrefix("m") ? 60 : 1)
                }
                return total
            }
        }
        guard let n = parseNumber(t), n >= 0 else { return nil }
        return n * (style == .hoursMinutes ? 3600 : 60)
    }

    /// "1:02:30" or "45:12" (minutes and seconds style), "1:30" (hours and minutes style).
    static func formatDuration(_ seconds: Double, _ style: DurationStyle) -> String {
        guard seconds.isFinite else { return "" }
        let sign = seconds < 0 ? "-" : ""
        switch style {
        case .hoursMinutes:
            let minutes = Int((abs(seconds) / 60).rounded())
            return sign + String(format: "%d:%02d", minutes / 60, minutes % 60)
        case .hoursMinutesSeconds:
            let total = Int(abs(seconds).rounded())
            let h = total / 3600, m = total / 60 % 60, s = total % 60
            return sign + (h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s))
        }
    }

    /// A colour as "#RRGGBB" from "#abc", "#AABBCC", "aabbcc" or "rgb(10, 20, 30)".
    static func parseColor(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("rgb") {
            let numbers = t.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard numbers.count >= 3, numbers.prefix(3).allSatisfy({ (0...255).contains($0) }) else { return nil }
            return String(format: "#%02X%02X%02X", numbers[0], numbers[1], numbers[2])
        }
        if t.hasPrefix("#") { t.removeFirst() }
        guard t.allSatisfy(\.isHexDigit), t.count == 3 || t.count == 6 else { return nil }
        if t.count == 3 { t = t.map { "\($0)\($0)" }.joined() }
        return "#" + t.uppercased()
    }

    /// A code without the spaces and dashes people write in it ("978-90-..." → "97890...").
    static func cleanBarcode(_ text: String) -> String {
        String(text.uppercased().filter { $0.isASCII && ($0.isNumber || $0.isLetter) })
    }

    /// Whether a barcode's check digit is right: EAN-13 and ISBN-13, UPC-A, EAN-8 and ISBN-10.
    /// nil for other codes, which have no check digit to test.
    static func barcodeIsValid(_ code: String) -> Bool? {
        let c = code.uppercased()
        if c.count == 10, c.dropLast().allSatisfy(\.isNumber), c.last!.isNumber || c.last == "X" {
            let digits = c.map { $0 == "X" ? 10 : Int(String($0))! }
            return digits.enumerated().reduce(0) { $0 + $1.element * (10 - $1.offset) } % 11 == 0
        }
        guard [8, 12, 13].contains(c.count), c.allSatisfy(\.isNumber) else { return nil }
        let digits = c.map { Int(String($0))! }
        // From the right, the check digit has weight 1, then 3, 1, 3, ...
        let sum = digits.reversed().enumerated().reduce(0) { $0 + $1.element * ($1.offset % 2 == 0 ? 1 : 3) }
        return sum % 10 == 0
    }

    static func emailIsValid(_ text: String) -> Bool {
        text.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]{2,}$"#, options: .regularExpression) != nil
    }

    /// A phone number as a `tel:` link: digits, with a leading + kept.
    static func phoneURL(_ text: String) -> URL? {
        let digits = text.filter(\.isNumber)
        guard digits.count >= 3 else { return nil }
        return URL(string: "tel:" + (text.trimmingCharacters(in: .whitespaces).hasPrefix("+") ? "+" : "") + digits)
    }

    /// The order of day, month and year in numeric dates.
    enum DateOrder { case dayMonthYear, monthDayYear }

    /// How this Mac writes dates (day first in most of the world, month first in the US).
    static let localeDateOrder: DateOrder = {
        let format = DateFormatter.dateFormat(fromTemplate: "dMy", options: 0, locale: .current) ?? "d/M/y"
        let d = format.firstIndex(of: "d"), m = format.firstIndex(of: "M")
        return (d != nil && m != nil && m! < d!) ? .monthDayYear : .dayMonthYear
    }()

    /// The numeric parts of a date like "05-03-2024", "3/14/24" or "2024-03-05", if it is one. A year
    /// comes first with four digits, or last with two or four ("1.2.3" is a version, not a date).
    static func dateParts(_ text: String) -> [Int]? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.allSatisfy({ $0.isASCII && ($0.isNumber || "-/.".contains($0)) }) else { return nil }
        let pieces = trimmed.split(separator: "-", omittingEmptySubsequences: false).flatMap { $0.split(separator: "/", omittingEmptySubsequences: false) }
            .flatMap { $0.split(separator: ".", omittingEmptySubsequences: false) }
        guard pieces.count == 3, pieces.allSatisfy({ !$0.isEmpty }) else { return nil }
        let lengths = pieces.map(\.count)
        let yearFirst = lengths[0] == 4 && lengths[1] <= 2 && lengths[2] <= 2
        let yearLast = lengths[0] <= 2 && lengths[1] <= 2 && (lengths[2] == 2 || lengths[2] == 4)
        guard yearFirst || yearLast else { return nil }
        let parts = pieces.compactMap { Int($0) }
        return parts.count == 3 ? parts : nil
    }

    /// A date followed by a time ("05/03/2024 14:30", "2024-03-05T14:30:00"): the date part and the
    /// hour, minute and second.
    static func splitTime(_ text: String) -> (date: String, time: (Int, Int, Int)?) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let ns = trimmed as NSString
        guard let match = timePattern.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) else { return (trimmed, nil) }
        func group(_ i: Int) -> String? {
            let r = match.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        guard let date = group(1), let h = group(2).flatMap({ Int($0) }), let m = group(3).flatMap({ Int($0) }) else { return (trimmed, nil) }
        let sec = group(4).flatMap { Int($0) } ?? 0
        guard h < 24, m < 60, sec < 60 else { return (trimmed, nil) }
        return (date, (h, m, sec))
    }

    private static let timePattern = try! NSRegularExpression(pattern: #"^(.+?)[ T](\d{1,2}):(\d{2})(?::(\d{2}))?$"#)

    /// Dates are read and written in the Gregorian calendar (files, Excel and formulas use its
    /// years), whatever calendar this Mac shows.
    static var gregorian: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    /// A date from text. `order` settles "03/04/2024": day first or month first (an import decides it
    /// per column); without it, a part above 12 decides, else this Mac's own order. Impossible dates
    /// like 31 February are refused.
    static func parseDate(_ text: String, order: DateOrder? = nil) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        // Numeric dates, with or without a time of day (local time).
        let (datePart, time) = splitTime(trimmed)
        // A date with a time that can't be ("25:00") is no date; it mustn't become noon.
        if time == nil, let match = timePattern.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)),
           dateParts((trimmed as NSString).substring(with: match.range(at: 1))) != nil { return nil }
        if let parts = dateParts(datePart) {
            var y: Int, m: Int, d: Int
            if String(parts[0]).count == 4 || datePart.prefix(4).allSatisfy(\.isNumber) {
                (y, m, d) = (parts[0], parts[1], parts[2])
            } else {
                let chosen = order ?? (parts[0] > 12 ? .dayMonthYear : parts[1] > 12 ? .monthDayYear : localeDateOrder)
                (y, m, d) = chosen == .dayMonthYear ? (parts[2], parts[1], parts[0]) : (parts[2], parts[0], parts[1])
            }
            if y < 100 { y += y < 50 ? 2000 : 1900 }
            let calendar = gregorian
            let (h, mi, sec) = time ?? (0, 0, 0)
            guard (1...12).contains(m), (1...31).contains(d),
                  let date = calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi, second: sec)),
                  calendar.component(.day, from: date) == d, calendar.component(.month, from: date) == m else { return nil }
            return date
        }
        // With a time zone ("2024-03-05T14:30:00Z"): that zone.
        if let d = try? Date(trimmed, strategy: .iso8601) { return d }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        guard let match = detector?.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              match.range.length * 2 >= (trimmed as NSString).length else { return nil }
        return match.date
    }

    /// yyyy-mm-dd in the local time zone. (The plain ISO style uses UTC, which shifts dates near midnight.)
    static let isoDay = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()

    static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 6
        // Number fields hold years and ids as often as amounts, and "1.959" for 1959 reads wrong.
        f.usesGroupingSeparator = false
        return f
    }()
}
