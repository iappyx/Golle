import AppKit
import SwiftUI

/// A duration: typed as "45:12", "1:02:30", "1h 30m" or "90 min", shown in the field's style.
/// Saved when editing ends (Return, Tab, clicking away); text that isn't a duration is put back.
struct DurationInput: View {
    let field: Field
    @Binding var value: Value?
    var plain = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var shown: String { value?.number.map { Value.formatDuration($0, field.options.durationStyle) } ?? "" }

    var body: some View {
        styled(TextField(field.name, text: $draft, prompt: Text(field.options.durationStyle == .hoursMinutes ? "1:30" : "3:45")))
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .focused($focused)
            .onSubmit(save)
            .onAppear { draft = shown }
            .onChange(of: value) { _, _ in if !focused { draft = shown } }
            .onChange(of: focused) { _, now in if !now { save() } }
            .onDisappear { if focused { save() } }
    }

    /// Plain in table cells; in forms, like the form's other fields.
    @ViewBuilder
    private func styled(_ field: some View) -> some View {
        if plain { field.textFieldStyle(.plain) } else { field }
    }

    private func save() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            if value != nil { value = nil }
        } else if let seconds = Value.parseDuration(text, field.options.durationStyle) {
            if value?.number != seconds { value = .number(seconds) }
            // From what was just saved: the binding can still give the value from before.
            draft = Value.formatDuration(seconds, field.options.durationStyle)
            return
        }
        draft = shown
    }
}


/// A number, typed plainly ("1234.5", "1.234,5", "€ 12"). Saved when editing ends (Return, Tab,
/// clicking away, another record shown); text that isn't a number is put back.
struct NumberInput: View {
    let field: Field
    @Binding var value: Value?
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var shown: String { value?.number.map(Value.plain) ?? "" }

    var body: some View {
        TextField(field.name, text: $draft)
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .focused($focused)
            .onSubmit(save)
            .onAppear { draft = shown }
            .onChange(of: value) { _, _ in if !focused { draft = shown } }
            .onChange(of: focused) { _, now in if !now { save() } }
            .onDisappear { if focused { save() } }
    }

    private func save() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            if value != nil { value = nil }
            draft = ""
        } else if let n = Value.parseNumber(text) {
            if value?.number != n { value = .number(n) }
            draft = Value.plain(n)
        } else {
            NSSound.beep()
            draft = shown
        }
    }
}

/// Text cleaned as it is stored (a barcode loses its spaces and dashes), while what is typed stays
/// as typed: cleaning the field's own text on every key would move the cursor to the end.
struct CleanedText<Content: View>: View {
    let stored: String
    let save: (String) -> Void
    let clean: (String) -> String
    @ViewBuilder let content: (Binding<String>) -> Content
    @State private var draft: String?

    var body: some View {
        content(Binding(get: { draft ?? stored }, set: { new in
            draft = new
            save(new)
        }))
        // Changed elsewhere (undo, a scan): show that.
        .onChange(of: stored) { _, new in if let draft, clean(draft) != new { self.draft = nil } }
    }
}

/// A percentage from 0 to 100: a slider and the number.
struct ProgressInput: View {
    @Binding var value: Value?

    var body: some View {
        HStack(spacing: 8) {
            Slider(value: Binding(get: { value?.number ?? 0 }, set: { value = .number($0.rounded()) }), in: 0...100)
            Text("\(Int(value?.number ?? 0))%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

/// A progress bar for tables and cards.
struct ProgressBar: View {
    let percent: Double

    var body: some View {
        HStack(spacing: 6) {
            ProgressView(value: min(max(percent, 0), 100), total: 100)
                .progressViewStyle(.linear)
                .tint(percent >= 100 ? .green : .accentColor)
                .frame(minWidth: 40)
            Text("\(Int(percent))%")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }
}

/// Email, phone and barcode: the text, a button that acts on it, and a note when it doesn't look
/// right (the value is saved either way: it's the user's data).
struct ActionTextInput: View {
    @ObservedObject var document: GolleDocument
    let field: Field
    @Binding var text: String
    @State private var scanning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                TextField(field.name, text: $text, prompt: Text(prompt))
                    .labelsHidden()
                action
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
        }
        .sheet(isPresented: $scanning) {
            BarcodeCaptureSheet { code in text = code }
        }
    }

    private var prompt: String {
        switch field.type {
        case .email: "name@example.com"
        case .phone: "+31 6 12345678"
        default: "ISBN or barcode"
        }
    }

    private var problem: String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        switch field.type {
        case .email: return Value.emailIsValid(t) ? nil : "This doesn't look like an email address."
        case .phone: return Value.phoneURL(t) == nil ? "This doesn't look like a phone number." : nil
        case .barcode: return Value.barcodeIsValid(Value.cleanBarcode(t)) == false ? "The check digit doesn't match: a digit may be wrong." : nil
        default: return nil
        }
    }

    @ViewBuilder
    private var action: some View {
        let t = text.trimmingCharacters(in: .whitespaces)
        switch field.type {
        case .email:
            Button { URL(string: "mailto:" + t).map { _ = NSWorkspace.shared.open($0) } } label: { Image(systemName: "envelope") }
                .buttonStyle(.borderless)
                .disabled(!Value.emailIsValid(t))
                .help("Write an email to \(t)")
        case .phone:
            Button { Value.phoneURL(t).map { _ = NSWorkspace.shared.open($0) } } label: { Image(systemName: "phone") }
                .buttonStyle(.borderless)
                .disabled(Value.phoneURL(t) == nil)
                .help("Call \(t) (with your iPhone or FaceTime)")
        case .barcode:
            Button { scanning = true } label: { Image(systemName: "barcode.viewfinder") }
                .buttonStyle(.borderless)
                .help("Scan the barcode with the camera")
        default:
            EmptyView()
        }
    }
}

/// A colour: a colour well, the hex code, and a button to clear it. Stored as "#RRGGBB".
struct ColorInput: View {
    @Binding var value: Value?

    var body: some View {
        HStack(spacing: 8) {
            ColorPicker("Colour", selection: Binding(
                get: { value?.text.flatMap(Color.init(cellHex:)) ?? .clear },
                set: { value = $0.hex.map(Value.text) }
            ), supportsOpacity: false)
            .labelsHidden()
            if let hex = value?.text {
                Text(hex).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                Button { value = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Clear colour")
            } else {
                Text("None").foregroundStyle(.secondary)
            }
        }
    }
}

/// A colour swatch for tables and cards.
struct ColorSwatch: View {
    let hex: String

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(cellHex: hex) ?? .clear)
                .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(Color.secondary.opacity(0.4), lineWidth: 0.5) }
                .frame(width: 22, height: 14)
            Text(hex).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }
}

extension Color {
    /// From "#RRGGBB".
    init?(cellHex hex: String) {
        guard let normal = Value.parseColor(hex), let n = UInt32(normal.dropFirst(), radix: 16) else { return nil }
        self.init(.sRGB, red: Double(n >> 16 & 0xFF) / 255, green: Double(n >> 8 & 0xFF) / 255, blue: Double(n & 0xFF) / 255)
    }

    /// As "#RRGGBB" in sRGB.
    var hex: String? {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
}

/// A lookup's value, shown the way the looked-up field shows it: choices as chips, images as
/// thumbnails, numbers to the right, stars as stars.
struct LookupView: View {
    @ObservedObject var document: GolleDocument
    let field: Field
    let record: Record
    let resolver: Resolver
    /// In a table cell (one line, numbers to the right), or in a form.
    var inCell = true

    var body: some View {
        let target = resolver.lookupTarget(field)?.field
        let value = resolver.value(record, field)
        switch value {
        case .choices(let choices)? where target?.type.usesChoices == true:
            ChipsView(field: target!, choices: choices)
        case .attachments(let files)? where target?.type == .image:
            HStack(spacing: 2) {
                ForEach(files.prefix(inCell ? 3 : 8)) { attachment in
                    if let image = document.thumbnail(attachment, size: 64) {
                        let side: CGFloat = inCell ? 18 : 40
                        Image(nsImage: image).resizable().scaledToFill().frame(width: side, height: side).clipShape(.rect(cornerRadius: 3))
                    }
                }
            }
        case .rating(let stars)?:
            RatingView(rating: stars).font(.caption)
        case .bool(let on)?:
            Image(systemName: on ? "checkmark.square.fill" : "square").foregroundStyle(on ? Color.accentColor : .secondary)
        case .number?:
            Text(resolver.text(record, field)).monospacedDigit().lineLimit(1)
                .foregroundStyle(inCell ? .primary : .secondary)
                .frame(maxWidth: inCell ? .infinity : nil, alignment: .trailing)
        default:
            let text = resolver.text(record, field)
            if inCell {
                Text(text).lineLimit(1)
            } else {
                Text(text.isEmpty ? "—" : text).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}
