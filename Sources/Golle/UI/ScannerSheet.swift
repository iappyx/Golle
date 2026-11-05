import AVFoundation
import SwiftUI
import Vision

/// Scan a barcode or ISBN with the Mac's camera (or an iPhone, through Continuity Camera), or type it,
/// then look it up and add the book or album as a record.
struct ScannerSheet: View {
    @ObservedObject var document: GolleDocument
    let tableID: DataTable.ID
    @Environment(\.dismiss) private var dismiss

    @StateObject private var camera = BarcodeCamera()
    @State private var code = ""
    @State private var results: [LookupResult] = []
    @State private var searching = false
    @State private var message: String?
    @State private var adding: LookupResult.ID?
    @State private var added: [String] = []
    @State private var lastLooked = ""
    /// When the camera last saw the code looked up last. While it stays in view it isn't looked up
    /// again; taken away for a few seconds and shown again, it is.
    @State private var lastSeen = Date.distantPast
    /// The lookup whose results count: a newer one replaces an older one still running.
    @State private var lookupID = UUID()
    @AppStorage(Preferences.Key.onlineLookups, store: Preferences.store) private var onlineLookups = true

    private var table: DataTable? { document.database.table(tableID) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                cameraPanel
                    .frame(width: 320)
                resultsPanel
                    .frame(maxWidth: .infinity)
            }
            .padding(16)
            .frame(maxHeight: .infinity)
            Divider()
            HStack {
                if !added.isEmpty {
                    Text("Added: " + added.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 780, height: 520)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: camera.detected) { _, detected in
            guard let detected else { return }
            // The same code, still in front of the camera: ignore it.
            if detected == lastLooked, Date().timeIntervalSince(lastSeen) < 4 {
                lastSeen = Date()
                resumeSoon()
                return
            }
            lastSeen = Date()
            code = detected
            look()
        }
    }

    private var cameraPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.black)
                if camera.state == .running {
                    CameraPreview(session: camera.session).clipShape(.rect(cornerRadius: 10))
                    RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .frame(width: 220, height: 110)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "camera").font(.largeTitle)
                        Text(camera.state.message).multilineTextAlignment(.center).font(.callout)
                    }
                    .foregroundStyle(.white.opacity(0.8))
                    .padding()
                }
            }
            .frame(height: 240)
            if camera.devices.count > 1 {
                Picker("Camera", selection: Binding(get: { camera.deviceID }, set: { camera.select($0) })) {
                    ForEach(camera.devices, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
                }
            }
            Text("Hold the barcode in the frame. An iPhone nearby can be used as the camera.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Or type an ISBN or barcode", text: $code)
                    .onSubmit(look)
                Button("Look Up", action: look).disabled(Lookup.clean(code).count < 8 || searching || !onlineLookups)
            }
        }
    }

    @ViewBuilder
    private var resultsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !onlineLookups {
                ContentUnavailableView {
                    Label("Online Lookups Are Off", systemImage: "network.slash")
                } description: {
                    Text("Scanning needs Open Library and MusicBrainz to find the book or album. Turn lookups on in Settings ▸ Privacy.")
                } actions: {
                    SettingsLink { Text("Open Settings…") }
                }
                .frame(maxHeight: .infinity)
            } else if searching {
                ProgressView("Looking up \(code)…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let message {
                ContentUnavailableView(message, systemImage: "barcode.viewfinder").frame(maxHeight: .infinity)
            } else if results.isEmpty {
                ContentUnavailableView("Scan a Barcode", systemImage: "barcode.viewfinder",
                                       description: Text("Books are found by ISBN at Open Library, albums by barcode at MusicBrainz. Only the code is sent."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(results) { result in row(result) }
                    }
                }
            }
        }
    }

    private func row(_ result: LookupResult) -> some View {
        HStack(alignment: .top, spacing: 10) {
            AsyncImage(url: result.coverURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: result.kind == .book ? "book.closed" : "opticaldisc").font(.title).foregroundStyle(.tertiary)
            }
            .frame(width: 64, height: 64)
            .background(.quaternary)
            .clipShape(.rect(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 3) {
                Text(result.title).font(.headline).lineLimit(2)
                Text(result.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text("from \(result.source)").font(.caption2).foregroundStyle(.tertiary)
                HStack {
                    Button("Add as New Record") { add(result, into: nil) }
                    if document.selectedRecordIDs.count == 1, let id = document.selectedRecordIDs.first,
                       table?.records.contains(where: { $0.id == id }) == true {
                        Button("Fill Selected Record") { add(result, into: id) }
                    }
                    if adding == result.id { ProgressView().controlSize(.small) }
                }
                .controlSize(.small)
                .disabled(adding != nil)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(.background.secondary, in: .rect(cornerRadius: 8))
    }

    /// Detection pauses on each hit; after a lookup it starts again, whatever the outcome.
    private func resumeSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { camera.resume() }
    }

    private func look() {
        let query = Lookup.clean(code)
        guard query.count >= 8, onlineLookups else { resumeSoon(); return }
        lastLooked = query
        lastSeen = Date()
        let id = UUID()
        lookupID = id
        searching = true
        message = nil
        results = []
        Task {
            do {
                let found = try await Lookup.find(query)
                await MainActor.run {
                    guard id == lookupID else { return }
                    // Counted from the answer: a slow lookup mustn't make the code still in view new again.
                    lastSeen = Date()
                    searching = false
                    results = found
                    if found.isEmpty { message = "Nothing found for \(query)" }
                    resumeSoon()
                }
            } catch {
                await MainActor.run {
                    guard id == lookupID else { return }
                    lastSeen = Date()
                    searching = false
                    message = "Lookup failed: \(error.localizedDescription)"
                    resumeSoon()
                }
            }
        }
    }

    /// Downloads the cover, then adds or fills the record (and any new linked records) in one change.
    private func add(_ result: LookupResult, into recordID: Record.ID?) {
        adding = result.id
        let lookup = lookupID, typed = code
        Task {
            let coverData = await Lookup.cover(result.coverURL)
            await MainActor.run {
                adding = nil
                guard let table else { return }
                let cover = coverData.map { document.addAttachment(data: $0, name: "\(result.title).jpg") }
                let (values, newLinked) = LookupFiller.values(for: result, in: table, database: document.database, cover: cover)
                let newRecord = recordID == nil ? GolleDocument.newRecord(in: table, values: values) : nil
                document.change(recordID == nil ? "Add \(result.title)" : "Fill \(result.title)") { db in
                    for (linkedTable, record) in newLinked {
                        db.tableIndex(linkedTable).map { db.tables[$0].records.append(record) }
                    }
                    guard let t = db.tableIndex(table.id) else { return }
                    if let newRecord {
                        db.tables[t].records.append(newRecord)
                    } else if let recordID, let r = db.tables[t].recordIndex(recordID) {
                        for (field, value) in values { db.tables[t].records[r][field] = value }
                        db.tables[t].records[r].modified = .stamp()
                    }
                }
                if let newRecord {
                    document.pinnedRecordIDs.insert(newRecord.id)
                    document.selectedRecordIDs = [newRecord.id]
                }
                added.append(result.title)
                // A newer scan may have come in while the cover downloaded: keep its results.
                if lookupID == lookup {
                    results = []
                    // Unless something else was typed meanwhile.
                    if code == typed { code = "" }
                }
                camera.resume()
            }
        }
    }
}

// MARK: Camera

/// The camera session and barcode detection. Detection pauses after a hit until `resume()`.
@MainActor
final class BarcodeCamera: NSObject, ObservableObject {
    enum State: Equatable {
        case idle, running, denied, noCamera, failed(String)
        var message: String {
            switch self {
            case .idle: "Starting the camera…"
            case .running: ""
            case .denied: "Golle may not use the camera. Allow it in System Settings ▸ Privacy & Security ▸ Camera."
            case .noCamera: "No camera found. Type the code instead."
            case .failed(let reason): reason
            }
        }
    }

    @Published var state = State.idle
    @Published var detected: String?
    @Published var devices: [AVCaptureDevice] = []
    @Published var deviceID: String?

    nonisolated let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "golle.barcodes")
    private nonisolated(unsafe) var paused = false
    private nonisolated(unsafe) var lastFrame = Date.distantPast
    /// Whether the sheet still wants the camera: access may be granted after it was closed.
    /// Read on the camera queue too.
    private nonisolated(unsafe) var wanted = false

    func start() {
        wanted = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    guard self.wanted else { return }
                    if granted { self.configure() } else { self.state = .denied }
                }
            }
        default: state = .denied
        }
    }

    private func configure() {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
                                                         mediaType: .video, position: .unspecified)
        devices = discovery.devices
        // Continuity Camera (an iPhone) focuses up close far better than a laptop camera.
        guard let device = devices.first(where: { $0.deviceType == .continuityCamera }) ?? devices.first else {
            state = .noCamera
            return
        }
        use(device)
    }

    func select(_ id: String?) {
        guard let device = devices.first(where: { $0.uniqueID == id }) else { return }
        use(device)
    }

    private func use(_ device: AVCaptureDevice) {
        deviceID = device.uniqueID
        let session = self.session
        let output = self.output
        let queue = self.queue
        queue.async {
            guard self.wanted else { return }
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if session.canAddInput(input) { session.addInput(input) }
                if session.outputs.isEmpty, session.canAddOutput(output) {
                    output.alwaysDiscardsLateVideoFrames = true
                    output.setSampleBufferDelegate(self, queue: queue)
                    session.addOutput(output)
                }
                session.commitConfiguration()
                if !session.isRunning { session.startRunning() }
                Task { @MainActor in self.state = .running }
            } catch {
                session.commitConfiguration()
                Task { @MainActor in self.state = .failed("The camera could not start: \(error.localizedDescription)") }
            }
        }
    }

    func stop() {
        wanted = false
        let session = self.session
        queue.async { if session.isRunning { session.stopRunning() } }
    }

    func resume() {
        queue.async { self.paused = false }
        detected = nil
    }
}

extension BarcodeCamera: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // A few frames a second is plenty, and keeps the fans quiet.
        guard !paused, Date().timeIntervalSince(lastFrame) > 0.25, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrame = Date()
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.ean13, .ean8, .upce, .code128, .code39, .itf14]
        try? VNImageRequestHandler(cvPixelBuffer: pixels, options: [:]).perform([request])
        guard let code = (request.results ?? []).compactMap(\.payloadStringValue).first(where: { Lookup.clean($0).count >= 8 }) else { return }
        paused = true
        Task { @MainActor in self.detected = Lookup.clean(code) }
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Scans one barcode into a field: the camera until it sees a code, then the code goes into the
/// field and the sheet closes. Nothing is looked up or sent anywhere.
struct BarcodeCaptureSheet: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = BarcodeCamera()

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.black)
                if camera.state == .running {
                    CameraPreview(session: camera.session).clipShape(.rect(cornerRadius: 10))
                    RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .frame(width: 220, height: 110)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "camera").font(.largeTitle)
                        Text(camera.state.message).multilineTextAlignment(.center).font(.callout)
                    }
                    .foregroundStyle(.white.opacity(0.8))
                    .padding()
                }
            }
            .frame(width: 360, height: 240)
            if camera.devices.count > 1 {
                Picker("Camera", selection: Binding(get: { camera.deviceID }, set: { camera.select($0) })) {
                    ForEach(camera.devices, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
                }
            }
            HStack {
                Text("Hold the barcode in the frame.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 392)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: camera.detected) { _, code in
            guard let code else { return }
            onCode(code)
            dismiss()
        }
    }
}
