import SwiftUI
import UniformTypeIdentifiers

/// A document window: tables and saved views in the sidebar, the records in the middle (as a table,
/// gallery or form), filters above, totals below, and the selected record in the inspector.
struct DocumentView: View {
    @ObservedObject var document: GolleDocument
    @Environment(\.undoManager) private var undoManager

    @State private var search = ""
    @State private var showInspector = true
    @State private var showFilter = false
    @State private var sheet: Sheet?
    @State private var prompt: NamePrompt?
    @State private var promptText = ""
    @State private var windowSize = CGSize(width: 1240, height: 780)

    enum Sheet: Identifiable {
        case fields, importFile(URL), settings, layoutEditor(FormLayout.ID), colorRules, duplicates, scanner, labels, findReplace, report
        var id: String {
            switch self {
            case .fields: "fields"
            case .importFile(let url): "import-\(url.path)"
            case .settings: "settings"
            case .layoutEditor(let id): "layout-\(id)"
            case .colorRules: "colors"
            case .duplicates: "duplicates"
            case .scanner: "scanner"
            case .labels: "labels"
            case .findReplace: "find-replace"
            case .report: "report"
            }
        }
    }

    struct NamePrompt: Identifiable {
        enum Kind { case renameTable(DataTable.ID), renameView(DataTable.ID, SavedView.ID), saveView }
        let id = UUID()
        let kind: Kind
        let title: String
        let action: String
    }

    var body: some View {
        Group {
            if document.isLocked {
                UnlockView(document: document)
            } else {
                NavigationSplitView {
                    Sidebar(document: document, rename: { kind, title, name in
                        promptText = name
                        prompt = NamePrompt(kind: kind, title: title, action: "Rename")
                    })
                    .navigationSplitViewColumnWidth(min: 170, ideal: 210)
                } detail: {
                    detail
                }
            }
        }
        .tint(document.database.settings.accent.color)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { windowSize = $0 }
        .focusedSceneObject(document)
        .focusedSceneValue(\.documentActions, actions)
        .onAppear {
            document.undoManager = undoManager
            // A document opened: the welcome window has done its job.
            WelcomeController.close()
        }
        .onChange(of: undoManager) { _, manager in document.undoManager = manager }
        .onChange(of: document.selectedTableID) { _, _ in search = ""; showFilter = false }
        .onChange(of: document.selectedViewID) { _, _ in showFilter = false }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .fields:
                if let table = document.selectedTableID { FieldEditor(document: document, tableID: table) }
            case .importFile(let url):
                ImportSheet(document: document, url: url)
            case .colorRules:
                if let table = document.selectedTableID { ColorRulesSheet(document: document, tableID: table) }
            case .duplicates:
                if let table = document.selectedTableID { DuplicatesSheet(document: document, tableID: table) }
            case .scanner:
                if let table = document.selectedTableID { ScannerSheet(document: document, tableID: table) }
            case .labels:
                LabelsSheet(document: document, records: labelRecords())
            case .findReplace:
                if let table = document.currentTable {
                    FindReplaceSheet(document: document, tableID: table.id, records: visibleRows(document.resolver(for: table), view: document.currentView))
                }
            case .report:
                if let table = document.currentTable {
                    ReportSheet(document: document, records: visibleRows(document.resolver(for: table), view: document.currentView))
                }
            case .settings:
                DatabaseSettingsSheet(document: document)
            case .layoutEditor(let id):
                if let table = document.selectedTableID {
                    // A sheet can't be larger than its window, so the editor takes what fits.
                    LayoutEditor(document: document, tableID: table, layoutID: id,
                                 size: CGSize(width: max(700, min(1700, windowSize.width - 40)), height: max(440, min(1100, windowSize.height - 40))))
                }
            }
        }
        .alert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }), presenting: prompt) { prompt in
            TextField("Name", text: $promptText)
            Button(prompt.action) { finish(prompt) }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Detail

    /// Labels for the selected records, or else every record in view.
    private func labelRecords() -> [Record] {
        guard let table = document.currentTable else { return [] }
        let rows = visibleRows(document.resolver(for: table), view: document.currentView)
        let selected = rows.filter { document.selectedRecordIDs.contains($0.id) }
        return selected.count > 1 ? selected : rows
    }

    @ViewBuilder
    private var detail: some View {
        if document.showsDashboard {
            DashboardView(document: document)
        } else if let table = document.currentTable {
            let view = document.currentView
            let resolver = document.resolver(for: table)
            let rows = visibleRows(resolver, view: view)
            VStack(spacing: 0) {
                if showFilter || !view.filter.isEmpty {
                    FilterBar(table: table, view: view, isSaved: document.isSavedView,
                              update: { document.updateCurrentView("Change Filter", $0) },
                              saveAs: { askToSaveView() },
                              close: {
                                  document.updateCurrentView("Clear Filter") { $0.filter = Filter() }
                                  showFilter = false
                              })
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    Divider()
                }
                content(table: table, view: view, rows: rows, resolver: resolver)
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                SummaryBar(document: document, table: table, rows: rows, resolver: resolver)
            }
            // Nothing in the detail column may insist on a width: when the window is narrow, a minimum
            // wider than the split view can give makes AppKit re-layout until it throws.
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .navigationTitle(document.isSavedView ? view.name : table.name)
            .navigationSubtitle(subtitle(table: table, shown: rows.count))
            .searchable(text: $search, placement: .toolbar, prompt: "Search \(table.name)")
            .toolbar { toolbar(table: table, view: view) }
            .inspector(isPresented: $showInspector) {
                inspector(table: table, resolver: resolver)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .clipped()
                    .inspectorColumnWidth(min: 260, ideal: 340, max: 560)
            }
        } else {
            ContentUnavailableView {
                Label("No Tables", systemImage: "tablecells")
            } actions: {
                Button("New Table") { document.addTable() }
            }
        }
    }

    @ViewBuilder
    private func content(table: DataTable, view: SavedView, rows: [Record], resolver: Resolver) -> some View {
        if table.fields.isEmpty {
            ContentUnavailableView {
                Label("No Fields", systemImage: "slider.horizontal.3")
            } description: {
                Text("A table needs fields before it can hold records.")
            } actions: {
                Button("Edit Fields…") { sheet = .fields }
            }
        } else {
            switch view.mode {
            case .table:
                RecordTable(document: document, table: table, rows: rows, resolver: resolver,
                            groupFields: view.groupBy.compactMap(table.field),
                            fields: view.visibleFields(table),
                            sort: Binding(get: { view.sort }, set: { keys in document.updateCurrentView("Sort") { $0.sort = keys } }),
                            columns: Binding(
                                get: { view.columnData.flatMap { try? JSONDecoder().decode(TableColumnCustomization<RecordTable.Row>.self, from: $0) } ?? TableColumnCustomization() },
                                set: { columns in
                                    let data = try? JSONEncoder().encode(columns)
                                    if data != view.columnData { document.updateCurrentView("Arrange Columns") { $0.columnData = data } }
                                }))
                    .overlay { emptyOverlay(table: table, rows: rows) }
            case .gallery:
                GalleryView(document: document, table: table, rows: rows, resolver: resolver, groupFields: view.groupBy.compactMap(table.field),
                            visible: view.visibleFields(table))
                    .overlay { emptyOverlay(table: table, rows: rows) }
            case .board:
                BoardView(document: document, table: table, view: view, rows: rows, resolver: resolver, editFields: { sheet = .fields })
            case .calendar:
                CalendarView(document: document, table: table, view: view, rows: rows, resolver: resolver, editFields: { sheet = .fields })
            case .map:
                MapRecordsView(document: document, table: table, view: view, rows: rows, resolver: resolver, editFields: { sheet = .fields })
            case .timeline:
                TimelineView(document: document, table: table, view: view, rows: rows, resolver: resolver, editFields: { sheet = .fields })
                    .id(view.id)
            case .chart:
                ChartModeView(document: document, table: table, view: view, rows: rows, resolver: resolver)
            case .layout:
                LayoutBrowser(document: document, table: table, view: view, rows: rows, resolver: resolver,
                              editLayout: { sheet = .layoutEditor($0) })
            }
        }
    }

    @ViewBuilder
    private func emptyOverlay(table: DataTable, rows: [Record]) -> some View {
        if table.records.isEmpty {
            ContentUnavailableView {
                Label("No Records", systemImage: "tray")
            } actions: {
                Button("New Record") { document.addRecord(to: table.id) }
            }
        } else if rows.isEmpty {
            if search.isEmpty {
                ContentUnavailableView("No Matching Records", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("No records match this view's filter."))
            } else {
                ContentUnavailableView.search(text: search)
            }
        }
    }

    /// Computed once per change of the database (or of the view, search or pinned records), not on
    /// every redraw: with thousands of records, filtering and sorting add up.
    private func visibleRows(_ resolver: Resolver, view: SavedView) -> [Record] {
        let key = "rows-\(resolver.table.id)-\(view.filter.hashValue)-\(view.sort.hashValue)-\(search)-\(document.pinnedRecordIDs.hashValue)"
        return document.memo(key) {
            // The search index only matters while searching; building it costs time on big tables.
            var rows = Query.visible(resolver, view: view, search: search, haystack: search.isEmpty ? nil : document.haystack(resolver))
            // New records stay in view until the user moves on, even when the filter hides them.
            if !document.pinnedRecordIDs.isEmpty {
                let shown = Set(rows.map(\.id))
                rows += resolver.table.records.filter { document.pinnedRecordIDs.contains($0.id) && !shown.contains($0.id) }
            }
            return rows
        }
    }

    @ToolbarContentBuilder
    private func toolbar(table: DataTable, view: SavedView) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("View", selection: Binding(get: { view.mode }, set: { mode in document.updateCurrentView("Change View") { $0.mode = mode } })) {
                ForEach(ViewMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Show records as a table, a gallery or a form")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { document.addRecord(to: table.id) } label: { Label("New Record", systemImage: "plus") }
                .help("New Record (⇧⌘N)")
            fieldsMenu(table: table, view: view)
            groupMenu(table: table, view: view)
            Button {
                if view.filter.isEmpty { showFilter.toggle() } else { showFilter = true }
            } label: {
                Label("Filter", systemImage: view.filter.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .help("Filter records (⌥⌘L)")
            Button { sheet = .fields } label: { Label("Fields", systemImage: "slider.horizontal.3") }
                .help("Edit Fields (⇧⌘E)")
            Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                .help("Show or hide the record form (⌥⌘I)")
        }
    }

    /// Which fields this view shows: table columns and the lines on cards.
    private func fieldsMenu(table: DataTable, view: SavedView) -> some View {
        Menu {
            ForEach(table.fields) { field in
                Toggle(isOn: Binding(
                    get: { !view.hiddenFieldIDs.contains(field.id) },
                    set: { on in
                        document.updateCurrentView("Show Fields") { v in
                            if on { v.hiddenFieldIDs.removeAll { $0 == field.id } } else if !v.hiddenFieldIDs.contains(field.id) { v.hiddenFieldIDs.append(field.id) }
                        }
                    }
                )) { Label(field.name, systemImage: field.type.symbol) }
            }
            if !view.hiddenFieldIDs.isEmpty {
                Divider()
                Button("Show All") { document.updateCurrentView("Show Fields") { $0.hiddenFieldIDs = [] } }
            }
        } label: {
            Label("Show Fields", systemImage: view.hiddenFieldIDs.isEmpty ? "eye" : "eye.slash")
        }
        .help(view.hiddenFieldIDs.isEmpty ? "Choose which fields this view shows" : "\(view.hiddenFieldIDs.count) hidden in this view")
    }

    /// Group by up to two fields. Shown for the table, gallery and timeline.
    private func groupMenu(table: DataTable, view: SavedView) -> some View {
        let groupable = table.fields.filter { $0.type != .longText && !$0.type.isAttachment && $0.type != .autoNumber }
        return Menu {
            Section("Group by") {
                groupPicker(level: 0, view: view, fields: groupable)
            }
            if !view.groupBy.isEmpty {
                Section("Then by") {
                    groupPicker(level: 1, view: view, fields: groupable.filter { $0.id != view.groupBy.first })
                }
                Divider()
                Button("Don't Group") { document.updateCurrentView("Group") { $0.groupBy = [] } }
            }
        } label: {
            Label("Group", systemImage: view.groupBy.isEmpty ? "list.bullet.indent" : "list.bullet.indent")
                .symbolVariant(view.groupBy.isEmpty ? .none : .circle)
        }
        .help(view.groupBy.isEmpty ? "Group records by a field" : "Grouped by " + view.groupBy.compactMap { table.field($0)?.name }.joined(separator: ", then "))
        .disabled(view.mode != .table && view.mode != .gallery && view.mode != .timeline)
    }

    @ViewBuilder
    private func groupPicker(level: Int, view: SavedView, fields: [Field]) -> some View {
        Picker("Field", selection: Binding<Field.ID?>(
            get: { view.groupBy.count > level ? view.groupBy[level] : nil },
            set: { id in
                document.updateCurrentView("Group") { v in
                    var groups = Array(v.groupBy.prefix(level))
                    if let id { groups.append(id) }
                    // Keep the second level when changing the first, unless it is now the same field.
                    if level == 0, let second = v.groupBy.dropFirst().first, second != id { groups.append(second) }
                    v.groupBy = groups
                }
            }
        )) {
            Text("None").tag(Field.ID?.none)
            ForEach(fields) { Label($0.name, systemImage: $0.type.symbol).tag(Field.ID?.some($0.id)) }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }

    @ViewBuilder
    private func inspector(table: DataTable, resolver: Resolver) -> some View {
        if document.selectedRecordIDs.count == 1, let id = document.selectedRecordIDs.first,
           let record = table.records.first(where: { $0.id == id }) {
            RecordForm(document: document, table: table, record: record, resolver: resolver)
        } else if document.selectedRecordIDs.count > 1 {
            BatchForm(document: document, table: table, ids: document.selectedRecordIDs, resolver: resolver)
                // Fresh editors for each selection, so text typed for one set of records never
                // shows for (or gets written to) another.
                .id(document.selectedRecordIDs)
        } else {
            ContentUnavailableView("No Record Selected", systemImage: "doc.text")
        }
    }

    private func subtitle(table: DataTable, shown: Int) -> String {
        let total = table.records.count
        let records = "\(total) record\(total == 1 ? "" : "s")"
        return shown == total ? records : "\(shown) of \(records)"
    }

    // MARK: Actions

    private var actions: DocumentActions {
        DocumentActions(
            editFields: { sheet = .fields },
            toggleFilter: { showFilter.toggle() },
            toggleInspector: { showInspector.toggle() },
            saveView: { askToSaveView() },
            importFile: { url in sheet = .importFile(url) },
            settings: { sheet = .settings },
            colorRules: { sheet = .colorRules },
            duplicates: { sheet = .duplicates },
            scanner: { sheet = .scanner },
            labels: { sheet = .labels },
            findReplace: { sheet = .findReplace },
            report: { sheet = .report },
            visibleRecords: {
                guard let table = document.currentTable else { return [] }
                return visibleRows(document.resolver(for: table), view: document.currentView)
            }
        )
    }

    private func askToSaveView() {
        promptText = document.isSavedView ? "\(document.currentView.name) copy" : "New View"
        prompt = NamePrompt(kind: .saveView, title: "Save View", action: "Save")
    }

    private func finish(_ prompt: NamePrompt) {
        switch prompt.kind {
        case .renameTable(let id): document.renameTable(id, to: promptText)
        case .renameView(let table, let view): document.renameView(view, in: table, to: promptText)
        case .saveView:
            document.saveCurrentView(named: promptText)
            showFilter = false
        }
    }
}

/// What the menus can ask of the frontmost document window.
struct DocumentActions {
    var editFields: () -> Void
    var toggleFilter: () -> Void
    var toggleInspector: () -> Void
    var saveView: () -> Void
    var importFile: (URL) -> Void
    var settings: () -> Void
    var colorRules: () -> Void
    var duplicates: () -> Void
    var scanner: () -> Void
    var labels: () -> Void
    var findReplace: () -> Void
    var report: () -> Void
    var visibleRecords: () -> [Record]
}

struct DocumentActionsKey: FocusedValueKey { typealias Value = DocumentActions }

extension FocusedValues {
    var documentActions: DocumentActions? {
        get { self[DocumentActionsKey.self] }
        set { self[DocumentActionsKey.self] = newValue }
    }
}

extension AccentChoice {
    var color: Color {
        switch self {
        case .orange: .orange
        case .red: .red
        case .pink: .pink
        case .purple: .purple
        case .blue: .blue
        case .teal: .teal
        case .green: .green
        case .graphite: .gray
        case .yellow: .yellow
        case .brown: .brown
        }
    }

    var label: String { rawValue.capitalized }
}

// MARK: Sidebar

private enum SidebarItem: Hashable {
    case dashboard
    case table(DataTable.ID)
    case view(DataTable.ID, SavedView.ID)
}

private struct Sidebar: View {
    @ObservedObject var document: GolleDocument
    let rename: (DocumentView.NamePrompt.Kind, String, String) -> Void

    private var selection: Binding<SidebarItem?> {
        Binding(
            get: {
                if document.showsDashboard { return .dashboard }
                guard let table = document.selectedTableID else { return nil }
                return document.selectedViewID.map { .view(table, $0) } ?? .table(table)
            },
            set: { item in
                document.showsDashboard = item == .dashboard
                switch item {
                case .dashboard: break
                case .table(let table):
                    document.selectedTableID = table
                    document.selectedViewID = nil
                case .view(let table, let view):
                    document.selectedTableID = table
                    document.selectedViewID = view
                case nil: break
                }
            }
        )
    }

    var body: some View {
        List(selection: selection) {
            Label("Dashboard", systemImage: "square.grid.2x2")
                .tag(SidebarItem.dashboard)
            Section {
                ForEach(document.database.tables) { table in
                    Label(table.name, systemImage: document.database.settings.symbol)
                        .badge(table.records.count)
                        .tag(SidebarItem.table(table.id))
                        .draggable(TableDrag(id: table.id))
                        .dropDestination(for: TableDrag.self) { items, _ in
                            guard let dragged = items.first?.id else { return false }
                            document.moveTable(dragged, before: table.id)
                            return true
                        }
                        .contextMenu {
                            Button("New Record") { document.addRecord(to: table.id) }
                            Divider()
                            Button("Rename…") { rename(.renameTable(table.id), "Rename Table", table.name) }
                            Button("Duplicate Table") { document.duplicateTable(table.id) }
                            Button("Move to End") {
                                if let from = document.database.tableIndex(table.id) {
                                    document.moveTables(from: [from], to: document.database.tables.count)
                                }
                            }
                            Button("Delete Table", role: .destructive) { document.deleteTable(table.id) }
                                .disabled(document.database.tables.count == 1)
                        }
                    ForEach(table.views) { view in
                        Label(view.name, systemImage: view.filter.isEmpty ? view.mode.symbol : "line.3.horizontal.decrease.circle")
                            .badge(count(view, in: table))
                            .padding(.leading, 16)
                            .tag(SidebarItem.view(table.id, view.id))
                            .contextMenu {
                                Button("Rename…") { rename(.renameView(table.id, view.id), "Rename View", view.name) }
                                Button("Delete View", role: .destructive) { document.deleteView(view.id, in: table.id) }
                            }
                    }
                }
            } header: {
                Text("Tables")
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { document.addTable() } label: { Label("New Table", systemImage: "plus") }
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
    }

    private func count(_ view: SavedView, in table: DataTable) -> Int {
        guard !view.filter.isEmpty else { return table.records.count }
        return document.memo("count-\(view.id)-\(view.filter.hashValue)") {
            let resolver = document.resolver(for: table)
            return table.records.filter { view.filter.matches($0, resolver) }.count
        }
    }
}


/// A table being dragged in the sidebar, to reorder tables.
struct TableDrag: Codable, Transferable {
    let id: UUID
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .golleTable)
    }
}

extension UTType {
    static let golleTable = UTType(exportedAs: "com.iappyx.golle.table-reference")
}
