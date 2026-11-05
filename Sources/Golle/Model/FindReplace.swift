import Foundation

/// Find & Replace over text fields: what would change, and the change itself.
enum FindReplace {
    struct Options: Equatable {
        var matchCase = false
        /// Only cells that are exactly the text (ignoring spaces around it), replaced as a whole.
        var wholeCell = false
    }

    /// The field types whose text can be replaced.
    static func canReplace(_ field: Field) -> Bool {
        field.type.isTextLike || field.type == .longText
    }

    /// The cell's new text, or nil when nothing in it matches.
    static func replace(in text: String, find: String, with replacement: String, options: Options) -> String? {
        guard !find.isEmpty else { return nil }
        let compare: String.CompareOptions = options.matchCase ? [] : [.caseInsensitive]
        if options.wholeCell {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let needle = find.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.compare(needle, options: compare) == .orderedSame && text != replacement ? replacement : nil
        }
        guard text.range(of: find, options: compare) != nil else { return nil }
        let new = text.replacingOccurrences(of: find, with: replacement, options: compare)
        return new == text ? nil : new
    }

    struct Match: Identifiable {
        var id: String { "\(record.id)-\(field.id)" }
        let record: Record
        let field: Field
        let old: String
        let new: String
    }

    /// Every cell of these records and fields that would change.
    static func matches(_ records: [Record], fields: [Field], find: String, with replacement: String, options: Options) -> [Match] {
        records.flatMap { record in
            fields.compactMap { field -> Match? in
                guard let text = record[field.id]?.text,
                      let replaced = replace(in: text, find: find, with: replacement, options: options) else { return nil }
                // As it will be stored: a barcode's spaces go, so "978 " for "978" changes nothing.
                let new = value(replaced, for: field)?.text ?? ""
                return new == text ? nil : Match(record: record, field: field, old: text, new: new)
            }
        }
    }

    /// The value a replaced text is stored as (barcodes lose their spaces and dashes).
    static func value(_ text: String, for field: Field) -> Value? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return field.type == .barcode ? Value.text(text).converted(to: .barcode) : .text(text)
    }
}
