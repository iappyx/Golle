import SwiftUI

/// Rules that decide which records a view shows, like a Finder smart folder.
struct FilterBar: View {
    let table: DataTable
    let view: SavedView
    let isSaved: Bool
    let update: ((inout SavedView) -> Void) -> Void
    let saveAs: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Show records that match").lineLimit(1)
                Picker("Match", selection: Binding(get: { view.filter.match }, set: { m in update { $0.filter.match = m } })) {
                    Text("all").tag(Filter.Match.all)
                    Text("any").tag(Filter.Match.any)
                }
                .labelsHidden()
                .fixedSize()
                Text("of these rules:").lineLimit(1)
                Spacer()
                if !isSaved && !view.filter.isEmpty {
                    Button("Save as View…", action: saveAs)
                }
                Button(view.filter.isEmpty ? "Done" : "Clear", action: close)
            }
            ForEach(view.filter.rules) { rule in
                RuleRow(table: table, rule: rule,
                        change: { new in update { v in v.filter.rules = v.filter.rules.map { $0.id == rule.id ? new : $0 } } },
                        remove: { update { $0.filter.rules.removeAll { $0.id == rule.id } } },
                        add: { addRule(after: rule.id) })
            }
            if view.filter.rules.isEmpty {
                Button { addRule(after: nil) } label: { Label("Add Rule", systemImage: "plus.circle") }
                    .buttonStyle(.borderless)
                    .disabled(table.fields.isEmpty)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func addRule(after id: FilterRule.ID?) {
        guard let field = table.fields.first else { return }
        let rule = FilterRule(fieldID: field.id, op: FilterOperator.operators(for: field.type)[0])
        update { view in
            let index = id.flatMap { id in view.filter.rules.firstIndex { $0.id == id } }.map { $0 + 1 } ?? view.filter.rules.count
            view.filter.rules.insert(rule, at: index)
        }
    }
}

struct RuleRow: View {
    let table: DataTable
    let rule: FilterRule
    let change: (FilterRule) -> Void
    let remove: () -> Void
    let add: () -> Void

    private var field: Field? { table.field(rule.fieldID) }

    var body: some View {
        HStack(spacing: 6) {
            Picker("Field", selection: Binding(get: { rule.fieldID }, set: { id in
                guard let field = table.field(id) else { return }
                var r = rule
                r.fieldID = id
                let ops = FilterOperator.operators(for: field.type)
                if !ops.contains(r.op) { r.op = ops[0] }
                change(Self.fitted(r, was: rule, in: table))
            })) {
                ForEach(table.fields) { Label($0.name, systemImage: $0.type.symbol).tag($0.id) }
            }
            .labelsHidden()
            .frame(maxWidth: 180)

            if let field {
                Picker("Condition", selection: Binding(get: { rule.op }, set: { op in
                    var r = rule
                    r.op = op
                    change(Self.fitted(r, was: rule, in: table))
                })) {
                    ForEach(FilterOperator.operators(for: field.type), id: \.self) { Text($0.label(for: field.type)).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 170)

                operand(field)
            }
            Spacer(minLength: 0)
            Button(action: remove) { Image(systemName: "minus.circle") }.help("Remove rule").buttonStyle(.borderless)
            Button(action: add) { Image(systemName: "plus.circle") }.help("Add rule").buttonStyle(.borderless)
        }
    }

    /// What kind of value a rule compares with: a date, a number of days, stars, an option, text.
    private static func operandKind(_ rule: FilterRule, _ table: DataTable) -> String {
        guard let field = table.field(rule.fieldID) else { return "" }
        if rule.op == .inLastDays || rule.op == .inNextDays { return "days" }
        if field.type == .date && [.equals, .notEquals, .before, .after].contains(rule.op) { return "date" }
        if field.type == .rating { return "rating" }
        if field.type.usesChoices && (rule.op == .equals || rule.op == .notEquals) { return "choice-\(field.id)" }
        if field.type.isNumeric || rule.op.isOrdering { return "number" }
        return "text"
    }

    /// The rule after its field or condition changed: a value of another kind ("abc" for a date,
    /// a date as a number of days) would silently match nothing, so it starts over.
    static func fitted(_ rule: FilterRule, was old: FilterRule, in table: DataTable) -> FilterRule {
        let kind = operandKind(rule, table)
        guard kind != operandKind(old, table) else { return rule }
        var r = rule
        r.operand = kind == "date" ? Date().formatted(Value.isoDay) : ""
        return r
    }

    @ViewBuilder
    private func operand(_ field: Field) -> some View {
        let text = Binding(get: { rule.operand }, set: { t in
            var r = rule
            r.operand = t
            change(r)
        })
        if !rule.op.needsOperand {
            EmptyView()
        } else if field.type == .date && [.equals, .notEquals, .before, .after].contains(rule.op) {
            DatePicker("Date", selection: Binding(
                get: { Value.parseDate(rule.operand) ?? Calendar.current.startOfDay(for: Date()) },
                set: { text.wrappedValue = $0.formatted(Value.isoDay) }
            ), displayedComponents: .date)
            .labelsHidden()
            .onAppear { if rule.operand.isEmpty { text.wrappedValue = Date().formatted(Value.isoDay) } }
        } else if field.type.usesChoices && (rule.op == .equals || rule.op == .notEquals) && !field.options.choices.isEmpty {
            Picker("Value", selection: text) {
                if !field.options.choices.contains(rule.operand) { Text(rule.operand.isEmpty ? "Choose…" : rule.operand).tag(rule.operand) }
                ForEach(field.options.choices, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 180)
        } else if field.type == .rating && rule.op != .isEmpty {
            RatingView(rating: Int(rule.operand) ?? 0) { text.wrappedValue = String($0) }
        } else {
            TextField(rule.op == .inLastDays || rule.op == .inNextDays ? "days" : "value", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
        }
    }
}
