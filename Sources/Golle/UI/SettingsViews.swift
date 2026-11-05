import SwiftUI

/// Colour, icon and password of one database.
struct DatabaseSettingsSheet: View {
    @ObservedObject var document: GolleDocument
    @Environment(\.dismiss) private var dismiss

    @State private var settingPassword = false
    @State private var password = ""
    @State private var confirm = ""
    @State private var hint = ""
    @State private var touchID = KeyStore.biometricsAvailable
    @State private var error: String?

    static let symbols = [
        "tablecells", "opticaldisc", "books.vertical", "film", "shippingbox", "person.2", "fork.knife",
        "square.stack.3d.up", "music.note", "gamecontroller", "camera", "leaf", "pawprint", "car",
        "wineglass", "tshirt", "paintpalette", "hammer", "heart", "star", "graduationcap", "briefcase",
        "house", "airplane",
    ]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Appearance") {
                    LabeledContent("Colour") {
                        HStack(spacing: 8) {
                            ForEach(AccentChoice.allCases) { accent in
                                Circle()
                                    .fill(accent.color)
                                    .frame(width: 20, height: 20)
                                    .overlay { if document.database.settings.accent == accent { Circle().strokeBorder(.white, lineWidth: 2).padding(3) } }
                                    .onTapGesture { document.setAccent(accent) }
                                    .help(accent.label)
                            }
                        }
                    }
                    LabeledContent("Icon") {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 4), count: 8), spacing: 4) {
                            ForEach(Self.symbols, id: \.self) { symbol in
                                Image(systemName: symbol)
                                    .frame(width: 28, height: 28)
                                    .background(document.database.settings.symbol == symbol ? Color.accentColor.opacity(0.25) : .clear, in: .rect(cornerRadius: 6))
                                    .contentShape(.rect)
                                    .onTapGesture { document.setSymbol(symbol) }
                            }
                        }
                    }
                }
                Section {
                    if settingPassword {
                        // Return sets the password (it mustn't close the sheet with nothing set).
                        SecureField("Password", text: $password).onSubmit(apply)
                        SecureField("Confirm", text: $confirm).onSubmit(apply)
                        TextField("Hint (optional)", text: $hint).onSubmit(apply)
                        if KeyStore.biometricsAvailable {
                            Toggle("Unlock with Touch ID on this Mac", isOn: $touchID)
                        }
                        if let error { Text(error).foregroundStyle(.red) }
                        HStack {
                            Spacer()
                            Button("Cancel") { reset() }
                            Button(document.isEncrypted ? "Change Password" : "Set Password") { apply() }
                                .disabled(password.isEmpty)
                                .keyboardShortcut(.defaultAction)
                        }
                    } else if document.isEncrypted {
                        LabeledContent("Status") { Label("Locked with a password", systemImage: "lock.fill") }
                        if document.rememberedForTouchID { Text("Touch ID can unlock it on this Mac.").foregroundStyle(.secondary) }
                        HStack {
                            Button("Change Password…") { settingPassword = true }
                            Button("Remove Password") { document.removePassword() }
                        }
                    } else {
                        LabeledContent("Status") { Label("Not locked", systemImage: "lock.open") }
                        Button("Set Password…") { settingPassword = true }
                    }
                } header: {
                    Text("Password")
                } footer: {
                    Text("A locked database is encrypted on disk (AES-256), including its images and files. If you forget the password, the data cannot be recovered.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(settingPassword ? nil : .defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 560)
    }

    private func apply() {
        guard !password.isEmpty else { return }
        guard password == confirm else { error = "The passwords don't match."; return }
        guard password.count >= 4 else { error = "Use at least 4 characters."; return }
        do {
            try document.setPassword(password, hint: hint, rememberWithTouchID: touchID && KeyStore.biometricsAvailable)
            reset()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reset() {
        settingPassword = false
        password = ""
        confirm = ""
        hint = ""
        error = nil
    }
}

/// Shown instead of the records while a locked database hasn't been unlocked.
struct UnlockView: View {
    @ObservedObject var document: GolleDocument
    @State private var password = ""
    @State private var error: String?
    @State private var attempts = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("This database is locked").font(.title2.bold())
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .focused($focused)
                .onSubmit(unlock)
            if let error {
                Text(error).foregroundStyle(.red)
            }
            if attempts > 0, let hint = document.lockInfo?.hint {
                Text("Hint: \(hint)").foregroundStyle(.secondary)
            }
            HStack {
                if document.rememberedForTouchID {
                    Button { touchID() } label: { Label("Use Touch ID", systemImage: "touchid") }
                }
                Button("Unlock", action: unlock).keyboardShortcut(.defaultAction)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            focused = true
            if document.rememberedForTouchID { touchID() }
        }
    }

    private func unlock() {
        do {
            try document.unlock(password: password)
        } catch {
            attempts += 1
            self.error = error.localizedDescription
            password = ""
        }
    }

    private func touchID() {
        Task {
            if await !document.unlockWithTouchID() { focused = true }
        }
    }
}

/// The app's Settings window: what belongs to the user and this Mac. Everything about one database
/// is in Database ▸ Appearance & Password, Edit Fields and the views, and travels with its file.
struct AppSettings: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Privacy", systemImage: "hand.raised") { PrivacySettings() }
            Tab("Import & Export", systemImage: "square.and.arrow.up.on.square") { ExchangeSettings() }
        }
        .frame(width: 520)
        .scenePadding(.minimum, edges: .bottom)
    }

    static func apply(_ value: String) {
        NSApp.appearance = switch value {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
    }
}

struct GeneralSettings: View {
    @AppStorage(Preferences.Key.appearance, store: Preferences.store) private var appearance = "system"
    @AppStorage(Preferences.Key.atLaunch, store: Preferences.store) private var atLaunch = Preferences.Launch.welcome.rawValue
    @AppStorage(Preferences.Key.currency, store: Preferences.store) private var currency = ""
    @AppStorage(Preferences.Key.historyLimit, store: Preferences.store) private var historyLimit = 100

    /// Every currency macOS knows, by name.
    private static let currencies: [(code: String, name: String)] = Locale.commonISOCurrencyCodes
        .map { ($0, Locale.current.localizedString(forCurrencyCode: $0) ?? $0) }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    Text("Match System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                Picker("When Golle opens", selection: $atLaunch) {
                    ForEach(Preferences.Launch.allCases) { Text($0.label).tag($0.rawValue) }
                }
            } footer: {
                Text("Each database has its own colour and icon: Database ▸ Appearance & Password.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Currency for new fields", selection: $currency) {
                    Text("From the region (\(Preferences.regionCurrency))").tag("")
                    Divider()
                    ForEach(Self.currencies, id: \.code) { Text("\($0.name) (\($0.code))").tag($0.code) }
                }
            } footer: {
                Text("Fields you already have keep their currency; change it in Edit Fields.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Record history", selection: $historyLimit) {
                    ForEach(Preferences.historyChoices, id: \.self) { n in
                        Text(n == 0 ? "Off" : "Last \(n) changes").tag(n)
                    }
                }
            } footer: {
                Text("Kept per record, in the database, with a button to restore an old value. A smaller number trims a record's history at its next change; Off keeps what is there but adds nothing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: appearance, initial: true) { _, value in AppSettings.apply(value) }
    }
}

struct PrivacySettings: View {
    @AppStorage(Preferences.Key.onlineLookups, store: Preferences.store) private var onlineLookups = true

    var body: some View {
        Form {
            Section {
                Toggle("Online lookups", isOn: $onlineLookups)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Scanning a barcode sends only the code to Open Library (books) or MusicBrainz (albums) and downloads the cover. Finding a place sends the address to Apple's map search.")
                    Text(onlineLookups
                         ? "Everything else stays on your Mac: no accounts, no sync, no telemetry."
                         : "Off, Golle sends nothing anywhere. Maps still show Apple's map tiles when you open a map, and the camera still reads barcodes into barcode fields.")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct ExchangeSettings: View {
    @AppStorage(Preferences.Key.csvSeparator, store: Preferences.store) private var separator = Preferences.Separator.comma.rawValue
    @AppStorage(Preferences.Key.csvBOM, store: Preferences.store) private var bom = true

    var body: some View {
        Form {
            Section {
                Picker("Separator", selection: $separator) {
                    ForEach(Preferences.Separator.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Toggle("Mark the file as UTF-8 for Excel", isOn: $bom)
            } header: {
                Text("CSV Export")
            } footer: {
                Text("Excel in countries that write decimals with a comma expects a semicolon; numbers are then written with a decimal comma too (12,99). Tab writes a .tsv file. The mark (a byte-order mark) makes Excel show accents and other characters correctly; some other tools prefer the file without it. Import guesses the separator by itself.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The "New from Template" window.
struct TemplatePicker: View {
    @Environment(\.newDocument) private var newDocument
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a Template").font(.title2.bold())
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                    ForEach(Template.all) { template in
                        Button {
                            newDocument { GolleDocument(database: template.make()) }
                            dismissWindow(id: "templates")
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Image(systemName: template.symbol)
                                    .font(.system(size: 26))
                                    .foregroundStyle(.white)
                                    .frame(width: 48, height: 48)
                                    .background(template.accent.color.gradient, in: .rect(cornerRadius: 10))
                                Text(template.name).font(.headline)
                                Text(template.summary).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                            .padding(12)
                            .background(.background.secondary, in: .rect(cornerRadius: 10))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 460)
    }
}
