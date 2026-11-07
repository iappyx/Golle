import AppKit
import SwiftUI

/// The records as cards: the first image as a cover, the title, and the next few fields.
struct GalleryView: View {
    @ObservedObject var document: GolleDocument
    let table: DataTable
    let rows: [Record]
    let resolver: Resolver
    var groupFields: [Field] = []
    /// The view's visible fields; cards show the first few.
    var visible: [Field] = []
    /// Shows a record (double-click): in the inspector, without changing the view.
    var open: (Record.ID) -> Void = { _ in }
    @State private var anchor: Record.ID?
    @State private var collapsed = Set<String>()

    /// Groups as flat sections; with two levels a section is "Group › Subgroup".
    private var sections: [(id: String, title: String, records: [Record])] {
        Grouping.groups(rows, by: groupFields, resolver).flatMap { group in
            group.subgroups.isEmpty
                ? [(group.id, group.title, group.records)]
                : group.subgroups.map { ($0.id, "\(group.title) › \($0.title)", $0.records) }
        }
    }

    private var imageField: Field? { table.fields.first { $0.type == .image } }
    private var detailFields: [Field] {
        Array((visible.isEmpty ? table.fields : visible).filter { $0.id != table.titleField?.id && $0.type != .image && $0.type != .longText && !$0.type.isComputed && $0.type != .autoNumber }.prefix(4))
    }

    var body: some View {
        ScrollView {
            if groupFields.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                    ForEach(rows) { record in
                        card(record)
                    }
                }
                .padding(14)
                .background(clearsSelection)
            } else {
                LazyVStack(alignment: .leading, spacing: 10, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections, id: \.id) { section in
                        Section {
                            if !collapsed.contains(section.id) {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
                                    ForEach(section.records) { record in card(record) }
                                }
                            }
                        } header: {
                            Button {
                                if collapsed.contains(section.id) { collapsed.remove(section.id) } else { collapsed.insert(section.id) }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: collapsed.contains(section.id) ? "chevron.right" : "chevron.down")
                                        .font(.caption.weight(.bold)).frame(width: 12)
                                    Text(section.title).font(.headline).lineLimit(1)
                                    Text("\(section.records.count)").foregroundStyle(.secondary).monospacedDigit()
                                    Spacer()
                                }
                                .padding(.vertical, 6)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .background(.background)
                        }
                    }
                }
                .padding(14)
                .background(clearsSelection)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        // Below the cards too: the empty rest of the window.
        .background(clearsSelection)
        .background(.background)
        .onDeleteCommand { document.deleteRecords(document.selectedRecordIDs, from: table.id) }
    }

    /// A click on the space between and around the cards clears the selection. It sits behind
    /// the cards rather than around them: a tap handler around them would answer a click on a card
    /// first (the card's own waits to see whether it is a double-click) and clear what the card selects.
    private var clearsSelection: some View {
        Color.clear
            .contentShape(.rect)
            .onTapGesture { document.selectedRecordIDs = [] }
    }

    private func card(_ record: Record) -> some View {
        let selected = document.selectedRecordIDs.contains(record.id)
        return VStack(alignment: .leading, spacing: 0) {
            if let field = imageField {
                // The cover sits in an overlay so its size never feeds back into the card's layout.
                Rectangle().fill(.quaternary)
                    .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 150)
                    .overlay {
                        if let attachment = record[field.id]?.attachments.first, let image = document.thumbnail(attachment) {
                            Image(nsImage: image).resizable().scaledToFill()
                        } else {
                            Image(systemName: "photo").font(.largeTitle).foregroundStyle(.tertiary)
                        }
                    }
                    .clipped()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(table.title(of: record)).font(.headline).lineLimit(2)
                ForEach(detailFields) { field in
                    let text = resolver.text(record, field)
                    if field.type == .rating, let rating = record[field.id]?.rating {
                        RatingView(rating: rating).font(.caption)
                    } else if field.type.usesChoices, let choices = record[field.id]?.choices, !choices.isEmpty {
                        ChipsView(field: field, choices: Array(choices.prefix(3)))
                    } else if field.type == .checklist, let items = record[field.id]?.checkItems, !items.isEmpty {
                        ChecklistSummary(items: items).font(.caption)
                    } else if field.type == .checkbox {
                        if record[field.id]?.bool == true { Label(field.name, systemImage: "checkmark").font(.caption).foregroundStyle(.secondary) }
                    } else if !text.isEmpty {
                        Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background.secondary)
        .overlay(alignment: .top) {
            if let color = table.color(of: record, resolver) { Rectangle().fill(color.color).frame(height: 5) }
        }
        .clipShape(.rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: selected ? 3 : 1)
        }
        .contentShape(.rect)
        // One gesture, tried in order: a double-click opens the record; otherwise a click with ⌘
        // adds or removes the card, with ⇧ selects up to it, and a plain click selects it. The keys
        // are checked by the gesture itself, when the card is clicked. (A drag that noted the keys
        // on mouse-down took the click away from the tap, so cards couldn't be selected.)
        .gesture(
            TapGesture(count: 2).onEnded { open(record.id) }
            .exclusively(before: TapGesture().modifiers(.command).onEnded { toggle(record.id) })
            .exclusively(before: TapGesture().modifiers(.shift).onEnded { extend(to: record.id) })
            .exclusively(before: TapGesture().onEnded { document.selectedRecordIDs = [record.id]; anchor = record.id })
        )
        .contextMenu {
            Button("Duplicate") { document.duplicateRecords(selection(including: record.id), in: table.id) }
            Button("Delete", role: .destructive) { document.deleteRecords(selection(including: record.id), from: table.id) }
        }
    }

    private func toggle(_ id: Record.ID) {
        if document.selectedRecordIDs.contains(id) { document.selectedRecordIDs.remove(id) } else { document.selectedRecordIDs.insert(id) }
        anchor = id
    }

    /// The cards in the order they are on screen (grouping reorders them).
    private var shown: [Record] { groupFields.isEmpty ? rows : sections.flatMap(\.records) }

    private func extend(to id: Record.ID) {
        let order = shown
        guard let anchor, let a = order.firstIndex(where: { $0.id == anchor }), let b = order.firstIndex(where: { $0.id == id }) else {
            document.selectedRecordIDs = [id]
            self.anchor = id
            return
        }
        document.selectedRecordIDs = Set(order[min(a, b)...max(a, b)].map(\.id))
    }

    private func selection(including id: Record.ID) -> Set<Record.ID> {
        document.selectedRecordIDs.contains(id) ? document.selectedRecordIDs : [id]
    }
}
