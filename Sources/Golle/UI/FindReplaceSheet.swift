import SwiftUI

/// Find & Replace in one text field, or all of them, over the records in view (or the selected
/// ones). Shows what will change before anything does; Replace All is one undo step.
struct FindReplaceSheet: View {
    @ObservedObject var document: GolleDocument
    let tableID: DataTable.ID
    /// The records in view, in their order.
    let records: [Record]
    var initialFind = ""
    var initialReplacement = ""
    @Environment(\.dismiss) private var dismiss

    @State private var fieldID: Field.ID?
    @State private var find = ""
    @State private var replacement = ""
    @State private var options = FindReplace.Options()
    @State private var onlySelected = false
    @FocusState private var findFocused: Bool
    /// The preview: worked out a moment after typing stops, not on every keystroke.
    @State private var matches: [FindReplace.Match] = []
    @State private var searched: Search?

    /// What the preview depends on.
    private struct Search: Equatable {
        var find: String
        var replacement: String
        var options: FindReplace.Options
        var fieldID: Field.ID?
        var onlySelected: Bool
        var revision: Int
        var selection: Set<Record.ID>
    }

    private var search: Search {
        Search(find: find, replacement: replacement, options: options, fieldID: fieldID, onlySelected: onlySelected,
               revision: document.revision, selection: onlySelected ? document.selectedRecordIDs : [])
    }

    private func currentMatches() -> [FindReplace.Match] {
        FindReplace.matches(scope, fields: fields, find: find, with: replacement, options: options)
    }

    private var table: DataTable? { document.database.table(tableID) }
    private var textFields: [Field] { table?.fields.filter(FindReplace.canReplace) ?? [] }
    private var fields: [Field] { fieldID.map { id in textFields.filter { $0.id == id } } ?? textFields }

    /// The records searched, as they are stored now.
    private var scope: [Record] {
        guard let table else { return [] }
        let ids = onlySelected ? document.selectedRecordIDs : Set(records.map(\.id))
        let order = records.map(\.id)
        let current = Dictionary(uniqueKeysWithValues: table.records.map { ($0.id, $0) })
        return order.filter(ids.contains).compactMap { current[$0] }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("In", selection: $fieldID) {
                    Text("All text fields").tag(Field.ID?.none)
                    Divider()
                    ForEach(textFields) { Label($0.name, systemImage: $0.type.symbol).tag(Field.ID?.some($0.id)) }
                }
                TextField("Find", text: $find).focused($findFocused)
                TextField("Replace with", text: $replacement, prompt: Text("Nothing (removes the text)"))
                Toggle("Match case", isOn: $options.matchCase)
                Toggle("Whole cell only", isOn: $options.wholeCell)
                if document.selectedRecordIDs.count > 1 {
                    Picker("Records", selection: $onlySelected) {
                        Text("In view (\(records.count))").tag(false)
                        Text("Selected (\(document.selectedRecordIDs.count))").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
            }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)
            preview(matches)
            Divider()
            HStack {
                Text(summary(matches)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Replace All") {
                    // As things are now, even if the preview hasn't caught up with the last keystroke.
                    document.replaceText(currentMatches(), in: tableID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(find.isEmpty || matches.isEmpty && searched == search)
            }
            .padding(12)
        }
        .frame(width: 560, height: 560)
        // With one record selected or none, there is no choice to make.
        .onChange(of: document.selectedRecordIDs.count) { _, n in if n <= 1 { onlySelected = false } }
        .onAppear {
            if find.isEmpty { find = initialFind }
            if replacement.isEmpty { replacement = initialReplacement }
            findFocused = true
            matches = currentMatches()
            searched = search
        }
        .task(id: search) {
            guard searched != search else { return }
            // Short tables at once; long ones once typing pauses.
            if (table?.records.count ?? 0) > 2000 {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            matches = currentMatches()
            searched = search
        }
    }

    private func summary(_ matches: [FindReplace.Match]) -> String {
        if find.isEmpty { return textFields.isEmpty ? "This table has no text fields." : "Type the text to find." }
        if matches.isEmpty { return "Not found in \(onlySelected ? "the selected records" : "the records in view")." }
        let records = Set(matches.map(\.record.id)).count
        return "\(matches.count) cell\(matches.count == 1 ? "" : "s") in \(records) record\(records == 1 ? "" : "s") will change."
    }

    @ViewBuilder
    private func preview(_ matches: [FindReplace.Match]) -> some View {
        if matches.isEmpty {
            ContentUnavailableView(find.isEmpty ? "Find Text" : "No Matches", systemImage: "text.magnifyingglass",
                                   description: Text("Only the records in view are searched: the filter and the search apply."))
                .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach(matches.prefix(200)) { match in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(table?.title(of: match.record) ?? "") · \(match.field.name)").font(.caption).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(Self.snippet(match.old)).strikethrough().foregroundStyle(.secondary)
                            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                            Text(match.new.isEmpty ? "(empty)" : Self.snippet(match.new))
                        }
                        .lineLimit(1)
                    }
                }
                if matches.count > 200 { Text("and \(matches.count - 200) more").foregroundStyle(.secondary) }
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// One line of a long text.
    private static func snippet(_ text: String) -> String {
        let line = text.replacingOccurrences(of: "\n", with: " ")
        return line.count > 120 ? String(line.prefix(120)) + "…" : line
    }
}
