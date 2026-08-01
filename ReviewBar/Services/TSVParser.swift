import Foundation

struct TSVDocument: Equatable, Sendable {
    let headers: [String]
    let rows: [[String: String]]

    static func parse(_ data: Data) throws -> TSVDocument {
        guard !data.isEmpty else { return TSVDocument(headers: [], rows: []) }
        guard var text = String(data: data, encoding: .utf8) else {
            throw AppError(kind: .malformedResponse, message: "An Analytics report wasn't valid UTF-8 text.")
        }
        if text.unicodeScalars.first?.value == 0xFEFF { text.removeFirst() }
        let records = try parseRecords(text)
        guard let first = records.first else { return TSVDocument(headers: [], rows: []) }
        let headers = first.map(normalizedHeader)
        guard headers.allSatisfy({ !$0.isEmpty }), Set(headers).count == headers.count else {
            throw AppError(kind: .malformedResponse, message: "An Analytics report contained missing or duplicate columns.")
        }
        var rows: [[String: String]] = []
        for record in records.dropFirst() where !(record.count == 1 && record[0].isEmpty) {
            guard record.count == headers.count else {
                throw AppError(kind: .malformedResponse, message: "An Analytics report row didn't match its header schema.")
            }
            rows.append(Dictionary(uniqueKeysWithValues: zip(headers, record)))
        }
        return TSVDocument(headers: headers, rows: rows)
    }

    static func normalizedHeader(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{00a0}", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    private static func parseRecords(_ text: String) throws -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var quoted = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if quoted {
                if character == "\"" {
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = text.index(after: next)
                        continue
                    }
                    quoted = false
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"" where field.isEmpty:
                    quoted = true
                case "\t":
                    record.append(field)
                    field = ""
                case "\n":
                    record.append(field.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
                    records.append(record)
                    record = []
                    field = ""
                default:
                    field.append(character)
                }
            }
            index = next
        }
        guard !quoted else {
            throw AppError(kind: .malformedResponse, message: "An Analytics report contained an unterminated quoted value.")
        }
        if !field.isEmpty || !record.isEmpty {
            record.append(field.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
            records.append(record)
        }
        return records
    }
}
