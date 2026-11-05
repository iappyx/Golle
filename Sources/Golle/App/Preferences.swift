import Foundation

/// App-wide preferences, set in the Settings window. They belong to the user and this Mac; anything
/// about a database itself (colour, icon, password, fields, views) is stored in its file.
enum Preferences {
    /// Where the preferences are kept. The tests swap in an empty one, so they run with the defaults
    /// whatever the user has set.
    static var store = UserDefaults.standard

    enum Key {
        static let appearance = "appearance"
        static let onlineLookups = "onlineLookups"
        static let atLaunch = "atLaunch"
        static let currency = "defaultCurrency"
        static let historyLimit = "historyLimit"
        static let csvSeparator = "csvSeparator"
        static let csvBOM = "csvBOM"
        static let openAtQuit = "openAtQuit"
        static let openAtQuitBookmarks = "openAtQuitBookmarks"
    }

    /// Barcode lookups (Open Library, MusicBrainz) and finding places on the map. Off, Golle sends
    /// nothing anywhere.
    static var onlineLookups: Bool { store.object(forKey: Key.onlineLookups) as? Bool ?? true }

    enum Launch: String, CaseIterable, Identifiable {
        case welcome, reopen, nothing
        var id: String { rawValue }
        var label: String {
            switch self {
            case .welcome: "Show the Welcome window"
            case .reopen: "Reopen the databases that were open"
            case .nothing: "Open nothing"
            }
        }
    }

    static var atLaunch: Launch { store.string(forKey: Key.atLaunch).flatMap(Launch.init) ?? .welcome }

    /// The currency new number fields start with: the one chosen, else the Mac's region's.
    static var currency: String {
        if let code = store.string(forKey: Key.currency), !code.isEmpty { return code }
        return regionCurrency
    }

    static var regionCurrency: String { Locale.current.currency?.identifier ?? "EUR" }

    /// How many changes each record's history keeps; 0 keeps none.
    static var historyLimit: Int { store.object(forKey: Key.historyLimit) as? Int ?? 100 }
    static let historyChoices = [0, 10, 25, 50, 100, 250, 500]

    enum Separator: String, CaseIterable, Identifiable {
        case comma, semicolon, tab
        var id: String { rawValue }
        var character: Character {
            switch self {
            case .comma: ","
            case .semicolon: ";"
            case .tab: "\t"
            }
        }
        var label: String {
            switch self {
            case .comma: "Comma (,)"
            case .semicolon: "Semicolon (;)"
            case .tab: "Tab"
            }
        }
    }

    static var csvSeparator: Separator { store.string(forKey: Key.csvSeparator).flatMap(Separator.init) ?? .comma }
    /// A byte-order mark at the start, which makes Excel read the file as UTF-8.
    static var csvBOM: Bool { store.object(forKey: Key.csvBOM) as? Bool ?? true }

    /// The databases open when Golle last quit, for "Reopen the databases that were open". Kept as
    /// bookmarks, so a database renamed or moved since is still found; one moved to the Bin is not.
    static var openAtQuit: [URL] {
        get {
            guard let bookmarks = store.array(forKey: Key.openAtQuitBookmarks) as? [Data] else {
                // Saved by an older Golle, as paths.
                return (store.stringArray(forKey: Key.openAtQuit) ?? []).map { URL(fileURLWithPath: $0) }
            }
            return bookmarks.compactMap { data -> URL? in
                var stale = false
                guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale),
                      !url.pathComponents.contains(".Trash") else { return nil }
                return url
            }
        }
        set {
            store.set(newValue.compactMap { try? $0.bookmarkData() }, forKey: Key.openAtQuitBookmarks)
            store.removeObject(forKey: Key.openAtQuit)
        }
    }
}
