import SwiftUI

/// The strip under the records: how many are shown, and totals the user picked (sum, average, …).
/// Totals cover the records in view, so they follow the filter and the search.
struct SummaryBar: View {
    @ObservedObject var document: GolleDocument
    let table: DataTable
    let rows: [Record]
    let resolver: Resolver

    var body: some View {
        HStack(spacing: 12) {
            Text(rows.count == table.records.count ? "\(rows.count) records" : "\(rows.count) of \(table.records.count) records")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .layoutPriority(1)
            if !document.selectedRecordIDs.isEmpty && document.selectedRecordIDs.count > 1 {
                Text("\(document.selectedRecordIDs.count) selected").foregroundStyle(.secondary).lineLimit(1)
            }
            if resolver.hasRules {
                attention
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(table.summaries) { item in
                        if let field = table.field(item.fieldID) {
                            chip(item, field)
                        }
                    }
                }
            }
            Menu {
                ForEach(table.fields) { field in
                    Menu {
                        ForEach(SummaryKind.kinds(for: field.type)) { kind in
                            Button(kind.label) { document.addSummary(field: field.id, kind: kind, in: table.id) }
                        }
                    } label: {
                        Label(field.name, systemImage: field.type.symbol)
                    }
                }
            } label: {
                Image(systemName: "sum")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add a total")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// Records in view that break a field rule (required, unique): a menu to go to them.
    @ViewBuilder
    private var attention: some View {
        let broken = document.memo("rules-\(table.id)-\(rows.map(\.id).hashValue)") {
            rows.compactMap { record -> (Record, String)? in
                let problems = resolver.ruleProblems(record)
                guard !problems.isEmpty else { return nil }
                return (record, problems.map { "\($0.field.name): \($0.problem.message.lowercased())" }.joined(separator: ", "))
            }
        }
        if !broken.isEmpty {
            Menu {
                Button("Select All \(broken.count)") { document.selectedRecordIDs = Set(broken.map(\.0.id)) }
                Divider()
                ForEach(broken.prefix(30), id: \.0.id) { record, why in
                    Button("\(table.title(of: record)) — \(why)") { document.selectedRecordIDs = [record.id] }
                }
                if broken.count > 30 { Text("and \(broken.count - 30) more") }
            } label: {
                Label("\(broken.count) need\(broken.count == 1 ? "s" : "") attention", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .tint(.orange)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Records that break a field rule: required or unique (Edit Fields)")
        }
    }

    private func chip(_ item: SummaryItem, _ field: Field) -> some View {
        let values = rows.map { resolver.value($0, field) }
        return Menu {
            ForEach(SummaryKind.kinds(for: field.type)) { kind in
                Button { document.setSummary(item.id, kind: kind, in: table.id) } label: {
                    if kind == item.kind { Label(kind.label, systemImage: "checkmark") } else { Text(kind.label) }
                }
            }
            Divider()
            Button("Remove") { document.removeSummary(item.id, from: table.id) }
        } label: {
            HStack(spacing: 4) {
                Text("\(field.name) · \(item.kind.label)").foregroundStyle(.secondary)
                Text(item.kind.compute(values, field: resolver.formatField(field))).fontWeight(.medium).monospacedDigit()
            }
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
