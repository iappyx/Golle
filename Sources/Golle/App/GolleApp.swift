import SwiftUI

/// Started from main.swift, which first checks for `--test`.
struct GolleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // NSApp doesn't exist yet while the App is being created.
        DispatchQueue.main.async { AppSettings.apply(Preferences.store.string(forKey: Preferences.Key.appearance) ?? "system") }
        // Copies of attachments opened in other apps are temporary.
        try? FileManager.default.removeItem(at: GolleDocument.temporaryFolder)
    }

    var body: some Scene {
        DocumentGroup(newDocument: {
            // A template chosen in the welcome window, else a blank database.
            let database = WelcomeController.pendingDatabase ?? .blank()
            WelcomeController.pendingDatabase = nil
            return GolleDocument(database: database)
        }) { file in
            DocumentView(document: file.document)
                .frame(minWidth: 820, minHeight: 460)
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            DatabaseCommands()
        }

        Window("New from Template", id: "templates") {
            TemplatePicker()
        }
        .windowResizability(.contentSize)

        Window("About Golle", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .restorationBehavior(.disabled)

        Settings {
            AppSettings()
        }
    }
}

/// File, View and Database menu items. They act on the document in the frontmost window.
struct DatabaseCommands: Commands {
    @FocusedObject private var document: GolleDocument?
    @FocusedValue(\.documentActions) private var actions
    @Environment(\.openWindow) private var openWindow

    /// The table the commands act on: none while locked or while the dashboard is showing (its
    /// records aren't visible then).
    private var table: DataTable.ID? {
        guard let document, !document.isLocked, !document.showsDashboard else { return nil }
        return document.selectedTableID
    }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Golle") { openWindow(id: "about") }
        }

        CommandGroup(after: .newItem) {
            Button("New from Template…") { openWindow(id: "templates") }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Button("Welcome Window") { WelcomeController.show() }
                .keyboardShortcut("0", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .importExport) {
            Button("Import CSV or Excel…") {
                if let url = Exporting.chooseImportFile() { actions?.importFile(url) }
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(table == nil || actions?.sheetOpen == true)
            Menu("Export") {
                Button("CSV (Records in View)…") {
                    if let document, let actions { Exporting.exportCSV(document: document, records: actions.visibleRecords()) }
                }
                .disabled(table == nil)
                Button("Excel (Records in View)…") {
                    if let document, let actions { Exporting.exportExcel(document: document, records: actions.visibleRecords()) }
                }
                .disabled(table == nil)
                // The whole database doesn't depend on what the window shows, so the dashboard has it too.
                Button("JSON (Whole Database)…") {
                    if let document { Exporting.exportJSON(document: document) }
                }
                .disabled(document == nil || document?.isLocked == true)
                Button("PDF…") {
                    if let document, let actions { Exporting.exportPDF(document: document, records: actions.visibleRecords()) }
                }
                .disabled(table == nil)
            }
            .disabled(document == nil || document?.isLocked == true)
        }

        CommandGroup(replacing: .printItem) {
            Button("Print…") {
                if let document, let actions { Exporting.print(document: document, records: actions.visibleRecords()) }
            }
            .keyboardShortcut("p")
            .disabled(table == nil || actions?.sheetOpen == true)
            Button("Print Report…") { actions?.report() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(table == nil || actions?.sheetOpen == true)
            Button("Print Labels or Cards…") { actions?.labels() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(table == nil || actions?.sheetOpen == true)
        }

        CommandGroup(before: .sidebar) {
            ForEach(Array(ViewMode.allCases.enumerated()), id: \.element) { index, mode in
                Button("as \(mode.label)") { document?.updateCurrentView("Change View") { $0.mode = mode } }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .disabled(table == nil)
            }
            Divider()
            Button("Show Filter") { actions?.toggleFilter() }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(table == nil)
            Button("Show Inspector") { actions?.toggleInspector() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(table == nil)
            Divider()
        }

        CommandMenu("Database") {
            Button("New Record") {
                if let document, let table { document.addRecord(to: table) }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(table == nil)

            Button("Duplicate Record") {
                if let document, let table { document.duplicateRecords(document.selectedRecordIDs, in: table) }
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(table == nil || document?.selectedRecordIDs.isEmpty != false)

            // The column of the cell last clicked into, from the topmost selected record down.
            Button("Fill Down") { actions?.fillDown() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(table == nil || (document?.selectedRecordIDs.count ?? 0) < 2)

            // No ⌘⌫ shortcut: menu shortcuts win over text fields, where ⌘⌫ deletes to the start of
            // the line. The Delete key deletes records in the table and gallery.
            Button("Delete Record") {
                if let document, let table { document.deleteRecords(document.selectedRecordIDs, from: table) }
            }
            .disabled(table == nil || document?.selectedRecordIDs.isEmpty != false)

            Divider()

            Button("Scan Barcode…") { actions?.scanner() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(table == nil || actions?.sheetOpen == true)
            Button("Find Duplicates…") { actions?.duplicates() }
                .disabled(table == nil || actions?.sheetOpen == true)
            Button("Find and Replace…") { actions?.findReplace() }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(table == nil || actions?.sheetOpen == true)

            Divider()

            Button("New Table") { document?.addTable() }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(document == nil || document?.isLocked == true)
            Button("Edit Fields…") { actions?.editFields() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(table == nil || actions?.sheetOpen == true)
            // Not ⌃⌘S: that shows and hides the sidebar.
            Button("Save View…") { actions?.saveView() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(table == nil || actions?.sheetOpen == true)
            Button("Colour Rules…") { actions?.colorRules() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(table == nil || actions?.sheetOpen == true)
            Button("Duplicate Table") { if let document, let table { document.duplicateTable(table) } }
                .disabled(table == nil)

            Divider()

            Button("Appearance & Password…") { actions?.settings() }
                .disabled(document == nil || document?.isLocked == true || actions?.sheetOpen == true)
        }
    }
}
