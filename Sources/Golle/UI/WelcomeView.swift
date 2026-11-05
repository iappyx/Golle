import AppKit
import SwiftUI

/// Shown when Golle starts without a document: recent databases, templates, New and Open.
struct WelcomeView: View {
    @State private var recents: [URL] = []

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 110, height: 110)
                Text("Golle").font(.largeTitle.bold())
                Text("Your own databases, your way.").foregroundStyle(.secondary)
                Spacer().frame(height: 6)
                VStack(alignment: .leading, spacing: 8) {
                    action("New Database", "plus.rectangle.on.rectangle") { WelcomeController.newDocument(nil) }
                    action("Open…", "folder") {
                        WelcomeController.close()
                        NSDocumentController.shared.openDocument(nil)
                    }
                }
                Spacer()
            }
            .padding(28)
            .frame(width: 280)
            .frame(maxHeight: .infinity)
            .background(.background.secondary)

            VStack(alignment: .leading, spacing: 14) {
                if !recents.isEmpty {
                    Text("Recent").font(.headline)
                    VStack(spacing: 2) {
                        ForEach(recents.prefix(6), id: \.self) { url in
                            Button { open(url) } label: {
                                HStack(spacing: 10) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 28, height: 28)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(url.deletingPathExtension().lastPathComponent).lineLimit(1)
                                        Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .help(url.path)
                        }
                    }
                }
                Text("Start from a Template").font(.headline)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                        ForEach(Template.all) { template in
                            Button { WelcomeController.newDocument(template.make()) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Image(systemName: template.symbol)
                                        .font(.system(size: 20))
                                        .foregroundStyle(.white)
                                        .frame(width: 38, height: 38)
                                        .background(template.accent.color.gradient, in: .rect(cornerRadius: 8))
                                    Text(template.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Text(template.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
                                .padding(10)
                                .background(.background.secondary, in: .rect(cornerRadius: 10))
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 820, height: 520)
        .onAppear {
            recents = NSDocumentController.shared.recentDocumentURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    private func action(_ title: String, _ symbol: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading)
        }
        .controlSize(.large)
        .frame(width: 200)
    }

    private func open(_ url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSAlert(error: error).runModal() }
        }
        WelcomeController.close()
    }
}

/// The welcome window, managed here rather than as a SwiftUI scene: at launch SwiftUI shows an Open
/// panel (or an empty document) when nothing is restored, and this replaces that with the welcome
/// window.
@MainActor
enum WelcomeController {
    private static var window: NSWindow?
    /// The database the next new document starts with (a template); read once by the DocumentGroup.
    static var pendingDatabase: Database?

    static func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: WelcomeView())
            let w = NSWindow(contentViewController: hosting)
            w.title = "Welcome to Golle"
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    static func close() {
        window?.close()
    }

    /// A new document, blank or from a template.
    static func newDocument(_ database: Database?) {
        pendingDatabase = database
        NSDocumentController.shared.newDocument(nil)
        close()
    }

    /// At launch: when no real document opened, show the welcome window instead of the Open panel
    /// or the empty document.
    static func launch() {
        let documents = NSDocumentController.shared.documents
        // Only macOS's own launch document: exactly one, untitled, untouched. A document the user
        // made or opened in the meantime is left alone (and then no welcome window is needed).
        if documents.count > 1 || documents.contains(where: { $0.fileURL != nil || $0.isDocumentEdited }) { return }
        if NSApp.windows.contains(where: { $0.attachedSheet != nil }) { return }
        for window in NSApp.windows where window is NSOpenPanel { (window as? NSOpenPanel)?.cancel(nil) }
        documents.forEach { $0.close() }
        switch Preferences.atLaunch {
        case .welcome:
            show()
        case .nothing:
            break
        case .reopen:
            // Those that still exist; with none left, the welcome window as usual.
            let urls = Preferences.openAtQuit.filter { FileManager.default.fileExists(atPath: $0.path) }
            if urls.isEmpty { show(); return }
            for url in urls {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    /// Notes which databases are open, for "Reopen the databases that were open" next time.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Preferences.openAtQuit = NSDocumentController.shared.documents.compactMap(\.fileURL)
        return .terminateNow
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // After SwiftUI has restored documents or put up its launch panel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { MainActor.assumeIsolated { WelcomeController.launch() } }
    }

    /// Clicking the Dock icon with no windows open shows the welcome window.
    /// Minimised windows are restored as usual.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if hasVisibleWindows || sender.windows.contains(where: \.isMiniaturized) { return true }
        MainActor.assumeIsolated { WelcomeController.show() }
        return false
    }
}
