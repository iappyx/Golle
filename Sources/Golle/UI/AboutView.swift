import SwiftUI

/// Golle ▸ About Golle: icon, name, version, what it is, who made it, and the license.
struct AboutView: View {
    @State private var showingLicense = false
    @State private var showingAcknowledgements = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? "Version \(short)" : "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Golle").font(.system(size: 22, weight: .semibold))
            Text(version).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            Text("A free personal database for your Mac.")
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            Text("Local only · no accounts · no telemetry")
                .font(.caption)
                .foregroundStyle(.tertiary)
            HStack(spacing: 4) {
                Text("© 2026 iappyx")
                Text("·")
                Link("iappyx.github.io", destination: URL(string: "https://iappyx.github.io/")!)
            }
            .font(.callout)
            .padding(.top, 10)
            Text("Released under the MIT License.").font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("License") { showingLicense = true }
                Button("Acknowledgements") { showingAcknowledgements = true }
            }
            .controlSize(.small)
            .padding(.top, 10)
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 40)
        .frame(width: 420)
        .sheet(isPresented: $showingLicense) {
            LicenseSheet(title: "MIT License", text: Self.bundledText("LICENSE"))
        }
        .sheet(isPresented: $showingAcknowledgements) {
            AcknowledgementsSheet()
        }
    }

    static func bundledText(_ name: String) -> String {
        Bundle.main.url(forResource: name, withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? "Copyright (c) 2026 iappyx. Released under the MIT License."
    }
}

/// Golle has no third-party code; these are the services it can ask for data, and what they get.
private struct AcknowledgementsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let sources: [(name: String, detail: String, url: String)] = [
        ("Open Library", "Book details and covers, found by ISBN when you scan or type one. Only the code is sent.", "https://openlibrary.org"),
        ("MusicBrainz", "Album details, found by barcode. Its data is free to use (CC0). Only the code is sent.", "https://musicbrainz.org"),
        ("Cover Art Archive", "Album covers for MusicBrainz releases.", "https://coverartarchive.org"),
        ("Apple Maps", "Finding places for Location fields, through Apple's MapKit.", "https://www.apple.com/maps/"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Acknowledgements").font(.headline)
            Text("Golle is built only on Apple's own frameworks; it contains no third-party code. Lookups use these services, only when you ask for one:")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(sources, id: \.name) { source in
                VStack(alignment: .leading, spacing: 2) {
                    Link(source.name, destination: URL(string: source.url)!).font(.callout.weight(.medium))
                    Text(source.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

private struct LicenseSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            ScrollView {
                Text(LicenseText.reflow(text)).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 420)
    }
}

/// License files are wrapped at about 80 columns; shown in a narrower window those breaks land
/// mid-sentence. Joins the lines of each paragraph so the text wraps to the window. Blank lines,
/// list items, copyright lines and lines after a short line (headings) keep their own line.
enum LicenseText {
    static func reflow(_ text: String) -> String {
        var paragraphs: [String] = []
        var current = ""
        var previous = ""
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !current.isEmpty { paragraphs.append(current) }
                current = ""
            } else if current.isEmpty {
                current = line
            } else if previous.count < 40 || startsOwnLine(line) {
                current += "\n" + line
            } else {
                current += " " + line
            }
            previous = line
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs.joined(separator: "\n\n")
    }

    private static func startsOwnLine(_ line: String) -> Bool {
        line.range(of: #"^([-*•·]|\(?[0-9A-Za-z]{1,3}[.)])\s"#, options: .regularExpression) != nil
            || line.hasPrefix("Copyright") || line.hasPrefix("©")
    }
}
