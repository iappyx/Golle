import AppKit

/// Formatted long text, stored as Markdown. The editor shows it formatted (bold, italic, strike,
/// code, links, headings, bullet and numbered lists); this converts both ways.
///
/// The subset: `# ` `## ` `### ` headings, `- ` bullets (shown as "•"), `1. ` numbers, `**bold**`,
/// `*italic*`, `~~strike~~`, `` `code` ``, `[text](url)`, and `\` to escape a mark.
enum Markdown {
    static let bodySize: CGFloat = NSFont.systemFontSize
    static let headingScale: [CGFloat] = [1.6, 1.35, 1.15]
    static let bullet = "• "

    // MARK: Markdown → formatted

    static func attributed(_ markdown: String, size: CGFloat = bodySize, color: NSColor = .textColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            var text = Substring(line)
            var fontSize = size
            var bold = false
            if let level = headingLevel(text) {
                text = text.dropFirst(level + 1)
                fontSize = size * headingScale[level - 1]
                bold = true
            } else if text.hasPrefix("- ") || text.hasPrefix("* ") {
                text = Substring(bullet) + text.dropFirst(2)
            }
            result.append(inline(String(text), size: fontSize, bold: bold, color: color))
            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color]))
            }
        }
        return result
    }

    private static func headingLevel(_ line: Substring) -> Int? {
        for level in [3, 2, 1] where line.hasPrefix(String(repeating: "#", count: level) + " ") { return level }
        return nil
    }

    struct Style: Equatable {
        var bold = false, italic = false, strike = false, code = false
        var link: String?
    }

    /// Inline marks within one line, as an attributed string.
    private static func inline(_ text: String, size: CGFloat, bold baseBold: Bool, color: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (piece, style) in runs(text) {
            var attrs = attributes(size: size, bold: style.bold || baseBold, italic: style.italic, strike: style.strike, code: style.code, color: color)
            if let link = style.link, let url = URL(string: link) { attrs[.link] = url }
            out.append(NSAttributedString(string: piece, attributes: attrs))
        }
        return out
    }

    /// Scans one line into text runs with their style. Shared by the editor and `plain`, so both read
    /// Markdown the same way.
    static func runs(_ text: String) -> [(String, Style)] {
        var out: [(String, Style)] = []
        var bold = false, italic = false, strike = false, code = false
        let chars = Array(text)
        var i = 0
        var run = ""

        func flush() {
            guard !run.isEmpty else { return }
            out.append((run, Style(bold: bold, italic: italic, strike: strike, code: code)))
            run = ""
        }
        func at(_ s: String) -> Bool {
            let mark = Array(s)
            return i + mark.count <= chars.count && Array(chars[i..<(i + mark.count)]) == mark
        }

        let escapable: Set<Character> = ["\\", "*", "_", "~", "`", "[", "]", "(", ")", "#", "-"]

        /// Whether a single `*` that could close italic comes later on the line.
        func closerAhead(from start: Int) -> Bool {
            var j = start
            while j < chars.count {
                if chars[j] == "\\" { j += 2; continue }
                if chars[j] == "*", !chars[j - 1].isWhitespace { return true }
                j += 1
            }
            return false
        }
        func find(_ s: String, from start: Int) -> Int? {
            let mark = Array(s)
            var j = start
            while j + mark.count <= chars.count {
                if Array(chars[j..<(j + mark.count)]) == mark { return j }
                j += 1
            }
            return nil
        }

        /// `[text](url)` at `start`: the text unescaped, the url with balanced brackets, and where it ends.
        func link(at start: Int) -> (String, String, Int)? {
            var j = start + 1
            var label = ""
            while j < chars.count, chars[j] != "]" {
                if chars[j] == "\\", j + 1 < chars.count, escapable.contains(chars[j + 1]) { label.append(chars[j + 1]); j += 2; continue }
                label.append(chars[j]); j += 1
            }
            guard j + 1 < chars.count, chars[j + 1] == "(" else { return nil }
            var depth = 0
            var k = j + 2
            var url = ""
            while k < chars.count {
                if chars[k] == "(" { depth += 1 }
                if chars[k] == ")" { if depth == 0 { return (label, url, k) }; depth -= 1 }
                url.append(chars[k]); k += 1
            }
            return nil
        }
        while i < chars.count {
            let c = chars[i]
            // Code: a run of backticks up to the next run of exactly as many. Inside, nothing is a
            // mark and backslashes are literal; one space just inside each fence is padding (so
            // code can start or end with a backtick).
            if c == "`" {
                var n = 0
                while i + n < chars.count, chars[i + n] == "`" { n += 1 }
                var j = i + n, close: Int?
                while j < chars.count {
                    guard chars[j] == "`" else { j += 1; continue }
                    var m = 0
                    while j + m < chars.count, chars[j + m] == "`" { m += 1 }
                    if m == n { close = j; break }
                    j += m
                }
                if let close {
                    flush()
                    var content = String(chars[(i + n)..<close])
                    if content.count >= 2, content.first == " ", content.last == " ", content.contains(where: { $0 != " " }) {
                        content = String(content.dropFirst().dropLast())
                    }
                    if !content.isEmpty { out.append((content, Style(bold: bold, italic: italic, strike: strike, code: true))) }
                    i = close + n
                    continue
                }
                // No closing fence: the backticks are text.
                run.append(contentsOf: chars[i..<(i + n)])
                i += n
                continue
            }
            if c == "\\", i + 1 < chars.count, escapable.contains(chars[i + 1]) {
                run.append(chars[i + 1]); i += 2; continue
            }
            if at("**") { flush(); bold.toggle(); i += 2; continue }
            if at("~~") { flush(); strike.toggle(); i += 2; continue }
            let prev = i > 0 ? chars[i - 1] : " ", next = i + 1 < chars.count ? chars[i + 1] : " "
            if c == "*" {
                // Works inside words (foo*bar*); a lone * (2 * 3, or with no partner) is text.
                if italic ? !prev.isWhitespace : (!next.isWhitespace && closerAhead(from: i + 1)) {
                    flush(); italic.toggle(); i += 1; continue
                }
            }
            if c == "_" {
                // Underscores only at word edges, so snake_case stays text.
                let opens = !italic && !next.isWhitespace && (prev.isWhitespace || prev.isPunctuation)
                let closes = italic && !prev.isWhitespace && (next.isWhitespace || next.isPunctuation)
                if opens || closes { flush(); italic.toggle(); i += 1; continue }
            }
            if c == "[", let (label, url, end) = link(at: i) {
                flush()
                out.append((label, Style(bold: bold, italic: italic, strike: strike, code: false, link: url)))
                i = end + 1
                continue
            }
            run.append(c)
            i += 1
        }

        flush()
        return out
    }

    static func attributes(size: CGFloat, bold: Bool, italic: Bool, strike: Bool, code: Bool, color: NSColor) -> [NSAttributedString.Key: Any] {
        var font = code ? NSFont.monospacedSystemFont(ofSize: size * 0.95, weight: bold ? .bold : .regular) : NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return attrs
    }

    // MARK: Formatted → Markdown

    static func markdown(_ text: NSAttributedString, baseSize: CGFloat = bodySize) -> String {
        let string = text.string as NSString
        var lines: [String] = []
        var location = 0
        while location <= string.length {
            let lineRange = string.lineRange(for: NSRange(location: location, length: 0))
            var contentRange = lineRange
            // Without the line break itself.
            while contentRange.length > 0, let last = string.substring(with: NSRange(location: NSMaxRange(contentRange) - 1, length: 1)).first, last.isNewline {
                contentRange.length -= 1
            }
            lines.append(line(text, range: contentRange, baseSize: baseSize))
            if NSMaxRange(lineRange) >= string.length {
                // A final line break means a final empty line.
                if lineRange.length > contentRange.length, NSMaxRange(lineRange) == string.length { lines.append("") }
                break
            }
            location = NSMaxRange(lineRange)
        }
        return lines.joined(separator: "\n")
    }

    private static func line(_ text: NSAttributedString, range: NSRange, baseSize: CGFloat) -> String {
        guard range.length > 0 else { return "" }
        let sub = text.attributedSubstring(from: range)
        var prefix = ""
        var body = NSAttributedString(attributedString: sub)
        // A heading: the line's text is bold and larger than body text.
        let firstFont = sub.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        var headingBold = false
        if let size = firstFont?.pointSize, size > baseSize * 1.08 {
            let level = size >= baseSize * 1.5 ? 1 : size >= baseSize * 1.25 ? 2 : 3
            prefix = String(repeating: "#", count: level) + " "
            headingBold = true
        } else if sub.string.hasPrefix(bullet) || sub.string.hasPrefix("•\t") {
            prefix = "- "
            body = sub.attributedSubstring(from: NSRange(location: 2, length: sub.length - 2))
        }
        var out = prefix

        // Open marks, in the order they opened. The parser toggles each mark on its own, so a run
        // that drops a mark closes just that one (**x*y**z* is "x" bold, "y" both, "z" italic;
        // closing and reopening italic around it would write ****, which reads as bold twice).
        // Code is the exception: inside it nothing is a mark, so it closes before any other mark
        // changes and opens last.
        var open: [String] = []
        var pending = ""
        var link: URL?
        var linkText = ""

        func set(_ wanted: [String]) {
            let isFence: (String) -> Bool = { $0.hasPrefix("`") }
            let fence = open.first(where: isFence), wantedFence = wanted.first(where: isFence)
            let others = open.filter { !isFence($0) }, wantedOthers = wanted.filter { !isFence($0) }
            if let fence, Set(others) != Set(wantedOthers) || wantedFence != fence {
                out += fence
                open.removeAll(where: isFence)
            }
            for mark in others.reversed() where !wantedOthers.contains(mark) {
                out += mark
                open.removeAll { $0 == mark }
            }
            for mark in wantedOthers where !open.contains(mark) {
                out += mark
                open.append(mark)
            }
            if let wantedFence, !open.contains(wantedFence) {
                out += wantedFence
                open.append(wantedFence)
            }
        }

        // The runs as Markdown sees them. Runs that differ only in what Markdown doesn't keep
        // (colour, from pasted code) are joined first: code split into several runs would
        // otherwise become several code spans back to back, which read as one with backticks in it.
        struct Piece { var text: String; var bold, italic, strike, code: Bool; var link: URL? }
        var pieces: [Piece] = []
        body.enumerateAttributes(in: NSRange(location: 0, length: body.length)) { attrs, r, _ in
            let font = attrs[.font] as? NSFont
            let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
            let piece = Piece(text: (body.string as NSString).substring(with: r),
                              bold: traits.contains(.boldFontMask) && !headingBold,
                              italic: traits.contains(.italicFontMask),
                              strike: (attrs[.strikethroughStyle] as? Int ?? 0) != 0,
                              code: font?.isFixedPitch == true || font?.fontName.lowercased().contains("mono") == true,
                              link: attrs[.link] as? URL ?? (attrs[.link] as? String).flatMap(URL.init(string:)))
            if var last = pieces.last, last.bold == piece.bold, last.italic == piece.italic, last.strike == piece.strike,
               last.code == piece.code, last.link == piece.link {
                last.text += piece.text
                pieces[pieces.count - 1] = last
            } else {
                pieces.append(piece)
            }
        }

        for piece in pieces {
            if piece.link != link {
                if let link { out += "[\(linkText)](\(linkAddress(link)))"; linkText = "" }
                link = piece.link
            }
            if link != nil { set([]); out += pending; pending = ""; linkText += escape(piece.text); continue }

            // In the order they open: bold outside italic outside strike. Code is written as a
            // whole span inside them.
            let wanted = [piece.bold ? "**" : nil, piece.italic ? "*" : nil, piece.strike ? "~~" : nil].compactMap { $0 }
            // Spaces (and tabs) at the edges of a run wait until the next text: marks that end
            // close before them and marks that start open after them, so "**bold **" doesn't happen.
            // (One test for whitespace throughout, or a character would be written twice.)
            let text = piece.text
            let leading = String(text.prefix { $0.isWhitespace })
            if leading.count == text.count { pending += text; continue }
            let trailing = String(String(text.reversed().prefix { $0.isWhitespace }).reversed())
            let core = String(text.dropFirst(leading.count).dropLast(trailing.count))
            if !pending.isEmpty || !leading.isEmpty { set(open.filter(wanted.contains)) }
            out += pending + leading
            pending = trailing
            set(wanted)
            out += piece.code ? codeSpan(core) : escape(core)
        }
        if let link { set([]); out += pending; pending = ""; out += "[\(linkText)](\(linkAddress(link)))" }
        set([])
        out += pending
        // Text that would read as a heading or a list mark stays text.
        if prefix.isEmpty, ["# ", "## ", "### ", "- ", "* "].contains(where: { out.hasPrefix($0) }) { out = "\\" + out }
        return out
    }

    /// Code between fences one backtick longer than any run of backticks inside it, padded with
    /// a space when it starts or ends with a backtick.
    private static func codeSpan(_ code: String) -> String {
        var longest = 0, current = 0
        for c in code {
            current = c == "`" ? current + 1 : 0
            longest = max(longest, current)
        }
        let fence = String(repeating: "`", count: longest + 1)
        let pad = code.hasPrefix("`") || code.hasSuffix("`") || (code.hasPrefix(" ") && code.hasSuffix(" ")) ? " " : ""
        return fence + pad + code + pad + fence
    }

    /// A link's address, with brackets encoded so the closing one is never mistaken for the end.
    private static func linkAddress(_ url: URL) -> String {
        url.absoluteString.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
    }

    /// Marks typed as text stay text. Only what the parser would read as a mark is escaped, so
    /// "2 * 3" and "snake_case" stay as they are.
    /// Each run is escaped on its own, so at its edges the neighbour is unknown (it may be a mark):
    /// a mark character there is always escaped.
    static func escape(_ s: String) -> String {
        let chars = Array(s)
        var out = ""
        for (i, c) in chars.enumerated() {
            let prev = i > 0 ? chars[i - 1] : " ", next = i + 1 < chars.count ? chars[i + 1] : " "
            let edge = i == 0 || i == chars.count - 1
            var needs = false
            switch c {
            case "\\", "`", "[", "]": needs = true
            case "~": needs = next == "~" || prev == "~"
            case "*":
                // A star can open or close italic unless it stands alone between spaces.
                needs = !(prev.isWhitespace && next.isWhitespace)
            case "_":
                // A character after it that gets a backslash looks like punctuation to the parser.
                let nextEscaped = "`\\[]~*_".contains(next)
                let paired = next == c || prev == c || nextEscaped
                let opens = !next.isWhitespace && (prev.isWhitespace || prev.isPunctuation)
                let closes = !prev.isWhitespace && (next.isWhitespace || next.isPunctuation)
                needs = paired || opens || closes
            default: break
            }
            if edge, "*_~".contains(c) { needs = true }
            if needs { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// The text without marks, for tables, cards and search. Scans the characters only, which is far
    /// quicker than building formatted text (it runs for every record when searching).
    static func plain(_ markdown: String) -> String {
        guard markdown.contains(where: { "*_~`[#-\\".contains($0) }) else { return markdown }
        return markdown.split(separator: "\n", omittingEmptySubsequences: false).map { raw -> String in
            var line = Substring(raw)
            var prefix = ""
            if let level = headingLevel(line) { line = line.dropFirst(level + 1) }
            else if line.hasPrefix("- ") || line.hasPrefix("* ") { line = line.dropFirst(2); prefix = bullet }
            return prefix + runs(String(line)).map(\.0).joined()
        }.joined(separator: "\n")
    }
}
