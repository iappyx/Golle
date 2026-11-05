import AppKit
import SwiftUI

/// Long text you format as you type: bold, italic, strike, code, headings, lists and links.
/// The field stores Markdown (see `Markdown`), so it stays readable and exports cleanly.
struct RichTextEditor: View {
    @Binding var markdown: String
    var minHeight: CGFloat = 90
    @State private var controller = RichTextController()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                button("bold", "Bold (⌘B)") { controller.toggle(.boldFontMask) }
                button("italic", "Italic (⌘I)") { controller.toggle(.italicFontMask) }
                button("strikethrough", "Strikethrough") { controller.toggleStrike() }
                button("chevron.left.forwardslash.chevron.right", "Code") { controller.toggleCode() }
                Divider().frame(height: 14)
                Menu {
                    Button("Heading 1") { controller.setHeading(1) }
                    Button("Heading 2") { controller.setHeading(2) }
                    Button("Heading 3") { controller.setHeading(3) }
                    Button("Body Text") { controller.setHeading(0) }
                } label: {
                    Image(systemName: "textformat.size")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Heading")
                button("list.bullet", "Bulleted list") { controller.toggleList(numbered: false) }
                button("list.number", "Numbered list") { controller.toggleList(numbered: true) }
                button("link", "Link") { controller.addLink() }
                Spacer()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            RichTextView(markdown: $markdown, controller: controller)
                .frame(minHeight: minHeight)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 5))
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.25)) }
        }
    }

    private func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 20, height: 18) }.help(help)
    }
}

/// Formatting commands for the text view the toolbar belongs to.
final class RichTextController {
    weak var textView: NSTextView?
    var onChange: (() -> Void)?

    private var base: CGFloat { Markdown.bodySize }

    /// Bold or italic on the selection (or for what is typed next). Removes it when all of the
    /// selection already has it.
    func toggle(_ trait: NSFontTraitMask) {
        guard let view = textView, let storage = view.textStorage else { return }
        let range = view.selectedRange()
        let manager = NSFontManager.shared
        if range.length == 0 {
            let font = view.typingAttributes[.font] as? NSFont ?? .systemFont(ofSize: base)
            let has = manager.traits(of: font).contains(trait)
            view.typingAttributes[.font] = has ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
            return
        }
        var all = true
        storage.enumerateAttribute(.font, in: range) { value, _, _ in
            if let font = value as? NSFont, !manager.traits(of: font).contains(trait) { all = false }
        }
        edit(range) {
            storage.enumerateAttribute(.font, in: range) { value, r, _ in
                let font = value as? NSFont ?? .systemFont(ofSize: self.base)
                storage.addAttribute(.font, value: all ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait), range: r)
            }
        }
    }

    func toggleStrike() {
        guard let view = textView, let storage = view.textStorage else { return }
        let range = view.selectedRange()
        guard range.length > 0 else {
            let on = (view.typingAttributes[.strikethroughStyle] as? Int ?? 0) != 0
            view.typingAttributes[.strikethroughStyle] = on ? 0 : NSUnderlineStyle.single.rawValue
            return
        }
        let on = (storage.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil) as? Int ?? 0) != 0
        edit(range) {
            if on { storage.removeAttribute(.strikethroughStyle, range: range) }
            else { storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
        }
    }

    func toggleCode() {
        guard let view = textView, let storage = view.textStorage else { return }
        let range = view.selectedRange()
        guard range.length > 0 else { return }
        let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        let isCode = font?.isFixedPitch == true
        edit(range) {
            storage.addAttribute(.font, value: isCode ? NSFont.systemFont(ofSize: self.base) : NSFont.monospacedSystemFont(ofSize: self.base * 0.95, weight: .regular), range: range)
        }
    }

    /// Level 1–3 makes the selected lines headings; 0 makes them body text.
    func setHeading(_ level: Int) {
        guard let view = textView, let storage = view.textStorage else { return }
        let lines = (storage.string as NSString).paragraphRange(for: view.selectedRange())
        let size = level == 0 ? base : base * Markdown.headingScale[level - 1]
        edit(lines) {
            storage.enumerateAttribute(.font, in: lines) { value, r, _ in
                let font = value as? NSFont ?? .systemFont(ofSize: self.base)
                let traits = NSFontManager.shared.traits(of: font)
                let wasHeading = font.pointSize > self.base * 1.08
                // Bold stays bold in body text unless it only came from the heading; code stays code.
                let bold = level > 0 || (traits.contains(.boldFontMask) && !wasHeading)
                var new = font.isFixedPitch
                    ? NSFont.monospacedSystemFont(ofSize: size * 0.95, weight: bold ? .bold : .regular)
                    : NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
                if traits.contains(.italicFontMask) { new = NSFontManager.shared.convert(new, toHaveTrait: .italicFontMask) }
                storage.addAttribute(.font, value: new, range: r)
            }
        }
        view.typingAttributes[.font] = NSFont.systemFont(ofSize: size, weight: level == 0 ? .regular : .bold)
    }

    /// Adds or removes "• " (or "1. ", "2. ", …) in front of each selected line.
    func toggleList(numbered: Bool) {
        guard let view = textView, let storage = view.textStorage else { return }
        let string = storage.string as NSString
        let lines = string.paragraphRange(for: view.selectedRange())
        var starts: [Int] = []
        string.enumerateSubstrings(in: lines, options: [.byParagraphs, .substringNotRequired]) { _, r, _, _ in starts.append(r.location) }
        if starts.isEmpty { starts = [lines.location] }
        let pattern = numbered ? #"^\d+\. "# : "^• "
        let allListed = starts.allSatisfy { start in
            let line = string.substring(from: start)
            return line.range(of: pattern, options: .regularExpression) != nil
        }
        edit(lines) {
            // From the end, so earlier positions stay valid.
            for (index, start) in starts.enumerated().reversed() {
                let line = (storage.string as NSString).substring(from: start)
                if allListed {
                    if let match = line.range(of: pattern, options: .regularExpression) {
                        storage.replaceCharacters(in: NSRange(location: start, length: line.distance(from: match.lowerBound, to: match.upperBound)), with: "")
                    }
                } else if line.range(of: pattern, options: .regularExpression) == nil {
                    let mark = numbered ? "\(index + 1). " : Markdown.bullet
                    storage.insert(NSAttributedString(string: mark, attributes: Markdown.attributes(size: self.base, bold: false, italic: false, strike: false, code: false, color: .textColor)), at: start)
                }
            }
        }
    }

    func addLink() {
        guard let view = textView, let storage = view.textStorage else { return }
        let range = view.selectedRange()
        let alert = NSAlert()
        alert.messageText = "Add Link"
        alert.informativeText = range.length > 0 ? "Link the selected text to:" : "Web address:"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "https://"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var address = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { return }
        if !address.contains("://") && !address.hasPrefix("mailto:") { address = "https://" + address }
        guard let url = URL(string: address) else { return }
        if range.length == 0 {
            let text = NSAttributedString(string: address, attributes: [.font: NSFont.systemFont(ofSize: base), .link: url])
            edit(NSRange(location: range.location, length: 0)) { storage.insert(text, at: range.location) }
        } else {
            edit(range) { storage.addAttribute(.link, value: url, range: range) }
        }
    }

    private func edit(_ range: NSRange, _ body: () -> Void) {
        guard let view = textView, let storage = view.textStorage else { return }
        guard view.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        body()
        storage.endEditing()
        view.didChangeText()
        onChange?()
    }
}

/// The AppKit text view behind the editor.
struct RichTextView: NSViewRepresentable {
    @Binding var markdown: String
    let controller: RichTextController

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let text = FormattingTextView()
        text.controller = controller
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text
        // Keep filling the editor when it is resized.
        scroll.contentView.postsFrameChangedNotifications = true
        context.coordinator.frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak scroll, weak text] _ in
            guard let scroll, let text else { return }
            text.minSize = NSSize(width: 0, height: scroll.contentSize.height)
            text.frame.size.height = max(text.frame.height, scroll.contentSize.height)
        }
        text.isRichText = true
        text.importsGraphics = false
        // Undo is the document's: one step per editing burst, like every other field.
        text.allowsUndo = false
        text.drawsBackground = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticLinkDetectionEnabled = true
        text.font = .systemFont(ofSize: Markdown.bodySize)
        text.textContainerInset = NSSize(width: 2, height: 4)
        text.delegate = context.coordinator
        text.textStorage?.setAttributedString(Markdown.attributed(markdown))
        text.typingAttributes = Markdown.attributes(size: Markdown.bodySize, bold: false, italic: false, strike: false, code: false, color: .textColor)
        context.coordinator.last = markdown
        context.coordinator.textView = text
        controller.textView = text
        controller.onChange = { [weak coordinator = context.coordinator] in coordinator?.edited() }
        return scroll
    }

    /// The editor goes away (another record, another view): save anything not saved yet.
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.commit()
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        // The toolbar's controller can be new after SwiftUI rebuilt the editor's state: reconnect it.
        if let text = scroll.documentView as? FormattingTextView, controller.textView !== text {
            controller.textView = text
            text.controller = controller
            controller.onChange = { [weak coordinator = context.coordinator] in coordinator?.edited() }
        }
        // The text view fills the editor, so a click below a short text still puts the cursor in it.
        if let text = scroll.documentView as? NSTextView, text.minSize.height != scroll.contentSize.height {
            text.minSize = NSSize(width: 0, height: scroll.contentSize.height)
            text.frame.size.height = max(text.frame.height, scroll.contentSize.height)
        }
        // A change from elsewhere (undo, another window): show it. Our own edits are already shown.
        guard markdown != context.coordinator.last, let text = scroll.documentView as? NSTextView else { return }
        // While typing, SwiftUI can pass a value from a keystroke ago (an older update arriving
        // late). Showing it would undo that keystroke and move the cursor; it is skipped.
        if context.coordinator.isEcho(markdown) { return }
        context.coordinator.dirty = false
        let selection = text.selectedRange()
        text.textStorage?.setAttributedString(Markdown.attributed(markdown))
        text.setSelectedRange(NSRange(location: min(selection.location, text.string.utf16.count), length: 0))
        context.coordinator.last = markdown
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextView
        var last = ""
        /// Whether the text was edited here since it was last saved or loaded. Only then is it
        /// written back: Markdown typed elsewhere (an import) may be written differently by the
        /// editor, and merely looking at a record mustn't change it.
        var dirty = false
        var frameObserver: NSObjectProtocol?
        /// The text view itself, so saving never depends on the toolbar's controller.
        weak var textView: NSTextView?

        var undoObserver: NSObjectProtocol?

        deinit {
            frameObserver.map(NotificationCenter.default.removeObserver)
            undoObserver.map(NotificationCenter.default.removeObserver)
        }

        init(_ parent: RichTextView) {
            self.parent = parent
            super.init()
            undoObserver = NotificationCenter.default.addObserver(forName: .golleUndoRedo, object: nil, queue: nil) { [weak self] _ in
                // What comes next is an undo or redo, not a late copy: show it, even if it looks
                // like one. Copies of the typing from before it are still skipped after it.
                self?.undoneAt = Date()
            }
        }

        func textDidChange(_ notification: Notification) { edited() }

        func textDidEndEditing(_ notification: Notification) { commit() }

        /// Saved right away, like the other fields (they share one undo step while typing), so
        /// closing the window or quitting just after typing loses nothing.
        func edited() {
            dirty = true
            commit()
        }

        func commit() {
            guard dirty else { return }
            dirty = false
            guard let text = textView ?? parent.controller.textView else { return }
            let markdown = Markdown.markdown(text.attributedString())
            guard markdown != last else { return }
            // The text from before this keystroke can come back late too.
            sent = Array((sent + [last, markdown]).suffix(8))
            last = markdown
            sentAt = Date()
            parent.markdown = markdown
        }

        /// Values saved from here in the last moment.
        var sent: [String] = []
        var undoneAt = Date.distantPast
        private var sentAt = Date.distantPast

        /// Whether a value is one this editor had a moment ago, coming back late (within
        /// milliseconds). An undo or redo clears the list, so its value is always shown.
        func isEcho(_ markdown: String) -> Bool {
            if Date().timeIntervalSince(undoneAt) < 0.3 {
                // The undo's own value: shown, and no longer counted as one of ours.
                undoneAt = .distantPast
                sent.removeAll { $0 == markdown }
                sentAt = Date()
                return false
            }
            return Date().timeIntervalSince(sentAt) < 0.3 && sent.dropLast().contains(markdown)
        }

        /// Return continues a list; Return on an empty list line ends it. After a heading, the next
        /// line is body text.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let string = textView.string as NSString
            let cursor = textView.selectedRange().location
            let lineRange = string.lineRange(for: NSRange(location: cursor, length: 0))
            let line = string.substring(with: lineRange).trimmingCharacters(in: .newlines)
            let body = Markdown.attributes(size: Markdown.bodySize, bold: false, italic: false, strike: false, code: false, color: .textColor)
            var mark: String?
            if line.hasPrefix(Markdown.bullet) { mark = Markdown.bullet }
            else if let match = line.range(of: #"^\d+\. "#, options: .regularExpression), let n = Int(line[match].dropLast(2)) { mark = "\(n + 1). " }
            if let mark {
                let bare = line.replacingOccurrences(of: #"^(• |\d+\. )"#, with: "", options: .regularExpression)
                if bare.trimmingCharacters(in: .whitespaces).isEmpty {
                    // An empty item ends the list.
                    let markLength = (line as NSString).length - (bare as NSString).length
                    textView.insertText("", replacementRange: NSRange(location: lineRange.location, length: markLength))
                    return true
                }
                textView.insertText(NSAttributedString(string: "\n" + mark, attributes: body), replacementRange: textView.selectedRange())
                return true
            }
            if let font = textView.typingAttributes[.font] as? NSFont, font.pointSize > Markdown.bodySize * 1.08 {
                textView.insertText(NSAttributedString(string: "\n", attributes: body), replacementRange: textView.selectedRange())
                textView.typingAttributes = body
                return true
            }
            return false
        }
    }
}

/// ⌘B, ⌘I and ⌘U while typing, handled by the text view itself so several editors on one form
/// don't fight over the shortcut.
final class FormattingTextView: NSTextView {
    weak var controller: RichTextController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else { return super.performKeyEquivalent(with: event) }
        switch key {
        case "b": controller?.toggle(.boldFontMask); return true
        case "i": controller?.toggle(.italicFontMask); return true
        case "u": controller?.toggleStrike(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
}
