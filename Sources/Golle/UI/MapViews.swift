import MapKit
import SwiftUI

/// Finding places by name or address, with Apple's map search.
enum Places {
    static func find(_ query: String) async -> Place? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, Preferences.onlineLookups else { return nil }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return nil }
        let coordinate = item.location.coordinate
        return Place(name: trimmed, latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}

extension Place {
    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// A location field in a form: the address, a button to find it, and a small map.
struct LocationEditor: View {
    @Binding var value: Value?
    @State private var text = ""
    @State private var searching = false
    @State private var notFound = false
    @AppStorage(Preferences.Key.onlineLookups, store: Preferences.store) private var onlineLookups = true

    private var place: Place? { value?.place }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Address or place", text: $text)
                    .labelsHidden()
                    .onSubmit(find)
                    .onChange(of: text) { _, new in
                        // Typing changes the name; the old pin no longer applies.
                        if new != (place?.name ?? "") { value = new.isEmpty ? nil : .location(Place(name: new)) }
                    }
                if searching {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Find") { find() }
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || !onlineLookups)
                        .help(onlineLookups ? "Find this place on the map" : "Online lookups are off in Golle ▸ Settings ▸ Privacy")
                }
            }
            if notFound {
                Text("Couldn't find that place.").font(.caption).foregroundStyle(.orange)
            }
            if let place, let coordinate = place.coordinate {
                Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 3000, longitudinalMeters: 3000))) {
                    Marker(place.name, coordinate: coordinate)
                }
                .frame(height: 140)
                .clipShape(.rect(cornerRadius: 6))
                .id("\(coordinate.latitude),\(coordinate.longitude)")
                Button("Open in Maps") {
                    let item = MKMapItem(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), address: nil)
                    item.name = place.name
                    item.openInMaps()
                }
                .controlSize(.small)
            }
        }
        .onAppear { text = place?.name ?? "" }
        // The value changed elsewhere (undo, another selection in a batch edit): show it, so old
        // text is never written to records it didn't come from.
        .onChange(of: value) { _, new in
            let name = new?.place?.name ?? ""
            if name != text { text = name }
        }
    }

    private func find() {
        let query = text
        searching = true
        notFound = false
        Task {
            let found = await Places.find(query)
            await MainActor.run {
                searching = false
                // Typed on while searching: the result is for text that is no longer there.
                guard text == query else { return }
                if let found { value = .location(found) } else { notFound = true }
            }
        }
    }
}

/// All records with a position on one map. Click a pin to select its record.
struct MapRecordsView: View {
    @ObservedObject var document: GolleDocument
    let table: DataTable
    let view: SavedView
    let rows: [Record]
    let resolver: Resolver
    let editFields: () -> Void
    @State private var finding = false
    @AppStorage(Preferences.Key.onlineLookups, store: Preferences.store) private var onlineLookups = true
    @State private var position = MapCameraPosition.automatic

    var body: some View {
        if let field = view.locationField(in: table) {
            let placed = rows.filter { $0[field.id]?.place?.hasCoordinates == true }
            let unplaced = rows.filter { $0[field.id]?.place.map { !$0.hasCoordinates && !$0.name.isEmpty } == true }
            VStack(spacing: 0) {
                HStack {
                    Picker("Places from", selection: Binding(get: { field.id }, set: { id in document.updateCurrentView("Change Map") { $0.locationFieldID = id } })) {
                        ForEach(table.fields.filter { $0.type == .location }) { Text($0.name).tag($0.id) }
                    }
                    .fixedSize()
                    Spacer()
                    if !unplaced.isEmpty {
                        Text("\(unplaced.count) not on the map yet").foregroundStyle(.secondary).lineLimit(1)
                        if finding { ProgressView().controlSize(.small) } else {
                            Button("Find Them") { findAll(unplaced, field: field) }
                                .disabled(!onlineLookups)
                                .help(onlineLookups ? "Find these places on the map" : "Online lookups are off in Golle ▸ Settings ▸ Privacy")
                        }
                    }
                }
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
                Divider()
                Map(position: $position, selection: Binding(
                    get: { document.selectedRecordIDs.count == 1 ? document.selectedRecordIDs.first : nil },
                    set: { document.selectedRecordIDs = $0.map { [$0] } ?? [] }
                )) {
                    ForEach(placed) { record in
                        if let coordinate = record[field.id]?.place?.coordinate {
                            Marker(table.title(of: record), coordinate: coordinate)
                                .tint(table.color(of: record, resolver)?.color ?? .accentColor)
                                .tag(record.id)
                        }
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ContentUnavailableView {
                Label("No Location Field", systemImage: "map")
            } description: {
                Text("The map shows records by a Location field. Add one to use the map.")
            } actions: {
                Button("Edit Fields…", action: editFields)
            }
        }
    }

    /// Looks up every address without a position, one after another, and saves them as one change.
    private func findAll(_ records: [Record], field: Field) {
        finding = true
        Task {
            var found: [(Record.ID, String, Place)] = []
            for record in records {
                guard let name = record[field.id]?.place?.name, let place = await Places.find(name) else { continue }
                found.append((record.id, name, place))
            }
            await MainActor.run {
                finding = false
                guard !found.isEmpty else { return }
                document.change("Find Places") { db in
                    guard let t = db.tableIndex(table.id) else { return }
                    for (id, name, place) in found {
                        // Skip records whose address was changed while searching.
                        guard let r = db.tables[t].recordIndex(id), db.tables[t].records[r][field.id]?.place?.name == name else { continue }
                        db.tables[t].records[r][field.id] = .location(place)
                    }
                }
                position = .automatic
            }
        }
    }
}
