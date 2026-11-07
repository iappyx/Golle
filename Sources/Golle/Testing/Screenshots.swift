import AppKit
import ScreenCaptureKit
import SwiftUI

/// `Golle --screenshots <folder> [light|dark]` draws document windows with demo data into PNGs and
/// quits. The windows sit off screen and the app never activates. They are captured through
/// ScreenCaptureKit as this process's own windows (title bar, toolbar and translucent sidebar
/// included), which needs no screen recording permission; drawing the views directly is the
/// fallback. Used for the README and to check layouts without clicking through the app.
@MainActor
enum Screenshots {
    static func run(into folder: URL, appearance: String? = nil) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // The default Settings, with the asked appearance (the Settings view applies its own).
        let suite = "golle.screenshots"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        Preferences.store = UserDefaults(suiteName: suite)!
        Preferences.store.set(appearance ?? "system", forKey: Preferences.Key.appearance)
        switch appearance {
        case "light": app.appearance = NSAppearance(named: .aqua)
        case "dark": app.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        var shots: [(String, GolleDocument, (GolleDocument) -> Void)] = []
        shots.append(("1-table", demo(), { doc in doc.selectedRecordIDs = [doc.currentTable!.records[0].id] }))
        shots.append(("2-gallery", demo(), { doc in doc.updateCurrentView { $0.mode = .gallery } }))
        shots.append(("31-summary", demo(), { doc in
            let albums = doc.currentTable!
            doc.updateCurrentView { view in
                view.mode = .summary
                view.summary.rowFieldID = albums.field(named: "Genre")?.id
                view.summary.columnFieldID = albums.field(named: "Format")?.id
                view.summary.measure = .sum
                view.summary.valueFieldID = albums.field(named: "Price Paid")?.id
            }
        }))
        shots.append(("22-artists", demo(), { doc in doc.selectedTableID = doc.database.tables[1].id }))
        shots.append(("3-form", demo(), { doc in
            doc.updateCurrentView { $0.mode = .layout }
            doc.selectedRecordIDs = [doc.currentTable!.records[2].id]
        }))
        shots.append(("4-saved-view", demo(), { doc in
            doc.selectedViewID = doc.currentTable!.views.first?.id
        }))
        shots.append(("7-grouped", demo(), { doc in
            let t = doc.currentTable!
            doc.updateCurrentView { $0.groupBy = [t.field(named: "Format")!.id, t.field(named: "Rating")!.id] }
        }))
        shots.append(("8-board", demo(), { doc in doc.updateCurrentView { $0.mode = .board } }))
        shots.append(("14-chart", demo(), { doc in
            let t = doc.currentTable!
            doc.updateCurrentView { $0.mode = .chart; $0.chart.categoryFieldID = t.field(named: "Genre")!.id }
        }))
        shots.append(("15-donut", demo(), { doc in
            let t = doc.currentTable!
            doc.updateCurrentView { $0.mode = .chart; $0.chart.kind = .pie; $0.chart.categoryFieldID = t.field(named: "Format")!.id }
        }))
        shots.append(("16-dashboard", demo(), { doc in doc.showsDashboard = true }))
        shots.append(("17-table-chips", demo(), { doc in
            let t = doc.currentTable!
            doc.updateCurrentView { $0.hiddenFieldIDs = [t.field(named: "Artist")!.id, t.field(named: "Year")!.id] }
        }))
        shots.append(("9-calendar", demo(), { doc in doc.updateCurrentView { $0.mode = .calendar } }))
        shots.append(("10-map", demo(), { doc in doc.updateCurrentView { $0.mode = .map } }))
        shots.append(("11-gallery-grouped", demo(), { doc in
            let t = doc.currentTable!
            doc.updateCurrentView { $0.mode = .gallery; $0.groupBy = [t.field(named: "Format")!.id] }
        }))
        shots.append(("25-timeline", booksDemo(), { doc in
            doc.selectedViewID = doc.currentTable!.views.first { $0.mode == .timeline }?.id
            doc.updateCurrentView { $0.timelineScale = .week }
            doc.selectedRecordIDs = [doc.currentTable!.records[1].id]
        }))
        shots.append(("26-timeline-grouped", booksDemo(), { doc in
            let t = doc.currentTable!
            doc.selectedViewID = t.views.first { $0.mode == .timeline }?.id
            doc.updateCurrentView { $0.groupBy = [t.field(named: "Status")!.id] }
        }))
        shots.append(("27-rules", demo(), { doc in
            let t = doc.currentTable!
            // A missing title and a barcode typed twice.
            doc.setValue(nil, record: t.records[3].id, field: t.field(named: "Title")!.id, table: t.id)
            doc.setValue(.text("4988005232214"), record: t.records[1].id, field: t.field(named: "Barcode")!.id, table: t.id)
            doc.setValue(.text("4988005232214"), record: t.records[5].id, field: t.field(named: "Barcode")!.id, table: t.id)
            doc.updateCurrentView { $0.hiddenFieldIDs = ["Year", "Genre", "Condition", "Cover", "Bought", "Length", "Price Paid", "Rating"].compactMap { t.field(named: $0)?.id } }
            doc.selectedRecordIDs = [t.records[1].id]
        }))
        // The demo as a real file, to open in Golle.
        let demoFile = folder.appendingPathComponent("Record Collection Demo.golledb")
        try? FileManager.default.removeItem(at: demoFile)
        try? demo().package().write(to: demoFile, options: .atomic, originalContentsURL: nil)
        var windows: [NSWindow] = []
        for (_, document, setup) in shots {
            setup(document)
            let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 1240, height: 760),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            // As a document window: the view's toolbar and title go into the window's title bar.
            let host = NSHostingController(rootView: DocumentView(document: document).frame(width: 1240, height: 760))
            host.sceneBridgingOptions = [.toolbars, .title]
            window.contentViewController = host
            window.title = "Record Collection"
            window.setContentSize(NSSize(width: 1240, height: 760))
            window.setFrameOrigin(NSPoint(x: -4000, y: 0))
            window.orderFrontRegardless()
            windows.append(window)
        }
        // The layout editor, at the size a sheet gets in a default window.
        do {
            let document = demo()
            let table = document.currentTable!.id
            let layout = document.addLayout(to: table)!
            shots.append(("5-layout-editor", document, { _ in }))
            let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 1160, height: 700),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: LayoutEditor(document: document, tableID: table, layoutID: layout, size: CGSize(width: 1160, height: 700)))
            window.orderFrontRegardless()
            windows.append(window)
        }
        for (name, size, make) in [
            ("18-welcome", CGSize(width: 820, height: 520), { (_: GolleDocument) in AnyView(WelcomeView()) }),
            ("21-about", CGSize(width: 420, height: 400), { (_: GolleDocument) in AnyView(AboutView().background(Color(nsColor: .windowBackgroundColor))) }),
            ("22-settings", CGSize(width: 520, height: 470), { (_: GolleDocument) in AnyView(AppSettings().background(Color(nsColor: .windowBackgroundColor))) }),
            ("23-settings-privacy", CGSize(width: 520, height: 260), { (_: GolleDocument) in AnyView(PrivacySettings().background(Color(nsColor: .windowBackgroundColor))) }),
            ("24-settings-export", CGSize(width: 520, height: 300), { (_: GolleDocument) in AnyView(ExchangeSettings().background(Color(nsColor: .windowBackgroundColor))) }),
            ("19-labels", CGSize(width: 900, height: 600), { (d: GolleDocument) in AnyView(LabelsSheet(document: d, records: d.currentTable!.records)) }),
            ("20-record-form", CGSize(width: 420, height: 900), { (d: GolleDocument) in
                let t = d.currentTable!
                return AnyView(RecordForm(document: d, table: t, record: t.records[0], resolver: d.resolver(for: t)))
            }),
            ("30-related", CGSize(width: 420, height: 640), { (d: GolleDocument) in
                // An artist with their albums underneath, edited in place.
                let artists = d.database.tables[1]
                let artist = artists.records.max { a, b in
                    d.database.tables[0].records.filter { $0.values.values.contains { $0.links.contains(a.id) } }.count
                        < d.database.tables[0].records.filter { $0.values.values.contains { $0.links.contains(b.id) } }.count
                }!
                return AnyView(RecordForm(document: d, table: artists, record: artist, resolver: d.resolver(for: artists)))
            }),
        ] as [(String, CGSize, (GolleDocument) -> AnyView)] {
            let document = demo()
            shots.append((name, document, { _ in }))
            let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -4000, y: 0), size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: make(document).frame(width: size.width, height: size.height))
            window.orderFrontRegardless()
            windows.append(window)
        }
        for (name, sheet) in [("12-colour-rules", 0), ("13-duplicates", 1)] {
            let document = demo()
            shots.append((name, document, { _ in }))
            let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 720, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
            let table = document.currentTable!.id
            window.contentView = sheet == 0
                ? NSHostingView(rootView: AnyView(ColorRulesSheet(document: document, tableID: table)))
                : NSHostingView(rootView: AnyView(DuplicatesSheet(document: document, tableID: table)))
            window.orderFrontRegardless()
            windows.append(window)
        }
        for (name, kind) in [("28-report", 0), ("29-find-replace", 1)] {
            let document = demo()
            shots.append((name, document, { _ in }))
            let size = kind == 0 ? NSSize(width: 980, height: 680) : NSSize(width: 560, height: 560)
            let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -4000, y: 0), size: size), styleMask: [.titled], backing: .buffered, defer: false)
            let records = document.currentTable!.records
            window.contentView = kind == 0
                ? NSHostingView(rootView: AnyView(ReportSheet(document: document, records: records)))
                : NSHostingView(rootView: AnyView(FindReplaceSheet(document: document, tableID: document.currentTable!.id, records: records, initialFind: "blue", initialReplacement: "Bleu")))
            window.orderFrontRegardless()
            windows.append(window)
        }
        do {
            let document = demo()
            shots.append(("6-field-editor", document, { _ in }))
            let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: FieldEditor(document: document, tableID: document.currentTable!.id))
            window.orderFrontRegardless()
            windows.append(window)
        }
        // Let SwiftUI lay out and load the table rows before drawing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            Task { @MainActor in
                let shareable = try? await SCShareableContent.currentProcess
                for (index, window) in windows.enumerated() {
                    let url = folder.appendingPathComponent("\(shots[index].0).png")
                    if let captured = shareable?.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }),
                       let image = await capture(captured, scale: window.backingScaleFactor) {
                        let rep = NSBitmapImageRep(cgImage: image)
                        try? rep.representation(using: .png, properties: [:])?.write(to: url)
                    } else if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: url)
                    }
                    print("wrote \(url.path)")
                }
                exit(0)
            }
        }
        app.run()
    }

    private static func capture(_ window: SCWindow, scale: CGFloat) async -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// The record collection template with a few albums and generated covers.
    /// A reading list over the last months, for the timeline.
    static func booksDemo() -> GolleDocument {
        var db = Template.all.first { $0.id == "books" }!.make()
        let table = db.tables[0]
        func f(_ name: String) -> Field.ID { table.field(named: name)!.id }
        let cal = Calendar.current
        func day(_ offset: Int) -> Value { .date(cal.startOfDay(for: cal.date(byAdding: .day, value: offset, to: Date())!)) }
        let books: [(String, String, String, Int, Int?, Int)] = [
            ("The Overstory", "Richard Powers", "Read", -70, -48, 5),
            ("Piranesi", "Susanna Clarke", "Read", -50, -41, 4),
            ("Middlemarch", "George Eliot", "Abandoned", -44, -30, 2),
            ("The Dispossessed", "Ursula K. Le Guin", "Read", -38, -20, 5),
            ("Braiding Sweetgrass", "Robin Wall Kimmerer", "Reading", -18, 9, 0),
            ("Klara and the Sun", "Kazuo Ishiguro", "Read", -15, -4, 4),
            ("The Remains of the Day", "Kazuo Ishiguro", "Reading", -3, 12, 0),
            ("Project Hail Mary", "Andy Weir", "Want to Read", 14, 24, 0),
        ]
        db.tables[0].records = books.map { title, author, status, start, end, stars in
            var r = Record()
            r[f("Title")] = .text(title)
            r[f("Author")] = .text(author)
            r[f("Status")] = .choices([status])
            r[f("Started")] = day(start)
            if let end { r[f("Finished")] = day(end) }
            if stars > 0 { r[f("Rating")] = .rating(stars) }
            return r
        }
        db.tables[0].colorRules = [
            ColorRule(color: .green, filter: Filter(rules: [FilterRule(fieldID: f("Status"), op: .equals, operand: "Reading")])),
            ColorRule(color: .graphite, filter: Filter(rules: [FilterRule(fieldID: f("Status"), op: .equals, operand: "Abandoned")])),
        ]
        return GolleDocument(database: db)
    }

    static func demo() -> GolleDocument {
        var db = Template.all.first { $0.id == "music" }!.make()
        let document = GolleDocument(database: db)
        let albums = db.tables[0]
        func f(_ name: String) -> Field.ID { albums.field(named: name)!.id }
        let artistsTable = db.tables[1]
        let artistName = artistsTable.field(named: "Name")!.id
        let data: [(String, String, Int, String, [String], Int, Double, NSColor)] = [
            ("Kind of Blue", "Miles Davis", 1959, "LP", ["Jazz"], 5, 32, .systemBlue),
            ("Blue Train", "John Coltrane", 1957, "LP", ["Jazz"], 5, 28, .systemIndigo),
            ("Abbey Road", "The Beatles", 1969, "LP", ["Rock", "Pop"], 4, 25, .systemGreen),
            ("Rumours", "Fleetwood Mac", 1977, "CD", ["Rock"], 4, 9, .systemOrange),
            ("Blue", "Joni Mitchell", 1971, "LP", ["Folk"], 5, 22, .systemTeal),
            ("Discovery", "Daft Punk", 2001, "CD", ["Electronic"], 3, 12, .systemPink),
            ("What's Going On", "Marvin Gaye", 1971, "LP", ["Soul"], 5, 30, .systemPurple),
            ("Random Access Memories", "Daft Punk", 2013, "Digital", ["Electronic", "Pop"], 4, 10, .systemRed),
        ]
        var artistIDs: [String: UUID] = Dictionary(uniqueKeysWithValues: artistsTable.records.map { ($0[artistName]!.text!, $0.id) })
        var artistRecords = artistsTable.records
        var records: [Record] = []
        for (index, item) in data.enumerated() {
            if artistIDs[item.1] == nil {
                var artist = Record()
                artist[artistName] = .text(item.1)
                let countries = ["John Coltrane": "USA", "The Beatles": "UK", "Fleetwood Mac": "UK", "Joni Mitchell": "Canada",
                                 "Daft Punk": "France", "Marvin Gaye": "USA"]
                if let country = countries[item.1], let field = artistsTable.field(named: "Country") { artist[field.id] = .text(country) }
                artistIDs[item.1] = artist.id
                artistRecords.append(artist)
            }
            var record = index == 0 ? albums.records[0] : Record()
            record[f("Title")] = .text(item.0)
            record[f("Artist")] = .links([artistIDs[item.1]!])
            record[f("Year")] = .number(Double(item.2))
            record[f("Format")] = .choices([item.3])
            record[f("Genre")] = .choices(item.4)
            record[f("Rating")] = .rating(item.5)
            record[f("Price Paid")] = .number(item.6)
            record[f("Condition")] = .choices([["Mint", "Near Mint", "Very Good"][index % 3]])
            record[f("Bought")] = .date(Calendar.current.date(byAdding: .day, value: -index * 3, to: Date())!)
            record[f("Cover")] = .attachments([document.addAttachment(data: cover(item.0, color: item.7), name: "\(item.0).png")])
            record[f("Length")] = .number(Double([2_757, 2_520, 2_831, 2_391, 2_165, 3_653, 2_116, 4_464][index]))
            records.append(record)
        }
        db.tables[0].records = records
        db.tables[1].records = artistRecords
        // Where each album was recorded, a colour rule, and one duplicate to find.
        let studio = Field(name: "Recorded At", type: .location)
        db.tables[0].fields.append(studio)
        let places = [("30th Street Studio, New York", 40.744, -73.996), ("Van Gelder Studio, Hackensack", 40.886, -74.043),
                      ("Abbey Road Studios, London", 51.532, -0.178), ("Record Plant, Sausalito", 37.859, -122.485),
                      ("A&M Studios, Los Angeles", 34.091, -118.341), ("Daft House, Paris", 48.857, 2.352),
                      ("Hitsville U.S.A., Detroit", 42.364, -83.088), ("Henson Studios, Los Angeles", 34.098, -118.337)]
        for (index, place) in places.enumerated() {
            records[index][studio.id] = .location(Place(name: place.0, latitude: place.1, longitude: place.2))
        }
        var price = db.tables[0].fields[db.tables[0].fieldIndex(f("Price Paid"))!]
        price.options.numberFormat = { var n = NumberFormat(); n.style = .currency; n.currency = "EUR"; return n }()
        db.tables[0].fields[db.tables[0].fieldIndex(price.id)!] = price
        db.tables[0].colorRules = [
            ColorRule(color: .yellow, filter: Filter(rules: [FilterRule(fieldID: f("Rating"), op: .equals, operand: "5")])),
            ColorRule(color: .teal, filter: Filter(rules: [FilterRule(fieldID: f("Format"), op: .equals, operand: "CD")])),
        ]
        db.tables[0].views.append(SavedView(name: "By Format", groupBy: [f("Format"), f("Rating")]))
        db.tables[0].views.append(SavedView(name: "Board", mode: .board))
        // Formatted notes, a checklist, a dashboard.
        records[0][f("Notes")] = .text("## Side A\n- **So What**\n- *Freddie Freeloader*\n\nRecorded in ~~one~~ two sessions. See [the story](https://en.wikipedia.org/wiki/Kind_of_Blue).")
        let care = Field(name: "Care", type: .checklist)
        db.tables[0].fields.append(care)
        records[0][care.id] = .checklist([CheckItem(text: "Clean", done: true), CheckItem(text: "New inner sleeve", done: true), CheckItem(text: "Digitise")])
        records[2][care.id] = .checklist([CheckItem(text: "Clean")])
        let genre = db.tables[0].fieldIndex(f("Genre"))!
        db.tables[0].fields[genre].options.choiceColors = ["Jazz": .blue, "Rock": .red, "Pop": .pink, "Folk": .green, "Soul": .orange, "Electronic": .purple]
        var byGenre = DashboardTile(tableID: db.tables[0].id)
        byGenre.chart.categoryFieldID = f("Genre")
        var formats = DashboardTile(tableID: db.tables[0].id)
        formats.chart.kind = .pie
        formats.chart.categoryFieldID = f("Format")
        var spent = DashboardTile(tableID: db.tables[0].id, kind: .number)
        spent.summary = .sum
        spent.fieldID = f("Price Paid")
        spent.title = "Spent on records"
        var perMonth = DashboardTile(tableID: db.tables[0].id)
        perMonth.chart.kind = .line
        perMonth.chart.categoryFieldID = f("Bought")
        perMonth.chart.dateUnit = .day
        db.dashboard = [byGenre, formats, spent, DashboardTile(tableID: db.tables[0].id, kind: .number), perMonth]
        var copy = records[1]
        copy.id = UUID()
        copy[f("Title")] = .text("blue train")
        records.append(copy)
        db.tables[0].records = records
        // The document already holds the covers; give it the filled-in database as one change.
        document.change("Demo") { $0 = db }
        document.selectedTableID = db.tables[0].id
        return document
    }

    private static func cover(_ title: String, color: NSColor) -> Data {
        let size = 400.0
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGradient(starting: color, ending: color.blended(withFraction: 0.6, of: .black)!)!.draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -60)
        NSColor.white.withAlphaComponent(0.18).setStroke()
        for r in stride(from: 40.0, to: 400, by: 36) {
            let ring = NSBezierPath(ovalIn: NSRect(x: 200 - r / 2, y: 200 - r / 2, width: r, height: r))
            ring.lineWidth = 3
            ring.stroke()
        }
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        (title as NSString).draw(in: NSRect(x: 24, y: 24, width: 352, height: 120), withAttributes: [
            .font: NSFont.systemFont(ofSize: 34, weight: .heavy), .foregroundColor: NSColor.white, .paragraphStyle: style,
        ])
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
}
