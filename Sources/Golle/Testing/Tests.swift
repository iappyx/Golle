import PDFKit
import AppKit
import SwiftUI
import Foundation

/// Unit tests for the parts that are easy to get subtly wrong: the file format, value conversion,
/// search, filters, sorting, formulas, links, CSV, attachments, encryption and undo.
/// Run with `scripts/test.sh`.
@MainActor
enum Tests {
    static func all() {
        fileRoundTrip()
        fileRejectsJunk()
        conversion()
        searching()
        filtering()
        sorting()
        summaries()
        formulas()
        links()
        editing()
        views()
        undo()
        package()
        attachments()
        locking()
        csv()
        importing()
        exporting()
        templates()
        layouts()
        numberFormats()
        newRecords()
        locations()
        grouping()
        duplicates()
        tableCopies()
        colourRules()
        batchEdit()
        excel()
        barcodes()
        markdown()
        history()
        checklists()
        tags()
        charts()
        columnsAndDashboard()
        fastSearch()
        bugScanFixes()
        secondScanFixes()
        thirdScanFixes()
        finalScanFixes()
        newFieldTypes()
        settings()
        lookupsAndRules()
        findReplaceTimelineReports()
        copyPasteRelated()
        grid()
        gridInWindow()
        summaryTable()
    }

    /// A database with one of every field type.
    static func sample() -> Database {
        let fields = FieldType.allCases.map { type -> Field in
            var field = Field(name: type.label, type: type, options: type.usesChoices ? FieldOptions(choices: ["Jazz", "Rock", "Folk"]) : FieldOptions())
            if type == .formula { field.options.formula = "{Number} * 2" }
            return field
        }
        func id(_ type: FieldType) -> Field.ID { fields.first { $0.type == type }!.id }
        var full = Record()
        full.values = [
            id(.text): .text("Kind of Blue"), id(.longText): .text("Line one\nLine two"), id(.number): .number(1959.5),
            id(.date): .date(sampleDate), id(.checkbox): .bool(true),
            id(.choice): .choices(["Jazz"]), id(.multiChoice): .choices(["Jazz", "Folk"]), id(.rating): .rating(4),
            id(.url): .text("https://example.com/ü?a=1&b=2"),
            id(.image): .attachments([Attachment(name: "cover.png")]), id(.file): .attachments([Attachment(name: "notes.pdf")]),
        ]
        var sparse = Record()
        sparse.values = [id(.text): .text("Blue Train")]
        var albums = DataTable(name: "Albums", fields: fields, records: [full, sparse, Record()])
        full.values[id(.link)] = .links([sparse.id])
        albums.records[0] = full
        albums.fields[albums.fieldIndex(id(.link))!].options.linkedTableID = albums.id
        albums.views = [SavedView(name: "Good", filter: Filter(rules: [FilterRule(fieldID: id(.rating), op: .greaterOrEqual, operand: "3")]),
                                  sort: [SortKey(fieldID: id(.number), ascending: false)], mode: .gallery)]
        albums.summaries = [SummaryItem(fieldID: id(.number), kind: .sum)]
        albums.layouts = [FormLayout.automatic(for: albums)]
        let empty = DataTable(name: "Empty ‘quoted’ name", fields: [], records: [])
        var db = Database(tables: [albums, empty])
        db.settings.accent = .teal
        db.settings.symbol = "film"
        return db
    }

    nonisolated static func field(_ db: Database, _ type: FieldType) -> Field { db.tables[0].fields.first { $0.type == type }! }

    private static func fileRoundTrip() {
        TestRunner.suite("File format round trip") {
            let original = sample()
            do {
                let bytes = try DatabaseFile.encode(original)
                TestRunner.expect(bytes.starts(with: Data("SQLite format 3".utf8)), "writes a real SQLite file")
                let read = try DatabaseFile.decode(bytes)
                TestRunner.equal(read.tables.map(\.name), original.tables.map(\.name), "table names and order")
                TestRunner.equal(read.tables[0].fields, original.tables[0].fields, "fields, types and options")
                TestRunner.equal(read.tables[0].records.map(\.id), original.tables[0].records.map(\.id), "record order")
                for (a, b) in zip(read.tables[0].records, original.tables[0].records) {
                    TestRunner.equal(a.values, b.values, "values of \(b.id)")
                }
                TestRunner.equal(read.tables[0].views, original.tables[0].views, "saved views")
                TestRunner.equal(read.tables[0].summaries, original.tables[0].summaries, "summaries")
                TestRunner.equal(read.tables[0].layouts, original.tables[0].layouts, "layouts")
                TestRunner.equal(read.settings, original.settings, "theme")
                TestRunner.equal(read, original, "whole database")
                TestRunner.equal(try DatabaseFile.encode(read), bytes, "writing is deterministic")
            } catch {
                TestRunner.expect(false, "round trip threw \(error)")
            }
        }
    }

    private static func fileRejectsJunk() {
        TestRunner.suite("File format rejects other files") {
            TestRunner.expect((try? DatabaseFile.decode(Data("hello".utf8))) == nil, "random bytes")
            TestRunner.expect((try? DatabaseFile.decode(Data())) == nil, "empty file")
            let other = try? SQLite()
            try? other?.execute("CREATE TABLE t(x)")
            if let bytes = try? other?.serialize() {
                TestRunner.expect((try? DatabaseFile.decode(bytes)) == nil, "foreign SQLite database")
            }
            // A newer format must not be opened (and then overwritten) by this version.
            if let newer = try? SQLite(bytes: try DatabaseFile.encode(sample())) {
                try? newer.execute("UPDATE meta SET value = '99' WHERE key = 'format'")
                if let bytes = try? newer.serialize() {
                    TestRunner.expect((try? DatabaseFile.decode(bytes)) == nil, "newer format")
                }
            }
        }
    }

    private static func conversion() {
        TestRunner.suite("Changing field types") {
            TestRunner.equal(Value.text("42").converted(to: .number), .number(42), "text to number")
            TestRunner.equal(Value.text("€ 1.250,50").converted(to: .number) != nil, true, "currency text to number")
            TestRunner.equal(Value.text("abc").converted(to: .number), nil, "non-number text is dropped")
            TestRunner.equal(Value.number(3).converted(to: .text), .text("3"), "whole number to text has no decimals")
            TestRunner.equal(Value.number(2.5).converted(to: .text), .text("2.5"), "fraction to text")
            TestRunner.equal(Value.text("yes").converted(to: .checkbox), .bool(true), "yes to checkbox")
            TestRunner.equal(Value.text("no").converted(to: .checkbox), nil, "no to checkbox is empty")
            TestRunner.equal(Value.number(7).converted(to: .rating), .rating(5), "rating is capped")
            TestRunner.equal(Value.rating(3).converted(to: .number), .number(3), "rating to number")
            TestRunner.equal(Value.text("a, b ,c").converted(to: .multiChoice), .choices(["a", "b", "c"]), "comma list to choices")
            TestRunner.equal(Value.choices(["a", "b"]).converted(to: .choice), .choices(["a"]), "multi to single choice keeps the first")
            TestRunner.equal(Value.text("x").converted(to: .image), nil, "text can't become an image")
            TestRunner.equal(Value.links([UUID()]).converted(to: .text), nil, "links don't become text ids")
            func day(_ text: String) -> [Int?] {
                guard let d = Value.parseDate(text) else { return [] }
                let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
                return [c.year, c.month, c.day]
            }
            TestRunner.equal(day("2024-03-05"), [2024, 3, 5], "ISO date")
            // Day or month first as this Mac's region writes them (GitHub's machines are set to the US).
            TestRunner.equal(day("05-03-2024"), Value.localeDateOrder == .monthDayYear ? [2024, 5, 3] : [2024, 3, 5], "05-03-2024 in the region's order")
            TestRunner.equal(day("31/12/1999"), [1999, 12, 31], "day/month/year")
            let date = Value.date(Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_000_000)))
            TestRunner.equal(date.converted(to: .text)?.converted(to: .date), date, "date survives a trip through text")
        }
    }

    private static func searching() {
        TestRunner.suite("Search") {
            let db = sample()
            let resolver = Resolver(database: db, table: db.tables[0])
            func count(_ q: String) -> Int { Query.search(db.tables[0].records, resolver, for: q).count }
            TestRunner.equal(count(""), 3, "empty search shows everything")
            TestRunner.equal(count("blue"), 2, "case-insensitive, across records")
            TestRunner.equal(count("kind blue"), 1, "all words must match")
            TestRunner.equal(count("FOLK"), 1, "searches choice fields")
            TestRunner.equal(count("line two"), 1, "searches long text")
            TestRunner.equal(count("example.com/u"), 1, "ignores accents")
            TestRunner.equal(count("cover.png"), 1, "searches attachment names")
            TestRunner.equal(count("3919"), 1, "searches formula results")
            TestRunner.equal(count("nothing-matches"), 0, "no match")
        }
    }

    private static func filtering() {
        TestRunner.suite("Filters") {
            let db = sample()
            let table = db.tables[0]
            let resolver = Resolver(database: db, table: table)
            func count(_ type: FieldType, _ op: FilterOperator, _ operand: String = "", match: Filter.Match = .all) -> Int {
                let filter = Filter(match: match, rules: [FilterRule(fieldID: field(db, type).id, op: op, operand: operand)])
                return table.records.filter { filter.matches($0, resolver) }.count
            }
            TestRunner.equal(count(.text, .contains, "blue"), 2, "text contains")
            TestRunner.equal(count(.text, .equals, "kind of blue"), 1, "text is (ignores case)")
            TestRunner.equal(count(.text, .beginsWith, "Blue"), 1, "begins with")
            TestRunner.equal(count(.text, .endsWith, "train"), 1, "ends with")
            TestRunner.equal(count(.text, .isEmpty), 1, "is empty")
            TestRunner.equal(count(.number, .greater, "1900"), 1, "number greater")
            TestRunner.equal(count(.number, .equals, "1959.5"), 1, "number equals compares numbers")
            TestRunner.equal(count(.number, .less, "abc"), 0, "bad operand matches nothing")
            TestRunner.equal(count(.rating, .greaterOrEqual, "4"), 1, "rating")
            TestRunner.equal(count(.checkbox, .isChecked), 1, "checked")
            TestRunner.equal(count(.checkbox, .isNotChecked), 2, "not checked")
            TestRunner.equal(count(.multiChoice, .equals, "folk"), 1, "multiple choice has")
            TestRunner.equal(count(.multiChoice, .notEquals, "Folk"), 2, "multiple choice does not have")
            TestRunner.equal(count(.date, .before, "1970-02-01"), 1, "date before")
            TestRunner.equal(count(.date, .after, "1970-02-01"), 0, "date after")
            TestRunner.equal(count(.date, .equals, "1970-01-12"), 1, "date on day")
            TestRunner.equal(count(.date, .inLastDays, "30"), 0, "in the last days")
            TestRunner.equal(count(.formula, .greater, "1000"), 1, "formula as number")
            TestRunner.equal(count(.link, .equals, "Blue Train"), 1, "link by title")
            let both = Filter(match: .any, rules: [FilterRule(fieldID: field(db, .text).id, op: .equals, operand: "Blue Train"),
                                                    FilterRule(fieldID: field(db, .checkbox).id, op: .isChecked)])
            TestRunner.equal(table.records.filter { both.matches($0, resolver) }.count, 2, "match any")
            var today = table
            var record = Record()
            record[field(db, .date).id] = .date(Date())
            today.records = [record]
            let r2 = Resolver(database: db, table: today)
            TestRunner.expect(FilterRule(fieldID: field(db, .date).id, op: .today).matches(record, r2), "today")
            TestRunner.expect(FilterRule(fieldID: field(db, .date).id, op: .inLastDays, operand: "7").matches(record, r2), "today is in the last 7 days")
        }
    }

    private static func sorting() {
        TestRunner.suite("Sorting") {
            let field = Field(name: "N", type: .number)
            let records = [5.0, nil, 1.0, 10.0].map { n -> Record in
                var r = Record()
                r[field.id] = n.map(Value.number)
                return r
            }
            let table = DataTable(name: "T", fields: [field], records: records)
            let resolver = Resolver(database: Database(tables: [table]), table: table)
            let up = Query.sort(records, by: [SortKey(fieldID: field.id)], resolver).map { $0[field.id]?.number }
            TestRunner.equal(up, [1, 5, 10, nil], "numbers ascending, empty last")
            let down = Query.sort(records, by: [SortKey(fieldID: field.id, ascending: false)], resolver).map { $0[field.id]?.number }
            TestRunner.equal(down, [10, 5, 1, nil], "numbers descending, empty still last")
            TestRunner.equal(Query.compare(.text("item 2"), .text("item 10")), .orderedAscending, "text sorts like Finder")
            let db = sample()
            let sorted = Query.visible(Resolver(database: db, table: db.tables[0]), view: db.tables[0].views[0], search: "")
            TestRunner.equal(sorted.count, 1, "saved view filters")
        }
    }

    private static func summaries() {
        TestRunner.suite("Summaries") {
            let field = Field(name: "N", type: .number)
            let values: [Value?] = [.number(2), .number(4), nil, .number(6)]
            TestRunner.equal(SummaryKind.sum.compute(values, field: field), "12", "sum")
            TestRunner.equal(SummaryKind.average.compute(values, field: field), "4", "average skips empty")
            TestRunner.equal(SummaryKind.minimum.compute(values, field: field), "2", "minimum")
            TestRunner.equal(SummaryKind.maximum.compute(values, field: field), "6", "maximum")
            TestRunner.equal(SummaryKind.filled.compute(values, field: field), "3", "filled")
            TestRunner.equal(SummaryKind.empty.compute(values, field: field), "1", "empty")
            TestRunner.equal(SummaryKind.average.compute([nil], field: field), "—", "nothing to average")
            let text = Field(name: "T", type: .text)
            TestRunner.equal(SummaryKind.unique.compute([.text("a"), .text("b"), .text("a")], field: text), "2", "unique")
        }
    }

    private static func formulas() {
        TestRunner.suite("Formulas") {
            let price = Field(name: "Price", type: .number)
            let quantity = Field(name: "Quantity", type: .number)
            let name = Field(name: "Name", type: .text)
            let when = Field(name: "When", type: .date)
            let done = Field(name: "Done", type: .checkbox)
            var record = Record()
            record[price.id] = .number(2.5)
            record[quantity.id] = .number(4)
            record[name.id] = .text("Thé")
            record[when.id] = .date(Calendar.current.date(from: DateComponents(year: 2024, month: 2, day: 28))!)
            func eval(_ formula: String, extra: [Field] = []) -> Resolver.Computed {
                let f = Field(name: "F", type: .formula, options: FieldOptions(formula: formula))
                let table = DataTable(name: "T", fields: [price, quantity, name, when, done, f] + extra, records: [record])
                return Resolver(database: Database(tables: [table]), table: table).formulaValue(record, f)
            }
            func value(_ formula: String) -> Value? { eval(formula).value }
            TestRunner.equal(value("{Price} * {Quantity}"), .number(10), "multiply fields")
            // Text pieces, finding, replacing, dates as text, and SWITCH.
            TestRunner.equal(value("MID(\"Golle\", 2, 3)"), .text("oll"), "MID counts from 1")
            TestRunner.equal(value("MID(\"Golle\", 4, 10)"), .text("le"), "MID stops at the end")
            TestRunner.expect(eval("MID(\"Golle\", 0, 2)").error != nil, "MID from 0 is an error")
            TestRunner.equal(value("FIND(\"LL\", \"Golle\")"), .number(3), "FIND ignores case")
            TestRunner.equal(value("FIND(\"e\", {Name})"), .number(3), "and accents")
            TestRunner.equal(value("FIND(\"x\", \"Golle\")"), .number(0), "0 when not found")
            TestRunner.equal(value("SUBSTITUTE(\"a-b-c\", \"-\", \" / \")"), .text("a / b / c"), "SUBSTITUTE replaces every one")
            TestRunner.equal(value("SUBSTITUTE(\"abc\", \"\", \"x\")"), .text("abc"), "nothing to replace")
            TestRunner.equal(value("LEFT({Name}, FIND(\"h\", {Name}))"), .text("Th"), "FIND inside LEFT")
            TestRunner.equal(value("FORMATDATE({When}, \"yyyy-MM-dd\")"), .text("2024-02-28"), "FORMATDATE with a pattern")
            TestRunner.equal(value("FORMATDATE({When}, \"d/M\")"), .text("28/2"), "short pattern")
            TestRunner.expect(eval("FORMATDATE({Price})").error != nil, "FORMATDATE needs a date")
            TestRunner.equal(value("SWITCH({Quantity}, 1, \"one\", 4, \"four\", \"many\")"), .text("four"), "SWITCH picks the match")
            TestRunner.equal(value("SWITCH({Quantity}, 1, \"one\", \"many\")"), .text("many"), "or the otherwise")
            TestRunner.equal(value("SWITCH({Quantity}, 1, \"one\")"), nil, "or nothing")
            TestRunner.equal(value("SWITCH({Name}, \"thé\", \"tea\", 1 / 0)"), .text("tea"), "only the result it picks is worked out")
            TestRunner.equal(value("1 + 2 * 3"), .number(7), "precedence")
            TestRunner.equal(value("(1 + 2) * 3"), .number(9), "brackets")
            TestRunner.equal(value("2 ^ 3 ^ 2"), .number(512), "power is right-associative")
            TestRunner.equal(value("-{Price} + 1"), .number(-1.5), "unary minus")
            TestRunner.equal(value("{Name} & \"!\""), .text("Thé!"), "join text")
            TestRunner.equal(value("UPPER({name})"), .text("THÉ"), "field names ignore case")
            TestRunner.equal(value("IF({Price} > 2, \"dear\", \"cheap\")"), .text("dear"), "IF")
            TestRunner.equal(value("IF({Done}, 1, 0)"), .number(0), "empty checkbox is false")
            TestRunner.equal(value("ROUND(10 / 3, 2)"), .number(3.33), "ROUND")
            TestRunner.equal(value("SUM(1, 2, 3)"), .number(6), "SUM")
            TestRunner.equal(value("YEAR({When})"), .number(2024), "YEAR")
            TestRunner.equal(value("ADDDAYS({When}, 2)")?.date.map { Calendar.current.component(.day, from: $0) }, 1, "ADDDAYS crosses into March (leap year)")
            TestRunner.equal(value("DAYS(DATE(2024, 3, 1), {When})"), .number(2), "DAYS")
            TestRunner.equal(value("{When} + 1 > {When}"), .bool(true), "date arithmetic and comparison")
            TestRunner.equal(value("LEN(\"abc\") = 3"), .bool(true), "LEN and =")
            TestRunner.equal(value("\"b\" > \"A\""), .bool(true), "text comparison ignores case")
            TestRunner.equal(value("ISBLANK({Done})"), .bool(true), "ISBLANK")
            TestRunner.equal(value(""), nil, "empty formula")
            TestRunner.expect(eval("1 / 0").error != nil, "division by zero is an error")
            TestRunner.expect(eval("{Nope} + 1").error?.contains("Nope") == true, "unknown field")
            TestRunner.expect(eval("FOO(1)").error?.contains("FOO") == true, "unknown function")
            TestRunner.expect(eval("(1 + 2").error != nil, "missing bracket")
            TestRunner.expect(eval("\"open").error != nil, "unclosed text")
            TestRunner.expect(eval("{Name} * 2").error != nil, "text times number")
            let loop = Field(name: "Loop", type: .formula, options: FieldOptions(formula: "{Loop} + 1"))
            let table = DataTable(name: "T", fields: [loop], records: [record])
            TestRunner.expect(Resolver(database: Database(tables: [table]), table: table).formulaValue(record, loop).error != nil, "a formula referring to itself stops")
            let chained = Field(name: "Double", type: .formula, options: FieldOptions(formula: "{Price} * 2"))
            TestRunner.equal(eval("{Double} + 1", extra: [chained]).value, .number(6), "formulas can use formulas")
        }
    }

    private static func links() {
        TestRunner.suite("Linked records") {
            let artistName = Field(name: "Name", type: .text)
            var artists = DataTable(name: "Artists", fields: [artistName])
            var miles = Record(); miles[artistName.id] = .text("Miles Davis")
            var coltrane = Record(); coltrane[artistName.id] = .text("John Coltrane")
            artists.records = [miles, coltrane]
            let title = Field(name: "Title", type: .text)
            let price = Field(name: "Price", type: .number)
            let artist = Field(name: "Artist", type: .link, options: FieldOptions(linkedTableID: artists.id))
            let names = Field(name: "Names", type: .formula, options: FieldOptions(formula: "JOIN({Artist}, \" & \")"))
            let count = Field(name: "Count", type: .formula, options: FieldOptions(formula: "COUNT({Artist})"))
            var album = Record()
            album[title.id] = .text("Kind of Blue")
            album[price.id] = .number(20)
            album[artist.id] = .links([miles.id, coltrane.id])
            let albums = DataTable(name: "Albums", fields: [title, price, artist, names, count], records: [album])

            let lookup = Field(name: "Spent", type: .formula, options: FieldOptions(formula: "SUM(LOOKUP({Albums}, \"Price\"))"))
            let back = Field(name: "Albums", type: .link, options: FieldOptions(linkedTableID: albums.id))
            artists.fields += [back, lookup]
            artists.records[0][back.id] = .links([album.id])

            let db = Database(tables: [albums, artists])
            let resolver = Resolver(database: db, table: albums)
            TestRunner.equal(resolver.text(album, artist), "Miles Davis, John Coltrane", "shows linked titles")
            TestRunner.equal(resolver.value(album, names), .text("Miles Davis & John Coltrane"), "formula over a link")
            TestRunner.equal(resolver.value(album, count), .number(2), "COUNT of links")
            let artistResolver = Resolver(database: db, table: db.tables[1])
            TestRunner.equal(artistResolver.value(db.tables[1].records[0], lookup), .number(20), "LOOKUP rolls up a field of linked records")
            let backlinks = artistResolver.backlinks(to: miles)
            TestRunner.equal(backlinks.map(\.records.count), [1], "backlinks")

            // Deleting a linked record leaves the link harmlessly dangling.
            var trimmed = db
            trimmed.tables[1].records.removeAll { $0.id == coltrane.id }
            TestRunner.equal(Resolver(database: trimmed, table: trimmed.tables[0]).text(album, artist), "Miles Davis", "deleted records drop out")

            let filter = Filter(rules: [FilterRule(fieldID: artist.id, op: .equals, operand: "john coltrane")])
            TestRunner.expect(filter.matches(album, resolver), "filter on a linked title")
            let sorted = Query.sort([album], by: [SortKey(fieldID: artist.id)], resolver)
            TestRunner.equal(sorted.count, 1, "sort by link")
        }
    }

    private static func editing() {
        TestRunner.suite("Editing") {
            let document = GolleDocument(database: sample())
            let table = document.database.tables[0]
            let number = table.fields.first { $0.type == .number }!
            let record = table.records[0]

            var retyped = number
            retyped.type = .text
            document.updateField(retyped, in: table.id)
            TestRunner.equal(document.database.tables[0].records[0][number.id], .text("1959.5"), "retyping converts values")

            document.setValue(.text(""), record: record.id, field: number.id, table: table.id)
            TestRunner.equal(document.database.tables[0].records[0][number.id], nil, "an empty value removes the cell")

            document.duplicateRecords([record.id], in: table.id)
            let records = document.database.tables[0].records
            TestRunner.equal(records.count, 4, "duplicate adds a record")
            let autoIDs = Set(table.fields.filter { $0.type == .autoNumber }.map(\.id))
            TestRunner.equal(records[1].values.filter { !autoIDs.contains($0.key) }, records[0].values.filter { !autoIDs.contains($0.key) }, "duplicate sits right after the original")
            for id in autoIDs {
                TestRunner.equal(records[1][id], .number(table.nextNumber(for: id)), "the copy gets the next auto number")
            }
            TestRunner.expect(records[1].id != records[0].id, "duplicate has its own id")
            TestRunner.equal(document.selectedRecordIDs, [records[1].id], "duplicate is selected")

            document.deleteField(number.id, from: table.id)
            let after = document.database.tables[0]
            TestRunner.expect(after.records.allSatisfy { $0[number.id] == nil }, "deleting a field removes its values")
            TestRunner.expect(after.summaries.isEmpty, "and its summaries")
            TestRunner.expect(after.views[0].sort.isEmpty, "and sorting on it")
            TestRunner.expect(!after.layouts[0].items.contains { $0.kind == .field(number.id) }, "and its place on layouts")

            document.addTable()
            TestRunner.equal(document.database.tables.last?.name, "Table 1", "new table gets a free name")
            TestRunner.equal(document.selectedTableID, document.database.tables.last?.id, "new table is selected")
            let link = document.addField(to: document.selectedTableID!, type: .link)!
            TestRunner.equal(document.currentTable?.field(link)?.options.linkedTableID, table.id, "a link field points at another table")
        }
    }

    private static func views() {
        TestRunner.suite("Views") {
            let document = GolleDocument(database: sample())
            let table = document.database.tables[0]
            let rating = table.fields.first { $0.type == .rating }!
            document.selectedTableID = table.id
            document.updateCurrentView { $0.filter.rules = [FilterRule(fieldID: rating.id, op: .isNotEmpty)] }
            TestRunner.expect(!document.currentView.filter.isEmpty, "unsaved filter applies")
            TestRunner.equal(document.database.tables[0].views.count, 1, "unsaved filter doesn't touch the file")
            document.saveCurrentView(named: "Rated")
            TestRunner.equal(document.database.tables[0].views.last?.name, "Rated", "save as view")
            TestRunner.equal(document.selectedViewID, document.database.tables[0].views.last?.id, "the new view is selected")
            document.updateCurrentView { $0.mode = .gallery }
            TestRunner.equal(document.database.tables[0].views.last?.mode, .gallery, "changing a saved view saves it")
            document.selectedViewID = nil
            TestRunner.expect(document.currentView.filter.isEmpty, "All Records is fresh after saving")
            document.addRecord(to: table.id)
            TestRunner.equal(document.pinnedRecordIDs.count, 1, "a new record stays in view")
            document.selectedViewID = document.database.tables[0].views.first?.id
            TestRunner.expect(document.pinnedRecordIDs.isEmpty, "until the view changes")
        }
    }

    private static func undo() {
        TestRunner.suite("Undo") {
            let undo = UndoManager()
            undo.groupsByEvent = false
            let document = GolleDocument(database: sample())
            document.undoManager = undo
            let table = document.database.tables[0]
            let field = table.fields[0]
            let record = table.records[1]
            let before = document.database

            undo.beginUndoGrouping()
            for text in ["B", "Bl", "Blu", "Blue"] {
                document.setValue(.text(text), record: record.id, field: field.id, table: table.id)
            }
            undo.endUndoGrouping()
            TestRunner.equal(undo.undoActionName, "Edit", "action name")
            undo.undo()
            TestRunner.equal(document.database, before, "typing in one cell undoes in one step")
            undo.redo()
            TestRunner.equal(document.database.tables[0].records[1][field.id], .text("Blue"), "redo")

            undo.beginUndoGrouping()
            document.deleteRecords([record.id], from: table.id)
            undo.endUndoGrouping()
            TestRunner.equal(document.database.tables[0].records.count, 2, "deleted")
            undo.undo()
            TestRunner.equal(document.database.tables[0].records[1].id, record.id, "undo restores the record in place")

            // After a save, the next keystroke must register undo again so the document shows edited.
            _ = try? document.snapshot(contentType: .golleDatabase)
            undo.beginUndoGrouping()
            document.setValue(.text("Blue!"), record: record.id, field: field.id, table: table.id)
            undo.endUndoGrouping()
            undo.undo()
            TestRunner.equal(document.database.tables[0].records[1][field.id], .text("Blue"), "edit after save is its own undo step")
        }
    }

    private static func package() {
        TestRunner.suite("Document package") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("golle-test-\(UUID().uuidString).golledb")
            defer { try? FileManager.default.removeItem(at: folder) }
            do {
                let document = GolleDocument(database: sample())
                let wrapper = try document.package()
                // Something a later version added, which this version must keep.
                wrapper.addRegularFile(withContents: Data("keep".utf8), preferredFilename: "Future.txt")
                try wrapper.write(to: folder, options: .atomic, originalContentsURL: nil)
                TestRunner.expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(DatabaseFile.sqliteName).path), "package holds database.sqlite")

                let reread = try GolleDocument(file: FileWrapper(url: folder))
                TestRunner.equal(reread.database, document.database, "reads back the package")
                let rewritten = try reread.package()
                TestRunner.equal(rewritten.fileWrappers?["Future.txt"]?.regularFileContents, Data("keep".utf8), "keeps files it doesn't know")
            } catch {
                TestRunner.expect(false, "package threw \(error)")
            }
        }
    }

    private static func attachments() {
        TestRunner.suite("Attachments") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("golle-test-\(UUID().uuidString).golledb")
            defer { try? FileManager.default.removeItem(at: folder) }
            do {
                let image = Field(name: "Photo", type: .image)
                let table = DataTable(name: "T", fields: [image], records: [Record()])
                let document = GolleDocument(database: Database(tables: [table]))
                let photo = document.addAttachment(data: Data("PNG bytes".utf8), name: "Holiday.PNG")
                let unused = document.addAttachment(data: Data("unused".utf8), name: "x.txt")
                document.setValue(.attachments([photo]), record: table.records[0].id, field: image.id, table: table.id)
                TestRunner.equal(photo.fileName, "\(photo.id.uuidString).png", "stored under its id")
                TestRunner.equal(document.attachmentData(photo), Data("PNG bytes".utf8), "reads back")

                try document.package().write(to: folder, options: .atomic, originalContentsURL: nil)
                let files = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Attachments").path)
                TestRunner.equal(files, [photo.fileName], "only attachments in use are saved")
                TestRunner.expect(!files.contains(unused.fileName), "unused file left out")

                let reread = try GolleDocument(file: FileWrapper(url: folder))
                TestRunner.equal(reread.attachmentData(photo), Data("PNG bytes".utf8), "attachment survives a save")
                let exported = reread.exportedURL(for: photo)
                TestRunner.equal(exported?.lastPathComponent, "Holiday.PNG", "opened copy keeps its name")
                TestRunner.equal(exported.flatMap { try? Data(contentsOf: $0) }, Data("PNG bytes".utf8), "opened copy has the content")
            } catch {
                TestRunner.expect(false, "attachments threw \(error)")
            }
        }
    }

    private static func locking() {
        TestRunner.suite("Password lock") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("golle-test-\(UUID().uuidString).golledb")
            defer { try? FileManager.default.removeItem(at: folder) }
            do {
                // Few rounds keep the test quick; the app uses LockInfo.defaultRounds.
                let (info, key) = try LockInfo.create(password: "sesame", hint: "door", rounds: 1000)
                TestRunner.expect(info.key(for: "sesame") != nil, "right password")
                TestRunner.expect(info.key(for: "Sesame") == nil, "wrong password")
                TestRunner.equal(try LockInfo.open(try LockInfo.seal(Data("x".utf8), with: key), with: key), Data("x".utf8), "seal and open")

                let image = Field(name: "Photo", type: .image)
                let table = DataTable(name: "Secret", fields: [Field(name: "Name", type: .text), image], records: [Record()])
                let document = GolleDocument(database: Database(tables: [table]))
                let photo = document.addAttachment(data: Data("private photo".utf8), name: "p.jpg")
                document.setValue(.attachments([photo]), record: table.records[0].id, field: image.id, table: table.id)
                document.setValue(.text("Top secret name"), record: table.records[0].id, field: table.fields[0].id, table: table.id)
                try document.setPassword("sesame", hint: "door", rememberWithTouchID: false)
                TestRunner.equal(document.attachmentData(photo), Data("private photo".utf8), "attachments still readable while open")

                try document.package().write(to: folder, options: .atomic, originalContentsURL: nil)
                TestRunner.expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(DatabaseFile.sqliteName).path), "no plain database on disk")
                var leaked = false
                for case let url as URL in FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)! {
                    if let data = try? Data(contentsOf: url),
                       data.range(of: Data("Top secret".utf8)) != nil || data.range(of: Data("private photo".utf8)) != nil { leaked = true }
                }
                TestRunner.expect(!leaked, "neither the data nor the attachment is readable on disk")

                let locked = try GolleDocument(file: FileWrapper(url: folder))
                TestRunner.expect(locked.isLocked, "opens locked")
                TestRunner.expect(locked.database.tables.isEmpty, "shows nothing while locked")
                TestRunner.equal(locked.lockInfo?.hint, "door", "hint")
                TestRunner.expect((try? locked.unlock(password: "wrong")) == nil, "wrong password refused")
                // A locked, never-unlocked document is written back unchanged.
                let untouched = try locked.package()
                TestRunner.equal(untouched.fileWrappers?[GolleDocument.sealedName]?.regularFileContents,
                                 try FileWrapper(url: folder).fileWrappers?[GolleDocument.sealedName]?.regularFileContents, "locked save keeps the sealed data")
                try locked.unlock(password: "sesame")
                TestRunner.expect(!locked.isLocked, "unlocks")
                TestRunner.equal(locked.database.tables.first?.name, "Secret", "data back")
                TestRunner.equal(locked.attachmentData(photo), Data("private photo".utf8), "attachment back")

                locked.removePassword()
                let plain = try locked.package()
                TestRunner.expect(plain.fileWrappers?[DatabaseFile.sqliteName] != nil, "removing the password saves plainly")
                TestRunner.expect(plain.fileWrappers?[LockInfo.fileName] == nil, "and drops lock.json")
                TestRunner.equal(plain.fileWrappers?["Attachments"]?.fileWrappers?[photo.fileName]?.regularFileContents, Data("private photo".utf8), "attachments saved plainly again")
            } catch {
                TestRunner.expect(false, "lock threw \(error)")
            }
        }
    }

    private static func csv() {
        TestRunner.suite("CSV") {
            TestRunner.equal(CSV.parse("a,b\n1,2\n"), [["a", "b"], ["1", "2"]], "simple")
            TestRunner.equal(CSV.parse("a;b\r\n1;2"), [["a", "b"], ["1", "2"]], "semicolons and CRLF")
            TestRunner.equal(CSV.parse("a\tb\n1\t2"), [["a", "b"], ["1", "2"]], "tabs")
            TestRunner.equal(CSV.parse("\"x, y\",\"say \"\"hi\"\"\"\n"), [["x, y", "say \"hi\""]], "quotes")
            TestRunner.equal(CSV.parse("\"two\nlines\",z"), [["two\nlines", "z"]], "newline in a quoted cell")
            TestRunner.equal(CSV.parse("\u{FEFF}a,b"), [["a", "b"]], "byte-order mark")
            TestRunner.equal(CSV.parse("a,,c\n\n"), [["a", "", "c"]], "empty cells kept, blank lines skipped")
            let rows = [["Name", "Note"], ["Kind of Blue", "a \"classic\", really\nyes"]]
            TestRunner.equal(CSV.parse(CSV.write(rows)), rows, "write and read back")
        }
    }

    private static func importing() {
        TestRunner.suite("Import") {
            TestRunner.equal(Importer.guessType(["1", "2.5", "", "-3"]), .number, "numbers")
            TestRunner.equal(Importer.guessType(["2024-01-02", "1999-12-31"]), .date, "dates")
            TestRunner.equal(Importer.guessType(["yes", "no", "yes"]), .checkbox, "yes/no")
            TestRunner.equal(Importer.guessType(["https://a.com", "http://b.org"]), .url, "links")
            TestRunner.equal(Importer.guessType(["LP", "CD", "LP", "CD", "LP"]), .choice, "few repeated values")
            TestRunner.equal(Importer.guessType(["Kind of Blue", "Blue Train"]), .text, "text")
            TestRunner.equal(Importer.guessType(["", ""]), .text, "empty column")

            let format = Importer.field(named: "Format", type: .choice, values: ["LP", "CD", "LP", " CD "])
            TestRunner.equal(format.options.choices, ["LP", "CD"], "choice list from values")
            let year = Field(name: "Year", type: .number)
            let tags = Importer.field(named: "Tags", type: .multiChoice, values: ["a; b", "b, c"])
            TestRunner.equal(tags.options.choices, ["a", "b", "c"], "multiple choice list")
            let records = Importer.records([["1959", "LP", "a; b"], ["x", "", ""]], columns: [(0, year), (1, format), (2, tags)])
            TestRunner.equal(records[0][year.id], .number(1959), "number")
            TestRunner.equal(records[0][format.id], .choices(["LP"]), "choice")
            TestRunner.equal(records[0][tags.id], .choices(["a", "b"]), "multiple choice")
            TestRunner.equal(records[1].values.isEmpty, true, "bad and empty cells are skipped")

            let document = GolleDocument(database: sample())
            let target = document.database.tables[0].id
            let newField = Field(name: "Label", type: .text)
            var record = Record()
            record[newField.id] = .text("Blue Note")
            document.importRecords([record], newFields: [newField], into: target)
            TestRunner.equal(document.database.tables[0].records.count, 4, "records appended")
            TestRunner.equal(document.database.tables[0].fields.last?.name, "Label", "new field added")
        }
    }

    /// The sample records' date: noon on 12 January 1970 wherever the tests run, so it is that day in
    /// every time zone (a fixed moment is the 13th in New Zealand).
    static let sampleDate = Calendar.current.date(from: DateComponents(year: 1970, month: 1, day: 12, hour: 12))!

    private static func exporting() {
        TestRunner.suite("Export") {
            let db = sample()
            let resolver = Resolver(database: db, table: db.tables[0])
            let csv = CSV.parse(Exporter.csv(db.tables[0].records, resolver: resolver))
            TestRunner.equal(csv.count, 4, "header and three records")
            TestRunner.equal(csv[0], db.tables[0].fields.map(\.name), "header is the field names")
            let row = Dictionary(uniqueKeysWithValues: zip(csv[0], csv[1]))
            TestRunner.equal(row["Number"], "1959.5", "numbers are plain")
            TestRunner.equal(row["Date"], "1970-01-12", "dates are ISO")
            TestRunner.equal(row["Checkbox"], "Yes", "checkbox")
            TestRunner.equal(row["Rating"], "4", "rating as a number")
            TestRunner.equal(row["Linked Records"], "Blue Train", "links by title")
            TestRunner.equal(row["Formula"], "3919", "formula result")
            TestRunner.equal(row["Long Text"], "Line one\nLine two", "newlines survive")
            do {
                let json = try JSONSerialization.jsonObject(with: try Exporter.json(db)) as? [String: Any]
                let tables = json?["tables"] as? [[String: Any]]
                TestRunner.equal(tables?.count, 2, "JSON has every table")
                let records = tables?[0]["records"] as? [[String: Any]]
                let values = records?[0]["values"] as? [String: Any]
                TestRunner.equal(values?["Number"] as? Double, 1959.5, "JSON number")
                TestRunner.equal(values?["Choice"] as? String, "Jazz", "JSON single choice")
                TestRunner.equal(values?["Multiple Choice"] as? [String], ["Jazz", "Folk"], "JSON multiple choice")
                TestRunner.equal(((values?["Linked Records"] as? [[String: String]])?.first?["title"]), "Blue Train", "JSON link")
            } catch {
                TestRunner.expect(false, "JSON threw \(error)")
            }
        }
    }

    private static func templates() {
        TestRunner.suite("Templates") {
            for template in Template.all {
                let db = template.make()
                TestRunner.expect(!db.tables.isEmpty, "\(template.name) has a table")
                for table in db.tables {
                    let resolver = Resolver(database: db, table: table)
                    for field in table.fields where field.type == .formula {
                        if case .failure(let error) = Formula.parse(field.options.formula) {
                            TestRunner.expect(false, "\(template.name) ▸ \(field.name): \(error.message)")
                        }
                        for record in table.records {
                            if let error = resolver.formulaValue(record, field).error {
                                TestRunner.expect(false, "\(template.name) ▸ \(field.name): \(error)")
                            }
                        }
                    }
                    for field in table.fields where field.type == .link {
                        TestRunner.expect(db.table(field.options.linkedTableID) != nil, "\(template.name) ▸ \(field.name) links to a table")
                    }
                    for view in table.views {
                        TestRunner.expect(view.filter.rules.allSatisfy { table.field($0.fieldID) != nil }, "\(template.name) ▸ \(view.name) filters on its own fields")
                    }
                }
                TestRunner.expect((try? DatabaseFile.decode(DatabaseFile.encode(db))) == db, "\(template.name) saves and loads")
            }
        }
    }

    private static func layouts() {
        TestRunner.suite("Layouts") {
            let db = sample()
            let layout = FormLayout.automatic(for: db.tables[0])
            TestRunner.equal(layout.items.filter { if case .field = $0.kind { true } else { false } }.count, db.tables[0].fields.count, "automatic layout has every field")
            TestRunner.expect(zip(layout.items, layout.items.dropFirst()).allSatisfy { $0.y + $0.height <= $1.y }, "items don't overlap")
            var item = LayoutItem(kind: .divider, x: 13, y: -20, width: 2000, height: 3)
            item.snap(within: CGSize(width: 640, height: 720))
            TestRunner.equal([item.x, item.y, item.width, item.height], [0, 0, 640, 16], "snapping keeps items on the page and on the grid")

            // Dragging the first field down past the second swaps them, and the column stays stacked.
            var stacked = FormLayout(name: "T")
            stacked.items = [0, 1, 2].map { LayoutItem(kind: .label("\($0)"), x: 24, y: 24 + Double($0) * 60, width: 300, height: 48) }
            let first = stacked.items[0]
            let original = first.frame
            stacked.items[0].y = 96   // dropped over item 1, below its middle
            stacked.items[0].x = 30
            stacked.settle(first.id, from: original)
            let order = stacked.items.sorted { $0.y < $1.y }.map(\.kind)
            TestRunner.equal(order, [.label("1"), .label("0"), .label("2")], "drop reorders the column")
            TestRunner.equal(stacked.items.sorted { $0.y < $1.y }.map(\.y), [24, 84, 144], "column is stacked again from the top")
            TestRunner.equal(stacked.items.first { $0.id == first.id }?.x, 24, "dropped item lines up with the column")

            // Dragging the last item to the top.
            var up = FormLayout(name: "T")
            up.items = [0, 1, 2].map { LayoutItem(kind: .label("\($0)"), x: 24, y: 24 + Double($0) * 60, width: 300, height: 48) }
            let last = up.items[2]
            up.items[2].y = 16
            up.settle(last.id, from: last.frame)
            TestRunner.equal(up.items.sorted { $0.y < $1.y }.map(\.kind), [.label("2"), .label("0"), .label("1")], "drag to the top")

            // Dropped on empty space: free placement, nothing else moves.
            var free = FormLayout(name: "T")
            free.items = [LayoutItem(kind: .label("a"), x: 24, y: 24, width: 200, height: 48),
                          LayoutItem(kind: .label("b"), x: 24, y: 84, width: 200, height: 48)]
            let a = free.items[0]
            free.items[0].x = 320
            free.items[0].y = 300
            let before = free.items
            free.settle(a.id, from: a.frame)
            TestRunner.equal(free.items, before, "drop on empty space stays put")
        }
    }

    private static func numberFormats() {
        TestRunner.suite("Number formats") {
            var f = NumberFormat()
            TestRunner.equal(f.format(1959), "1959", "plain has no thousands separator")
            TestRunner.equal(f.format(2.5), Value.numberFormatter.string(from: 2.5)!, "plain keeps decimals")
            f.style = .grouped
            TestRunner.expect(f.format(1234567).count > 7, "thousands separators")
            f.style = .currency
            f.currency = "EUR"
            TestRunner.expect(f.format(12.5).contains("€") && f.format(12.5).contains("50"), "currency with two decimals: \(f.format(12.5))")
            f = NumberFormat()
            f.style = .percent
            TestRunner.equal(f.format(25), "25%", "percent")
            f = NumberFormat()
            f.decimals = 2
            f.suffix = "kg"
            TestRunner.expect(f.format(3).hasSuffix(" kg") && f.format(3).contains("00"), "fixed decimals and unit: \(f.format(3))")
            f = NumberFormat()
            f.prefix = "INV-"
            TestRunner.equal(f.format(42), "INV-42", "prefix")
            var field = Field(name: "Price", type: .number)
            field.options.numberFormat = { var n = NumberFormat(); n.suffix = "€"; return n }()
            TestRunner.equal(Value.number(5).display(for: field), "5€", "symbols as suffix stick to the number")
            TestRunner.equal(SummaryKind.sum.compute([.number(2), .number(3)], field: field), "5€", "totals use the format")
        }
    }

    private static func newRecords() {
        TestRunner.suite("Defaults and automatic fields") {
            let owned = Field(name: "Owned", type: .checkbox, options: FieldOptions(defaultValue: "yes"))
            let bought = Field(name: "Bought", type: .date, options: FieldOptions(defaultValue: "today"))
            let format = Field(name: "Format", type: .choice, options: FieldOptions(choices: ["LP", "CD"], defaultValue: "LP"))
            let copies = Field(name: "Copies", type: .number, options: FieldOptions(defaultValue: "1"))
            let number = Field(name: "No.", type: .autoNumber)
            let created = Field(name: "Created", type: .createdAt)
            let table = DataTable(name: "T", fields: [owned, bought, format, copies, number, created])
            let document = GolleDocument(database: Database(tables: [table]))
            let first = document.addRecord(to: table.id)!
            let second = document.addRecord(to: table.id)!
            let records = document.database.tables[0].records
            TestRunner.equal(records[0][owned.id], .bool(true), "checkbox default")
            TestRunner.equal(records[0][bought.id], .date(Calendar.current.startOfDay(for: Date())), "today")
            TestRunner.equal(records[0][format.id], .choices(["LP"]), "choice default")
            TestRunner.equal(records[0][copies.id], .number(1), "number default")
            TestRunner.equal(records.first { $0.id == first }?[number.id], .number(1), "first auto number")
            TestRunner.equal(records.first { $0.id == second }?[number.id], .number(2), "next auto number")
            document.deleteRecords([second], from: table.id)
            let third = document.addRecord(to: table.id)!
            TestRunner.equal(document.database.tables[0].records.first { $0.id == third }?[number.id], .number(2), "numbers continue from the highest in use")
            let resolver = Resolver(database: document.database, table: document.database.tables[0])
            TestRunner.equal(resolver.value(document.database.tables[0].records[0], created), .date(document.database.tables[0].records[0].created), "created field")
            let fresh = Filter(rules: [FilterRule(fieldID: created.id, op: .today)])
            TestRunner.expect(fresh.matches(document.database.tables[0].records[0], resolver), "filter on created date")

            // Adding an auto-number field numbers the records already there, in order.
            let added = document.addField(to: table.id, type: .autoNumber)!
            TestRunner.equal(document.database.tables[0].records.map { $0[added]?.number }, [1, 2], "existing records get numbers")
            do {
                let read = try DatabaseFile.decode(DatabaseFile.encode(document.database))
                TestRunner.equal(read.tables[0].records.map { $0[number.id] }, document.database.tables[0].records.map { $0[number.id] }, "auto numbers are saved")
                TestRunner.equal(read.tables[0].fields, document.database.tables[0].fields, "defaults and formats are saved")
            } catch {
                TestRunner.expect(false, "save threw \(error)")
            }
        }
    }

    private static func locations() {
        TestRunner.suite("Locations") {
            let place = Field(name: "Place", type: .location)
            var record = Record()
            record[place.id] = .location(Place(name: "Leeuwarden", latitude: 53.2, longitude: 5.79))
            var unplaced = Record()
            unplaced[place.id] = .location(Place(name: "Sneek"))
            let table = DataTable(name: "T", fields: [place], records: [record, unplaced])
            do {
                let read = try DatabaseFile.decode(DatabaseFile.encode(Database(tables: [table])))
                TestRunner.equal(read.tables[0].records[0][place.id], record[place.id], "place with coordinates is saved")
                TestRunner.equal(read.tables[0].records[1][place.id], unplaced[place.id], "place without coordinates is saved")
            } catch {
                TestRunner.expect(false, "save threw \(error)")
            }
            TestRunner.equal(record[place.id]?.display(for: place), "Leeuwarden", "shows the name")
            TestRunner.equal(Value.text("Harlingen").converted(to: .location), .location(Place(name: "Harlingen")), "text becomes a place to find")
            TestRunner.equal(Value.location(Place(name: "X", latitude: 1, longitude: 2)).converted(to: .text), .text("X"), "place becomes text")
            let csv = Exporter.cell(record, place, Resolver(database: Database(tables: [table]), table: table))
            TestRunner.equal(csv, "Leeuwarden", "CSV has the name")
        }
    }

    private static func grouping() {
        TestRunner.suite("Grouping") {
            let format = Field(name: "Format", type: .choice)
            let year = Field(name: "Year", type: .number)
            let bought = Field(name: "Bought", type: .date)
            func record(_ f: String?, _ y: Double, _ month: Int) -> Record {
                var r = Record()
                r[format.id] = f.map { .choices([$0]) }
                r[year.id] = .number(y)
                r[bought.id] = .date(Calendar.current.date(from: DateComponents(year: 2024, month: month, day: 10))!)
                return r
            }
            let records = [record("LP", 1970, 3), record("CD", 1990, 3), record("LP", 1960, 5), record(nil, 2000, 3), record("LP", 1970, 5)]
            let table = DataTable(name: "T", fields: [format, year, bought], records: records)
            let resolver = Resolver(database: Database(tables: [table]), table: table)
            let one = Grouping.groups(records, by: [format], resolver)
            TestRunner.equal(one.map(\.title), ["CD", "LP", "No Format"], "groups in order, empty last")
            TestRunner.equal(one.map(\.records.count), [1, 3, 1], "records per group")
            TestRunner.equal(one[1].records.map { $0[year.id]?.number }, [1970, 1960, 1970], "records keep their order")
            let two = Grouping.groups(records, by: [format, year], resolver)
            TestRunner.equal(two[1].subgroups.map(\.title), ["1960", "1970"], "second level")
            TestRunner.equal(two[1].subgroups.map(\.records.count), [1, 2], "second level counts")
            TestRunner.expect(two[1].subgroups[0].id != two[0].id && two[1].subgroups[0].id.hasPrefix(two[1].id), "subgroup ids are paths")
            let months = Grouping.groups(records, by: [bought], resolver)
            TestRunner.equal(months.count, 2, "dates group by month")
            TestRunner.equal(months.map(\.records.count), [3, 2], "March before May")
        }
    }

    private static func duplicates() {
        TestRunner.suite("Duplicates") {
            let name = Field(name: "Name", type: .text)
            let tags = Field(name: "Tags", type: .multiChoice)
            let note = Field(name: "Note", type: .text)
            var a = Record(); a[name.id] = .text("Kind of Blue"); a[tags.id] = .choices(["Jazz"])
            var b = Record(); b[name.id] = .text("  kind of  BLUE "); b[tags.id] = .choices(["Modal", "Jazz"]); b[note.id] = .text("Mono")
            var c = Record(); c[name.id] = .text("Blue Train")
            let d = Record()
            let albums = DataTable(name: "Albums", fields: [name, tags, note], records: [a, b, c, d])
            let link = Field(name: "Albums", type: .link, options: FieldOptions(linkedTableID: albums.id))
            var fan = Record(); fan[link.id] = .links([b.id, c.id])
            let fans = DataTable(name: "Fans", fields: [link], records: [fan])
            var db = Database(tables: [albums, fans])
            let resolver = Resolver(database: db, table: albums)
            let groups = Duplicates.find(in: albums, fields: [name.id], resolver)
            TestRunner.equal(groups, [[a.id, b.id]], "same name ignoring case and spaces; empty records left out")
            Duplicates.merge(groups, in: albums.id, database: &db)
            TestRunner.equal(db.tables[0].records.count, 3, "duplicate removed")
            let kept = db.tables[0].records[0]
            TestRunner.equal(kept[tags.id], .choices(["Jazz", "Modal"]), "choices combined")
            TestRunner.equal(kept[note.id], .text("Mono"), "empty field filled")
            TestRunner.equal(kept[name.id], .text("Kind of Blue"), "kept record's own value wins")
            TestRunner.equal(db.tables[1].records[0][link.id], .links([a.id, c.id]), "links move to the kept record")
        }
    }

    private static func tableCopies() {
        TestRunner.suite("Duplicating a table") {
            let db = sample()
            let original = db.tables[0]
            let copy = original.duplicated()
            TestRunner.expect(copy.id != original.id, "new table id")
            TestRunner.expect(Set(copy.fields.map(\.id)).isDisjoint(with: original.fields.map(\.id)), "new field ids")
            TestRunner.expect(Set(copy.records.map(\.id)).isDisjoint(with: original.records.map(\.id)), "new record ids")
            TestRunner.equal(copy.records.count, original.records.count, "every record")
            let link = copy.fields.first { $0.type == .link }!
            TestRunner.equal(link.options.linkedTableID, copy.id, "a link within the table points at the copy")
            TestRunner.expect(copy.records[0][link.id]?.links.first == copy.records[1].id, "links point at the copied records")
            TestRunner.equal(copy.views[0].filter.rules[0].fieldID, copy.fields.first { $0.type == .rating }!.id, "views use the new fields")
            TestRunner.equal(copy.summaries[0].fieldID, copy.fields.first { $0.type == .number }!.id, "totals use the new fields")
            let resolver = Resolver(database: Database(tables: [copy]), table: copy)
            TestRunner.equal(resolver.text(copy.records[0], copy.fields.first { $0.type == .formula }!), resolver.text(copy.records[0], copy.fields.first { $0.type == .formula }!), "formulas work in the copy")
            TestRunner.equal(copy.records.map { r in r.values.count }, original.records.map { r in r.values.count }, "all values copied")

            let document = GolleDocument(database: db)
            document.duplicateTable(original.id)
            TestRunner.equal(document.database.tables.last?.name, "Albums copy", "named as a copy")
            document.moveTable(document.database.tables.last!.id, before: original.id)
            TestRunner.equal(document.database.tables.first?.name, "Albums copy", "tables reorder")
        }
    }

    private static func colourRules() {
        TestRunner.suite("Colour rules") {
            var db = sample()
            let rating = field(db, .rating)
            let checkbox = field(db, .checkbox)
            db.tables[0].colorRules = [
                ColorRule(color: .red, filter: Filter(rules: [FilterRule(fieldID: rating.id, op: .greaterOrEqual, operand: "4")])),
                ColorRule(color: .green, filter: Filter(rules: [FilterRule(fieldID: checkbox.id, op: .isChecked)])),
                ColorRule(color: .blue, filter: Filter()),
            ]
            let resolver = Resolver(database: db, table: db.tables[0])
            TestRunner.equal(db.tables[0].color(of: db.tables[0].records[0], resolver), .red, "first matching rule wins")
            TestRunner.equal(db.tables[0].color(of: db.tables[0].records[1], resolver), nil, "a rule without conditions colours nothing")
            do {
                let read = try DatabaseFile.decode(DatabaseFile.encode(db))
                TestRunner.equal(read.tables[0].colorRules, db.tables[0].colorRules, "saved")
            } catch {
                TestRunner.expect(false, "save threw \(error)")
            }
        }
    }

    private static func batchEdit() {
        TestRunner.suite("Batch edit") {
            let undo = UndoManager()
            undo.groupsByEvent = false
            let document = GolleDocument(database: sample())
            document.undoManager = undo
            let table = document.database.tables[0]
            let choice = field(document.database, .choice)
            let ids = Set(table.records.map(\.id))
            undo.beginUndoGrouping()
            document.setValue(.choices(["Rock"]), records: ids, field: choice.id, table: table.id)
            undo.endUndoGrouping()
            TestRunner.expect(document.database.tables[0].records.allSatisfy { $0[choice.id] == .choices(["Rock"]) }, "every record set")
            TestRunner.equal(undo.undoActionName, "Edit 3 Records", "one undo step")
            undo.undo()
            TestRunner.equal(document.database.tables[0].records[0][choice.id], .choices(["Jazz"]), "undo restores each value")
            TestRunner.equal(document.database.tables[0].records[1][choice.id], nil, "including empty ones")
        }
    }

    private static func excel() {
        TestRunner.suite("Excel") {
            TestRunner.equal(XLSX.column(0), "A", "column A")
            TestRunner.equal(XLSX.column(27), "AB", "column AB")
            TestRunner.equal(XLSX.columnIndex("AB12"), 27, "reference to index")
            let day = Calendar.current.date(from: DateComponents(year: 2024, month: 3, day: 5))!
            TestRunner.equal(XLSX.serial(day), 45356, "Excel date serial")
            TestRunner.equal(XLSX.date(fromSerial: 45356), day, "serial back to a date")

            let db = sample()
            let resolver = Resolver(database: db, table: db.tables[0])
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("golle-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent("Albums.xlsx")
                try Exporter.xlsx(db.tables[0].records, resolver: resolver).write(to: url)
                let rows = try XLSX.read(url)
                TestRunner.equal(rows.count, 4, "header and three records")
                TestRunner.equal(rows[0], db.tables[0].fields.map(\.name), "header")
                let row = Dictionary(uniqueKeysWithValues: zip(rows[0], rows[1]))
                TestRunner.equal(row["Text"], "Kind of Blue", "text")
                TestRunner.equal(row["Number"], "1959.5", "number")
                TestRunner.equal(row["Date"], sampleDate.formatted(Value.isoDay), "date comes back as a date")
                TestRunner.equal(row["Checkbox"], "Yes", "boolean")
                TestRunner.equal(row["Rating"], "4", "rating as a number")
                TestRunner.equal(row["Long Text"], "Line one\nLine two", "newlines survive")
                TestRunner.equal(row["Linked Records"], "Blue Train", "links by title")
                let typed = db.tables[0].fields.enumerated().filter { !$0.element.type.isAutomatic }.map(\.offset)
                TestRunner.equal(typed.map { rows[2].count > $0 ? rows[2][$0] : "" }.filter { !$0.isEmpty }, ["Blue Train"], "empty cells stay empty")
                TestRunner.equal(Importer.guessType(rows.dropFirst().map { $0.count > 2 ? $0[2] : "" }), .number, "imports as numbers")
            } catch {
                TestRunner.expect(false, "Excel threw \(error)")
            }
        }
    }

    private static func barcodes() {
        TestRunner.suite("Barcodes") {
            TestRunner.equal(Lookup.clean("978-0-14-032872-1"), "9780140328721", "clean ISBN")
            TestRunner.expect(Lookup.isISBN("9780140328721"), "valid ISBN-13")
            TestRunner.expect(!Lookup.isISBN("9780140328722"), "bad check digit")
            TestRunner.expect(Lookup.isISBN("0-14-032872-X") == Lookup.checksum10("014032872X"), "ISBN-10 with X")
            TestRunner.expect(Lookup.isISBN("0140328726"), "valid ISBN-10")
            TestRunner.expect(!Lookup.isISBN("5099902987620"), "a CD barcode is not an ISBN")
            TestRunner.equal(LookupFiller.choice(for: "12\" Vinyl", in: ["LP", "CD"]), "LP", "vinyl becomes LP")
            TestRunner.equal(LookupFiller.choice(for: "CD", in: ["LP", "CD"]), "CD", "CD")
            TestRunner.equal(LookupFiller.choice(for: "Cassette", in: ["LP"]), "Cassette", "unknown format kept")

            // The record collection template: title, artist link (new artist record), year, format, cover.
            let db = Template.all.first { $0.id == "music" }!.make()
            let albums = db.tables[0]
            let result = LookupResult(kind: .music, code: "5099902987620", title: "Blue Train", creators: ["John Coltrane", "Miles Davis"],
                                      year: 1957, format: "12\" Vinyl", source: "test")
            let cover = Attachment(name: "cover.jpg")
            let (values, newLinked) = LookupFiller.values(for: result, in: albums, database: db, cover: cover)
            func value(_ name: String) -> Value? { albums.field(named: name).flatMap { values[$0.id] } }
            TestRunner.equal(value("Title"), .text("Blue Train"), "title")
            TestRunner.equal(value("Year"), .number(1957), "year")
            TestRunner.equal(value("Format"), .choices(["LP"]), "format as the field's option")
            TestRunner.equal(value("Cover"), .attachments([cover]), "cover")
            TestRunner.equal(newLinked.count, 1, "a new artist for the unknown name only")
            TestRunner.equal(value("Artist")?.links.count, 2, "both artists linked")
            let miles = db.tables[1].records[0].id
            TestRunner.expect(value("Artist")?.links.contains(miles) == true, "existing artist reused")
        }
    }

    private static func markdown() {
        TestRunner.suite("Formatted text") {
            func roundTrip(_ md: String) -> String { Markdown.markdown(Markdown.attributed(md)) }
            for sample in ["plain text", "**bold** and *italic*", "~~gone~~ and `code`", "# Title", "## Sub", "### Small",
                           "- one\n- two", "1. first\n2. second", "a [link](https://example.com) here",
                           "line one\n\nline three", "**bold *both* bold**", "2 * 3 = 6", "snake_case_name",
                           "\\*not italic\\*", "\\# not a heading", ""] {
                TestRunner.equal(roundTrip(sample), sample, "round trip: \(sample)")
            }
            let text = Markdown.attributed("# Big\n**b** - *i*")
            let heading = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            TestRunner.expect((heading?.pointSize ?? 0) > Markdown.bodySize * 1.4, "heading is large")
            TestRunner.equal(Markdown.plain("**Kind** of *Blue*\n- side A"), "Kind of Blue\n• side A", "plain text for tables")
            for sample in ["**bold *both* bold**", "# T\n- a\n1. b", "a [link](https://x.y) `code` ~~s~~ \\*lit\\*", "2 * 3 snake_case", "plain"] {
                TestRunner.equal(Markdown.plain(sample), Markdown.attributed(sample).string, "quick plain text matches the editor: \(sample)")
            }
            // What the editor produces from typed formatting.
            let typed = NSMutableAttributedString(string: "Hello world", attributes: [.font: NSFont.systemFont(ofSize: Markdown.bodySize)])
            typed.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: Markdown.bodySize), range: NSRange(location: 6, length: 5))
            TestRunner.equal(Markdown.markdown(typed), "Hello **world**", "bold from the editor")
            let spaced = NSMutableAttributedString(string: "a bold b", attributes: [.font: NSFont.systemFont(ofSize: Markdown.bodySize)])
            spaced.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: Markdown.bodySize), range: NSRange(location: 1, length: 6))
            TestRunner.equal(Markdown.markdown(spaced), "a **bold** b", "spaces stay outside the marks")
            TestRunner.equal(Markdown.plain(Markdown.markdown(NSAttributedString(string: "price: 5*3"))), "price: 5*3", "a star between characters reads back as typed")
            TestRunner.equal(Markdown.markdown(NSAttributedString(string: "2 * 3")), "2 * 3", "a lone star between spaces stays as is")

            // Formatting the editor produces must come back the same after save and reload.
            let base = NSFont.systemFont(ofSize: Markdown.bodySize)
            func styled(_ parts: [(String, NSFont, [NSAttributedString.Key: Any])]) -> NSAttributedString {
                let text = NSMutableAttributedString()
                for (s, font, extra) in parts {
                    var attrs: [NSAttributedString.Key: Any] = [.font: font]
                    extra.forEach { attrs[$0.key] = $0.value }
                    text.append(NSAttributedString(string: s, attributes: attrs))
                }
                return text
            }
            let bold = NSFont.boldSystemFont(ofSize: Markdown.bodySize)
            let italic = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
            let code = NSFont.monospacedSystemFont(ofSize: Markdown.bodySize * 0.95, weight: .regular)
            @MainActor func survives(_ text: NSAttributedString, _ label: String) {
                let once = Markdown.markdown(text)
                let twice = Markdown.markdown(Markdown.attributed(once))
                TestRunner.equal(twice, once, "\(label) is stable (\(once))")
                TestRunner.equal(Markdown.attributed(once).string, text.string, "\(label) keeps its text")
            }
            survives(styled([("#1 priority", bold, [:])]), "bold line starting with #")
            survives(styled([("- not a list", bold, [:])]), "bold line starting with a dash")
            survives(styled([("foo", base, [:]), ("bar", italic, [:])]), "italic inside a word")
            survives(styled([("5", base, [:]), ("x", italic, [:])]), "italic after a digit")
            survives(styled([("see ", base, [:]), ("Foo", base, [.link: URL(string: "https://en.wikipedia.org/wiki/Foo_(bar)")!])]), "link with brackets")
            survives(styled([("_x_ [a]", base, [.link: URL(string: "https://x.com")!])]), "link text with marks")
            survives(styled([("a`b", code, [:])]), "code with a backtick")
            survives(styled([("a\\*b", code, [:])]), "code with a backslash")
            let reread = Markdown.attributed(Markdown.markdown(styled([("Foo", base, [.link: URL(string: "https://en.wikipedia.org/wiki/Foo_(bar)")!])])))
            TestRunner.equal((reread.attribute(.link, at: 0, effectiveRange: nil) as? URL)?.absoluteString.removingPercentEncoding, "https://en.wikipedia.org/wiki/Foo_(bar)", "link address survives")
            TestRunner.equal(Markdown.markdown(NSAttributedString(string: "a *star* here")), "a \\*star\\* here", "typed marks that would format are escaped")
            TestRunner.equal(Markdown.plain(Markdown.markdown(NSAttributedString(string: "**x** _y_ ~~z~~ `c`"))), "**x** _y_ ~~z~~ `c`", "escaped marks read back as typed")
        }
    }

    private static func history() {
        TestRunner.suite("Record history") {
            let undo = UndoManager()
            undo.groupsByEvent = false
            let document = GolleDocument(database: sample())
            document.undoManager = undo
            let table = document.database.tables[0]
            let title = table.fields[0]
            let record = table.records[0]
            undo.beginUndoGrouping()
            for text in ["K", "Ki", "Kin"] { document.setValue(.text(text), record: record.id, field: title.id, table: table.id) }
            undo.endUndoGrouping()
            var changes = document.database.tables[0].history[record.id] ?? []
            TestRunner.equal(changes.count, 1, "typing in one field is one entry")
            TestRunner.equal(changes.first?.old, .text("Kind of Blue"), "old value")
            TestRunner.equal(changes.first?.new, .text("Kin"), "new value")
            _ = try? document.snapshot(contentType: .golleDatabase)
            undo.beginUndoGrouping()
            document.setValue(.text("Kind"), record: record.id, field: title.id, table: table.id)
            undo.endUndoGrouping()
            changes = document.database.tables[0].history[record.id] ?? []
            TestRunner.equal(changes.count, 2, "a later edit is a new entry")
            undo.undo()
            TestRunner.equal(document.database.tables[0].history[record.id]?.count, 1, "undo takes the entry back")
            undo.removeAllActions()
            document.undoManager = nil
            for i in 0..<150 {
                _ = try? document.snapshot(contentType: .golleDatabase)
                document.setValue(.text("v\(i)"), record: record.id, field: title.id, table: table.id)
            }
            TestRunner.equal(document.database.tables[0].history[record.id]?.count, Change.limit, "kept to the limit")
            TestRunner.equal(document.database.tables[0].history[record.id]?.last?.new, .text("v149"), "newest kept")
            do {
                let read = try DatabaseFile.decode(DatabaseFile.encode(document.database))
                TestRunner.equal(read.tables[0].history[record.id], document.database.tables[0].history[record.id], "history is saved")
            } catch {
                TestRunner.expect(false, "save threw \(error)")
            }
            var table2 = DataTable(name: "T", fields: [title])
            table2.recordChange(record.id, field: title.id, old: .text("a"), new: .text("b"), continuing: false)
            table2.recordChange(record.id, field: title.id, old: .text("b"), new: .text("a"), continuing: true)
            TestRunner.expect(table2.history[record.id] == nil, "typing back to the start is no change")
        }
    }

    private static func checklists() {
        TestRunner.suite("Checklists") {
            let field = Field(name: "Tasks", type: .checklist)
            let items = [CheckItem(text: "Clean", done: true), CheckItem(text: "Sleeve"), CheckItem(text: "Play")]
            var record = Record()
            record[field.id] = .checklist(items)
            TestRunner.equal(record[field.id]?.display(for: field), "1/3 done", "progress")
            let table = DataTable(name: "T", fields: [field], records: [record])
            let resolver = Resolver(database: Database(tables: [table]), table: table)
            TestRunner.expect(!FilterRule(fieldID: field.id, op: .isChecked).matches(record, resolver), "not all done")
            TestRunner.expect(FilterRule(fieldID: field.id, op: .contains, operand: "sleeve").matches(record, resolver), "contains an item")
            var done = record
            done[field.id] = .checklist(items.map { CheckItem(id: $0.id, text: $0.text, done: true) })
            TestRunner.expect(FilterRule(fieldID: field.id, op: .isChecked).matches(done, resolver), "all done")
            TestRunner.equal(Value.text("[x] a\n[ ] b\n- c").converted(to: .checklist)?.checkItems.map(\.text), ["a", "b", "c"], "text to checklist")
            TestRunner.equal(Value.text("[x] a\n[ ] b").converted(to: .checklist)?.checkItems.map(\.done), [true, false], "ticks from text")
            do {
                let read = try DatabaseFile.decode(DatabaseFile.encode(Database(tables: [table])))
                TestRunner.equal(read.tables[0].records[0][field.id], record[field.id], "saved")
            } catch {
                TestRunner.expect(false, "save threw \(error)")
            }
        }
    }

    private static func tags() {
        TestRunner.suite("Coloured options") {
            var field = Field(name: "Format", type: .choice, options: FieldOptions(choices: ["LP", "CD", "Tape"]))
            TestRunner.equal(field.color(of: "LP"), AccentChoice.allCases[0], "colour by position")
            TestRunner.equal(field.color(of: "CD"), AccentChoice.allCases[1], "next colour")
            field.options.choiceColors["CD"] = .teal
            TestRunner.equal(field.color(of: "CD"), .teal, "chosen colour")
            TestRunner.equal(field.color(of: "Unknown"), nil, "values not in the list: no colour")

            let document = GolleDocument(database: sample())
            let table = document.database.tables[0]
            let choice = Tests.field(document.database, .choice)
            document.renameChoice("Jazz", to: "Modern Jazz", field: choice.id, table: table.id)
            let renamed = document.database.tables[0]
            TestRunner.equal(renamed.field(choice.id)?.options.choices.first, "Modern Jazz", "option renamed")
            TestRunner.equal(renamed.records[0][choice.id], .choices(["Modern Jazz"]), "records follow")
        }
    }

    private static func charts() {
        TestRunner.suite("Chart data") {
            let format = Field(name: "Format", type: .choice, options: FieldOptions(choices: ["LP", "CD", "Tape"]))
            let price = Field(name: "Price", type: .number)
            let bought = Field(name: "Bought", type: .date)
            let tags = Field(name: "Tags", type: .multiChoice, options: FieldOptions(choices: ["a", "b"]))
            func record(_ f: String?, _ p: Double, month: Int, tags t: [String] = []) -> Record {
                var r = Record()
                r[format.id] = f.map { .choices([$0]) }
                r[price.id] = .number(p)
                r[bought.id] = .date(Calendar.current.date(from: DateComponents(year: 2026, month: month, day: 15))!)
                r[tags.id] = t.isEmpty ? nil : .choices(t)
                return r
            }
            let records = [record("CD", 10, month: 1, tags: ["a", "b"]), record("LP", 20, month: 1, tags: ["a"]), record("LP", 30, month: 3), record(nil, 5, month: 3)]
            let table = DataTable(name: "T", fields: [format, price, bought, tags], records: records)
            let resolver = Resolver(database: Database(tables: [table]), table: table)
            var settings = ChartSettings()
            settings.categoryFieldID = format.id
            var points = ChartData.points(records, settings: settings, resolver)
            TestRunner.equal(points.map(\.label), ["LP", "CD", "No Format"], "the field's option order, empty last")
            TestRunner.equal(points.map(\.value), [2, 1, 1], "counts")
            TestRunner.equal(points.map(\.slot), [0, 1, 2], "colour slots by position, not size")
            settings.measure = .sum
            settings.valueFieldID = price.id
            TestRunner.equal(ChartData.points(records, settings: settings, resolver).map(\.value), [50, 10, 5], "sums")
            settings.measure = .average
            TestRunner.equal(ChartData.points(records, settings: settings, resolver).first?.value, 25, "average")
            settings = ChartSettings()
            settings.categoryFieldID = bought.id
            settings.kind = .line
            points = ChartData.points(records, settings: settings, resolver)
            TestRunner.equal(points.map(\.value), [2, 0, 2], "per month, including empty months")
            settings.categoryFieldID = tags.id
            settings.kind = .bar
            points = ChartData.points(records, settings: settings, resolver)
            TestRunner.equal(points.map(\.label), ["a", "b", "No Tags"], "multiple choice counts each option")
            TestRunner.equal(points.map(\.value), [2, 1, 2], "multiple choice counts")
            let many = Field(name: "Name", type: .text)
            let crowd = (1...12).map { i -> Record in var r = Record(); r[many.id] = .text("Item \(i)"); return r }
            let crowdTable = DataTable(name: "C", fields: [many], records: crowd)
            settings.categoryFieldID = many.id
            points = ChartData.points(crowd, settings: settings, Resolver(database: Database(tables: [crowdTable]), table: crowdTable))
            TestRunner.equal(points.count, ChartData.maxSlots, "more than eight fold into Other")
            TestRunner.equal(points.last?.label, "Other", "Other last")
            TestRunner.equal(points.last?.value, 5, "Other sums the rest")
            TestRunner.equal(points.last?.slot, nil, "Other has no colour slot")
        }
    }

    private static func columnsAndDashboard() {
        TestRunner.suite("Columns and dashboard") {
            var db = sample()
            let table = db.tables[0]
            var view = SavedView(name: "Narrow")
            view.hiddenFieldIDs = Array(table.fields.dropFirst(2).map(\.id))
            TestRunner.equal(view.visibleFields(table).map(\.id), Array(table.fields.prefix(2).map(\.id)), "hidden fields drop out")
            view.hiddenFieldIDs = table.fields.map(\.id)
            TestRunner.equal(view.visibleFields(table).count, 1, "at least one column stays")
            view.columnData = Data("{}".utf8)
            view.chart.kind = .pie
            db.tables[0].views = [view]
            var tile = DashboardTile(tableID: table.id)
            tile.chart.kind = .line
            tile.title = "Spending"
            var number = DashboardTile(tableID: table.id, kind: .number)
            number.summary = .sum
            number.fieldID = field(db, .number).id
            db.dashboard = [tile, number]
            do {
                let read = try DatabaseFile.decode(DatabaseFile.encode(db))
                TestRunner.equal(read.dashboard, db.dashboard, "dashboard saved")
                TestRunner.equal(read.tables[0].views, db.tables[0].views, "columns and chart settings saved")
            } catch {
                TestRunner.expect(false, "save threw \(error)")
            }
            let resolver = Resolver(database: db, table: table)
            TestRunner.equal(ChartData.number(table.records, tile: DashboardTile(tableID: table.id, kind: .number), resolver), "3", "count tile")
            TestRunner.equal(ChartData.number(table.records, tile: number, resolver), Value.numberFormatter.string(from: 1959.5)!, "sum tile")
        }
    }

    private static func fastSearch() {
        TestRunner.suite("Fast search") {
            let db = sample()
            let resolver = Resolver(database: db, table: db.tables[0])
            let haystack = Query.haystack(resolver)
            for query in ["blue", "kind blue", "FOLK", "line two", "example.com/u", "3919", "cover.png", "nothing-matches", ""] {
                let slow = Query.visible(resolver, view: SavedView(name: "v"), search: query).map(\.id)
                let fast = Query.visible(resolver, view: SavedView(name: "v"), search: query, haystack: haystack).map(\.id)
                TestRunner.equal(fast, slow, "same results for “\(query)”")
            }
        }
    }

    /// One check per bug from the bug scan, so they stay fixed.
    private static func bugScanFixes() {
        TestRunner.suite("Bug scan: numbers and dates") {
            for bad in ["inf", "Infinity", "1e400", "nan", "A1", "B12", "v2", "12:30", "+31 6 12345678", "0x10"] {
                TestRunner.equal(Value.parseNumber(bad), nil, "not a number: \(bad)")
            }
            TestRunner.equal(Value.parseNumber("€ 12,50"), 12.5, "currency with decimal comma")
            TestRunner.equal(Value.parseNumber("1.250,50"), 1250.5, "thousands dot, decimal comma")
            TestRunner.equal(Value.parseNumber("1,250.50"), 1250.5, "thousands comma, decimal dot")
            TestRunner.equal(Value.parseNumber("12 kg"), 12, "unit")
            TestRunner.equal(Value.parseNumber("-3.5"), -3.5, "negative")
            TestRunner.equal(Value.parseNumber("25%"), 25, "percent")
            TestRunner.equal(Value.number(1e20).converted(to: .rating), .rating(5), "huge number to rating doesn't crash")
            TestRunner.equal(Value.number(.infinity).converted(to: .rating), nil, "infinity to rating")
            TestRunner.equal(Value.parseDate("31-02-2024"), nil, "31 February is refused")
            let order = Importer.dateOrder(["03/14/2024", "03/04/2024"])
            TestRunner.equal(order, .monthDayYear, "a column with 03/14 is month first")
            let day = Field(name: "D", type: .date)
            let records = Importer.records([["03/14/2024"], ["03/04/2024"]], columns: [(0, day)])
            TestRunner.equal(records.map { $0[day.id]?.date.map { Calendar.current.component(.month, from: $0) } ?? nil }, [3, 3], "the whole column is read month first")
            let moment = Calendar.current.date(from: DateComponents(year: 2024, month: 1, day: 5, hour: 21, minute: 30))!
            TestRunner.equal(Value.parseDate("2024-01-05T21:30:00"), moment, "date-time without a zone is local time")
        }

        TestRunner.suite("Bug scan: files") {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("golle-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let csv = folder.appendingPathComponent("latin.csv")
            try? "Naam,Plaats\nRené,Zürich\n".data(using: .windowsCP1252)!.write(to: csv)
            TestRunner.equal((try? CSV.read(csv)).map { CSV.parse($0) }, [["Naam", "Plaats"], ["René", "Zürich"]], "Windows-1252 CSV")
            var db = sample()
            db.tables[0].records[1][Tests.field(db, .number).id] = .number(.infinity)
            TestRunner.expect((try? Exporter.json(db)) != nil, "JSON export with an infinite number doesn't crash")
            // Excel date-times come back at the same local time.
            let when = Field(name: "When", type: .createdAt)
            let table = DataTable(name: "T", fields: [when], records: [Record()])
            let url = folder.appendingPathComponent("t.xlsx")
            try? Exporter.xlsx(table.records, resolver: Resolver(database: Database(tables: [table]), table: table)).write(to: url)
            let cell = (try? XLSX.read(url))?.dropFirst().first?.first ?? ""
            let created = table.records[0].created
            TestRunner.expect(Value.parseDate(cell).map { abs($0.timeIntervalSince(created)) < 1 } == true, "Excel date-time round trip in local time (\(cell))")
            // One unreadable saved view doesn't drop the others.
            let json = #"{"views":[{"id":"\#(UUID().uuidString)","name":"Good"},{"id":"bad","name":7},{"id":"\#(UUID().uuidString)","name":"Also good","filter":{"rules":[{"id":"\#(UUID().uuidString)","fieldID":"\#(UUID().uuidString)","op":"newOperator"}]}}]}"#
            let settings = try? JSONDecoder().decode(TableSettings.self, from: Data(json.utf8))
            TestRunner.equal(settings?.views.map(\.name), ["Good", "Also good"], "readable views are kept")
            TestRunner.equal(settings?.views.last?.filter.rules.count, 0, "an unknown rule is skipped, not the view")
            // Attachments that only history refers to are still saved.
            let image = Field(name: "Photo", type: .image)
            var photos = DataTable(name: "P", fields: [image], records: [Record()])
            let old = Attachment(name: "old.png")
            photos.recordChange(photos.records[0].id, field: image.id, old: .attachments([old]), new: nil, continuing: false)
            TestRunner.expect(Database(tables: [photos]).referencedAttachments.contains(old), "history attachments are kept on save")
        }

        TestRunner.suite("Bug scan: formulas") {
            // Two tables whose formulas look each other up: an error, not a crash.
            let linkA = UUID(), linkB = UUID()
            var a = DataTable(name: "A")
            var b = DataTable(name: "B")
            a.fields = [Field(id: linkA, name: "L", type: .link, options: FieldOptions(linkedTableID: b.id)),
                        Field(name: "F", type: .formula, options: FieldOptions(formula: "COUNT(LOOKUP({L}, \"G\"))"))]
            b.fields = [Field(id: linkB, name: "L", type: .link, options: FieldOptions(linkedTableID: a.id)),
                        Field(name: "G", type: .formula, options: FieldOptions(formula: "COUNT(LOOKUP({L}, \"F\"))"))]
            var ra = Record(), rb = Record()
            ra[linkA] = .links([rb.id]); rb[linkB] = .links([ra.id])
            a.records = [ra]; b.records = [rb]
            let db = Database(tables: [a, b])
            let result = Resolver(database: db, table: a).formulaValue(ra, a.fields[1])
            TestRunner.expect(result.error != nil || result.value != nil, "cross-table formula loop ends")
            func eval(_ formula: String) -> Resolver.Computed {
                let f = Field(name: "F", type: .formula, options: FieldOptions(formula: formula))
                let t = DataTable(name: "T", fields: [f], records: [Record()])
                return Resolver(database: Database(tables: [t]), table: t).formulaValue(t.records[0], f)
            }
            TestRunner.expect(eval("ADDDAYS(TODAY(), 1e20)").error != nil, "huge ADDDAYS is an error")
            TestRunner.expect(eval("LEFT(\"abc\", SQRT(-1))").error != nil, "LEFT with NaN is an error")
            TestRunner.expect(eval("DATE(1e20, 1, 1)").error != nil, "huge DATE is an error")
            TestRunner.expect(eval("TODAY() + 1e20").error != nil, "huge date arithmetic is an error")
            // LOOKUP of a created date.
            let created = Field(name: "Created", type: .createdAt)
            var other = DataTable(name: "O", fields: [Field(name: "Name", type: .text), created], records: [Record()])
            other.records[0][other.fields[0].id] = .text("x")
            let link = Field(name: "L", type: .link, options: FieldOptions(linkedTableID: other.id))
            let latest = Field(name: "Latest", type: .formula, options: FieldOptions(formula: "MAX(LOOKUP({L}, \"Created\"))"))
            var main = DataTable(name: "M", fields: [link, latest], records: [Record()])
            main.records[0][link.id] = .links([other.records[0].id])
            TestRunner.expect(Resolver(database: Database(tables: [main, other]), table: main).value(main.records[0], latest) != nil, "LOOKUP of a created date")
        }

        TestRunner.suite("Bug scan: editing") {
            let undo = UndoManager()
            undo.groupsByEvent = false
            func step(_ body: () -> Void) { undo.beginUndoGrouping(); body(); undo.endUndoGrouping() }
            let document = GolleDocument(database: sample())
            document.undoManager = undo
            let table = document.database.tables[0]
            let choice = Tests.field(document.database, .choice)
            let record = table.records[0].id
            // Two separate board drops are two undo steps.
            step { document.setValue(.choices(["Rock"]), records: [record], field: choice.id, table: table.id) }
            step { document.setValue(.choices(["Folk"]), records: [record], field: choice.id, table: table.id) }
            undo.undo()
            TestRunner.equal(document.database.tables[0].records[0][choice.id], .choices(["Rock"]), "one undo takes back one drop")
            // Renaming an option, keystroke by keystroke, is one undo step.
            step { document.renameChoice("Rock", to: "Rocks", field: choice.id, table: table.id) }
            // The next keystroke joins the same undo step (it registers no undo of its own).
            document.renameChoice("Rocks", to: "Rocksteady", field: choice.id, table: table.id)
            undo.undo()
            TestRunner.equal(document.database.tables[0].field(choice.id)?.options.choices.contains("Rock"), true, "renaming an option is one step")
            document.undoManager = nil
            // Batch: adding one option keeps each record's others.
            let multi = Tests.field(document.database, .multiChoice)
            let all = Set(table.records.map(\.id))
            document.updateValues(records: all, field: multi.id, table: table.id) { value in
                var c = value?.choices ?? []; if !c.contains("Rock") { c.append("Rock") }; return .choices(c)
            }
            TestRunner.equal(document.database.tables[0].records[0][multi.id], .choices(["Jazz", "Folk", "Rock"]), "batch add keeps other options")
            TestRunner.equal(document.database.tables[0].records[1][multi.id], .choices(["Rock"]), "and adds to empty ones")
            // Text → Auto Number keeps numbers already typed.
            let t = document.addField(to: table.id, type: .text)!
            document.setValue(.text("12"), record: table.records[0].id, field: t, table: table.id)
            var f = document.database.tables[0].field(t)!
            f.type = .autoNumber
            document.updateField(f, in: table.id)
            TestRunner.equal(document.database.tables[0].records[0][t], .number(12), "existing number kept")
            TestRunner.equal(document.database.tables[0].records[1][t], .number(13), "others numbered after it")
            // Renaming a field updates the formulas that use it.
            var number = Tests.field(document.database, .number)
            number.name = "Price"
            document.updateField(number, in: table.id)
            TestRunner.equal(Tests.field(document.database, .formula).options.formula, "{Price} * 2", "formula follows the rename")
            var blank = number
            blank.name = "  "
            document.updateField(blank, in: table.id)
            TestRunner.equal(document.database.tables[0].field(number.id)?.name, "Price", "an empty name is refused")
            var dup = number
            dup.name = "text"
            document.updateField(dup, in: table.id)
            TestRunner.equal(document.database.tables[0].field(number.id)?.name, "Price", "a name in use is refused")
            // Import into an existing table: defaults and auto numbers.
            let auto = Field(name: "No", type: .autoNumber)
            let owned = Field(name: "Owned", type: .checkbox, options: FieldOptions(defaultValue: "yes"))
            let name = Field(name: "Name", type: .text)
            var existing = DataTable(name: "E", fields: [name, auto, owned])
            existing.records = [GolleDocument.newRecord(in: existing)]
            let importer = GolleDocument(database: Database(tables: [existing]))
            importer.importRecords(Importer.records([["a"], ["b"]], columns: [(0, name)]), newFields: [], into: existing.id, mapped: [name.id])
            TestRunner.equal(importer.database.tables[0].records.map { $0[auto.id] }, [.number(1), .number(2), .number(3)], "imported records numbered")
            TestRunner.equal(importer.database.tables[0].records.last?[owned.id], .bool(true), "imported records get defaults")
        }

        TestRunner.suite("Bug scan: views and layouts") {
            let undo = UndoManager()
            undo.groupsByEvent = false
            let document = GolleDocument(database: sample())
            document.undoManager = undo
            let table = document.database.tables[0]
            let rating = Tests.field(document.database, .rating)
            document.updateCurrentView { $0.filter.rules = [FilterRule(fieldID: rating.id, op: .isNotEmpty)] }
            undo.beginUndoGrouping()
            document.saveCurrentView(named: "Rated")
            undo.endUndoGrouping()
            undo.undo()
            TestRunner.expect(!document.currentView.filter.isEmpty, "undoing Save View brings the filter back")
            // Duplicating keeps chart and hidden fields on the copied fields.
            var db = sample()
            db.tables[0].views[0].hiddenFieldIDs = [db.tables[0].fields[2].id]
            db.tables[0].views[0].chart.categoryFieldID = db.tables[0].fields[5].id
            let copy = db.tables[0].duplicated()
            TestRunner.equal(copy.views[0].hiddenFieldIDs, [copy.fields[2].id], "hidden fields remapped")
            TestRunner.equal(copy.views[0].chart.categoryFieldID, copy.fields[5].id, "chart field remapped")
            // Groups whose names contain "/" stay apart.
            let f1 = Field(name: "A", type: .text), f2 = Field(name: "B", type: .text)
            var r1 = Record(); r1[f1.id] = .text("AC/DC"); r1[f2.id] = .text("x")
            var r2 = Record(); r2[f1.id] = .text("AC"); r2[f2.id] = .text("DC")
            let t2 = DataTable(name: "T", fields: [f1, f2], records: [r1, r2])
            let groups = Grouping.groups([r1, r2], by: [f1, f2], Resolver(database: Database(tables: [t2]), table: t2))
            let ids = groups.map(\.id) + groups.flatMap { $0.subgroups.map(\.id) }
            TestRunner.equal(Set(ids).count, ids.count, "group ids are unique")
            // A wide item dropped over two columns doesn't stack them.
            var layout = FormLayout(name: "T")
            layout.items = [LayoutItem(kind: .label("A"), x: 24, y: 24, width: 280, height: 48), LayoutItem(kind: .label("C"), x: 336, y: 24, width: 280, height: 48),
                            LayoutItem(kind: .label("B"), x: 24, y: 84, width: 280, height: 48), LayoutItem(kind: .label("D"), x: 336, y: 84, width: 280, height: 48)]
            var title = LayoutItem(kind: .title, x: 24, y: 150, width: 592, height: 40)
            let original = title.frame
            title.y = 30
            layout.items.append(title)
            layout.settle(title.id, from: original)
            let c = layout.items.first { $0.kind == .label("C") }!, a = layout.items.first { $0.kind == .label("A") }!
            TestRunner.equal(c.y, a.y, "side-by-side items stay side by side")
            var corner = LayoutItem(kind: .divider, x: 296, y: 24, width: 600, height: 40)
            corner.snap(within: CGSize(width: 640, height: 720), resizing: true)
            TestRunner.equal([corner.x, corner.width], [296, 344], "resizing stops at the page edge without moving")
        }

        TestRunner.suite("Bug scan: lookups") {
            let genre = Field(name: "Genre", type: .multiChoice, options: FieldOptions(choices: ["Rock", "Jazz"]))
            let code = Field(name: "Barcode", type: .number)
            let table = DataTable(name: "T", fields: [Field(name: "Title", type: .text), genre, code])
            let result = LookupResult(kind: .book, code: "014032872X", title: "X", genres: ["rock"], source: "test")
            let (values, _) = LookupFiller.values(for: result, in: table, database: Database(tables: [table]), cover: nil)
            TestRunner.equal(values[genre.id], .choices(["Rock"]), "the field's own spelling")
            TestRunner.equal(values[code.id], nil, "an ISBN with X stays out of a number field")
        }
    }
    private static func secondScanFixes() {
        TestRunner.suite("Second scan: formulas") {
            var table = DataTable(name: "T")
            var loop = Field(name: "A", type: .formula)
            loop.options.formula = "{A}+{A}+{A}+{A}"
            table.fields = [loop]
            table.records = [Record()]
            let start = Date()
            let result = Resolver(database: Database(tables: [table]), table: table).formulaValue(table.records[0], loop)
            TestRunner.expect(result.error != nil, "a formula referring to itself stops")
            TestRunner.expect(Date().timeIntervalSince(start) < 0.5, "and stops quickly (\(Date().timeIntervalSince(start)) s)")

            weak var gone: Resolver?
            do {
                let db = sample()
                let resolver = Resolver(database: db, table: db.tables[0])
                _ = db.tables.dropFirst().map { resolver.resolver(for: $0) }
                gone = resolver
            }
            TestRunner.expect(gone == nil, "a resolver is freed when it is no longer used")

            // Renaming a field changes LOOKUPs of it, not text that happens to match a half-typed name.
            let country = Field(name: "Country", type: .text)
            let artists = DataTable(name: "Artists", fields: [Field(name: "Name", type: .text), country])
            let artist = Field(name: "Artist", type: .link, options: FieldOptions(linkedTableID: artists.id))
            var origin = Field(name: "Origin", type: .formula)
            origin.options.formula = #"IF({Format}="LP", LOOKUP({Artist}, "Country"), "")"#
            var other = Field(name: "Other", type: .formula)
            other.options.formula = #"LOOKUP({Artist}, “Country”)"#
            let albums = DataTable(name: "Albums", fields: [Field(name: "Format", type: .text), artist, origin, other])
            let document = GolleDocument(database: Database(tables: [albums, artists]))
            for step in ["L", "LP", "LPs"] {
                var f = document.database.tables[1].field(country.id)!
                f.name = step
                document.updateField(f, in: artists.id)
            }
            TestRunner.equal(document.database.tables[0].field(origin.id)?.options.formula, #"IF({Format}="LP", LOOKUP({Artist}, "LPs"), "")"#, "only the LOOKUP argument is renamed")
            TestRunner.equal(document.database.tables[0].field(other.id)?.options.formula, #"LOOKUP({Artist}, “LPs”)"#, "curly quotes too")

            var spaced = document.database.tables[1].field(country.id)!
            spaced.name = "Land "
            document.updateField(spaced, in: artists.id)
            TestRunner.equal(document.database.tables[1].field(country.id)?.name, "Land", "names are stored trimmed")
            var accent = document.database.tables[1].fields[0]
            accent.name = "Lând"
            document.updateField(accent, in: artists.id)
            TestRunner.equal(document.database.tables[1].fields[0].name, "Name", "a name differing only in accents is taken")
        }

        TestRunner.suite("Second scan: numbers and dates") {
            let dot = Locale.current.decimalSeparator == "."
            TestRunner.equal(Value.parseNumber("1.250"), Value.parseNumber("€ 1.250"), "1.250 reads the same with or without a currency")
            TestRunner.equal(Value.parseNumber("1.250"), dot ? 1.25 : 1250, "1.250 follows the locale")
            TestRunner.equal(Value.parseNumber("0,125"), 0.125, "0,125 is a decimal")
            TestRunner.equal(Value.parseNumber("1234,567"), 1234.567, "1234,567 is a decimal")
            TestRunner.equal(Value.parseNumber("1e3"), 1000, "exponent")
            TestRunner.equal(Value.parseDate("2024-02-30"), nil, "30 February is refused")
            TestRunner.equal(Value.parseDate("2023-02-29"), nil, "29 February 2023 is refused")
            TestRunner.equal(Value.parseDate("1.2.3"), nil, "a version number is no date")
            let g = Value.gregorian
            let dayFirst = Value.parseDate("03/04/2024 10:00", order: .dayMonthYear)
            TestRunner.equal(dayFirst.map { g.component(.month, from: $0) }, 4, "a date with a time follows the column's order")
            TestRunner.equal(dayFirst.map { g.component(.hour, from: $0) }, 10, "and keeps its time")
            TestRunner.equal(Importer.dateOrder(["13/04/2024 10:00", "03/04/2024 09:00"]), .dayMonthYear, "date-times decide the order too")
            TestRunner.equal(Value.parseDate("2024-03-05").map { g.component(.year, from: $0) }, 2024, "ISO date")
            let march = g.date(from: DateComponents(year: 2024, month: 3, day: 5))!
            TestRunner.equal(XLSX.serial(march), 45356, "Excel serial")
            TestRunner.equal(XLSX.safeSheetName("Q1: Sales? [old]"), "Q1- Sales- -old-", "sheet names without forbidden characters")
            TestRunner.equal(XLSX.safeSheetName("''"), "Sheet1", "an empty sheet name gets one")
        }

        TestRunner.suite("Second scan: formatted text") {
            func attributed(_ pieces: [(String, Bool, Bool, Bool)]) -> NSAttributedString {
                let out = NSMutableAttributedString()
                for (text, bold, italic, code) in pieces {
                    out.append(NSAttributedString(string: text, attributes: Markdown.attributes(size: Markdown.bodySize, bold: bold, italic: italic, strike: false, code: code, color: .textColor)))
                }
                return out
            }
            func styles(_ markdown: String) -> [String] {
                Markdown.runs(markdown).flatMap { text, style in text.map { "\($0)\(style.bold ? "B" : "")\(style.italic ? "I" : "")\(style.code ? "C" : "")" } }
            }
            @MainActor func roundTrip(_ pieces: [(String, Bool, Bool, Bool)], _ label: String) {
                let expected = pieces.flatMap { text, b, i, c in text.map { "\($0)\(b ? "B" : "")\(i ? "I" : "")\(c ? "C" : "")" } }
                let md = Markdown.markdown(attributed(pieces))
                TestRunner.equal(styles(md), expected, "\(label) (\(md))")
            }
            roundTrip([("x", true, false, false), ("y", true, true, false), ("z", false, true, false)], "bold and italic overlapping")
            roundTrip([("c1", false, false, true), ("c2", true, false, true)], "bold inside code")
            roundTrip([("x", false, true, false), ("*", false, false, false)], "a star after italic")
            roundTrip([("*", false, false, false), ("x", true, false, false)], "a star before bold")
            roundTrip([("a ", false, false, false), ("b", false, true, false), ("* c", false, false, false)], "a star between")
            roundTrip([("2 * 3", false, false, false)], "a lone star")
        }

        TestRunner.suite("Second scan: records") {
            let number = Field(name: "No", type: .autoNumber)
            let name = Field(name: "Name", type: .text)
            var table = DataTable(name: "T", fields: [name, number])
            table.records = [GolleDocument.newRecord(in: table), GolleDocument.newRecord(in: table)]
            table.records[1][number.id] = .number(2)
            let document = GolleDocument(database: Database(tables: [table]))
            document.duplicateRecords([table.records[0].id], in: table.id)
            let numbers = document.database.tables[0].records.compactMap { $0[number.id]?.number }
            TestRunner.equal(Set(numbers).count, numbers.count, "a duplicate gets its own auto number")

            var imported = Importer.records([["a", ""], ["b", "1"], ["c", "9"], [" ", " "]], columns: [(0, name), (1, number)])
            TestRunner.equal(imported.count, 3, "a row of empty cells adds no record")
            document.importRecords(imported, newFields: [], into: table.id, mapped: [name.id, number.id])
            let all = document.database.tables[0].records.compactMap { $0[number.id]?.number }
            TestRunner.equal(all.count, document.database.tables[0].records.count, "every imported record is numbered")
            TestRunner.equal(Set(all).count, all.count, "and no number is used twice")
            imported = []
            TestRunner.equal(CSV.parse("a,b\n,,\n1,2\n"), [["a", "b"], ["1", "2"]], "CSV rows of empty cells are skipped")

            // A colour rule on a deleted field goes with it.
            let status = Field(name: "Status", type: .text)
            var ruled = DataTable(name: "R", fields: [name, status])
            ruled.records = [Record()]
            ruled.colorRules = [ColorRule(color: .green, filter: Filter(rules: [FilterRule(fieldID: status.id, op: .equals, operand: "Done")]))]
            let rules = GolleDocument(database: Database(tables: [ruled]))
            rules.deleteField(status.id, from: ruled.id)
            TestRunner.equal(rules.database.tables[0].colorRules.count, 0, "colour rule removed with its field")
            let orphan = ruled.colorRules
            var kept = rules.database.tables[0]
            kept.colorRules = orphan
            TestRunner.equal(kept.color(of: kept.records[0], Resolver(database: Database(tables: [kept]), table: kept)), nil, "a rule without fields colours nothing")

            // Restoring an old value converts it to the field's type now.
            TestRunner.equal(Value.text("12").converted(to: .number), .number(12), "old text restored into a number field")
        }

        TestRunner.suite("Second scan: charts") {
            let kind = Field(name: "Kind", type: .choice, options: FieldOptions(choices: ["Book", "Film", "Other"]))
            let price = Field(name: "Price", type: .number)
            var table = DataTable(name: "C", fields: [kind, price])
            for (k, p) in [("Book", 10.0), ("Book", nil), ("Other", 20.0)] as [(String, Double?)] {
                var r = Record()
                r[kind.id] = .choices([k])
                if let p { r[price.id] = .number(p) }
                table.records.append(r)
            }
            var settings = ChartSettings()
            settings.categoryFieldID = kind.id
            settings.valueFieldID = price.id
            settings.measure = .average
            let resolver = Resolver(database: Database(tables: [table]), table: table)
            let points = ChartData.points(table.records, settings: settings, resolver)
            TestRunner.equal(points.first { $0.label == "Other" }?.slot, 1, "an option called Other keeps its colour")
            TestRunner.equal(ChartData.measure(table.records, settings: settings, resolver), 15, "the overall average counts only values")
            let week = ChartData.label(Value.gregorian.date(from: DateComponents(year: 2025, month: 3, day: 3))!, .week)
            TestRunner.expect(week != ChartData.label(Value.gregorian.date(from: DateComponents(year: 2026, month: 3, day: 3))!, .week), "weeks of different years differ")
        }
    }
    private static func thirdScanFixes() {
        TestRunner.suite("Third scan: linked formulas") {
            var table = DataTable(name: "Ledger")
            let amount = Field(name: "Amount", type: .number)
            let prev = Field(name: "Prev", type: .link, options: FieldOptions(linkedTableID: table.id))
            var total = Field(name: "Total", type: .formula)
            total.options.formula = #"{Amount} + SUM(LOOKUP({Prev}, "Total"))"#
            table.fields = [amount, prev, total]
            for i in 0..<95 {
                var r = Record()
                r[amount.id] = .number(1)
                if i > 0 { r[prev.id] = .links([table.records[i - 1].id]) }
                table.records.append(r)
            }
            let resolver = Resolver(database: Database(tables: [table]), table: table)
            let newestFirst = table.records.reversed().map { resolver.formulaValue($0, total).value?.number }
            TestRunner.equal(newestFirst, (1...95).reversed().map { Double($0) }, "a running total is right in any order")

            var pair = DataTable(name: "Pair")
            let friend = Field(name: "Friend", type: .link, options: FieldOptions(linkedTableID: pair.id))
            var x = Field(name: "X", type: .formula)
            x.options.formula = #"1 + SUM(LOOKUP({Friend}, "X"))"#
            pair.fields = [friend, x]
            var a = Record(), b = Record()
            a[friend.id] = .links([b.id])
            b[friend.id] = .links([a.id])
            pair.records = [a, b]
            let cycle = Resolver(database: Database(tables: [pair]), table: pair)
            TestRunner.expect(cycle.formulaValue(a, x).error != nil && cycle.formulaValue(b, x).error != nil, "records that look each other up show an error")

            let cafe = Field(name: "Café", type: .number)
            var double = Field(name: "Double", type: .formula)
            double.options.formula = "{cafe} * 2"
            let menu = DataTable(name: "Menu", fields: [cafe, double])
            let document = GolleDocument(database: Database(tables: [menu]))
            var renamed = cafe
            renamed.name = "Koffie"
            document.updateField(renamed, in: menu.id)
            TestRunner.equal(document.database.tables[0].field(double.id)?.options.formula, "{Koffie} * 2", "a reference without accents is renamed too")
        }

        TestRunner.suite("Third scan: formatted text") {
            func attributed(_ pieces: [(String, Bool, Bool)]) -> NSAttributedString {
                let out = NSMutableAttributedString()
                for (text, italic, code) in pieces {
                    out.append(NSAttributedString(string: text, attributes: Markdown.attributes(size: Markdown.bodySize, bold: false, italic: italic, strike: false, code: code, color: .textColor)))
                }
                return out
            }
            @MainActor func roundTrip(_ pieces: [(String, Bool, Bool)], _ label: String) {
                // Whitespace at the edge of a style moves outside it, so its own style isn't compared.
                func mark(_ c: Character, _ i: Bool, _ code: Bool) -> String { c.isWhitespace && !code ? "\(c)" : "\(c)\(i ? "I" : "")\(code ? "C" : "")" }
                let expected = pieces.flatMap { text, i, c in text.map { mark($0, i, c) } }
                let md = Markdown.markdown(attributed(pieces))
                let got = Markdown.runs(md).flatMap { text, style in text.map { mark($0, style.italic, style.code) } }
                TestRunner.equal(got, expected, "\(label) (\(md))")
            }
            roundTrip([("a`", false, true)], "code ending in a backtick")
            roundTrip([("`", false, true)], "code that is a backtick")
            roundTrip([("a``b", false, true)], "code with two backticks")
            roundTrip([("x ", false, false), ("code", false, true), (" y", false, false)], "plain code")
            roundTrip([("my_`x", true, false)], "underscore before a backtick in italic")
            roundTrip([("b_~", true, false)], "underscore before a tilde in italic")
            roundTrip([("a\t", true, false), ("b", false, false)], "italic ending in a tab")
        }

        TestRunner.suite("Third scan: values and files") {
            TestRunner.equal(Value.parseNumber("00.500"), 0.5, "00.500 is a decimal")
            TestRunner.equal(Value.parseNumber("1.250.5"), nil, "1.250.5 is no number")
            TestRunner.equal(Value.parseNumber("-0x10"), nil, "no hex numbers")
            TestRunner.equal(Value.parseNumber("1.250.000"), 1_250_000, "thousands groups")
            TestRunner.equal(Value.parseDate("05/03/2024 25:00"), nil, "an impossible time is refused")
            TestRunner.expect(XLSX.safeSheetName("History") != "History", "Excel's reserved sheet name is avoided")
            TestRunner.expect(XLSX.safeSheetName(String(repeating: "😀", count: 20)).utf16.count <= 31, "sheet names fit in 31 UTF-16 units")

            let genre = Field(name: "Genre", type: .choice, options: FieldOptions(choices: ["Jazz", "Folk"]))
            var table = DataTable(name: "G", fields: [genre])
            table.colorRules = [ColorRule(color: .blue, filter: Filter(rules: [FilterRule(fieldID: genre.id, op: .equals, operand: "Jazz")]))]
            let document = GolleDocument(database: Database(tables: [table]))
            document.renameChoice("Jazz", to: "Bebop", field: genre.id, table: table.id)
            TestRunner.equal(document.database.tables[0].colorRules[0].filter.rules[0].operand, "Bebop", "colour rules follow a renamed option")

            let tags = Field(name: "Tags", type: .multiChoice, options: FieldOptions(choices: (1...10).map { "T\($0)" }))
            var tagged = DataTable(name: "Tagged", fields: [tags])
            for i in 1...7 { var r = Record(); r[tags.id] = .choices(["T\(i)"]); tagged.records.append(r) }
            var both = Record()
            both[tags.id] = .choices(["T9", "T10"])
            tagged.records.append(both)
            var settings = ChartSettings()
            settings.categoryFieldID = tags.id
            let points = ChartData.points(tagged.records, settings: settings, Resolver(database: Database(tables: [tagged]), table: tagged))
            TestRunner.equal(points.last?.value, 1, "Other counts a record in two of its categories once")
        }
    }
    private static func finalScanFixes() {
        TestRunner.suite("Final scan: formatted text") {
            // Pasted code keeps a colour per word: still one code span.
            let pasted = NSMutableAttributedString()
            for (word, color) in [("print", NSColor.systemPink), ("(", .textColor), ("x", .systemBlue), (")", .textColor)] {
                pasted.append(NSAttributedString(string: word, attributes: Markdown.attributes(size: Markdown.bodySize, bold: false, italic: false, strike: false, code: true, color: color)))
            }
            let md = Markdown.markdown(pasted)
            TestRunner.equal(Markdown.runs(md).map(\.0), ["print(x)"], "coloured code stays one span (\(md))")
            TestRunner.equal(Markdown.runs(md).first?.1.code, true, "and stays code")

            var text = "**x**\u{0B}y"
            for _ in 0..<3 { text = Markdown.markdown(Markdown.attributed(text)) }
            TestRunner.equal(text.filter { $0 == "\u{0B}" }.count, 1, "a line-break character from Word isn't doubled")
        }

        TestRunner.suite("Final scan: formulas and values") {
            var table = DataTable(name: "Ledger")
            let prev = Field(name: "Prev", type: .link, options: FieldOptions(linkedTableID: table.id))
            var total = Field(name: "Total", type: .formula)
            total.options.formula = #"1 + SUM(LOOKUP({Prev}, "Total"))"#
            table.fields = [prev, total]
            for i in 0..<250 {
                var r = Record()
                if i > 0 { r[prev.id] = .links([table.records[i - 1].id]) }
                table.records.append(r)
            }
            let resolver = Resolver(database: Database(tables: [table]), table: table)
            TestRunner.equal(resolver.formulaValue(table.records[249], total).value?.number, 250, "a running total over 250 records, newest first")

            let label = Field(name: "Label", type: .text)
            var labels = DataTable(name: "Labels", fields: [label])
            var blueNote = Record()
            blueNote[label.id] = .text("Blue Note")
            labels.records = [blueNote]
            let labelLink = Field(name: "Label", type: .link, options: FieldOptions(linkedTableID: labels.id))
            var artists = DataTable(name: "Artists", fields: [Field(name: "Name", type: .text), labelLink])
            var miles = Record()
            miles[labelLink.id] = .links([blueNote.id])
            artists.records = [miles]
            let artist = Field(name: "Artist", type: .link, options: FieldOptions(linkedTableID: artists.id))
            var via = Field(name: "Via", type: .formula)
            via.options.formula = #"JOIN(LOOKUP({Artist}, "Label"))"#
            var albums = DataTable(name: "Albums", fields: [artist, via])
            var album = Record()
            album[artist.id] = .links([miles.id])
            albums.records = [album]
            let db = Database(tables: [albums, artists, labels])
            TestRunner.equal(Resolver(database: db, table: albums).text(album, via), "Blue Note", "LOOKUP of a link field gives names")

            let price = Field(name: "Price", type: .number)
            var shown = Field(name: "Shown", type: .formula)
            shown.options.formula = #""Price {Price}: " & {Price}"#
            let shop = DataTable(name: "Shop", fields: [price, shown])
            let document = GolleDocument(database: Database(tables: [shop]))
            var cost = price
            cost.name = "Cost"
            document.updateField(cost, in: shop.id)
            TestRunner.equal(document.database.tables[0].field(shown.id)?.options.formula, #""Price {Price}: " & {Cost}"#, "text in quotes is left alone")

            TestRunner.equal(Value.parseNumber("10x"), 10, "10x is a number with a unit")
            TestRunner.equal(Value.parseNumber("0x10"), nil, "0x10 is not")
        }

        TestRunner.suite("Final scan: option rename and undo") {
            let undo = UndoManager()
            undo.groupsByEvent = false
            let genre = Field(name: "Genre", type: .choice, options: FieldOptions(choices: ["Jazz", "Folk"]))
            let table = DataTable(name: "G", fields: [genre])
            let document = GolleDocument(database: Database(tables: [table]))
            document.undoManager = undo
            document.scratchViews[table.id] = SavedView(name: "All Records", filter: Filter(rules: [FilterRule(fieldID: genre.id, op: .equals, operand: "Jazz")]))
            undo.beginUndoGrouping()
            document.renameChoice("Jazz", to: "Bebop", field: genre.id, table: table.id)
            undo.endUndoGrouping()
            TestRunner.equal(document.scratchViews[table.id]?.filter.rules.first?.operand, "Bebop", "All Records' filter follows the rename")
            undo.undo()
            TestRunner.equal(document.scratchViews[table.id]?.filter.rules.first?.operand, "Jazz", "and goes back on undo")
            document.renameChoice("Jazz", to: "Folk", field: genre.id, table: table.id)
            TestRunner.equal(document.scratchViews[table.id]?.filter.rules.first?.operand, "Jazz", "a refused rename changes nothing")
        }
    }
    private static func lookupsAndRules() {
        TestRunner.suite("Lookup fields") {
            var artists = DataTable(name: "Artists")
            let name = Field(name: "Name", type: .text)
            let country = Field(name: "Country", type: .text)
            let born = Field(name: "Born", type: .number)
            let style = Field(name: "Style", type: .multiChoice, options: FieldOptions(choices: ["Jazz", "Rock"]))
            artists.fields = [name, country, born, style]
            var miles = Record(); miles[name.id] = .text("Miles"); miles[country.id] = .text("USA"); miles[born.id] = .number(1926); miles[style.id] = .choices(["Jazz"])
            var bowie = Record(); bowie[name.id] = .text("Bowie"); bowie[country.id] = .text("UK"); bowie[born.id] = .number(1947); bowie[style.id] = .choices(["Rock", "Jazz"])
            artists.records = [miles, bowie]
            let link = Field(name: "Artist", type: .link, options: FieldOptions(linkedTableID: artists.id))
            func lookup(_ target: Field, through: Field.ID = link.id) -> Field {
                var f = Field(name: "Lookup \(target.name)", type: .lookup)
                f.options.rollupLinkFieldID = through
                f.options.rollupFieldID = target.id
                return f
            }
            let from = lookup(country), year = lookup(born), styles = lookup(style)
            var one = Record(); one[link.id] = .links([miles.id])
            var two = Record(); two[link.id] = .links([miles.id, bowie.id])
            let none = Record()
            var solo = Record(); solo[link.id] = .links([bowie.id])
            let albums = DataTable(name: "Albums", fields: [Field(name: "Title", type: .text), link, from, year, styles], records: [one, two, none, solo])
            let db = Database(tables: [albums, artists])
            let r = Resolver(database: db, table: albums)
            TestRunner.equal(r.value(one, from), .text("USA"), "one linked record: its value")
            TestRunner.equal(r.value(one, year), .number(1926), "a number stays a number")
            TestRunner.equal(r.text(one, year), "1926", "shown like the field it looks up")
            TestRunner.equal(r.text(two, from), "USA, UK", "several: a list")
            TestRunner.equal(r.value(two, styles), .choices(["Jazz", "Rock"]), "choices together, once each")
            TestRunner.equal(r.value(none, from), nil, "no links: empty")
            TestRunner.equal(Exporter.rollupTable(from, albums, db)?.id, artists.id, "the editor lists the linked table's fields")
            var retypedLink = albums
            retypedLink.fields[1].type = .text
            TestRunner.equal(Exporter.rollupTable(from, retypedLink, Database(tables: [retypedLink, artists])), nil, "not once the link is no longer a link")
            // Through "Linked From": the link field that points at this table, not just any link.
            var reverse = Field(name: "Albums", type: .lookup)
            reverse.options.rollupLinkFieldID = link.id
            let elsewhere = DataTable(name: "Other", fields: [Field(name: "To albums", type: .link, options: FieldOptions(linkedTableID: albums.id))])
            TestRunner.equal(Exporter.rollupTable(reverse, artists, Database(tables: [elsewhere, albums, artists]))?.id, albums.id, "Linked From finds the table linking here")
            TestRunner.equal(r.lookupTarget(from)?.field.id, country.id, "the looked-up field")
            // Sorting, filtering and totals work on the looked-up values.
            let sorted = Query.visible(r, view: SavedView(name: "", sort: [SortKey(fieldID: year.id, ascending: false)]), search: "")
            TestRunner.equal(sorted.filter { $0.id == one.id || $0.id == solo.id }.map(\.id), [solo.id, one.id], "sorts by the looked-up number")
            TestRunner.expect(FilterRule(fieldID: from.id, op: .equals, operand: "uk").matches(two, r), "filters on each looked-up value")
            TestRunner.expect(!FilterRule(fieldID: from.id, op: .equals, operand: "usa, uk").matches(one, r), "not on the list as a whole")
            TestRunner.expect(FilterRule(fieldID: year.id, op: .greater, operand: "1900").matches(one, r), "compares looked-up numbers")
            TestRunner.equal(SummaryKind.sum.compute([one, none].map { r.value($0, year) }, field: year), Value.numberFormatter.string(from: 1926), "adds up")
            TestRunner.equal(Exporter.cell(two, from, r), "USA, UK", "exports as shown")

            // Through Linked From: an artist looks up its albums' titles.
            let title = albums.fields[0]
            var withTitles = albums
            withTitles.records[0][title.id] = .text("Kind of Blue")
            withTitles.records[1][title.id] = .text("Mixed")
            var titles = Field(name: "Titles", type: .lookup)
            titles.options.rollupLinkFieldID = link.id
            titles.options.rollupFieldID = title.id
            var artists2 = artists
            artists2.fields.append(titles)
            let db2 = Database(tables: [withTitles, artists2])
            TestRunner.equal(Resolver(database: db2, table: artists2).text(miles, titles), "Kind of Blue, Mixed", "through Linked From")

            // Two lookups that look at each other stop instead of looping.
            var a = DataTable(name: "A"), b = DataTable(name: "B")
            let toB = Field(name: "B", type: .link, options: FieldOptions(linkedTableID: b.id))
            let toA = Field(name: "A", type: .link, options: FieldOptions(linkedTableID: a.id))
            var la = Field(name: "L", type: .lookup), lb = Field(name: "L", type: .lookup)
            la.options.rollupLinkFieldID = toB.id; la.options.rollupFieldID = lb.id
            lb.options.rollupLinkFieldID = toA.id; lb.options.rollupFieldID = la.id
            var ra = Record(), rb = Record()
            ra[toB.id] = .links([rb.id]); rb[toA.id] = .links([ra.id])
            a.fields = [toB, la]; a.records = [ra]
            b.fields = [toA, lb]; b.records = [rb]
            TestRunner.equal(Resolver(database: Database(tables: [a, b]), table: a).text(ra, la), "", "a circle of lookups is empty, not endless")

            // Deleting the looked-up field leaves the lookup unset, not pointing at nothing.
            let document = GolleDocument(database: db)
            document.deleteField(country.id, from: artists.id)
            TestRunner.equal(document.database.tables[0].field(from.id)?.options.rollupFieldID, nil, "deleted target is let go")
            TestRunner.equal(Value.text("x").converted(to: .lookup), nil, "nothing converts into a lookup")
            TestRunner.expect(FieldType.lookup.isComputed, "a lookup is computed")

            // The record collection template shows each album's artist country.
            let music = Template.all.first { $0.id == "music" }!.make()
            let musicAlbums = music.tables.first { $0.name == "Albums" }!
            let countryLookup = musicAlbums.fields.first { $0.type == .lookup }!
            let shown = musicAlbums.records.map { Resolver(database: music, table: musicAlbums).text($0, countryLookup) }
            TestRunner.expect(shown.contains("USA"), "template albums show their artist's country")
        }

        TestRunner.suite("Field rules") {
            var title = Field(name: "Title", type: .text)
            title.options.required = true
            var code = Field(name: "Code", type: .barcode)
            code.options.unique = true
            var table = DataTable(name: "T", fields: [title, code])
            var a = Record(); a[title.id] = .text("A"); a[code.id] = .text("123")
            var b = Record(); b[code.id] = .text("123")
            var c = Record(); c[title.id] = .text("C"); c[code.id] = .text("456")
            let d = Record()
            table.records = [a, b, c, d]
            let r = Resolver(database: Database(tables: [table]), table: table)
            TestRunner.equal(r.ruleProblem(a, title), nil, "filled in")
            TestRunner.equal(r.ruleProblem(b, title), .missing, "required and empty")
            TestRunner.equal(r.ruleProblem(a, code), .duplicate(1), "same code as another")
            TestRunner.equal(r.ruleProblem(c, code), nil, "a code of its own")
            TestRunner.equal(r.ruleProblem(d, code), nil, "empty cells don't clash")
            TestRunner.equal(r.sameValue(as: a, code).map(\.id), [b.id], "which record it clashes with")
            TestRunner.equal(r.ruleProblems(b).map(\.field.id), [title.id, code.id], "every broken rule, in field order")
            TestRunner.expect(r.hasRules, "the table has rules")

            var name = Field(name: "Name", type: .text)
            name.options.unique = true
            var t2 = DataTable(name: "T2", fields: [name])
            var x = Record(); x[name.id] = .text("Émile ")
            var y = Record(); y[name.id] = .text("emile")
            t2.records = [x, y]
            TestRunner.equal(Resolver(database: Database(tables: [t2]), table: t2).ruleProblem(x, name), .duplicate(1), "ignoring case, accents and spaces")
            TestRunner.equal(Resolver.RuleProblem.duplicate(2).message, "Same as 2 other records", "message")
            TestRunner.expect(!FieldType.checkbox.canBeRequired && !FieldType.formula.canBeRequired && FieldType.date.canBeRequired, "which types can be required")
            TestRunner.expect(FieldType.barcode.canBeUnique && !FieldType.image.canBeUnique && !FieldType.checkbox.canBeUnique, "which types can be unique")

            // Unique compares numbers as they are, not as rounded for showing; formula errors don't clash.
            var whole = NumberFormat()
            whole.decimals = 0
            var amount = Field(name: "Amount", type: .number, options: FieldOptions(numberFormat: whole))
            amount.options.unique = true
            var broken = Field(name: "Broken", type: .formula, options: FieldOptions(formula: "1 / {Nope}"))
            broken.options.unique = true
            var t3 = DataTable(name: "T3", fields: [amount, broken])
            var p = Record(); p[amount.id] = .number(1.2)
            var q = Record(); q[amount.id] = .number(1.4)
            t3.records = [p, q]
            let r3 = Resolver(database: Database(tables: [t3]), table: t3)
            TestRunner.equal(r3.ruleProblem(p, amount), nil, "1.2 and 1.4 both show as 1, but aren't the same")
            TestRunner.equal(r3.ruleProblem(p, broken), nil, "two formula errors aren't duplicates")

            // A link to a deleted record leaves the cell empty, so a required link is missing.
            var link = Field(name: "Artist", type: .link)
            link.options.required = true
            var t4 = DataTable(name: "T4", fields: [link])
            link.options.linkedTableID = t4.id
            t4.fields = [link]
            var dangling = Record(); dangling[link.id] = .links([UUID()])
            t4.records = [dangling]
            TestRunner.equal(Resolver(database: Database(tables: [t4]), table: t4).ruleProblem(dangling, link), .missing, "links to deleted records don't count")
            var retyped = title
            retyped.type = .checkbox
            let t5 = DataTable(name: "T5", fields: [retyped])
            TestRunner.expect(!Resolver(database: Database(tables: [t5]), table: t5).hasRules, "a rule the type can't have is no rule")

            // Value rules: a range, dates on one side of today, a pattern. Empty cells break none.
            var price = Field(name: "Price", type: .number)
            price.options.minimum = 0
            price.options.maximum = 100
            var bought = Field(name: "Bought", type: .date)
            bought.options.dateLimit = .notFuture
            var post = Field(name: "Postcode", type: .text)
            post.options.pattern = TextPattern.dutchPostcode.regex
            post.options.patternName = TextPattern.dutchPostcode.name
            var t6 = DataTable(name: "T6", fields: [price, bought, post])
            let cal = Calendar.current
            var ok = Record(); ok[price.id] = .number(50); ok[bought.id] = .date(cal.date(byAdding: .day, value: -3, to: Date())!); ok[post.id] = .text("8911 AB")
            var bad = Record(); bad[price.id] = .number(120); bad[bought.id] = .date(cal.date(byAdding: .day, value: 3, to: Date())!); bad[post.id] = .text("89 AB")
            var low = Record(); low[price.id] = .number(-1); low[bought.id] = .date(Date())
            let blank = Record()
            t6.records = [ok, bad, low, blank]
            let r6 = Resolver(database: Database(tables: [t6]), table: t6)
            TestRunner.equal(r6.ruleProblems(ok).count, 0, "a record that follows every rule")
            TestRunner.equal(r6.ruleProblem(bad, price), .outOfRange("Above 100"), "above the maximum")
            TestRunner.equal(r6.ruleProblem(low, price), .outOfRange("Below 0"), "below the minimum")
            TestRunner.equal(r6.ruleProblem(bad, bought), .wrongDate(.notFuture), "a date in the future")
            TestRunner.equal(r6.ruleProblem(low, bought), nil, "today is not the future")
            TestRunner.equal(r6.ruleProblem(bad, post), .noMatch("Dutch postcode (1234 AB)"), "text that doesn't match")
            TestRunner.equal(r6.ruleProblems(blank).count, 0, "empty cells break no value rule")
            TestRunner.equal(Resolver.RuleProblem.outOfRange("Above 100").sentence(price), "Price is above 100", "said in the form")
            TestRunner.expect(r6.hasRules, "value rules count as rules")
            for (pattern, good, wrong) in [(TextPattern.digits, "0123", "12a"), (.lettersAndDigits, "Één2", "a-b"), (.email, "a@b.nl", "a@b"), (.capital, "Ölst", "ölst")] {
                TestRunner.expect("\(good)".range(of: pattern.regex, options: .regularExpression) != nil, "\(pattern.name): \(good) matches")
                TestRunner.expect("\(wrong)".range(of: pattern.regex, options: .regularExpression) == nil, "\(pattern.name): \(wrong) doesn't")
            }
            var unreadable = Field(name: "Code", type: .text)
            unreadable.options.pattern = "[unclosed"
            TestRunner.expect(!Resolver.hasRules(unreadable), "a pattern that can't be read is no rule")
            var stars = Field(name: "Stars", type: .rating)
            stars.options.minimum = 3
            var two = Record(); two[stars.id] = .rating(2)
            let t7 = DataTable(name: "T7", fields: [stars], records: [two])
            TestRunner.equal(Resolver(database: Database(tables: [t7]), table: t7).ruleProblem(two, stars), .outOfRange("Below 3"), "a rating below the minimum")

            // Rules are saved.
            do {
                let read = try DatabaseFile.decode(DatabaseFile.encode(Database(tables: [table])))
                TestRunner.equal(read.tables[0].fields.map(\.options.required), [true, false], "required saved")
                TestRunner.equal(read.tables[0].fields.map(\.options.unique), [false, true], "unique saved")
                let ruled = try DatabaseFile.decode(DatabaseFile.encode(Database(tables: [t6])))
                TestRunner.equal(ruled.tables[0].fields[0].options.maximum, 100, "a maximum saved")
                TestRunner.equal(ruled.tables[0].fields[1].options.dateLimit, .notFuture, "a date limit saved")
                TestRunner.equal(ruled.tables[0].fields[2].options.patternName, TextPattern.dutchPostcode.name, "a pattern saved")
            } catch {
                TestRunner.expect(false, "save threw \(error)")
            }
        }
    }

    private static func summaryTable() {
        TestRunner.suite("Summary table") {
            let format = Field(name: "Format", type: .choice, options: FieldOptions(choices: ["LP", "CD"]))
            let genre = Field(name: "Genre", type: .multiChoice, options: FieldOptions(choices: ["Jazz", "Rock"]))
            let year = Field(name: "Year", type: .number)
            let price = Field(name: "Price", type: .number)
            let bought = Field(name: "Bought", type: .date)
            var table = DataTable(name: "Albums", fields: [format, genre, year, price, bought])
            let cal = Calendar.current
            func album(_ f: String?, _ g: [String], _ y: Double, _ p: Double?, _ month: Int) -> Record {
                var r = Record()
                if let f { r[format.id] = .choices([f]) }
                if !g.isEmpty { r[genre.id] = .choices(g) }
                r[year.id] = .number(y)
                if let p { r[price.id] = .number(p) }
                r[bought.id] = .date(cal.date(from: DateComponents(year: 2026, month: month, day: 10))!)
                return r
            }
            table.records = [album("CD", ["Rock"], 1977, 10, 1), album("LP", ["Jazz"], 1959, 30, 1), album("LP", ["Jazz", "Rock"], 1969, 20, 3),
                             album(nil, [], 2013, nil, 3)]
            let r = Resolver(database: Database(tables: [table]), table: table)
            var settings = PivotSettings()
            settings.rowFieldID = format.id
            settings.columnFieldID = genre.id
            guard let result = Pivot.compute(table.records, settings: settings, r) else { TestRunner.expect(false, "a result"); return }
            TestRunner.equal(result.rows.map(\.label), ["LP", "CD", "No Format"], "rows in the options' order, empty last")
            TestRunner.equal(result.columns.map(\.label), ["Jazz", "Rock", "No Genre"], "columns too")
            TestRunner.equal(result.cells[0].map(\.value), [2, 1, nil], "LP: two jazz, one rock (a record with both counts in each)")
            TestRunner.equal(result.rowTotals.map(\.value), [2, 1, 1], "row totals count each record once")
            TestRunner.equal(result.columnTotals.map(\.value), [2, 2, 1], "column totals")
            TestRunner.equal(result.total.value, 4, "every record once in the total")
            TestRunner.equal(result.cells[0][0].records.count, 2, "a cell knows its records, to select them")

            // Sums and averages of a number field, in its format; records without a number don't count.
            settings.measure = .sum
            settings.valueFieldID = price.id
            settings.columnFieldID = nil
            let sums = Pivot.compute(table.records, settings: settings, r)!
            TestRunner.equal(sums.columns.count, 0, "no column field: only the totals")
            TestRunner.equal(sums.rowTotals.map(\.value), [50, 10, nil], "sums per row; nothing for a row without prices")
            settings.measure = .average
            TestRunner.equal(Pivot.compute(table.records, settings: settings, r)!.total.value, 20, "an average over the records with a number")
            settings.measure = .maximum
            TestRunner.equal(Pivot.compute(table.records, settings: settings, r)!.rowTotals.first?.value, 30, "the highest")
            settings.measure = .minimum
            TestRunner.equal(Pivot.compute(table.records, settings: settings, r)!.rowTotals.first?.value, 20, "the lowest")

            // Numbers in steps (years by decade), dates by month.
            settings = PivotSettings()
            settings.rowFieldID = year.id
            settings.rowStep = .tens
            let decades = Pivot.compute(table.records, settings: settings, r)!
            TestRunner.equal(decades.rows.map(\.label), ["1950 – 1959", "1960 – 1969", "1970 – 1979", "2010 – 2019"], "years by decade, in order")
            settings.rowFieldID = bought.id
            settings.rowDateUnit = .month
            let months = Pivot.compute(table.records, settings: settings, r)!
            TestRunner.equal(months.rows.count, 2, "dates by month")
            TestRunner.equal(months.rowTotals.map(\.value), [2, 2], "two in each month, earliest first")

            // Copied for a spreadsheet: a header, a row per category, the totals.
            settings = PivotSettings()
            settings.rowFieldID = format.id
            let copied = Pivot.copyText(Pivot.compute(table.records, settings: settings, r)!, settings: settings, resolver: r, rowName: "Format")
            TestRunner.equal(copied, "Format\tTotal\nLP\t2\nCD\t1\nNo Format\t1\nTotal\t4", "copied as rows with tabs")
            // Saved with the view; the summary is the ninth view (⌘9).
            var view = SavedView(name: "S", mode: .summary)
            view.summary = settings
            if let data = try? JSONEncoder().encode(view), let read = try? JSONDecoder().decode(SavedView.self, from: data) {
                TestRunner.equal(read.summary, settings, "settings saved")
                TestRunner.equal(read.mode, .summary, "mode saved")
            } else {
                TestRunner.expect(false, "view round trip")
            }
            TestRunner.equal(ViewMode.allCases.firstIndex(of: .summary), 8, "⌘9")
        }
    }

    /// The table grid in a window of this app that is never on screen: clicks and key presses go
    /// to that window only (nothing activates, no other app sees them), and the values typed are
    /// checked in the document.
    private static func gridInWindow() {
        TestRunner.suite("Table grid in a window") {
            let harness = GridHarness()
            defer { harness.close() }
            let h = harness
            // The first arrow picks the first cell.
            h.key(.down)
            TestRunner.equal(h.document.selectedRecordIDs, [h.records[0]], "the first key press selects the first cell")
            // Text: type, Return.
            h.type("Lamp")
            h.key(.return)
            TestRunner.equal(h.value(0, "Name"), .text("Lamp"), "typing into a text cell")
            TestRunner.equal(h.document.selectedRecordIDs, [h.records[1]], "Return moves down")
            h.type("Desk")
            h.key(.tab)
            TestRunner.equal(h.value(1, "Name"), .text("Desk"), "Tab saves")
            // Now in Quantity of the second row.
            h.type("12")
            h.key(.return)
            TestRunner.equal(h.value(1, "Quantity"), .number(12), "typing into a number cell")
            // Row 3 now; across the columns with Tab, each type typed in as you would.
            TestRunner.equal(h.document.selectedRecordIDs, [h.records[2]], "on the third row")
            h.key(.tab) // Price
            h.type("9,50")
            h.key(.tab)
            TestRunner.equal(h.value(2, "Price"), .number(9.5), "a price with a decimal comma")
            h.type("2024-03-05") // Bought
            h.key(.tab)
            TestRunner.equal(h.value(2, "Bought")?.date.map { Calendar.current.dateComponents([.year, .month, .day], from: $0) },
                             DateComponents(year: 2024, month: 3, day: 5), "a date typed in")
            h.key(.space) // Done
            TestRunner.equal(h.value(2, "Done"), .bool(true), "Space checks a checkbox")
            h.key(.space)
            TestRunner.equal(h.value(2, "Done"), nil, "and unchecks it")
            h.key(.tab) // Stars
            h.type("4")
            TestRunner.equal(h.value(2, "Stars"), .rating(4), "a digit sets the rating")
            h.key(.tab) // Length
            h.type("1:30")
            h.key(.tab)
            TestRunner.equal(h.value(2, "Length"), .number(90), "a duration")
            h.type("golle.app") // Site
            h.key(.tab)
            TestRunner.equal(h.value(2, "Site"), .text("golle.app"), "a web link")
            h.type("a@b.nl") // Mail
            h.key(.tab)
            TestRunner.equal(h.value(2, "Mail"), .text("a@b.nl"), "an email address")
            h.type("978-0 14") // Code
            h.key(.tab)
            TestRunner.equal(h.value(2, "Code"), .text("978014"), "a barcode, without spaces and dashes")
            h.type("40") // Progress
            h.key(.tab)
            TestRunner.equal(h.value(2, "Progress"), .number(40), "progress")
            // The rest open their own editor in a popover on the cell (Return), empty cells too; a
            // popover can't open in a window that is off screen, so only the keys are checked here.
            for name in ["Kind", "Tags", "Notes", "Photos", "Files", "Steps", "Place"] {
                h.key(.return)
                h.key(.escape)
                h.key(.tab)
                TestRunner.equal(h.value(2, name), nil, "\(name): Return and Escape change nothing by themselves")
            }
            // A formula can't be typed into.
            h.type("7")
            TestRunner.equal(h.value(2, "Total"), nil, "nothing typed into a formula")
            // Escape while typing leaves the value as it was.
            h.key(.left, keys: .command)
            h.type("Gone")
            h.key(.escape)
            TestRunner.equal(h.value(2, "Name"), nil, "Escape cancels typing")
            // Delete clears the cell; ⌘Z puts it back.
            h.key(.up)
            h.key(.delete)
            TestRunner.equal(h.value(1, "Name"), nil, "Delete clears the cell")
            // Return in the last row adds a record.
            h.key(.down, keys: .command)
            h.type("New")
            h.key(.return)
            TestRunner.equal(h.table.records.count, 4, "Return in the last row adds a record")
            TestRunner.equal(h.value(2, "Name"), .text("New"), "after saving the typing")

            // The long-text editor of the popover on its own: it takes the keyboard when it shows,
            // with the letter typed to open it, and what is typed next goes after it.
            final class Box: ObservableObject { @Published var text = "Old" }
            let box = Box()
            struct Editor: View {
                @ObservedObject var box: Box
                var body: some View { RichTextEditor(markdown: $box.text, focusOnAppear: true, typed: "N") }
            }
            let popover = NSWindow(contentRect: NSRect(x: -6000, y: 800, width: 380, height: 220), styleMask: [.titled], backing: .buffered, defer: false)
            popover.contentView = NSHostingView(rootView: Editor(box: box).frame(width: 380, height: 220))
            popover.orderFrontRegardless()
            h.pump(0.5)
            TestRunner.expect(popover.firstResponder is NSTextView, "the editor has the cursor at once")
            for c in "ew" {
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: popover.windowNumber, context: nil, characters: String(c),
                                                    charactersIgnoringModifiers: String(c), isARepeat: false, keyCode: 0) { popover.sendEvent(event) }
                    h.pump(0.03)
                }
            }
            h.pump(0.6)
            popover.makeFirstResponder(nil)
            h.pump(0.3)
            TestRunner.equal(box.text, "OldNew", "the typed letter and the rest go after the text")
            popover.orderOut(nil)

            // Typing in the form's long text beside the grid goes into the text, not the grid.
            let notes = h.textViews()
            TestRunner.expect(!notes.isEmpty, "the form beside the grid has a long-text editor")
            if let view = notes.first {
                h.window.makeFirstResponder(view)
                h.pump(0.2)
                h.typeKeys("hello")
                h.pump(0.6)
                TestRunner.equal(view.string, "hello", "typed into the notes")
                h.window.makeFirstResponder(nil)
                h.pump(0.3)
                TestRunner.equal(h.value(0, "Notes"), .text("hello"), "and saved")
                TestRunner.equal(h.value(0, "Name"), .text("Lamp"), "the grid's cell is left alone")
            }
        }
    }

    private static func grid() {
        TestRunner.suite("Table grid") {
            let r = (0..<4).map { _ in UUID() }, c = (0..<3).map { _ in UUID() }
            var sel = GridSelection(GridPoint(record: r[1], field: c[1]))
            TestRunner.equal(sel.block(order: r, columns: c).records, [r[1]], "one cell")
            TestRunner.expect(!sel.isBlock(order: r, columns: c), "is not a block")
            // Arrows move, ⇧ extends, the edges hold.
            sel = sel.moved(rows: 1, columns: 1, extend: true, order: r, columns: c)
            let block = sel.block(order: r, columns: c)
            TestRunner.equal(block.records, [r[1], r[2]], "⇧ and arrows extend over rows")
            TestRunner.equal(block.fields, [c[1], c[2]], "and columns")
            TestRunner.expect(sel.contains(GridPoint(record: r[2], field: c[2]), order: r, columns: c), "the block holds its corner")
            TestRunner.expect(!sel.contains(GridPoint(record: r[0], field: c[1]), order: r, columns: c), "but not what is outside")
            let moved = sel.moved(rows: 10, columns: -10, extend: false, order: r, columns: c)
            TestRunner.equal(moved.cursor, GridPoint(record: r[3], field: c[0]), "an arrow without ⇧ moves one cell, kept inside the table")
            TestRunner.equal(moved.anchor, moved.cursor, "and the block is gone")
            // The cursor and anchor in reverse order still give the block top-down.
            var up = GridSelection(GridPoint(record: r[3], field: c[2]))
            up = up.extended(to: GridPoint(record: r[1], field: c[0]))
            TestRunner.equal(up.block(order: r, columns: c).records, [r[1], r[2], r[3]], "dragged upwards: rows in order")
            TestRunner.equal(up.block(order: r, columns: c).fields, c, "columns in order")
            // Whole rows from the row numbers, ⌘ adds single rows.
            var rows = GridSelection(GridPoint(record: r[0], field: c[0]), wholeRows: true)
            rows.extraRows = [r[3]]
            TestRunner.equal(rows.block(order: r, columns: c).records, [r[0], r[3]], "rows picked one by one")
            TestRunner.equal(rows.block(order: r, columns: c).fields, c, "every column of them")
            // A selection follows its records when they are sorted.
            let sorted = [r[3], r[2], r[1], r[0]]
            TestRunner.equal(sel.block(order: sorted, columns: c).records, [r[2], r[1]], "after sorting: the same records")
            // A record that is gone: no block.
            TestRunner.equal(GridSelection(GridPoint(record: UUID(), field: c[0])).block(order: r, columns: c).records, [], "a deleted record selects nothing")
            TestRunner.equal(GridSelection.all(order: r, columns: c)?.block(order: r, columns: c).records, r, "select all")

            // Columns: order and widths per view.
            let a = Field(name: "A", type: .text), b = Field(name: "B", type: .number), d = Field(name: "D", type: .checkbox)
            let table = DataTable(name: "T", fields: [a, b, d])
            var view = SavedView(name: "V")
            TestRunner.equal(view.columns(table).map(\.id), [a.id, b.id, d.id], "table order to start with")
            view.columnOrder = GridColumns.moving(d.id, before: a.id, in: [a.id, b.id, d.id])
            TestRunner.equal(view.columns(table).map(\.id), [d.id, a.id, b.id], "a column moved to the front")
            view.columnOrder = [b.id]
            TestRunner.equal(view.columns(table).map(\.id), [b.id, a.id, d.id], "fields not arranged yet follow in table order")
            view.hiddenFieldIDs = [a.id]
            TestRunner.equal(view.columns(table).map(\.id), [b.id, d.id], "hidden fields are no columns")
            TestRunner.equal(GridColumns.width(d, in: view), 64, "a checkbox column starts narrow")
            view.columnWidths[a.id.uuidString] = 300
            TestRunner.equal(GridColumns.width(a, in: view), 300, "a width set by dragging")
            view.columnWidths[a.id.uuidString] = 5
            TestRunner.equal(GridColumns.width(a, in: view), GridColumns.minWidth, "never too narrow to grab")
            if let data = try? JSONEncoder().encode(view), let read = try? JSONDecoder().decode(SavedView.self, from: data) {
                TestRunner.equal(read.columnOrder, view.columnOrder, "order saved")
                TestRunner.equal(read.columnWidths, view.columnWidths, "widths saved")
            } else {
                TestRunner.expect(false, "view round trip")
            }
            // Sorting from the header.
            TestRunner.equal(GridColumns.sorting([], by: a.id, adding: false), [SortKey(fieldID: a.id)], "a click sorts ascending")
            TestRunner.equal(GridColumns.sorting([SortKey(fieldID: a.id)], by: a.id, adding: false), [SortKey(fieldID: a.id, ascending: false)], "again: descending")
            TestRunner.equal(GridColumns.sorting([SortKey(fieldID: a.id)], by: b.id, adding: false), [SortKey(fieldID: b.id)], "another column replaces the sort")
            TestRunner.equal(GridColumns.sorting([SortKey(fieldID: a.id)], by: b.id, adding: true), [SortKey(fieldID: a.id), SortKey(fieldID: b.id)], "with ⇧ it is added")

            // Clearing a block and filling it down, each one undo step.
            let formula = Field(name: "F", type: .formula, options: FieldOptions(formula: "{B} * 2"))
            var t = DataTable(name: "T", fields: [a, b, formula])
            var x = Record(); x[a.id] = .text("x"); x[b.id] = .number(1)
            var y = Record(); y[a.id] = .text("y"); y[b.id] = .number(2)
            var z = Record(); z[a.id] = .text("z")
            t.records = [x, y, z]
            let undo = UndoManager()
            undo.groupsByEvent = false
            let document = GolleDocument(database: Database(tables: [t]))
            document.undoManager = undo
            undo.beginUndoGrouping()
            document.fillDown(fields: [a.id, b.id, formula.id], records: [x.id, y.id, z.id], table: t.id)
            undo.endUndoGrouping()
            TestRunner.equal(document.database.tables[0].records.map { $0[a.id] }, [.text("x"), .text("x"), .text("x")], "filled down in the first column")
            TestRunner.equal(document.database.tables[0].records.map { $0[b.id] }, [.number(1), .number(1), .number(1)], "and the second")
            undo.undo()
            TestRunner.equal(document.database.tables[0].records.map { $0[b.id] }, [.number(1), .number(2), nil], "one undo step")
            undo.beginUndoGrouping()
            document.clearCells(records: [x.id, y.id], fields: [b.id, formula.id], table: t.id)
            undo.endUndoGrouping()
            TestRunner.equal(document.database.tables[0].records.map { $0[b.id] }, [nil, nil, nil], "a block cleared")
            TestRunner.equal(document.database.tables[0].records[0][a.id], .text("x"), "the columns beside it stay")
            TestRunner.equal(document.database.tables[0].history[x.id]?.last?.old, .number(1), "in the history")
            undo.undo()
            TestRunner.equal(document.database.tables[0].records[1][b.id], .number(2), "undone in one step")
            // Photos and files are cleared too; a formula stays as it is.
            let photos = Field(name: "Photos", type: .image), files = Field(name: "Files", type: .file)
            var withFiles = DataTable(name: "F", fields: [photos, files, formula])
            var p1 = Record(), p2 = Record()
            p1[photos.id] = .attachments([Attachment(name: "a.png")]); p1[files.id] = .attachments([Attachment(name: "a.pdf")])
            p2[photos.id] = .attachments([Attachment(name: "b.png"), Attachment(name: "c.png")])
            withFiles.records = [p1, p2]
            let fileDocument = GolleDocument(database: Database(tables: [withFiles]))
            fileDocument.clearCells(records: [p1.id, p2.id], fields: [photos.id, files.id, formula.id], table: withFiles.id)
            TestRunner.equal(fileDocument.database.tables[0].records.map { $0[photos.id] }, [nil, nil], "photos cleared from several records")
            TestRunner.equal(fileDocument.database.tables[0].records[0][files.id], nil, "files cleared")

            // Fill Down copies photos too.
            var down = DataTable(name: "D", fields: [photos])
            var top = Record(); top[photos.id] = .attachments([Attachment(name: "top.png")])
            let below = Record()
            down.records = [top, below]
            let downDocument = GolleDocument(database: Database(tables: [down]))
            downDocument.fillDown(fields: [photos.id], records: [top.id, below.id], table: down.id)
            TestRunner.equal(downDocument.database.tables[0].records[1][photos.id], top[photos.id], "Fill Down copies photos")

            // Copied in Golle and pasted back: photos and links come along as they are; another type
            // of field gets the text.
            let title = Field(name: "Title", type: .text)
            let copyTable = DataTable(name: "C", fields: [photos, title], records: [top, below])
            let copyResolver = Resolver(database: Database(tables: [copyTable]), table: copyTable)
            let copiedText = CellClipboard.text([top], fields: [photos], resolver: copyResolver)
            let cells = CellClipboard.cells([top], fields: [photos])
            let intoPhotos = CellClipboard.plan(CellClipboard.grid(copiedText), table: copyTable, columns: copyTable.fields, startColumn: 0,
                                                rows: [below.id], resolver: copyResolver, values: cells)
            TestRunner.expect(intoPhotos.updates.contains { $0.record == below.id && $0.field == photos.id && $0.value == top[photos.id] }, "a photo pasted into a photo cell")
            let intoTitle = CellClipboard.plan(CellClipboard.grid(copiedText), table: copyTable, columns: copyTable.fields, startColumn: 1,
                                               rows: [below.id], resolver: copyResolver, values: cells)
            TestRunner.expect(intoTitle.updates.contains { $0.field == title.id && $0.value == .text("top.png") }, "into a text field: its name")
            let asText = CellClipboard.plan(CellClipboard.grid(copiedText), table: copyTable, columns: copyTable.fields, startColumn: 0,
                                            rows: [below.id], resolver: copyResolver)
            TestRunner.expect(asText.isEmpty, "only text (copied elsewhere): a name can't become a photo")
            undo.removeAllActions()
            document.undoManager = nil
        }
    }

    private static func copyPasteRelated() {
        TestRunner.suite("Copy and paste") {
            // Reading the clipboard: tabs between cells, a line per row, quotes as spreadsheets write them.
            TestRunner.equal(CellClipboard.grid("a\tb\r\nc\td\n"), [["a", "b"], ["c", "d"]], "rows and cells; the last line break ends the block")
            TestRunner.equal(CellClipboard.grid("1\n\n3"), [["1"], [""], ["3"]], "empty rows are kept, so a column lands on the right records")
            TestRunner.equal(CellClipboard.grid("\"two\nlines\"\t\"say \"\"hi\"\"\""), [["two\nlines", "say \"hi\""]], "quoted cells")
            TestRunner.equal(CellClipboard.grid("12\" vinyl"), [["12\" vinyl"]], "a quote inside a cell is just a quote")
            TestRunner.expect(CellClipboard.isBlock("a\tb") && CellClipboard.isBlock("a\nb") && !CellClipboard.isBlock("abc\n"), "what counts as a block")
            TestRunner.equal(CellPasting.oneLine("a\tb\nc"), "a b c", "a block kept in one cell becomes one line")

            let title = Field(name: "Title", type: .text)
            let year = Field(name: "Year", type: .number)
            let format = Field(name: "Format", type: .choice, options: FieldOptions(choices: ["LP", "CD"]))
            let bought = Field(name: "Bought", type: .date)
            let number = Field(name: "No.", type: .autoNumber)
            let label = Field(name: "Label", type: .formula, options: FieldOptions(formula: "{Title} & \" \" & {Year}"))
            var table = DataTable(name: "Albums", fields: [title, year, format, bought, number, label])
            var a = Record(); a[title.id] = .text("Blue"); a[year.id] = .number(1971); a[format.id] = .choices(["LP"]); a[number.id] = .number(1)
            a[bought.id] = .date(Calendar.current.date(from: DateComponents(year: 2024, month: 3, day: 5))!)
            var b = Record(); b[title.id] = .text("Rumours"); b[year.id] = .number(1977); b[number.id] = .number(2)
            table.records = [a, b]
            let db = Database(tables: [table])
            let r = Resolver(database: db, table: table)
            let copied = CellClipboard.text([a, b], fields: table.fields, resolver: r)
            TestRunner.equal(copied, "Blue\t1971\tLP\t2024-03-05\t1\tBlue 1971\nRumours\t1977\t\t\t2\tRumours 1977", "rows copied as lines, cells as an export writes them")

            // Pasting the copy into an empty table of the same fields gives the same values back.
            var empty = table
            empty.records = []
            let back = CellClipboard.plan(CellClipboard.grid(copied), table: empty, columns: empty.fields, startColumn: 0, rows: [], resolver: Resolver(database: Database(tables: [empty]), table: empty))
            TestRunner.equal(back.added.count, 2, "two new records")
            TestRunner.equal(back.added.first?[year.id], .number(1971), "numbers come back")
            TestRunner.equal(back.added.first?[bought.id], a[bought.id], "dates come back")
            TestRunner.equal(back.added.first?[format.id], .choices(["LP"]), "choices come back")
            TestRunner.equal(back.added.first?[label.id], nil, "formulas aren't pasted into")
            TestRunner.equal(back.readOnly, 2, "the automatic number and the formula are skipped")

            // A column pasted from the Year column down, over the records shown and on into new ones.
            let column = CellClipboard.plan(CellClipboard.grid("1972\n\nabc\n1990"), table: table, columns: table.fields, startColumn: 1,
                                            rows: [a.id, b.id], resolver: r)
            TestRunner.expect(column.updates.contains { $0.record == a.id && $0.field == year.id && $0.value == .number(1972) }, "the first row gets the first value")
            TestRunner.expect(column.updates.contains { $0.record == b.id && $0.field == year.id && $0.value == nil }, "an empty cell clears")
            TestRunner.equal(column.skipped, 1, "text that isn't a number is left out")
            TestRunner.equal(column.added.map { $0[year.id] }, [.number(1990)], "rows past the last record become records")

            // A first row of field names puts each column under its field.
            let named = CellClipboard.plan(CellClipboard.grid("Format\tTitle\nTape\tHarvest"), table: table, columns: table.fields, startColumn: 3,
                                           rows: [], resolver: r)
            TestRunner.equal(named.added.first?[title.id], .text("Harvest"), "columns by name")
            TestRunner.equal(named.newChoices[format.id], ["Tape"], "a new option is added to the choices")

            // In the document: one undo step, history, numbers for new records.
            let undo = UndoManager()
            undo.groupsByEvent = false
            let document = GolleDocument(database: db)
            document.undoManager = undo
            undo.beginUndoGrouping()
            let pasted = document.paste(column, into: table.id)
            undo.endUndoGrouping()
            let after = document.database.tables[0]
            TestRunner.equal(after.records.count, 3, "a record added")
            TestRunner.equal(after.records[0][year.id], .number(1972), "a cell changed")
            TestRunner.equal(after.records[2][number.id], .number(3), "the new record is numbered after the others")
            TestRunner.equal(pasted, [a.id, b.id, after.records[2].id], "the records pasted into")
            TestRunner.equal(after.history[a.id]?.last?.new, .number(1972), "in the record's history")
            undo.undo()
            TestRunner.equal(document.database.tables[0].records.count, 2, "one undo step")
            TestRunner.equal(document.database.tables[0].records[0][year.id], .number(1971), "undone")
            undo.removeAllActions()
            document.undoManager = nil
            let withChoice = document.paste(named, into: table.id)
            TestRunner.equal(document.database.tables[0].field(format.id)?.options.choices, ["LP", "CD", "Tape"], "the new option is in the list")
            TestRunner.equal(withChoice.count, 1, "one record pasted")

            // Fill down: the first record's value into the others.
            document.fillDown(field: format.id, records: [a.id, b.id], table: table.id)
            TestRunner.equal(document.database.tables[0].records[1][format.id], .choices(["LP"]), "filled down")
            TestRunner.equal(document.database.tables[0].records[0][format.id], .choices(["LP"]), "the first stays")
            document.fillDown(field: label.id, records: [a.id, b.id], table: table.id)
            TestRunner.equal(document.database.tables[0].records[1][label.id], nil, "not into a formula")

            // Links by name.
            var artists = DataTable(name: "Artists", fields: [Field(name: "Name", type: .text)])
            var miles = Record(); miles[artists.fields[0].id] = .text("Miles Davis")
            artists.records = [miles]
            let link = Field(name: "Artist", type: .link, options: FieldOptions(linkedTableID: artists.id))
            let songs = DataTable(name: "Songs", fields: [link])
            let linkResolver = Resolver(database: Database(tables: [songs, artists]), table: songs)
            TestRunner.equal(CellClipboard.value("miles davis", for: link, order: nil, resolver: linkResolver), .links([miles.id]), "a link by name")
            TestRunner.equal(CellClipboard.value("Nobody", for: link, order: nil, resolver: linkResolver), nil, "an unknown name links nothing")
        }

        TestRunner.suite("Related records") {
            let name = Field(name: "Name", type: .text)
            var artists = DataTable(name: "Artists", fields: [name])
            var miles = Record(); miles[name.id] = .text("Miles")
            artists.records = [miles]
            let link = Field(name: "Artist", type: .link, options: FieldOptions(linkedTableID: artists.id))
            let notes = Field(name: "Notes", type: .longText)
            let title = Field(name: "Title", type: .text)
            let year = Field(name: "Year", type: .number), price = Field(name: "Price", type: .number), extra = Field(name: "Extra", type: .text)
            var albums = DataTable(name: "Albums", fields: [link, notes, year, title, price, extra])
            var kind = Record(); kind[title.id] = .text("Kind of Blue"); kind[link.id] = .links([miles.id])
            albums.records = [kind]
            TestRunner.equal(RelatedRecords.columns(albums, link: link).map(\.id), [title.id, year.id, price.id],
                             "the name first, then short fields; not the link back or long text")
            let document = GolleDocument(database: Database(tables: [artists, albums]))
            let added = document.addRecord(to: albums.id, values: [link.id: .links([miles.id])])
            let resolver = document.resolver(for: document.database.tables[0])
            let linked = resolver.backlinks(to: miles).first?.records.map(\.id) ?? []
            TestRunner.equal(linked, [kind.id, added].compactMap { $0 }, "a record added from the form links back")
        }
    }

    private static func findReplaceTimelineReports() {
        TestRunner.suite("Find and Replace") {
            let options = FindReplace.Options()
            TestRunner.equal(FindReplace.replace(in: "The Beatles", find: "the", with: "Les", options: options), "Les Beatles", "ignores case")
            TestRunner.equal(FindReplace.replace(in: "The Beatles", find: "the", with: "Les", options: .init(matchCase: true)), nil, "or not")
            TestRunner.equal(FindReplace.replace(in: "a-a-a", find: "a", with: "b", options: options), "b-b-b", "every time")
            TestRunner.equal(FindReplace.replace(in: "LP ", find: "lp", with: "Vinyl", options: .init(wholeCell: true)), "Vinyl", "whole cell")
            TestRunner.equal(FindReplace.replace(in: "LP box", find: "lp", with: "Vinyl", options: .init(wholeCell: true)), nil, "whole cell only")
            TestRunner.equal(FindReplace.replace(in: "x", find: "", with: "y", options: options), nil, "nothing to find")

            let undo = UndoManager()
            undo.groupsByEvent = false
            var table = DataTable(name: "T")
            let name = Field(name: "Name", type: .text), notes = Field(name: "Notes", type: .longText), code = Field(name: "Code", type: .barcode)
            let year = Field(name: "Year", type: .number)
            table.fields = [name, notes, code, year]
            var a = Record(); a[name.id] = .text("Red Album"); a[notes.id] = .text("red vinyl"); a[code.id] = .text("12 34")
            var b = Record(); b[name.id] = .text("Blue"); b[notes.id] = .text("Red")
            table.records = [a, b]
            let document = GolleDocument(database: Database(tables: [table]))
            document.undoManager = undo
            let fields = table.fields.filter(FindReplace.canReplace)
            TestRunner.equal(fields.map(\.id), [name.id, notes.id, code.id], "text fields only")
            let matches = FindReplace.matches(table.records, fields: fields, find: "red", with: "Green", options: options)
            TestRunner.equal(matches.count, 3, "three cells")
            undo.beginUndoGrouping()
            document.replaceText(matches, in: table.id)
            undo.endUndoGrouping()
            let after = document.database.tables[0]
            TestRunner.equal(after.records[0][name.id], .text("Green Album"), "replaced")
            TestRunner.equal(after.records[1][notes.id], .text("Green"), "in long text too")
            TestRunner.equal(after.history[a.id]?.count, 2, "in the record's history")
            undo.undo()
            TestRunner.equal(document.database.tables[0].records[0][name.id], .text("Red Album"), "one undo step")
            undo.removeAllActions()
            document.undoManager = nil
            let codes = FindReplace.matches(table.records, fields: [code], find: "34", with: "-56", options: options)
            document.replaceText(codes, in: table.id)
            TestRunner.equal(document.database.tables[0].records[0][code.id], .text("1256"), "barcodes keep only their digits")
            TestRunner.expect(FindReplace.matches(document.database.tables[0].records, fields: [code], find: "56", with: "56 ", options: options).isEmpty,
                              "a replacement that stores the same barcode changes nothing")
            TestRunner.equal(FindReplace.replace(in: "LP", find: " lp ", with: "Vinyl", options: .init(wholeCell: true)), "Vinyl", "whole cell trims the text found too")
            // A cell that changed since the matches were found is left alone.
            let stale = FindReplace.matches(document.database.tables[0].records, fields: [name], find: "Blue", with: "Navy", options: options)
            document.setValue(.text("Indigo"), record: b.id, field: name.id, table: table.id)
            document.replaceText(stale, in: table.id)
            TestRunner.equal(document.database.tables[0].records[1][name.id], .text("Indigo"), "stale matches skipped")
        }

        TestRunner.suite("Timeline") {
            let start = Field(name: "Start", type: .date), end = Field(name: "End", type: .date)
            let created = Field(name: "Created", type: .createdAt)
            var table = DataTable(name: "T", fields: [Field(name: "Name", type: .text), start, end, created])
            var view = SavedView(name: "Plan", mode: .timeline)
            TestRunner.equal(view.dateField(in: table)?.id, start.id, "starts at the first date")
            TestRunner.equal(view.endDateField(in: table)?.id, nil, "one-day bars until an end is chosen")
            view.endDateFieldID = start.id
            TestRunner.equal(view.endDateField(in: table)?.id, nil, "the end is never the start")
            view.endDateFieldID = end.id
            view.timelineScale = .month
            TestRunner.equal(view.endDateField(in: table)?.id, end.id, "the chosen end")
            if let data = try? JSONEncoder().encode(view), let read = try? JSONDecoder().decode(SavedView.self, from: data) {
                TestRunner.equal(read.mode, .timeline, "mode saved")
                TestRunner.equal(read.endDateFieldID, end.id, "end saved")
                TestRunner.equal(read.timelineScale, .month, "scale saved")
            } else {
                TestRunner.expect(false, "view round trip")
            }
            TestRunner.equal(ViewMode.allCases.firstIndex(of: .timeline), 7, "⌘8, after the existing views")

            let cal = Calendar.current
            let day = cal.date(from: DateComponents(year: 2026, month: 3, day: 2, hour: 14, minute: 30))!
            var r = Record(); r[start.id] = .date(day); r[end.id] = .date(cal.date(byAdding: .day, value: 3, to: day)!)
            var open = Record(); open[start.id] = .date(day)
            table.records = [r, open]
            let undo = UndoManager()
            undo.groupsByEvent = false
            let document = GolleDocument(database: Database(tables: [table]))
            document.undoManager = undo
            undo.beginUndoGrouping()
            document.shiftDates(record: r.id, table: table.id, start: start.id, end: end.id, moveStart: true, byDays: 5)
            undo.endUndoGrouping()
            var moved = document.database.tables[0].records[0]
            TestRunner.equal(moved[start.id]?.date, cal.date(byAdding: .day, value: 5, to: day), "the start moves, time of day kept")
            TestRunner.equal(moved[end.id]?.date, cal.date(byAdding: .day, value: 8, to: day), "the end moves with it")
            undo.undo()
            TestRunner.equal(document.database.tables[0].records[0][start.id]?.date, day, "one undo step")
            undo.removeAllActions()
            document.undoManager = nil
            document.shiftDates(record: r.id, table: table.id, start: start.id, end: end.id, moveStart: false, byDays: -2)
            moved = document.database.tables[0].records[0]
            TestRunner.equal(moved[start.id]?.date, day, "resizing keeps the start")
            TestRunner.equal(moved[end.id]?.date, cal.date(byAdding: .day, value: 1, to: day), "and moves the end")
            document.shiftDates(record: open.id, table: table.id, start: start.id, end: end.id, moveStart: false, byDays: 4)
            TestRunner.equal(document.database.tables[0].records[1][end.id]?.date, cal.date(byAdding: .day, value: 4, to: day), "an empty end counts from the start")
            // Moving a one-day bar leaves its empty end empty.
            var single = Record(); single[start.id] = .date(day)
            // An end before the start shows as the start: resizing counts from there.
            var backwards = Record(); backwards[start.id] = .date(day); backwards[end.id] = .date(cal.date(byAdding: .day, value: -5, to: day)!)
            var planTable = DataTable(name: "P", fields: table.fields)
            planTable.records = [single, backwards]
            let plan = GolleDocument(database: Database(tables: [planTable]))
            let planID = plan.database.tables[0].id
            plan.shiftDates(record: single.id, table: planID, start: start.id, end: end.id, moveStart: true, byDays: 3)
            TestRunner.equal(plan.database.tables[0].records[0][end.id], nil, "moving keeps an empty end empty")
            TestRunner.equal(plan.database.tables[0].records[0][start.id]?.date, cal.date(byAdding: .day, value: 3, to: day), "and moves the start")
            plan.shiftDates(record: backwards.id, table: planID, start: start.id, end: end.id, moveStart: false, byDays: 2)
            TestRunner.equal(plan.database.tables[0].records[1][end.id]?.date, cal.date(byAdding: .day, value: 2, to: day), "resizing a backwards bar counts from its start")
            TestRunner.equal(TimelineView.dates(day, day), day.formatted(.dateTime.day().month(.abbreviated)), "a one-day label")

            let books = Template.all.first { $0.id == "books" }?.make().tables[0]
            TestRunner.expect(books?.views.contains { $0.mode == .timeline && $0.endDateFieldID != nil } == true, "the reading list has a timeline")
        }

        TestRunner.suite("Reports") {
            let format = Field(name: "Format", type: .choice, options: FieldOptions(choices: ["LP", "CD"]))
            let price = Field(name: "Price", type: .number)
            var table = DataTable(name: "Albums", fields: [Field(name: "Title", type: .text), format, price])
            for (f, p) in [("LP", 10.0), ("CD", 5), ("LP", 20), ("CD", 7), ("LP", 1)] {
                var rec = Record(); rec[format.id] = .choices([f]); rec[price.id] = .number(p); table.records.append(rec)
            }
            table.summaries = [SummaryItem(fieldID: price.id, kind: .sum)]
            let r = Resolver(database: Database(tables: [table]), table: table)
            var options = ReportOptions(title: "Albums", fields: table.fields.map(\.id), groupBy: [format.id])
            let lines = Report.lines(table.records, groupFields: [format], options: options, resolver: r)
            let groups = lines.compactMap { line -> String? in if case .group(let t, _, _) = line { t } else { nil } }
            TestRunner.equal(groups, ["CD", "LP"], "a header per group, in order")
            let totals = lines.compactMap { line -> Int? in if case .totals(let records, _) = line { records.count } else { nil } }
            TestRunner.equal(totals, [2, 3, 5], "totals per group and for all")
            let records = lines.filter { if case .record = $0 { true } else { false } }.count
            TestRunner.equal(records, 5, "every record once")
            TestRunner.equal(Report.pages(lines, height: 10_000).count, 1, "fits one page")
            let small = Report.pages(lines, height: 60)
            TestRunner.expect(small.count > 1, "cut into pages")
            TestRunner.expect(small.allSatisfy { page in if case .group = page.last! { false } else { true } }, "no page ends on a group title")
            options.pagePerGroup = true
            let perGroup = Report.pages(Report.lines(table.records, groupFields: [format], options: options, resolver: r), height: 10_000)
            TestRunner.equal(perGroup.count, 2, "a page per group")
            options.totals = false
            let bare = Report.lines(table.records, groupFields: [], options: options, resolver: r)
            TestRunner.equal(bare.count, 5, "ungrouped, without totals: just the records")
            let pdf = Report.pdf(table: table, records: table.records, options: options, resolver: r)
            TestRunner.expect((pdf.flatMap(PDFDocument.init(data:))?.pageCount ?? 0) >= 1, "renders a PDF")
        }
    }

    private static func settings() {
        TestRunner.suite("Settings") {
            let store = Preferences.store
            defer {
                for key in [Preferences.Key.historyLimit, Preferences.Key.currency, Preferences.Key.onlineLookups,
                            Preferences.Key.csvSeparator, Preferences.Key.atLaunch, Preferences.Key.openAtQuit,
                            Preferences.Key.openAtQuitBookmarks] { store.removeObject(forKey: key) }
            }
            TestRunner.equal(Preferences.historyLimit, 100, "history keeps 100 by default")
            TestRunner.equal(Preferences.onlineLookups, true, "lookups on by default")
            TestRunner.equal(Preferences.atLaunch, .welcome, "welcome window by default")
            TestRunner.equal(Preferences.csvSeparator, .comma, "comma by default")
            TestRunner.equal(Preferences.csvBOM, true, "byte-order mark by default")
            TestRunner.equal(Preferences.currency, Preferences.regionCurrency, "currency from the region")

            // History limit and off.
            var table = DataTable(name: "T")
            let field = UUID(), record = UUID()
            store.set(3, forKey: Preferences.Key.historyLimit)
            for i in 0..<5 { table.recordChange(record, field: field, old: .text("\(i)"), new: .text("\(i + 1)"), continuing: false) }
            TestRunner.equal(table.history[record]?.count, 3, "kept to the chosen limit")
            TestRunner.equal(table.history[record]?.last?.new, .text("5"), "the newest kept")
            store.set(0, forKey: Preferences.Key.historyLimit)
            table.recordChange(record, field: field, old: .text("5"), new: .text("6"), continuing: false)
            TestRunner.equal(table.history[record]?.count, 3, "off: nothing added, the old kept")

            // Currency for new number fields only.
            store.set("JPY", forKey: Preferences.Key.currency)
            TestRunner.equal(NumberFormat().currency, "JPY", "new fields take the chosen currency")
            if let data = try? JSONEncoder().encode({ var f = NumberFormat(); f.currency = "USD"; return f }()),
               let read = try? JSONDecoder().decode(NumberFormat.self, from: data) {
                TestRunner.equal(read.currency, "USD", "saved fields keep theirs")
            } else {
                TestRunner.expect(false, "number format round trip")
            }
            store.set("", forKey: Preferences.Key.currency)
            TestRunner.equal(Preferences.currency, Preferences.regionCurrency, "empty is the region again")

            // CSV separators.
            let rows = [["a", "b;c", "d,e"], ["1\t2", "x", ""]]
            TestRunner.equal(CSV.write(rows, separator: ";"), "a;\"b;c\";\"d,e\"\r\n\"1\t2\";x;\r\n", "semicolons, quoted where needed")
            TestRunner.equal(CSV.parse(CSV.write(rows, separator: "\t")), rows, "tabs read back")
            TestRunner.equal(CSV.parse(CSV.write(rows, separator: ";")), rows, "semicolons read back")

            // Semicolon files write decimal commas, and read them back whatever this Mac's region.
            let price = Field(name: "Price", type: .number), year = Field(name: "Year", type: .number)
            let label = Field(name: "Label", type: .text)
            var prices = DataTable(name: "P", fields: [price, year, label])
            var pr = Record(); pr[price.id] = .number(1.25); pr[year.id] = .number(1977); pr[label.id] = .text("v1.5")
            prices.records = [pr]
            let pricesResolver = Resolver(database: Database(tables: [prices]), table: prices)
            let semi = Exporter.csv(prices.records, resolver: pricesResolver, separator: ";")
            TestRunner.equal(semi, "Price;Year;Label\r\n\"1,25\";1977;v1.5\r\n", "decimal comma with semicolons, text left alone")
            TestRunner.equal(Exporter.csv(prices.records, resolver: pricesResolver, separator: ","), "Price,Year,Label\r\n1.25,1977,v1.5\r\n", "decimal point with commas")
            TestRunner.equal(Value.$decimalSeparator.withValue(",") { Value.parseNumber("1,250") }, 1.25, "a semicolon file's 1,250 is one and a quarter")
            TestRunner.equal(Value.$decimalSeparator.withValue(".") { Value.parseNumber("1,250") }, 1250, "a comma file's is a thousand")
            TestRunner.equal(Value.$decimalSeparator.withValue(",") { Value.parseNumber("1.5") }, 1.5, "a decimal point still reads")
            TestRunner.equal(CSV.parse(CSV.write(rows)), rows, "commas read back")

            // Lookups off: nothing goes out.
            store.set(false, forKey: Preferences.Key.onlineLookups)
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var threw = false, cover: Data? = Data(), place: Place? = Place(name: "x")
            Task.detached {
                do { _ = try await Lookup.find("9780140449136") } catch { threw = error is OfflineError }
                cover = await Lookup.cover(URL(string: "https://covers.openlibrary.org/b/id/1-L.jpg"))
                place = await Places.find("Amsterdam")
                done.signal()
            }
            done.wait()
            TestRunner.expect(threw, "barcode lookup refuses")
            TestRunner.equal(cover, nil, "no cover download")
            TestRunner.equal(place, nil, "no place search")

            // Launch choice and the databases open at quit.
            store.set("reopen", forKey: Preferences.Key.atLaunch)
            TestRunner.equal(Preferences.atLaunch, .reopen, "reopen chosen")
            store.set("junk", forKey: Preferences.Key.atLaunch)
            TestRunner.equal(Preferences.atLaunch, .welcome, "an unknown value is the default")
            // Remembered as bookmarks: a database renamed since is still found.
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("golle-reopen-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let before = folder.appendingPathComponent("a b.golledb"), after = folder.appendingPathComponent("Renamed.golledb")
            FileManager.default.createFile(atPath: before.path, contents: Data("x".utf8))
            Preferences.openAtQuit = [before]
            func paths() -> [String] { Preferences.openAtQuit.map { $0.resolvingSymlinksInPath().path } }
            TestRunner.equal(paths(), [before.resolvingSymlinksInPath().path], "open databases remembered")
            try? FileManager.default.moveItem(at: before, to: after)
            TestRunner.equal(paths(), [after.resolvingSymlinksInPath().path], "and found again after a rename")
            store.removeObject(forKey: Preferences.Key.openAtQuitBookmarks)
            store.set(["/tmp/old.golledb"], forKey: Preferences.Key.openAtQuit)
            TestRunner.equal(Preferences.openAtQuit.map(\.path), ["/tmp/old.golledb"], "paths saved by an older Golle still read")
        }
    }

    private static func newFieldTypes() {
        TestRunner.suite("Field types: durations, colours, codes") {
            TestRunner.equal(Value.parseDuration("45:12", .hoursMinutesSeconds), 2712, "minutes and seconds")
            TestRunner.equal(Value.parseDuration("1:02:30", .hoursMinutesSeconds), 3750, "hours, minutes and seconds")
            TestRunner.equal(Value.parseDuration("1:30", .hoursMinutes), 5400, "hours and minutes")
            TestRunner.equal(Value.parseDuration("1h 30m", .hoursMinutesSeconds), 5400, "with units")
            TestRunner.equal(Value.parseDuration("90 min", .hoursMinutesSeconds), 5400, "in minutes")
            TestRunner.equal(Value.parseDuration("1,5 uur", .hoursMinutesSeconds), 5400, "in Dutch")
            TestRunner.equal(Value.parseDuration("3", .hoursMinutesSeconds), 180, "a plain number is minutes")
            TestRunner.equal(Value.parseDuration("2", .hoursMinutes), 7200, "or hours, in the hours style")
            TestRunner.equal(Value.parseDuration("1:75", .hoursMinutesSeconds), nil, "75 seconds is no duration")
            TestRunner.equal(Value.parseDuration("soon", .hoursMinutesSeconds), nil, "words are not")
            TestRunner.equal(Value.formatDuration(3750, .hoursMinutesSeconds), "1:02:30", "shown with hours")
            TestRunner.equal(Value.formatDuration(2712, .hoursMinutesSeconds), "45:12", "shown without")
            TestRunner.equal(Value.formatDuration(5400, .hoursMinutes), "1:30", "shown as hours and minutes")
            TestRunner.equal(Value.text("3:45").converted(to: .duration), .number(225), "text to duration")
            TestRunner.equal(Value.number(150).converted(to: .progress), .number(100), "progress stops at 100")

            TestRunner.equal(Value.parseColor("#abc"), "#AABBCC", "short hex")
            TestRunner.equal(Value.parseColor("rgb(255, 0, 10)"), "#FF000A", "rgb()")
            TestRunner.equal(Value.parseColor("blue-ish"), nil, "not a colour")
            TestRunner.equal(Value.barcodeIsValid("9780306406157"), true, "ISBN-13")
            TestRunner.equal(Value.barcodeIsValid("9780306406158"), false, "a wrong check digit")
            TestRunner.equal(Value.barcodeIsValid("080442957X"), true, "ISBN-10 ending in X")
            TestRunner.equal(Value.barcodeIsValid("036000291452"), true, "UPC-A")
            TestRunner.equal(Value.barcodeIsValid("ABC-123"), nil, "codes without a check digit aren't judged")
            TestRunner.equal(Value.text("978-0-306-40615-7").converted(to: .barcode), .text("9780306406157"), "dashes are left out")
            TestRunner.expect(Value.emailIsValid("anna@example.nl") && !Value.emailIsValid("anna@"), "email addresses")
            TestRunner.equal(Value.phoneURL("+31 6 1234 5678")?.absoluteString, "tel:+31612345678", "phone numbers call")

            let when = Field(name: "When", type: .date, options: { var o = FieldOptions(); o.includesTime = true; return o }())
            let moment = Value.gregorian.date(from: DateComponents(year: 2024, month: 3, day: 5, hour: 14, minute: 30))!
            TestRunner.expect(Value.date(moment).display(for: when).contains(":"), "a date with time shows the time")
            var length = Field(name: "Length", type: .duration)
            length.options.durationStyle = .hoursMinutesSeconds
            var table = DataTable(name: "T", fields: [when, length])
            var r = Record()
            r[when.id] = .date(moment)
            r[length.id] = .number(3750)
            table.records = [r]
            let resolver = Resolver(database: Database(tables: [table]), table: table)
            let row = [Exporter.cell(r, when, resolver), Exporter.cell(r, length, resolver)]
            TestRunner.equal(row, ["2024-03-05 14:30", "1:02:30"], "CSV writes the time and the duration")
            let back = Importer.records([row], columns: [(0, when), (1, length)])
            TestRunner.equal(back.first?[when.id], .date(moment), "and reads the time back")
            TestRunner.equal(back.first?[length.id], .number(3750), "and the duration")

            let longer = FilterRule(fieldID: length.id, op: .greater, operand: "1:00:00")
            TestRunner.expect(longer.matches(r, resolver), "a duration filter is typed like the field")
            TestRunner.equal(Importer.guessType(["a@b.nl", "c@d.com"]), .email, "email columns")
            TestRunner.equal(Importer.guessType(["#FF0000", "#00ff00"]), .color, "colour columns")
            TestRunner.equal(Importer.guessType(["1:02:30", "0:45:00"]), .duration, "duration columns")
            TestRunner.equal(Importer.field(named: "At", type: .date, values: ["2024-03-05 14:30"]).options.includesTime, true, "imported times stay visible")

            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("golle-types-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("t.xlsx")
            try? Exporter.xlsx(table.records, resolver: resolver).write(to: url)
            let sheet = (try? XLSX.read(url)) ?? []
            TestRunner.equal(sheet.dropFirst().first, ["2024-03-05T14:30:00", "1:02:30"], "Excel keeps the time and the duration")
        }

        TestRunner.suite("Field types: rollups") {
            let db = Template.all.first { $0.id == "music" }!.make()
            let artists = db.tables.first { $0.name == "Artists" }!
            let count = artists.fields.first { $0.type == .rollup }!
            TestRunner.equal(Resolver(database: db, table: artists).text(artists.records[0], count), "1", "an artist counts its albums (Linked From)")

            var tracks = DataTable(name: "Tracks")
            let length = Field(name: "Length", type: .duration)
            tracks.fields = [Field(name: "Title", type: .text), length]
            for seconds in [300.0, 420, 180] { var t = Record(); t[length.id] = .number(seconds); tracks.records.append(t) }
            let link = Field(name: "Tracks", type: .link, options: FieldOptions(linkedTableID: tracks.id))
            var total = Field(name: "Total", type: .rollup)
            total.options.rollupLinkFieldID = link.id
            total.options.rollupFieldID = length.id
            total.options.rollupKind = .sum
            var album = Record()
            album[link.id] = .links(tracks.records.map(\.id))
            let albums = DataTable(name: "Albums", fields: [link, total], records: [album])
            let both = Database(tables: [albums, tracks])
            let resolver = Resolver(database: both, table: albums)
            TestRunner.equal(resolver.value(album, total), .number(900), "a rollup adds up linked durations")
            TestRunner.equal(resolver.text(album, total), "15:00", "and shows them as a duration")
            var longest = total
            longest.options.rollupKind = .maximum
            TestRunner.equal(resolver.text(album, longest), "7:00", "the longest track")

            // Two rollups that look at each other stop instead of looping.
            var a = DataTable(name: "A"), b = DataTable(name: "B")
            let toB = Field(name: "B", type: .link, options: FieldOptions(linkedTableID: b.id))
            let toA = Field(name: "A", type: .link, options: FieldOptions(linkedTableID: a.id))
            var sumA = Field(name: "Sum", type: .rollup), sumB = Field(name: "Sum", type: .rollup)
            sumA.options.rollupLinkFieldID = toB.id; sumA.options.rollupFieldID = sumB.id; sumA.options.rollupKind = .sum
            sumB.options.rollupLinkFieldID = toA.id; sumB.options.rollupFieldID = sumA.id; sumB.options.rollupKind = .sum
            var ra = Record(), rb = Record()
            ra[toB.id] = .links([rb.id]); rb[toA.id] = .links([ra.id])
            a.fields = [toB, sumA]; a.records = [ra]
            b.fields = [toA, sumB]; b.records = [rb]
            _ = Resolver(database: Database(tables: [a, b]), table: a).text(ra, sumA)
            TestRunner.expect(true, "rollups in a circle stop")

            // Duplicating a table keeps its rollups working.
            let copy = albums.duplicated()
            TestRunner.equal(copy.fields[1].options.rollupLinkFieldID, copy.fields[0].id, "a copied rollup goes through the copied link")
        }
    }
}


/// A table grid in a window that stays off screen, with clicks and keys sent to that window only.
@MainActor
final class GridHarness {
    /// Accepts the first click: a window that isn't in front otherwise takes it to come forward.
    private final class Host<V: View>: NSHostingView<V> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    let document: GolleDocument
    let window: NSWindow
    let size = CGSize(width: 1760, height: 700)

    var table: DataTable { document.database.tables[0] }
    var records: [Record.ID] { table.records.map(\.id) }

    init() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.finishLaunching()
        let types: [(String, FieldType)] = [("Name", .text), ("Quantity", .number), ("Price", .number), ("Bought", .date), ("Done", .checkbox),
                                            ("Stars", .rating), ("Length", .duration), ("Site", .url), ("Mail", .email), ("Code", .barcode),
                                            ("Progress", .progress), ("Kind", .choice), ("Tags", .multiChoice), ("Notes", .longText),
                                            ("Photos", .image), ("Files", .file), ("Steps", .checklist), ("Place", .location), ("Total", .formula)]
        var table = DataTable(name: "Items", fields: types.map { Field(name: $0.0, type: $0.1) })
        table.fields[11].options.choices = ["A", "B"]
        table.fields[12].options.choices = ["x", "y"]
        table.fields[18].options.formula = "{Quantity} * 2"
        table.fields[13].options.richText = true
        table.records = [Record(), Record(), Record()]
        document = GolleDocument(database: Database(tables: [table]))
        document.selectedTableID = document.database.tables[0].id
        window = NSWindow(contentRect: NSRect(x: -6000, y: 0, width: size.width, height: size.height), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = Host(rootView: Live(document: document).frame(width: size.width, height: size.height))
        window.orderFrontRegardless()
        pump(0.4)
    }

    /// The grid redrawn with the document, as the window's own view does.
    private struct Live: View {
        @ObservedObject var document: GolleDocument
        var body: some View {
            let table = document.database.tables[0]
            let resolver = document.resolver(for: table)
            HStack(spacing: 0) {
                RecordGrid(document: document, table: table, view: document.currentView, rows: table.records, resolver: resolver)
                // The inspector beside it, as in the window: the first record's form.
                if let record = table.records.first {
                    RecordForm(document: document, table: table, record: record, resolver: resolver).frame(width: 360)
                }
            }
        }
    }

    /// The text views (long text) in the window, in the form beside the grid.
    func textViews() -> [NSTextView] {
        func find(_ view: NSView) -> [NSTextView] {
            (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(find)
        }
        return window.contentView.map(find)?.filter { !$0.isFieldEditor } ?? []
    }

    /// Types into whatever has the keyboard.
    func typeKeys(_ text: String) { type(text) }

    func close() { window.orderOut(nil) }

    func value(_ row: Int, _ name: String) -> Value? {
        table.records[row][table.field(named: name)!.id]
    }

    func pump(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }

    /// The middle of a cell, in the window's coordinates (counted from the bottom).
    func point(row: Int, field name: String) -> CGPoint {
        let view = document.currentView
        let columns = view.columns(table)
        var x = RecordGrid.numberWidth
        for field in columns {
            let width = CGFloat(GridColumns.width(field, in: view))
            if field.name == name { x += width / 2; break }
            x += width
        }
        let y = RecordGrid.headerHeight + CGFloat(row) * RecordGrid.rowHeight + RecordGrid.rowHeight / 2
        return CGPoint(x: x, y: size.height - y)
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, count: Int) {
        if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1) {
            window.sendEvent(event)
        }
        pump(0.03)
    }

    func click(row: Int, field: String) {
        let p = point(row: row, field: field)
        mouse(.leftMouseDown, at: p, count: 1)
        mouse(.leftMouseUp, at: p, count: 1)
        // Past the double-click time, so the next click is a click of its own.
        pump(NSEvent.doubleClickInterval + 0.1)
    }

    func doubleClick(row: Int, field: String) {
        let p = point(row: row, field: field)
        mouse(.leftMouseDown, at: p, count: 1)
        mouse(.leftMouseUp, at: p, count: 1)
        mouse(.leftMouseDown, at: p, count: 2)
        mouse(.leftMouseUp, at: p, count: 2)
        pump(0.3)
    }

    enum Key {
        case `return`, tab, escape, up, down, left, right, delete, space
        var code: (UInt16, String) {
            switch self {
            case .return: (36, "\r")
            case .tab: (48, "\t")
            case .escape: (53, "\u{1B}")
            case .up: (126, String(UnicodeScalar(NSUpArrowFunctionKey)!))
            case .down: (125, String(UnicodeScalar(NSDownArrowFunctionKey)!))
            case .left: (123, String(UnicodeScalar(NSLeftArrowFunctionKey)!))
            case .right: (124, String(UnicodeScalar(NSRightArrowFunctionKey)!))
            case .delete: (51, "\u{7F}")
            case .space: (49, " ")
            }
        }
    }

    private func send(_ characters: String, code: UInt16, keys: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: keys, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: characters,
                                            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
                window.sendEvent(event)
            }
            pump(0.03)
        }
    }

    func key(_ key: Key, keys: NSEvent.ModifierFlags = []) {
        send(key.code.1, code: key.code.0, keys: keys)
        pump(0.15)
    }

    func type(_ text: String) {
        for character in text { send(String(character), code: 0) }
        pump(0.15)
    }
}
