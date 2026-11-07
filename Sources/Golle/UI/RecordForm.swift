import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// One record as a form, with an editor per field type. Shown in the inspector.
struct RecordForm: View {
    @ObservedObject var document: GolleDocument
    let table: DataTable
    let record: Record
    let resolver: Resolver

    var body: some View {
        Form {
            Section {
                ForEach(table.fields) { field in
                    FieldInput(document: document, table: table, record: record, field: field, resolver: resolver)
                }
            } header: {
                Text(table.title(of: record)).font(.headline)
            } footer: {
                Text("Created \(record.created.formatted(date: .abbreviated, time: .shortened)) · Modified \(record.modified.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Below the fields: appearing and going while a required or unique field is typed in, it
            // would move the fields under the cursor.
            RulesSection(document: document, table: table, record: record, resolver: resolver)
            BacklinksSection(document: document, record: record, resolver: resolver)
            HistorySection(document: document, table: table, record: record)
        }
        .formStyle(.grouped)
        .id(record.id)
    }
}

/// The field rules (required, unique) this record breaks, with the records it clashes with.
struct RulesSection: View {
    @ObservedObject var document: GolleDocument
    let table: DataTable
    let record: Record
    let resolver: Resolver

    var body: some View {
        let problems = resolver.hasRules ? resolver.ruleProblems(record) : []
        if !problems.isEmpty {
            Section {
                ForEach(problems, id: \.field.id) { field, problem in
                    VStack(alignment: .leading, spacing: 3) {
                        Label {
                            Text(problem.sentence(field))
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        if case .duplicate = problem {
                            let others = resolver.sameValue(as: record, field)
                            HStack(spacing: 8) {
                                ForEach(others.prefix(4)) { other in
                                    Button(table.title(of: other)) { document.selectedRecordIDs = [other.id] }
                                        .buttonStyle(.link)
                                }
                                if others.count > 4 { Text("and \(others.count - 4) more").foregroundStyle(.secondary) }
                            }
                            .font(.caption)
                            .padding(.leading, 26)
                        }
                    }
                }
            } header: {
                Text("Needs Attention")
            }
        }
    }
}

/// Records in other tables that link to this one, each table as a small editable table: an
/// album's tracks, a recipe's ingredients, a project's tasks. Cells are edited in place, "+" adds a
/// record that already links here, and the table's totals show underneath.
struct BacklinksSection: View {
    @ObservedObject var document: GolleDocument
    let record: Record
    let resolver: Resolver

    var body: some View {
        // Every link field pointing at this table, also when nothing links yet: that is where the
        // first one is added.
        let links = resolver.database.tables.flatMap { other in
            other.fields.filter { $0.type == .link && ($0.options.linkedTableID ?? other.id) == resolver.table.id }.map { (table: other, field: $0) }
        }
        ForEach(links, id: \.field.id) { link in
            let several = links.filter { $0.table.id == link.table.id }.count > 1
            RelatedRecords(document: document, record: record, table: link.table, link: link.field,
                           resolver: resolver.resolver(for: link.table), title: several ? "\(link.table.name) · \(link.field.name)" : link.table.name)
        }
    }
}

/// The records of one table that link to a record, through one link field.
struct RelatedRecords: View {
    @ObservedObject var document: GolleDocument
    let record: Record
    /// The table the related records are in, and its link field pointing here.
    let table: DataTable
    let link: Field
    let resolver: Resolver
    let title: String

    /// Shown at most; the rest are a click away in their table.
    static let limit = 50

    /// The columns: the record's name first, then the next short fields, as many as fit beside it.
    static func columns(_ table: DataTable, link: Field) -> [Field] {
        let short = table.fields.filter { field in
            field.id != link.id && ![.longText, .image, .file, .checklist, .location, .link].contains(field.type)
        }
        let title = table.titleField.flatMap { t in short.first { $0.id == t.id } }
        return Array(([title].compactMap { $0 } + short.filter { $0.id != title?.id }).prefix(3))
    }

    var body: some View {
        let related = table.records.filter { $0[link.id]?.links.contains(record.id) == true }
        let columns = Self.columns(table, link: link)
        Section {
            if !related.isEmpty {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        ForEach(Array(columns.enumerated()), id: \.element.id) { i, field in
                            Text(field.name).lineLimit(1)
                                .frame(maxWidth: i == 0 ? .infinity : 90, alignment: Self.alignsRight(field) ? .trailing : .leading)
                        }
                        Color.clear.frame(width: 20, height: 1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                    ForEach(related.prefix(Self.limit)) { other in
                        Divider()
                        row(other, columns: columns)
                    }
                    if related.count > Self.limit {
                        Divider()
                        Button("and \(related.count - Self.limit) more in \(table.name)") { show(related[Self.limit].id) }
                            .buttonStyle(.link)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                    totals(related, columns: columns)
                }
            }
            Button {
                add()
            } label: {
                Label(related.isEmpty ? "Add a Record to \(table.name)" : "Add to \(table.name)", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .help("A new record in \(table.name), linked to \(resolver.database.table(link.options.linkedTableID ?? table.id)?.title(of: record) ?? "this record")")
        } header: {
            HStack {
                Text(title)
                if !related.isEmpty { Text("\(related.count)").foregroundStyle(.secondary).monospacedDigit() }
            }
        }
    }

    private func row(_ other: Record, columns: [Field]) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(columns.enumerated()), id: \.element.id) { i, field in
                EditableCell(document: document, table: table, field: field, record: other, resolver: resolver)
                    .frame(maxWidth: i == 0 ? .infinity : 90, alignment: Self.alignsRight(field) ? .trailing : .leading)
            }
            Menu {
                Button("Show in \(table.name)") { show(other.id) }
                Divider()
                Button("Unlink") { unlink(other) }
                Button("Delete Record", role: .destructive) { document.deleteRecords([other.id], from: table.id) }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 20)
            .help("Show, unlink or delete \(table.title(of: other))")
        }
        .frame(minHeight: 24)
    }

    /// The table's totals (the Σ under its records) for the columns shown, over these records.
    @ViewBuilder
    private func totals(_ records: [Record], columns: [Field]) -> some View {
        let items = columns.map { field in table.summaries.first { $0.fieldID == field.id } }
        if items.contains(where: { $0 != nil }) {
            Divider()
            HStack(spacing: 8) {
                ForEach(Array(columns.enumerated()), id: \.element.id) { i, field in
                    Group {
                        if let item = items[i] {
                            Text(item.kind.compute(records.map { resolver.value($0, field) }, field: resolver.formatField(field)))
                                .help("\(item.kind.label) of \(field.name)")
                        } else {
                            Text(i == 0 ? "Total" : "")
                        }
                    }
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(maxWidth: i == 0 ? .infinity : 90, alignment: Self.alignsRight(field) ? .trailing : .leading)
                }
                Color.clear.frame(width: 20, height: 1)
            }
            .padding(.top, 6)
        }
    }

    static func alignsRight(_ field: Field) -> Bool {
        field.type.isNumeric || field.type == .duration || field.type == .formula || field.type == .rollup
    }

    private func add() {
        _ = document.addRecord(to: table.id, values: [link.id: .links([record.id])])
    }

    private func unlink(_ other: Record) {
        let rest = (other[link.id]?.links ?? []).filter { $0 != record.id }
        document.setValue(rest.isEmpty ? nil : .links(rest), record: other.id, field: link.id, table: table.id)
    }

    private func show(_ id: Record.ID) {
        document.selectedTableID = table.id
        document.selectedRecordIDs = [id]
    }
}

/// The editor for one field of one record.
struct FieldInput: View {
    @ObservedObject var document: GolleDocument
    let table: DataTable
    let record: Record
    let field: Field
    let resolver: Resolver
    var showsLabel = true

    var body: some View {
        FieldEditorRow(document: document, field: field, record: record, resolver: resolver, showsLabel: showsLabel, value: Binding(
            get: { record[field.id] },
            set: { document.setValue($0, record: record.id, field: field.id, table: table.id) }
        ))
    }
}

/// The editor for one field, chosen by its type.
struct FieldEditorRow: View {
    @ObservedObject var document: GolleDocument
    let field: Field
    let record: Record
    let resolver: Resolver
    var showsLabel = true
    @Binding var value: Value?

    var body: some View {
        switch field.type {
        case .text:
            TextField(showsLabel ? field.name : "", text: text, prompt: showsLabel ? nil : Text(field.name))
        case .longText where field.options.richText:
            VStack(alignment: .leading, spacing: 4) {
                if showsLabel { Text(field.name) }
                RichTextEditor(markdown: text)
            }
        case .longText:
            VStack(alignment: .leading, spacing: 4) {
                if showsLabel { Text(field.name) }
                TextEditor(text: text)
                    .font(.body)
                    .frame(minHeight: 60)
                    .scrollContentBackground(.hidden)
                    .padding(2)
                    .background(.background.secondary, in: .rect(cornerRadius: 4))
            }
        case .url:
            labeled {
                HStack {
                    TextField(field.name, text: text, prompt: Text("example.com"))
                        .labelsHidden()
                    if let url = value?.text.flatMap(Self.link) {
                        Link(destination: url) { Image(systemName: "arrow.up.forward.app") }
                            .help("Open \(url.absoluteString)")
                    }
                }
            }
        case .number:
            labeled {
                // Typed as text and saved when editing ends: also when another record is shown
                // before Return (a number field saves only then on its own).
                NumberInput(field: field, value: $value)
            }
        case .date:
            labeled {
                if let date = value?.date {
                    HStack {
                        DatePicker(field.name, selection: Binding(get: { date }, set: { value = .date($0) }),
                                   displayedComponents: field.options.includesTime ? [.date, .hourAndMinute] : .date)
                            .labelsHidden()
                        Button { value = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Clear date")
                    }
                } else {
                    Button(field.options.includesTime ? "Now" : "Add Date") { value = .date(Self.newDate(for: field)) }
                }
            }
        case .email, .phone:
            labeled {
                ActionTextInput(document: document, field: field, text: text)
            }
        case .barcode:
            labeled {
                // Stored without spaces and dashes, however it is typed or pasted.
                CleanedText(stored: value?.text ?? "", save: { value = Value.text($0).converted(to: .barcode) },
                            clean: { Value.text($0).converted(to: .barcode)?.text ?? "" }) { text in
                    ActionTextInput(document: document, field: field, text: text)
                }
            }
        case .duration:
            labeled {
                DurationInput(field: field, value: $value)
            }
        case .progress:
            labeled {
                ProgressInput(value: $value)
            }
        case .color:
            labeled {
                ColorInput(value: $value)
            }
        case .lookup:
            labeled {
                LookupView(document: document, field: field, record: record, resolver: resolver, inCell: false)
            }
        case .rollup:
            labeled {
                let shown = resolver.text(record, field)
                Text(shown.isEmpty ? "—" : shown).textSelection(.enabled).foregroundStyle(.secondary).monospacedDigit()
            }
        case .checkbox:
            Toggle(field.name, isOn: Binding(get: { value?.bool ?? false }, set: { value = $0 ? .bool(true) : nil }))
        case .rating:
            labeled {
                RatingView(rating: value?.rating ?? 0) { value = $0 > 0 ? .rating($0) : nil }
            }
        case .choice:
            labeled {
                Picker(field.name, selection: Binding(
                    get: { value?.choices.first ?? "" },
                    set: { value = $0.isEmpty ? nil : .choices([$0]) }
                )) {
                    Text("None").tag("")
                    ForEach(choiceList, id: \.self) { option in
                        Label { Text(option) } icon: {
                            Image(systemName: "circle.fill").foregroundStyle(field.color(of: option)?.color ?? .gray)
                        }
                        .tag(option)
                    }
                }
                .labelsHidden()
            }
        case .multiChoice:
            labeled {
                Menu {
                    ForEach(choiceList, id: \.self) { choice in
                        Toggle(choice, isOn: Binding(
                            get: { value?.choices.contains(choice) == true },
                            set: { on in
                                var current = value?.choices ?? []
                                if on { current.append(choice) } else { current.removeAll { $0 == choice } }
                                // Keep the order of the field's list.
                                let ordered = field.options.choices.filter(current.contains) + current.filter { !field.options.choices.contains($0) }
                                value = ordered.isEmpty ? nil : .choices(ordered)
                            }
                        ))
                    }
                } label: {
                    if let choices = value?.choices, !choices.isEmpty { ChipsView(field: field, choices: choices) } else { Text("None") }
                }
                .fixedSize()
            }
        case .checklist:
            labeled(vertical: true) {
                ChecklistEditor(value: $value)
            }
        case .image, .file:
            labeled(vertical: true) {
                AttachmentEditor(document: document, field: field, value: $value, current: { [document, record, resolver] in
                    document.database.table(resolver.table.id)?.records.first { $0.id == record.id }?[field.id]
                })
            }
        case .link:
            labeled(vertical: true) {
                LinkEditor(document: document, field: field, record: record, resolver: resolver, value: $value)
            }
        case .location:
            labeled(vertical: true) {
                LocationEditor(value: $value)
            }
        case .autoNumber, .createdAt, .modifiedAt:
            labeled {
                Text(resolver.text(record, field).isEmpty ? "—" : resolver.text(record, field))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .textSelection(.enabled)
            }
        case .formula:
            labeled {
                let computed = resolver.formulaValue(record, field)
                if let error = computed.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                } else {
                    Text(computed.value?.display(for: field) ?? "—").textSelection(.enabled).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// A new date: today, or now to the minute when the field shows the time.
    static func newDate(for field: Field) -> Date {
        guard field.options.includesTime else { return Calendar.current.startOfDay(for: Date()) }
        let now = Date()
        return Calendar.current.dateInterval(of: .minute, for: now)?.start ?? now
    }

    @ViewBuilder
    private func labeled<Content: View>(vertical: Bool = false, @ViewBuilder _ content: () -> Content) -> some View {
        if !showsLabel {
            content()
        } else if vertical {
            VStack(alignment: .leading, spacing: 6) {
                Text(field.name)
                content()
            }
        } else {
            LabeledContent(field.name) { content() }
        }
    }

    /// The field's options, plus any value a record holds that is no longer in the list.
    private var choiceList: [String] {
        field.options.choices + (value?.choices ?? []).filter { !field.options.choices.contains($0) }
    }

    private var text: Binding<String> {
        Binding(get: { value?.text ?? "" }, set: { value = $0.isEmpty ? nil : .text($0) })
    }

    private var number: Binding<Double?> {
        Binding(get: { value?.number }, set: { value = $0.map(Value.number) })
    }

    static func link(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") || trimmed.hasPrefix("mailto:") || trimmed.hasPrefix("tel:") { return URL(string: trimmed) }
        if trimmed.contains("@") && !trimmed.contains("/") { return URL(string: "mailto:" + trimmed) }
        return URL(string: "https://" + trimmed)
    }
}

// MARK: Attachments

/// Images or files of one field: thumbnails, drop target, add, open, Quick Look and remove.
struct AttachmentEditor: View {
    @ObservedObject var document: GolleDocument
    let field: Field
    @Binding var value: Value?
    /// The field's value as it is now in the document. A slow drop (a download) adds to this, not to
    /// the value from when it was dropped, so changes made meanwhile aren't overwritten.
    var current: () -> Value? = { nil }
    @State private var preview: URL?
    @State private var targeted = false
    @State private var failure: String?
    @State private var loading = false

    private var items: [Attachment] { value?.attachments ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if field.type == .image {
                // A horizontal strip: its minimum width doesn't depend on the number of images, which an
                // adaptive grid's does (and that makes split views re-layout forever).
                if !items.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(items) { item in
                                thumbnail(item)
                            }
                        }
                    }
                    .frame(height: 88)
                }
            } else {
                ForEach(items) { item in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data))
                            .resizable().frame(width: 18, height: 18)
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                    }
                    .contentShape(.rect)
                    .onTapGesture(count: 2) { open(item) }
                    .contextMenu { menu(item) }
                }
            }
            HStack {
                Button(field.type == .image ? "Add Image…" : "Add File…") { choose() }
                Button("Paste") { paste() }
                    .help("Paste an image or file you copied")
                if items.isEmpty {
                    Text("or drop here").foregroundStyle(.secondary).font(.caption)
                }
                if loading { ProgressView().controlSize(.small) }
            }
            .controlSize(.small)
            if let failure {
                Text(failure).foregroundStyle(.red).font(.caption)
            }
        }
        .padding(4)
        .background(targeted ? Color.accentColor.opacity(0.15) : .clear, in: .rect(cornerRadius: 6))
        // Files from Finder, images from a browser or Photos, and links to images on the web.
        .onDrop(of: [.fileURL, .image, .url], isTargeted: $targeted) { providers in
            receive(providers)
            return true
        }
        .onPasteCommand(of: [.fileURL, .image, .png, .tiff, .jpeg]) { providers in receive(providers) }
        .quickLookPreview($preview)
    }

    private func thumbnail(_ item: Attachment) -> some View {
        Group {
            if let image = document.image(item) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").font(.title).foregroundStyle(.secondary)
            }
        }
        .frame(width: 84, height: 84)
        .background(.quaternary)
        .clipShape(.rect(cornerRadius: 6))
        .contentShape(.rect)
        .onTapGesture(count: 2) { preview = document.exportedURL(for: item) }
        .contextMenu { menu(item) }
        .help(item.name)
    }

    @ViewBuilder
    private func menu(_ item: Attachment) -> some View {
        Button("Quick Look") { preview = document.exportedURL(for: item) }
        Button("Open") { open(item) }
        Button("Save a Copy…") { saveCopy(item) }
        Divider()
        Button("Remove", role: .destructive) {
            let rest = items.filter { $0.id != item.id }
            value = rest.isEmpty ? nil : .attachments(rest)
        }
    }

    private func open(_ item: Attachment) {
        if let url = document.exportedURL(for: item) { NSWorkspace.shared.open(url) }
    }

    private func saveCopy(_ item: Attachment) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.name
        guard panel.runModal() == .OK, let url = panel.url, let data = document.attachmentData(item) else { return }
        try? data.write(to: url)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if field.type == .image { panel.allowedContentTypes = [.image] }
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    /// What the pasteboard holds: copied files first, else an image (as PNG).
    private func paste() {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            add(urls)
        } else if let image = NSImage(pasteboard: board), let png = Self.png(image) {
            append([document.addAttachment(data: png, name: "Pasted Image.png")])
        } else {
            failure = "There is no image or file to paste."
        }
    }

    /// Loads dropped or pasted items: file URLs, image data (also file promises from Photos) and web
    /// links to images. Everything arrives first, then the field changes once.
    private func receive(_ providers: [NSItemProvider]) {
        failure = nil
        loading = true
        Task {
            var files: [(Data, String)] = []
            var errors: [String] = []
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                   let url = await Self.loadURL(provider, type: .fileURL), url.isFileURL {
                    if let data = try? Data(contentsOf: url) { files.append((data, url.lastPathComponent)) }
                    else { errors.append("Could not read \(url.lastPathComponent).") }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                          let (data, name) = await Self.loadImage(provider) {
                    files.append((data, name))
                } else if let url = await Self.loadURL(provider, type: .url), url.scheme?.hasPrefix("http") == true {
                    // A link has to be downloaded: not with online lookups off.
                    if !Preferences.onlineLookups {
                        errors.append("Online lookups are off in Settings, so the link can't be downloaded. Drop the image itself.")
                    } else if let (data, response) = try? await URLSession.shared.data(from: url),
                       (response.mimeType?.hasPrefix("image/") == true || field.type == .file) {
                        let name = url.lastPathComponent.isEmpty ? "Image" : url.lastPathComponent
                        files.append((data, name.contains(".") ? name : name + "." + (response.mimeType?.split(separator: "/").last.map(String.init) ?? "jpg")))
                    } else {
                        errors.append("The link isn't an image.")
                    }
                }
            }
            await MainActor.run {
                loading = false
                if field.type == .image {
                    let images = files.filter { NSImage(data: $0.0) != nil }
                    if images.count < files.count { errors.append("Only images can go in this field.") }
                    files = images
                }
                append(files.map { document.addAttachment(data: $0.0, name: $0.1) })
                if !errors.isEmpty { failure = errors.joined(separator: " ") }
            }
        }
    }

    private func append(_ added: [Attachment]) {
        guard !added.isEmpty else { return }
        value = .attachments((current()?.attachments ?? items) + added)
    }

    private static func loadURL(_ provider: NSItemProvider, type: UTType) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    /// Image data, from a file representation when there is one (Photos hands over a file promise).
    private static func loadImage(_ provider: NSItemProvider) async -> (Data, String)? {
        let type = provider.registeredContentTypes.first { $0.conforms(to: .image) } ?? .image
        let name = (provider.suggestedName ?? "Image") + (provider.suggestedName?.contains(".") == true ? "" : "." + (type.preferredFilenameExtension ?? "png"))
        if let data: Data = await withCheckedContinuation({ continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
                continuation.resume(returning: url.flatMap { try? Data(contentsOf: $0) })
            }
        }) {
            return (data, name)
        }
        let data: Data? = await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(for: type) { data, _ in continuation.resume(returning: data) }
        }
        return data.map { ($0, name) }
    }

    static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func add(_ urls: [URL]) {
        failure = nil
        var added: [Attachment] = []
        for url in urls {
            if field.type == .image, let type = UTType(filenameExtension: url.pathExtension), !type.conforms(to: .image) {
                failure = "\(url.lastPathComponent) is not an image."
                continue
            }
            do { added.append(try document.importAttachment(from: url)) }
            catch { failure = "Could not add \(url.lastPathComponent): \(error.localizedDescription)" }
        }
        append(added)
    }
}

// MARK: Links

/// The records a link field points at, with a searchable picker to add more.
struct LinkEditor: View {
    @ObservedObject var document: GolleDocument
    let field: Field
    let record: Record
    let resolver: Resolver
    @Binding var value: Value?
    @State private var picking = false

    private var target: DataTable? { document.database.table(field.options.linkedTableID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(resolver.linkedRecords(record, field), id: \.record.id) { linked in
                HStack {
                    Button(linked.table.title(of: linked.record)) {
                        document.selectedTableID = linked.table.id
                        document.selectedRecordIDs = [linked.record.id]
                    }
                    .buttonStyle(.link)
                    .help("Show this record")
                    Spacer()
                    Button { unlink(linked.record.id) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Remove link")
                }
            }
            if let target {
                Button("Link \(target.name) Record…") { picking = true }
                    .controlSize(.small)
                    .popover(isPresented: $picking, arrowEdge: .leading) { picker(target) }
            } else {
                Text("Choose a table for this field in Edit Fields.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func picker(_ target: DataTable) -> some View {
        LinkPicker(document: document, target: target, record: record, resolver: resolver, value: $value,
                   showsLinked: false) { picking = false }
    }

    private func unlink(_ id: UUID) {
        let rest = (value?.links ?? []).filter { $0 != id }
        value = rest.isEmpty ? nil : .links(rest)
    }
}

/// Picks the records a link field points at: search, click to add, or make a new one. With
/// `showsLinked`, the records already linked are listed on top, each with a button to remove it
/// (the table's cells use that; the form lists them itself).
struct LinkPicker: View {
    @ObservedObject var document: GolleDocument
    let target: DataTable
    let record: Record
    let resolver: Resolver
    @Binding var value: Value?
    var showsLinked = true
    let done: () -> Void
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let linkedIDs = value?.links ?? []
        let linkedSet = Set(linkedIDs)
        let targetResolver = resolver.resolver(for: target)
        let candidates = Query.search(target.records.filter { !linkedSet.contains($0.id) && $0.id != record.id },
                                      targetResolver, for: search)
        VStack(spacing: 0) {
            if showsLinked, !linkedIDs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(linkedIDs, id: \.self) { id in
                        if let linked = resolver.lookup(id) {
                            HStack {
                                Text(linked.table.title(of: linked.record)).lineLimit(1)
                                Spacer()
                                Button { unlink(id) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.secondary)
                                    .help("Remove link")
                            }
                        }
                    }
                }
                .padding([.horizontal, .top], 10)
                Divider().padding(.top, 8)
            }
            TextField("Search \(target.name)", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(8)
                .focused($searchFocused)
                // Return links the first match.
                .onSubmit {
                    if let first = candidates.first { value = .links((value?.links ?? []) + [first.id]); search = "" }
                }
                .onAppear { DispatchQueue.main.async { searchFocused = true } }
            List(candidates.prefix(200)) { candidate in
                Button(target.title(of: candidate)) {
                    value = .links((value?.links ?? []) + [candidate.id])
                }
                .buttonStyle(.plain)
            }
            .frame(width: 280, height: 260)
            HStack {
                Button("New \(target.name) Record") {
                    if let id = document.addRecord(to: target.id) {
                        value = .links((value?.links ?? []) + [id])
                    }
                    done()
                }
                Spacer()
                // Not Return: that links the first match while searching.
                Button("Done", action: done)
            }
            .padding(8)
        }
    }

    private func unlink(_ id: UUID) {
        let rest = (value?.links ?? []).filter { $0 != id }
        value = rest.isEmpty ? nil : .links(rest)
    }
}

// MARK: Batch edit

/// Several selected records: each field shows the shared value, or "mixed", and a change applies to
/// all of them at once.
struct BatchForm: View {
    @ObservedObject var document: GolleDocument
    let table: DataTable
    let ids: Set<Record.ID>
    let resolver: Resolver

    private var records: [Record] { table.records.filter { ids.contains($0.id) } }

    /// Fields that make sense to set on many records at once. (A checklist belongs to one record.)
    private var fields: [Field] {
        table.fields.filter { !$0.type.isAutomatic && $0.type != .link && !$0.type.isAttachment && $0.type != .checklist }
    }

    var body: some View {
        Form {
            Section {
                if let first = records.first {
                    ForEach(fields) { field in
                        let values = records.map { $0[field.id] }
                        let mixed = !values.allSatisfy { $0 == values[0] }
                        if field.type == .multiChoice {
                            optionToggles(field, values: values)
                        } else {
                            FieldEditorRow(document: document, field: label(field, mixed: mixed), record: first, resolver: resolver,
                                           value: Binding(
                                               get: { mixed ? nil : values[0] },
                                               set: { document.setValue($0, records: ids, field: field.id, table: table.id, typing: true) }
                                           ))
                            // Mixed values show as empty, so choosing "None" or clearing changes
                            // nothing: this empties the field in every selected record.
                            if mixed {
                                Button("Clear \(field.name) in All", systemImage: "xmark.circle") {
                                    document.setValue(nil, records: ids, field: field.id, table: table.id)
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            }
                        }
                    }
                }
            } header: {
                Text("Edit \(ids.count) Records").font(.headline)
            } footer: {
                Text("A change here applies to every selected record. Fields that differ show “mixed”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Multiple choice on many records: each option is on for all, off for all, or mixed (–).
    /// Ticking adds that option to every record and keeps their other options.
    private func optionToggles(_ field: Field, values: [Value?]) -> some View {
        let options = field.options.choices
        return LabeledContent(field.name) {
            Menu {
                ForEach(options, id: \.self) { option in
                    let count = values.filter { $0?.choices.contains(option) == true }.count
                    Button {
                        let add = count < values.count
                        document.updateValues(records: ids, field: field.id, table: table.id) { value in
                            var current = value?.choices ?? []
                            if add, !current.contains(option) { current.append(option) }
                            if !add { current.removeAll { $0 == option } }
                            let ordered = options.filter(current.contains) + current.filter { !options.contains($0) }
                            return ordered.isEmpty ? nil : .choices(ordered)
                        }
                    } label: {
                        Label(option, systemImage: count == values.count ? "checkmark.square" : count == 0 ? "square" : "minus.square")
                    }
                }
            } label: {
                Text("Add or remove…")
            }
            .fixedSize()
        }
    }

    private func label(_ field: Field, mixed: Bool) -> Field {
        var f = field
        if mixed { f.name += " (mixed)" }
        return f
    }
}
