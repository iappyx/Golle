import Foundation

/// Looking up a scanned barcode: books by ISBN at Open Library, albums by barcode at MusicBrainz.
/// Both are free and need no account. Only the code is sent.
struct LookupResult: Identifiable, Equatable {
    enum Kind { case book, music }

    let id = UUID()
    var kind: Kind
    var code: String
    var title: String
    var creators: [String] = []
    var year: Int?
    var date: Date?
    var publisher: String?
    var pages: Int?
    var format: String?
    var tracks: Int?
    var genres: [String] = []
    var coverURL: URL?
    var source: String

    var subtitle: String {
        ([creators.joined(separator: ", ")] + [year.map(String.init), format, publisher].compactMap { $0 })
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Online lookups are turned off in Settings.
struct OfflineError: LocalizedError {
    var errorDescription: String? { "Online lookups are off in Golle ▸ Settings ▸ Privacy." }
}

enum Lookup {
    /// MusicBrainz asks every client to name itself, its version and where to find it.
    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "Golle/\(version) (https://github.com/iappyx/Golle)"
    }()

    /// Digits only, keeping a final X of an ISBN-10.
    static func clean(_ code: String) -> String {
        let upper = code.uppercased()
        return String(upper.enumerated().filter { $0.element.isNumber || ($0.element == "X" && $0.offset == upper.count - 1) }.map(\.element))
    }

    static func isISBN(_ code: String) -> Bool {
        let c = clean(code)
        if c.count == 13, c.hasPrefix("978") || c.hasPrefix("979") { return checksum13(c) }
        if c.count == 10 { return checksum10(c) }
        return false
    }

    static func checksum13(_ c: String) -> Bool {
        let digits = c.compactMap(\.wholeNumberValue)
        guard digits.count == 13 else { return false }
        let sum = digits.enumerated().reduce(0) { $0 + $1.element * ($1.offset % 2 == 0 ? 1 : 3) }
        return sum % 10 == 0
    }

    static func checksum10(_ c: String) -> Bool {
        let values = c.map { $0 == "X" ? 10 : ($0.wholeNumberValue ?? -100) }
        guard values.count == 10, values.allSatisfy({ $0 >= 0 }) else { return false }
        return values.enumerated().reduce(0) { $0 + $1.element * (10 - $1.offset) } % 11 == 0
    }

    /// Books first for ISBNs, music otherwise; falls back to the other source when nothing is found.
    static func find(_ code: String) async throws -> [LookupResult] {
        guard Preferences.onlineLookups else { throw OfflineError() }
        let c = clean(code)
        guard c.count >= 8 else { return [] }
        if isISBN(c) {
            let books = try await openLibrary(c)
            return books.isEmpty ? try await musicBrainz(c) : books
        }
        let music = try await musicBrainz(c)
        return music.isEmpty ? try await openLibrary(c) : music
    }

    private static func get(_ url: URL) async throws -> Any {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [:] }
        return try JSONSerialization.jsonObject(with: data)
    }

    static func openLibrary(_ isbn: String) async throws -> [LookupResult] {
        var components = URLComponents(string: "https://openlibrary.org/search.json")!
        components.queryItems = [
            URLQueryItem(name: "isbn", value: isbn),
            URLQueryItem(name: "fields", value: "title,subtitle,author_name,first_publish_year,publisher,number_of_pages_median,cover_i,subject"),
            URLQueryItem(name: "limit", value: "3"),
        ]
        let json = try await get(components.url!) as? [String: Any]
        let docs = json?["docs"] as? [[String: Any]] ?? []
        return docs.compactMap { doc in
            guard let title = doc["title"] as? String else { return nil }
            let full = (doc["subtitle"] as? String).map { "\(title): \($0)" } ?? title
            return LookupResult(
                kind: .book, code: isbn, title: full,
                creators: doc["author_name"] as? [String] ?? [],
                year: doc["first_publish_year"] as? Int,
                publisher: (doc["publisher"] as? [String])?.first,
                pages: doc["number_of_pages_median"] as? Int,
                genres: Array((doc["subject"] as? [String] ?? []).prefix(5)),
                coverURL: (doc["cover_i"] as? Int).flatMap { URL(string: "https://covers.openlibrary.org/b/id/\($0)-L.jpg") },
                source: "Open Library")
        }
    }

    static func musicBrainz(_ barcode: String) async throws -> [LookupResult] {
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/release/")!
        components.queryItems = [
            URLQueryItem(name: "query", value: "barcode:\(barcode)"),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "5"),
        ]
        let json = try await get(components.url!) as? [String: Any]
        let releases = json?["releases"] as? [[String: Any]] ?? []
        let dateFormat = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
        return releases.compactMap { release in
            guard let id = release["id"] as? String, let title = release["title"] as? String else { return nil }
            let credits = (release["artist-credit"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            let dateText = release["date"] as? String ?? ""
            let media = release["media"] as? [[String: Any]] ?? []
            let labels = (release["label-info"] as? [[String: Any]] ?? []).compactMap { ($0["label"] as? [String: Any])?["name"] as? String }
            return LookupResult(
                kind: .music, code: barcode, title: title, creators: credits,
                year: Int(dateText.prefix(4)),
                date: dateText.count == 10 ? try? Date(dateText, strategy: dateFormat) : nil,
                publisher: labels.first,
                format: media.compactMap { $0["format"] as? String }.first,
                tracks: media.compactMap { $0["track-count"] as? Int }.reduce(0, +),
                coverURL: URL(string: "https://coverartarchive.org/release/\(id)/front-500"),
                source: "MusicBrainz")
        }
    }

    static func cover(_ url: URL?) async -> Data? {
        guard let url, Preferences.onlineLookups else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count > 1000 else { return nil }
        return data
    }
}

/// Puts a lookup result into a table's fields, matched by field name:
/// Title/Name, Author/Artist, Year, Released/Published, Publisher/Label, Pages, Tracks, Format,
/// Genre, ISBN/Barcode, and the first image field (preferring Cover) for the cover.
enum LookupFiller {
    private static let names: [String: [String]] = [
        "title": ["title", "name", "album", "book"],
        "creator": ["author", "authors", "artist", "artists", "writer", "band", "creator", "by", "composer"],
        "year": ["year", "released", "release year", "published", "publication year", "year published"],
        "date": ["release date", "released", "published", "publication date", "date"],
        "publisher": ["publisher", "label", "record label", "publisher/label"],
        "pages": ["pages", "page count", "number of pages"],
        "tracks": ["tracks", "track count", "number of tracks"],
        "format": ["format", "media", "medium"],
        "genre": ["genre", "genres", "subject", "subjects", "style", "tags"],
        "code": ["isbn", "barcode", "ean", "upc", "code", "isbn-13"],
        "cover": ["cover", "artwork", "image", "photo", "picture"],
    ]

    static func field(_ role: String, in table: DataTable, types: Set<FieldType>) -> Field? {
        for name in names[role] ?? [] {
            if let field = table.fields.first(where: { Duplicates.normalize($0.name) == name && types.contains($0.type) }) { return field }
        }
        return nil
    }

    /// The values for a record, and new records to add to linked tables (for an Author or Artist link).
    static func values(for result: LookupResult, in table: DataTable, database: Database, cover: Attachment?)
        -> (values: [Field.ID: Value], newLinked: [(table: DataTable.ID, record: Record)]) {
        var values: [Field.ID: Value] = [:]
        var newLinked: [(DataTable.ID, Record)] = []
        let textish: Set<FieldType> = [.text, .longText]

        if let field = field("title", in: table, types: textish) ?? table.titleField.flatMap({ textish.contains($0.type) ? $0 : nil }) {
            values[field.id] = .text(result.title)
        }
        if !result.creators.isEmpty, let field = field("creator", in: table, types: [.text, .longText, .link, .multiChoice, .choice]) {
            switch field.type {
            case .link:
                if let linked = database.table(field.options.linkedTableID), let titleField = linked.titleField {
                    var ids: [UUID] = []
                    for name in result.creators {
                        if let existing = linked.records.first(where: { Duplicates.normalize(linked.title(of: $0)) == Duplicates.normalize(name) }) {
                            ids.append(existing.id)
                        } else if let pending = newLinked.first(where: { $0.0 == linked.id && $0.1[titleField.id]?.text == name }) {
                            ids.append(pending.1.id)
                        } else {
                            var record = GolleDocument.newRecord(in: linked)
                            record[titleField.id] = .text(name)
                            newLinked.append((linked.id, record))
                            ids.append(record.id)
                        }
                    }
                    values[field.id] = .links(ids)
                }
            case .multiChoice: values[field.id] = .choices(result.creators)
            case .choice: values[field.id] = .choices([result.creators[0]])
            default: values[field.id] = .text(result.creators.joined(separator: ", "))
            }
        }
        if let year = result.year {
            if let field = field("year", in: table, types: [.number]) { values[field.id] = .number(Double(year)) }
            if let field = field("date", in: table, types: [.date]) {
                values[field.id] = .date(result.date ?? Value.gregorian.date(from: DateComponents(year: year, month: 1, day: 1))!)
            }
            if let field = field("year", in: table, types: [.text]) { values[field.id] = .text(String(year)) }
        }
        if let publisher = result.publisher, let field = field("publisher", in: table, types: [.text, .choice]) {
            values[field.id] = field.type == .choice ? .choices([publisher]) : .text(publisher)
        }
        if let pages = result.pages, pages > 0, let field = field("pages", in: table, types: [.number]) { values[field.id] = .number(Double(pages)) }
        if let tracks = result.tracks, tracks > 0, let field = field("tracks", in: table, types: [.number]) { values[field.id] = .number(Double(tracks)) }
        if let format = result.format, let field = field("format", in: table, types: [.choice, .text]) {
            values[field.id] = field.type == .choice ? .choices([choice(for: format, in: field.options.choices)]) : .text(format)
        }
        if !result.genres.isEmpty, let field = field("genre", in: table, types: [.multiChoice, .choice, .text]) {
            // Prefer genres the field already lists.
            // In the field's own spelling ("Rock", not "rock"), so filters and colours match.
            let known = result.genres.compactMap { g in field.options.choices.first { $0.caseInsensitiveCompare(g) == .orderedSame } }
            let picked = known.isEmpty ? Array(result.genres.prefix(3)) : known
            switch field.type {
            case .multiChoice: values[field.id] = .choices(picked)
            case .choice: values[field.id] = .choices([picked[0]])
            default: values[field.id] = .text(picked.joined(separator: ", "))
            }
        }
        if let field = field("code", in: table, types: [.barcode, .text, .number]) ?? table.fields.first(where: { $0.type == .barcode }) {
            // A number field only takes an all-digit code (an ISBN ending in X goes nowhere).
            if field.type == .number {
                if result.code.allSatisfy(\.isNumber), let n = Double(result.code) { values[field.id] = .number(n) }
            } else {
                values[field.id] = .text(result.code)
            }
        }
        if let cover, let field = field("cover", in: table, types: [.image]) ?? table.fields.first(where: { $0.type == .image }) {
            values[field.id] = .attachments([cover])
        }
        return (values, newLinked)
    }

    /// A media format as one of the field's options: "12\" Vinyl" → "LP" when the list has LP.
    static func choice(for format: String, in options: [String]) -> String {
        let lower = format.lowercased()
        if let exact = options.first(where: { $0.lowercased() == lower }) { return exact }
        let candidates: [String] = lower.contains("vinyl") || lower.contains("12\"")
            ? (lower.contains("7\"") ? ["7\"", "Single", "Vinyl"] : ["LP", "Vinyl", "12\"", "Record"])
            : lower.contains("cd") ? ["CD"]
            : lower.contains("cassette") ? ["Cassette", "Tape"]
            : lower.contains("digital") ? ["Digital", "Download"]
            : lower.contains("dvd") ? ["DVD"] : []
        for candidate in candidates {
            if let match = options.first(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) { return match }
        }
        return format
    }
}
