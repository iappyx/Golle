import Foundation

/// Ready-made databases for the "New from Template" window.
struct Template: Identifiable {
    let id: String
    let name: String
    let symbol: String
    let summary: String
    let accent: AccentChoice
    let make: () -> Database

    static let all: [Template] = [
        Template(id: "blank", name: "Blank", symbol: "doc", summary: "One empty table with a name and notes.", accent: .orange) { .blank() },
        Template(id: "music", name: "Record Collection", symbol: "opticaldisc", summary: "Albums with artist, year, format and cover, linked to artists.", accent: .purple, make: music),
        Template(id: "books", name: "Reading List", symbol: "books.vertical", summary: "Books you own, are reading or want to read.", accent: .teal, make: books),
        Template(id: "movies", name: "Movies & Series", symbol: "film", summary: "What you watched, when, and what you thought of it.", accent: .red, make: movies),
        Template(id: "inventory", name: "Home Inventory", symbol: "shippingbox", summary: "Belongings with value, location, photos and receipts.", accent: .blue, make: inventory),
        Template(id: "contacts", name: "Contacts", symbol: "person.2", summary: "People with email, phone, birthday and tags.", accent: .green, make: contacts),
        Template(id: "recipes", name: "Recipes", symbol: "fork.knife", summary: "Recipes with ingredients, time, course and a photo.", accent: .orange, make: recipes),
        Template(id: "collection", name: "Collection", symbol: "square.stack.3d.up", summary: "Anything you collect: coins, stamps, LEGO, plants.", accent: .pink, make: collection),
    ]

    // MARK: Builders

    private static func field(_ name: String, _ type: FieldType, choices: [String] = [], formula: String = "") -> Field {
        Field(name: name, type: type, options: FieldOptions(choices: choices, formula: formula))
    }

    private static func rule(_ field: Field, _ op: FilterOperator, _ operand: String = "") -> FilterRule {
        FilterRule(fieldID: field.id, op: op, operand: operand)
    }

    private static func database(_ tables: [DataTable], accent: AccentChoice, symbol: String) -> Database {
        var db = Database(tables: tables)
        db.settings.accent = accent
        db.settings.symbol = symbol
        return db
    }

    private static func music() -> Database {
        let artistName = field("Name", .text)
        let country = field("Country", .text)
        var artists = DataTable(name: "Artists", fields: [artistName, country, field("Notes", .longText)])
        let length = field("Length", .duration)

        var title = field("Title", .text)
        title.options.required = true
        let artist = Field(name: "Artist", type: .link, options: FieldOptions(linkedTableID: artists.id))
        // The artist's country, shown with each album.
        var from = field("Country", .lookup)
        from.options.rollupLinkFieldID = artist.id
        from.options.rollupFieldID = country.id
        var barcode = field("Barcode", .barcode)
        barcode.options.unique = true
        let year = field("Year", .number)
        let format = field("Format", .choice, choices: ["LP", "7\"", "12\"", "CD", "Cassette", "Digital"])
        let genre = field("Genre", .multiChoice, choices: ["Jazz", "Rock", "Pop", "Classical", "Electronic", "Hip-Hop", "Folk", "Soul", "Blues"])
        let condition = field("Condition", .choice, choices: ["Mint", "Near Mint", "Very Good", "Good", "Fair", "Poor"])
        let rating = field("Rating", .rating)
        let cover = field("Cover", .image)
        let price = field("Price Paid", .number)
        let bought = field("Bought", .date)
        let age = field("Age", .formula, formula: "IF(ISBLANK({Year}), \"\", YEAR(TODAY()) - {Year} & \" years\")")
        var albums = DataTable(name: "Albums", fields: [title, artist, from, year, format, genre, condition, rating, cover, price, bought, length, barcode, field("Notes", .longText), age])
        // An artist counts its albums, through the albums' Artist link.
        var albumCount = field("Albums", .rollup)
        albumCount.options.rollupLinkFieldID = artist.id
        albumCount.options.rollupKind = .count
        artists.fields.insert(albumCount, at: 2)
        albums.views = [
            SavedView(name: "Favourites", filter: Filter(rules: [rule(rating, .greaterOrEqual, "4")]), sort: [SortKey(fieldID: rating.id, ascending: false)]),
            SavedView(name: "Vinyl", filter: Filter(match: .any, rules: [rule(format, .equals, "LP"), rule(format, .equals, "7\""), rule(format, .equals, "12\"")]), mode: .gallery),
        ]
        albums.summaries = [SummaryItem(fieldID: price.id, kind: .sum)]

        // An artist's albums show in its form under "Linked From".
        var miles = Record(); miles[artistName.id] = .text("Miles Davis"); miles[country.id] = .text("USA")
        artists.records = [miles]
        var kind = Record()
        kind[title.id] = .text("Kind of Blue"); kind[artist.id] = .links([miles.id]); kind[year.id] = .number(1959)
        kind[format.id] = .choices(["LP"]); kind[genre.id] = .choices(["Jazz"]); kind[rating.id] = .rating(5)
        albums.records = [kind]
        return database([albums, artists], accent: .purple, symbol: "opticaldisc")
    }

    private static func books() -> Database {
        var title = field("Title", .text)
        title.options.required = true
        let author = field("Author", .text)
        let status = field("Status", .choice, choices: ["Want to Read", "Reading", "Read", "Abandoned"])
        let rating = field("Rating", .rating)
        let finished = field("Finished", .date)
        let pages = field("Pages", .number)
        let genre = field("Genre", .multiChoice, choices: ["Fiction", "Non-fiction", "Biography", "History", "Science", "Fantasy", "Mystery", "Poetry"])
        var isbn = field("ISBN", .barcode)
        isbn.options.unique = true
        let started = field("Started", .date)
        var table = DataTable(name: "Books", fields: [title, author, status, rating, genre, pages, field("Progress", .progress), isbn, started, finished, field("Cover", .image), field("Owned", .checkbox), field("Notes", .longText)])
        var timeline = SavedView(name: "Reading Timeline", mode: .timeline)
        timeline.dateFieldID = started.id
        timeline.endDateFieldID = finished.id
        timeline.timelineScale = .month
        table.views = [
            SavedView(name: "Reading Now", filter: Filter(rules: [rule(status, .equals, "Reading")])),
            SavedView(name: "To Read", filter: Filter(rules: [rule(status, .equals, "Want to Read")])),
            SavedView(name: "Read This Year", filter: Filter(rules: [rule(finished, .inLastDays, "365")]), sort: [SortKey(fieldID: finished.id, ascending: false)]),
            timeline,
        ]
        table.summaries = [SummaryItem(fieldID: pages.id, kind: .sum), SummaryItem(fieldID: rating.id, kind: .average)]
        return database([table], accent: .teal, symbol: "books.vertical")
    }

    private static func movies() -> Database {
        let title = field("Title", .text)
        let kind = field("Kind", .choice, choices: ["Movie", "Series", "Documentary"])
        let watched = field("Watched", .date)
        let rating = field("Rating", .rating)
        let toWatch = field("Watchlist", .checkbox)
        var table = DataTable(name: "Watched", fields: [title, kind, field("Year", .number), field("Director", .text), watched, rating, toWatch, field("Where", .choice, choices: ["Cinema", "Netflix", "Prime Video", "Disney+", "TV", "Blu-ray"]), field("Poster", .image), field("Review", .longText)])
        table.views = [
            SavedView(name: "Watchlist", filter: Filter(rules: [rule(toWatch, .isChecked)])),
            SavedView(name: "Top Rated", filter: Filter(rules: [rule(rating, .equals, "5")]), mode: .gallery),
        ]
        return database([table], accent: .red, symbol: "film")
    }

    private static func inventory() -> Database {
        let item = field("Item", .text)
        let room = field("Room", .choice, choices: ["Living Room", "Kitchen", "Bedroom", "Office", "Garage", "Attic", "Garden"])
        let quantity = field("Quantity", .number)
        let value = field("Value", .number)
        let total = field("Total Value", .formula, formula: "IF(ISBLANK({Quantity}), {Value}, {Quantity} * {Value})")
        let warranty = field("Warranty Until", .date)
        var table = DataTable(name: "Items", fields: [item, room, field("Category", .choice, choices: ["Electronics", "Furniture", "Appliances", "Jewellery", "Tools", "Art", "Clothing"]), quantity, value, total, field("Purchased", .date), warranty, field("Serial Number", .text), field("Barcode", .barcode), field("Photos", .image), field("Receipt", .file), field("Notes", .longText)])
        table.views = [
            SavedView(name: "Warranty Running", filter: Filter(rules: [rule(warranty, .after, Date().formatted(Value.isoDay))])),
        ]
        table.summaries = [SummaryItem(fieldID: total.id, kind: .sum)]
        return database([table], accent: .blue, symbol: "shippingbox")
    }

    private static func contacts() -> Database {
        let first = field("First Name", .text)
        let last = field("Last Name", .text)
        let full = field("Full Name", .formula, formula: "TRIM({First Name} & \" \" & {Last Name})")
        let birthday = field("Birthday", .date)
        let tags = field("Tags", .multiChoice, choices: ["Family", "Friend", "Work", "Neighbour", "Club"])
        let age = field("Age", .formula, formula: "IF(ISBLANK({Birthday}), \"\", FLOOR(DAYS(TODAY(), {Birthday}) / 365.25))")
        var table = DataTable(name: "People", fields: [first, last, full, field("Email", .email), field("Phone", .phone), field("Address", .longText), birthday, age, tags, field("Photo", .image), field("Notes", .longText)])
        table.views = [
            SavedView(name: "Family", filter: Filter(rules: [rule(tags, .equals, "Family")])),
            SavedView(name: "Birthdays Soon", filter: Filter(rules: [rule(birthday, .isNotEmpty)]), sort: [SortKey(fieldID: birthday.id)]),
        ]
        return database([table], accent: .green, symbol: "person.2")
    }

    private static func recipes() -> Database {
        let name = field("Name", .text)
        let course = field("Course", .choice, choices: ["Breakfast", "Starter", "Main", "Side", "Dessert", "Drink", "Snack"])
        let minutes = field("Minutes", .number)
        let favourite = field("Favourite", .checkbox)
        var table = DataTable(name: "Recipes", fields: [name, course, field("Cuisine", .text), minutes, field("Serves", .number), favourite, field("Photo", .image), field("Ingredients", .longText), field("Method", .longText), field("Source", .url)])
        table.views = [
            SavedView(name: "Quick (≤ 30 min)", filter: Filter(rules: [rule(minutes, .lessOrEqual, "30")])),
            SavedView(name: "Favourites", filter: Filter(rules: [rule(favourite, .isChecked)]), mode: .gallery),
        ]
        return database([table], accent: .orange, symbol: "fork.knife")
    }

    private static func collection() -> Database {
        let name = field("Name", .text)
        let owned = field("Owned", .checkbox)
        let value = field("Value", .number)
        var table = DataTable(name: "Collection", fields: [name, field("Category", .choice, choices: ["Category A", "Category B"]), field("Year", .number), owned, field("Condition", .rating), value, field("Acquired", .date), field("Photos", .image), field("Notes", .longText)])
        table.views = [
            SavedView(name: "Wishlist", filter: Filter(rules: [rule(owned, .isNotChecked)])),
            SavedView(name: "Gallery", mode: .gallery),
        ]
        table.summaries = [SummaryItem(fieldID: value.id, kind: .sum)]
        return database([table], accent: .pink, symbol: "square.stack.3d.up")
    }
}
