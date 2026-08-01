import Foundation

struct TSVDocument: Equatable, Sendable {
    let headers: [String]
    let rows: [[String: String]]

    static func parse(_ data: Data) throws -> TSVDocument {
        guard !data.isEmpty else { return TSVDocument(headers: [], rows: []) }
        var headers: [String] = []
        var rows: [[String: String]] = []

        try parseRecords(data) { record in
            if headers.isEmpty {
                headers = record.map(normalizedHeader)
                guard headers.allSatisfy({ !$0.isEmpty }), Set(headers).count == headers.count else {
                    throw AppError(kind: .malformedResponse, message: "An Analytics report contained missing or duplicate columns.")
                }
            } else if !(record.count == 1 && record[0].isEmpty) {
                guard record.count == headers.count else {
                    throw AppError(kind: .malformedResponse, message: "An Analytics report row didn't match its header schema.")
                }
                rows.append(Dictionary(uniqueKeysWithValues: zip(headers, record)))
            }
        }
        return TSVDocument(headers: headers, rows: rows)
    }

    static func normalizedHeader(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{00a0}", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    /// Parses directly from UTF-8 bytes so the decompressed `Data`, a second
    /// full-size `String`, and a complete intermediate record matrix are never
    /// retained simultaneously.
    private static func parseRecords(
        _ data: Data,
        consume: ([String]) throws -> Void
    ) throws {
        var record: [String] = []
        var field: [UInt8] = []
        var quoted = false
        var index = 0
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF { index = 3 }

        func finishField() throws {
            guard let value = String(bytes: field, encoding: .utf8) else {
                throw AppError(kind: .malformedResponse, message: "An Analytics report wasn't valid UTF-8 text.")
            }
            record.append(value)
            field.removeAll(keepingCapacity: true)
        }

        func finishRecord() throws {
            try finishField()
            try consume(record)
            record.removeAll(keepingCapacity: true)
        }

        while index < data.count {
            if index.isMultiple(of: 16 * 1_024) { try Task.checkCancellation() }
            let byte = data[index]
            if quoted {
                if byte == 0x22 {
                    if index + 1 < data.count, data[index + 1] == 0x22 {
                        field.append(0x22)
                        index += 2
                        continue
                    }
                    quoted = false
                } else {
                    field.append(byte)
                }
            } else {
                switch byte {
                case 0x22 where field.isEmpty:
                    quoted = true
                case 0x09:
                    try finishField()
                case 0x0A:
                    try finishRecord()
                case 0x0D:
                    try finishRecord()
                    if index + 1 < data.count, data[index + 1] == 0x0A { index += 1 }
                default:
                    field.append(byte)
                }
            }
            index += 1
        }
        guard !quoted else {
            throw AppError(kind: .malformedResponse, message: "An Analytics report contained an unterminated quoted value.")
        }
        if !field.isEmpty || !record.isEmpty {
            try finishRecord()
        }
    }
}
