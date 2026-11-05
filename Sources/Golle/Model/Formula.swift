import Foundation

/// A small spreadsheet-like formula language for computed fields.
///
///     {Price} * {Quantity}
///     IF({Rating} >= 4, "Favourite", "")
///     {First name} & " " & {Last name}
///     DAYS(TODAY(), {Bought})
///     SUM(LOOKUP({Tracks}, "Length"))
///
/// Fields are referenced by name in braces. Operators: + - * / ^, & (join text), = <> < > <= >=.
/// Functions are listed in `Formula.functions`.
enum Formula {
    typealias Result = Swift.Result<Expression, ParseError>

    struct ParseError: Error, Equatable {
        var message: String
    }

    indirect enum Expression: Equatable {
        case number(Double)
        case text(String)
        case field(String)
        case call(String, [Expression])
        case unary(String, Expression)
        case binary(String, Expression, Expression)
    }

    /// A formula's intermediate and final values.
    enum Item: Equatable {
        case number(Double)
        case text(String)
        case bool(Bool)
        case date(Date)
        case list([Item])
        case empty
        case error(String)

        var value: Value? {
            switch self {
            case .number(let n): n.isFinite ? .number(n) : nil
            case .text(let s): s.isEmpty ? nil : .text(s)
            case .bool(let b): .bool(b)
            case .date(let d): .date(d)
            case .list(let items): items.isEmpty ? nil : .text(items.map(\.string).filter { !$0.isEmpty }.joined(separator: ", "))
            case .empty, .error: nil
            }
        }

        var number: Double? {
            switch self {
            case .number(let n): n
            case .bool(let b): b ? 1 : 0
            case .empty: 0
            case .text(let s): Value.parseNumber(s)
            case .date(let d): d.timeIntervalSince1970 / 86_400
            case .list(let l): l.count == 1 ? l[0].number : nil
            case .error: nil
            }
        }

        var string: String {
            switch self {
            case .number(let n): Value.numberFormatter.string(from: n as NSNumber) ?? String(n)
            case .text(let s): s
            case .bool(let b): b ? "TRUE" : "FALSE"
            case .date(let d): d.formatted(date: .abbreviated, time: .omitted)
            case .list(let l): l.map(\.string).joined(separator: ", ")
            case .empty, .error: ""
            }
        }

        var truthy: Bool {
            switch self {
            case .bool(let b): b
            case .number(let n): n != 0
            case .text(let s): !s.isEmpty
            case .date: true
            case .list(let l): !l.isEmpty
            case .empty, .error: false
            }
        }

        var flattened: [Item] {
            if case .list(let l) = self { return l.flatMap(\.flattened) }
            return [self]
        }

        init(_ value: Value?) {
            switch value {
            case nil: self = .empty
            case .text(let s)?: self = .text(s)
            case .number(let n)?: self = .number(n)
            case .date(let d)?: self = .date(d)
            case .bool(let b)?: self = .bool(b)
            case .rating(let r)?: self = .number(Double(r))
            case .choices(let c)?: self = c.count == 1 ? .text(c[0]) : .list(c.map(Item.text))
            case .attachments(let a)?: self = .list(a.map { .text($0.name) })
            case .links(let l)?: self = .list(l.map { .text($0.uuidString) })
            case .location(let p)?: self = .text(p.name.isEmpty ? Value.coordinates(p) : p.name)
            case .checklist(let items)?: self = .list(items.map { .text($0.text) })
            }
        }
    }

    struct Context {
        let resolver: Resolver
        let record: Record
    }

    // MARK: Parsing

    static func parse(_ source: String) -> Result {
        do {
            var parser = Parser(tokens: try tokenize(source))
            if parser.tokens.isEmpty { return .success(.text("")) }
            let expression = try parser.comparison()
            if parser.position < parser.tokens.count {
                throw ParseError(message: "Unexpected \(parser.tokens[parser.position].description)")
            }
            return .success(expression)
        } catch let error as ParseError {
            return .failure(error)
        } catch {
            return .failure(ParseError(message: "\(error)"))
        }
    }

    enum Token: Equatable {
        case number(Double), text(String), field(String), name(String), symbol(String)

        var description: String {
            switch self {
            case .number(let n): Value.plain(n)
            case .text(let s): "\"\(s)\""
            case .field(let f): "{\(f)}"
            case .name(let n): n
            case .symbol(let s): "“\(s)”"
            }
        }
    }

    static func tokenize(_ source: String) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(source)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                var j = i
                while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
                guard let n = Double(String(chars[i..<j])) else { throw ParseError(message: "Bad number \(String(chars[i..<j]))") }
                tokens.append(.number(n))
                i = j
            } else if c == "\"" || c == "“" || c == "”" {
                var j = i + 1
                var text = ""
                while j < chars.count, !(chars[j] == "\"" || chars[j] == "”" || chars[j] == "“") {
                    text.append(chars[j]); j += 1
                }
                guard j < chars.count else { throw ParseError(message: "Text is missing its closing quote") }
                tokens.append(.text(text))
                i = j + 1
            } else if c == "{" {
                guard let end = chars[(i + 1)...].firstIndex(of: "}") else { throw ParseError(message: "Field name is missing its closing }") }
                tokens.append(.field(String(chars[(i + 1)..<end]).trimmingCharacters(in: .whitespaces)))
                i = end + 1
            } else if c.isLetter || c == "_" {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                tokens.append(.name(String(chars[i..<j]).uppercased()))
                i = j
            } else {
                let two = i + 1 < chars.count ? String(chars[i...(i + 1)]) : ""
                if ["<=", ">=", "<>", "!=", "=="].contains(two) {
                    tokens.append(.symbol(two == "!=" ? "<>" : two == "==" ? "=" : two))
                    i += 2
                } else if "+-*/^&=<>(),;≠≤≥×÷".contains(c) {
                    let map: [Character: String] = ["≠": "<>", "≤": "<=", "≥": ">=", "×": "*", "÷": "/", ";": ","]
                    tokens.append(.symbol(map[c] ?? String(c)))
                    i += 1
                } else {
                    throw ParseError(message: "Unexpected character “\(c)”")
                }
            }
        }
        return tokens
    }

    struct Parser {
        let tokens: [Token]
        var position = 0

        mutating func take(_ symbol: String) -> Bool {
            if position < tokens.count, tokens[position] == .symbol(symbol) { position += 1; return true }
            return false
        }

        mutating func comparison() throws -> Expression {
            var left = try concatenation()
            while let op = ["=", "<>", "<", ">", "<=", ">="].first(where: { take($0) }) {
                left = .binary(op, left, try concatenation())
            }
            return left
        }

        mutating func concatenation() throws -> Expression {
            var left = try additive()
            while take("&") { left = .binary("&", left, try additive()) }
            return left
        }

        mutating func additive() throws -> Expression {
            var left = try multiplicative()
            while let op = ["+", "-"].first(where: { take($0) }) { left = .binary(op, left, try multiplicative()) }
            return left
        }

        mutating func multiplicative() throws -> Expression {
            var left = try power()
            while let op = ["*", "/"].first(where: { take($0) }) { left = .binary(op, left, try power()) }
            return left
        }

        mutating func power() throws -> Expression {
            let base = try unary()
            if take("^") { return .binary("^", base, try power()) }
            return base
        }

        mutating func unary() throws -> Expression {
            if take("-") { return .unary("-", try unary()) }
            if take("+") { return try unary() }
            return try primary()
        }

        mutating func primary() throws -> Expression {
            guard position < tokens.count else { throw ParseError(message: "The formula ends too soon") }
            let token = tokens[position]
            position += 1
            switch token {
            case .number(let n): return .number(n)
            case .text(let s): return .text(s)
            case .field(let f): return .field(f)
            case .name(let name):
                if name == "TRUE" { return .call("TRUE", []) }
                if name == "FALSE" { return .call("FALSE", []) }
                guard take("(") else { throw ParseError(message: "\(name) needs brackets, like \(name)(…). Fields go in braces: {\(name.capitalized)}") }
                guard Formula.functions[name] != nil else { throw ParseError(message: "Unknown function \(name)") }
                var args: [Expression] = []
                if !take(")") {
                    repeat { args.append(try comparison()) } while take(",")
                    guard take(")") else { throw ParseError(message: "Missing ) after \(name)") }
                }
                return .call(name, args)
            case .symbol("("):
                let inner = try comparison()
                guard take(")") else { throw ParseError(message: "Missing )") }
                return inner
            case .symbol(let s):
                throw ParseError(message: "Unexpected “\(s)”")
            }
        }
    }

    // MARK: Evaluation

    static func evaluate(_ expression: Expression, context: Context) -> Item {
        switch expression {
        case .number(let n): return .number(n)
        case .text(let s): return .text(s)
        case .field(let name):
            let table = context.resolver.table
            guard let field = table.field(named: name) else { return .error("No field named {\(name)}") }
            if field.type == .link {
                let linked = context.resolver.linkedRecords(context.record, field)
                return .list(linked.map { .text($0.table.title(of: $0.record)) })
            }
            let computed = field.type == .formula ? context.resolver.formulaValue(context.record, field) : Resolver.Computed(value: context.resolver.value(context.record, field))
            if let error = computed.error { return .error(error) }
            return Item(computed.value)
        case .unary(_, let inner):
            let value = evaluate(inner, context: context)
            if case .error = value { return value }
            guard let n = value.number else { return .error("Can't make “\(value.string)” negative") }
            return .number(-n)
        case .binary(let op, let l, let r):
            let a = evaluate(l, context: context), b = evaluate(r, context: context)
            if case .error = a { return a }
            if case .error = b { return b }
            return binary(op, a, b)
        case .call(let name, let args):
            // IF evaluates only the branch it takes.
            if name == "IF" {
                guard args.count == 2 || args.count == 3 else { return .error("IF needs a condition and one or two results") }
                let condition = evaluate(args[0], context: context)
                if case .error = condition { return condition }
                if condition.truthy { return evaluate(args[1], context: context) }
                return args.count == 3 ? evaluate(args[2], context: context) : .empty
            }
            if name == "LOOKUP" {
                guard args.count == 2, case .field(let linkName) = args[0] else { return .error("LOOKUP needs a link field and a field name: LOOKUP({Link}, \"Field\")") }
                let fieldName = evaluate(args[1], context: context).string
                guard let link = context.resolver.table.field(named: linkName), link.type == .link else { return .error("{\(linkName)} is not a link field") }
                var items: [Item] = []
                for (table, record) in context.resolver.linkedRecords(context.record, link) {
                    let other = context.resolver.resolver(for: table)
                    guard let field = table.field(named: fieldName) else { return .error("\(table.name) has no field “\(fieldName)”") }
                    // Through the resolver, so formulas and created/modified dates are looked up too.
                    // A linked formula's error is passed on, not turned into an empty value.
                    if field.type == .link {
                        // Linked records by name, as {Link} gives them.
                        items += other.linkedRecords(record, field).map { .text($0.table.title(of: $0.record)) }
                    } else if field.type == .formula {
                        let computed = other.formulaValue(record, field)
                        if let error = computed.error { return .error(error) }
                        items.append(Item(computed.value))
                    } else {
                        items.append(Item(other.value(record, field)))
                    }
                }
                return .list(items)
            }
            let values = args.map { evaluate($0, context: context) }
            if let error = values.first(where: { if case .error = $0 { true } else { false } }) { return error }
            guard let function = functions[name] else { return .error("Unknown function \(name)") }
            return function(values)
        }
    }

    static func binary(_ op: String, _ a: Item, _ b: Item) -> Item {
        switch op {
        case "&": return .text(a.string + b.string)
        case "=", "<>", "<", ">", "<=", ">=":
            let order = compare(a, b)
            let result: Bool = switch op {
            case "=": order == .orderedSame
            case "<>": order != .orderedSame
            case "<": order == .orderedAscending
            case ">": order == .orderedDescending
            case "<=": order != .orderedDescending
            default: order != .orderedAscending
            }
            return .bool(result)
        default:
            // Dates: date − date is days; date ± number moves by days.
            if case .date(let x) = a {
                if case .date(let y) = b, op == "-" { return .number((x.timeIntervalSince(y) / 86_400).rounded()) }
                if let n = b.number, op == "+" || op == "-" {
                    guard let days = Formula.int(op == "+" ? n : -n) else { return .error("Date out of range") }
                    return Calendar.current.date(byAdding: .day, value: days, to: x).map(Item.date) ?? .error("Date out of range")
                }
            }
            guard let x = a.number else { return .error("“\(a.string)” is not a number") }
            guard let y = b.number else { return .error("“\(b.string)” is not a number") }
            switch op {
            case "+": return .number(x + y)
            case "-": return .number(x - y)
            case "*": return .number(x * y)
            case "/": return y == 0 ? .error("Division by zero") : .number(x / y)
            default: return .number(pow(x, y))
            }
        }
    }

    static func compare(_ a: Item, _ b: Item) -> ComparisonResult {
        switch (a, b) {
        case let (.date(x), .date(y)): return x.compare(y)
        case (.number, _), (_, .number), (.bool, _), (_, .bool):
            if let x = a.number, let y = b.number { return x < y ? .orderedAscending : x > y ? .orderedDescending : .orderedSame }
            fallthrough
        default:
            return a.string.compare(b.string, options: [.caseInsensitive, .diacriticInsensitive, .numeric])
        }
    }

    /// Renames `{Old}` to `{New}` in the table's formulas, and `LOOKUP({Link}, "Old")` where the link
    /// points at this table, so renaming a field doesn't break the formulas that use it. Other text in
    /// quotes is left alone.
    static func renameField(_ old: String, to new: String, inTable tableID: UUID, database db: inout Database) {
        guard !old.isEmpty, old != new else { return }
        // Formulas find fields ignoring case and accents, so "cafe" refers to "Café" too.
        func same(_ name: String) -> Bool {
            name.trimmingCharacters(in: .whitespaces).compare(old, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        guard let braces = try? NSRegularExpression(pattern: "\\{([^{}]*)\\}"),
              let lookup = try? NSRegularExpression(
                pattern: "LOOKUP\\s*\\(\\s*\\{\\s*([^{}]*?)\\s*\\}\\s*,\\s*[\"“”]([^\"“”]*)[\"“”]\\s*\\)",
                options: .caseInsensitive) else { return }
        for t in db.tables.indices {
            let table = db.tables[t]
            for f in table.fields.indices where table.fields[f].type == .formula {
                var formula = table.fields[f].options.formula
                // Back to front, so earlier ranges stay valid.
                if table.id == tableID {
                    // Text in quotes is left as it is, braces and all.
                    let quoted = Self.quotedRanges(formula)
                    for match in braces.matches(in: formula, range: NSRange(formula.startIndex..., in: formula)).reversed() {
                        guard !quoted.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                              let inner = Range(match.range(at: 1), in: formula), same(String(formula[inner])),
                              let whole = Range(match.range, in: formula) else { continue }
                        formula.replaceSubrange(whole, with: "{\(new)}")
                    }
                }
                for match in lookup.matches(in: formula, range: NSRange(formula.startIndex..., in: formula)).reversed() {
                    guard let linkRange = Range(match.range(at: 1), in: formula),
                          let nameRange = Range(match.range(at: 2), in: formula), same(String(formula[nameRange])) else { continue }
                    var linkName = String(formula[linkRange])
                    // The link may itself have just been renamed (a link to the same table).
                    if table.id == tableID, same(linkName) { linkName = new }
                    guard let link = table.field(named: linkName), link.type == .link,
                          (link.options.linkedTableID ?? table.id) == tableID else { continue }
                    formula.replaceSubrange(nameRange, with: new)
                }
                db.tables[t].fields[f].options.formula = formula
            }
        }
    }

    /// Where the quoted text is in a formula ("…" or “…”), as the tokenizer reads it.
    static func quotedRanges(_ formula: String) -> [NSRange] {
        var ranges: [NSRange] = []
        var start: Int?
        for (i, unit) in formula.utf16.enumerated() {
            let c = Character(UnicodeScalar(unit) ?? " ")
            let quote = c == "\"" || c == "“" || c == "”"
            if let s = start {
                if quote { ranges.append(NSRange(location: s, length: i - s + 1)); start = nil }
            } else if quote {
                start = i
            }
        }
        if let s = start { ranges.append(NSRange(location: s, length: formula.utf16.count - s)) }
        return ranges
    }

    /// A whole number for counts and days; nil for NaN, infinity or values too large (converting
    /// those with `Int(_:)` would crash).
    static func int(_ value: Double) -> Int? {
        guard value.isFinite, abs(value) < 1e9 else { return nil }
        return Int(value.rounded(.towardZero))
    }

    // MARK: Functions

    static let functions: [String: ([Item]) -> Item] = {
        func numbers(_ items: [Item]) -> [Double] { items.flatMap(\.flattened).filter { $0 != .empty }.compactMap(\.number) }
        func one(_ name: String, _ body: @escaping (Item) -> Item) -> ([Item]) -> Item {
            { $0.count == 1 ? body($0[0]) : .error("\(name) takes one value") }
        }
        func number(_ name: String, _ body: @escaping (Double) -> Double) -> ([Item]) -> Item {
            one(name) { item in item.number.map { .number(body($0)) } ?? .error("\(name) needs a number") }
        }
        func date(_ name: String, _ component: Calendar.Component) -> ([Item]) -> Item {
            one(name) { item in
                guard case .date(let d) = item else { return item == .empty ? .empty : .error("\(name) needs a date") }
                return .number(Double(Value.gregorian.component(component, from: d)))
            }
        }
        return [
            "TRUE": { _ in .bool(true) },
            "FALSE": { _ in .bool(false) },
            "AND": { args in .bool(args.flatMap(\.flattened).allSatisfy(\.truthy)) },
            "OR": { args in .bool(args.flatMap(\.flattened).contains(where: \.truthy)) },
            "NOT": one("NOT") { .bool(!$0.truthy) },
            "ISBLANK": one("ISBLANK") { item in
                switch item {
                case .empty: .bool(true)
                case .text(let s): .bool(s.isEmpty)
                case .list(let l): .bool(l.isEmpty)
                default: .bool(false)
                }
            },
            "SUM": { .number(numbers($0).reduce(0, +)) },
            "AVG": { args in let n = numbers(args); return n.isEmpty ? .empty : .number(n.reduce(0, +) / Double(n.count)) },
            "AVERAGE": { args in let n = numbers(args); return n.isEmpty ? .empty : .number(n.reduce(0, +) / Double(n.count)) },
            "MIN": { args in numbers(args).min().map(Item.number) ?? .empty },
            "MAX": { args in numbers(args).max().map(Item.number) ?? .empty },
            "COUNT": { args in .number(Double(args.flatMap(\.flattened).filter { $0 != .empty && $0 != .text("") }.count)) },
            "ROUND": { args in
                guard (1...2).contains(args.count), let x = args[0].number else { return .error("ROUND needs a number and optionally a number of decimals") }
                let places = args.count == 2 ? (args[1].number ?? 0) : 0
                let factor = pow(10, places)
                return .number((x * factor).rounded() / factor)
            },
            "FLOOR": number("FLOOR") { $0.rounded(.down) },
            "CEILING": number("CEILING") { $0.rounded(.up) },
            "ABS": number("ABS") { abs($0) },
            "SQRT": number("SQRT") { $0.squareRoot() },
            "MOD": { args in
                guard args.count == 2, let x = args[0].number, let y = args[1].number else { return .error("MOD needs two numbers") }
                return y == 0 ? .error("Division by zero") : .number(x.truncatingRemainder(dividingBy: y))
            },
            "LEN": one("LEN") { .number(Double($0.string.count)) },
            "UPPER": one("UPPER") { .text($0.string.uppercased()) },
            "LOWER": one("LOWER") { .text($0.string.lowercased()) },
            "TRIM": one("TRIM") { .text($0.string.trimmingCharacters(in: .whitespacesAndNewlines)) },
            "TEXT": one("TEXT") { .text($0.string) },
            "NUMBER": one("NUMBER") { item in item.number.map(Item.number) ?? .error("“\(item.string)” is not a number") },
            "LEFT": { args in
                guard args.count == 2, let n = args[1].number else { return .error("LEFT needs text and a length") }
                guard let count = Formula.int(n) else { return .error("LEFT needs a whole number") }
                return .text(String(args[0].string.prefix(max(0, count))))
            },
            "RIGHT": { args in
                guard args.count == 2, let n = args[1].number else { return .error("RIGHT needs text and a length") }
                guard let count = Formula.int(n) else { return .error("RIGHT needs a whole number") }
                return .text(String(args[0].string.suffix(max(0, count))))
            },
            "CONTAINS": { args in
                guard args.count == 2 else { return .error("CONTAINS needs text and what to look for") }
                return .bool(args[0].string.range(of: args[1].string, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
            },
            "CONCAT": { args in .text(args.map(\.string).joined()) },
            "JOIN": { args in
                guard (1...2).contains(args.count) else { return .error("JOIN needs a list and optionally a separator") }
                let separator = args.count == 2 ? args[1].string : ", "
                return .text(args[0].flattened.map(\.string).filter { !$0.isEmpty }.joined(separator: separator))
            },
            "TODAY": { _ in .date(Calendar.current.startOfDay(for: Date())) },
            "NOW": { _ in .date(Date()) },
            "YEAR": date("YEAR", .year),
            "MONTH": date("MONTH", .month),
            "DAY": date("DAY", .day),
            "WEEKDAY": date("WEEKDAY", .weekday),
            "DATE": { args in
                guard args.count == 3, let y = args[0].number, let m = args[1].number, let d = args[2].number else { return .error("DATE needs a year, month and day") }
                guard let year = Formula.int(y), let month = Formula.int(m), let day = Formula.int(d) else { return .error("Not a date") }
                return Value.gregorian.date(from: DateComponents(year: year, month: month, day: day)).map(Item.date) ?? .error("Not a date")
            },
            "DAYS": { args in
                guard args.count == 2, case .date(let end) = args[0], case .date(let start) = args[1] else {
                    return args.contains(.empty) ? .empty : .error("DAYS needs two dates: DAYS(end, start)")
                }
                let calendar = Calendar.current
                return .number(Double(calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 0))
            },
            "ADDDAYS": { args in
                guard args.count == 2, case .date(let d) = args[0], let n = args[1].number else { return .error("ADDDAYS needs a date and a number") }
                guard let days = Formula.int(n) else { return .error("Date out of range") }
                return Calendar.current.date(byAdding: .day, value: days, to: d).map(Item.date) ?? .error("Date out of range")
            },
            // Handled in `evaluate`, listed here so the parser knows them.
            "IF": { _ in .empty },
            "LOOKUP": { _ in .empty },
        ]
    }()

    /// For the formula help in the field editor.
    static let help: [(String, String)] = [
        ("{Field}", "the value of a field in this record"),
        ("+ − * / ^", "arithmetic; date − date gives days"),
        ("&", "join text: {First} & \" \" & {Last}"),
        ("= <> < > <= >=", "compare"),
        ("IF(test, then, else)", "choose a result"),
        ("AND, OR, NOT, ISBLANK", "logic"),
        ("SUM, AVG, MIN, MAX, COUNT", "totals; work on lists too"),
        ("ROUND(x, places), FLOOR, CEILING, ABS, SQRT, MOD", "numbers"),
        ("LEN, UPPER, LOWER, TRIM, LEFT, RIGHT, CONTAINS, CONCAT", "text"),
        ("TODAY(), NOW(), YEAR, MONTH, DAY, WEEKDAY", "dates"),
        ("DATE(y, m, d), DAYS(end, start), ADDDAYS(date, n)", "date maths"),
        ("LOOKUP({Link}, \"Field\")", "a field of every linked record, as a list"),
        ("JOIN(list, \", \")", "a list as text"),
    ]
}
