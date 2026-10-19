@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit
import DatabaseTypes
@_spi(DatabaseExecution) import DatabaseWire

/// Application protocol projection; the Cloudflare host only carries its bytes.
struct SQLApplicationResponseEncoder: SQLBlockResponseEncoder {
    let requestID: UInt64
    let encoder: DatabaseWireEncoder

    func measure(_ output: borrowing SQLBlockOutputView) throws -> UInt64 {
        do {
            return UInt64(try encoder.measureSQLResponse(requestID: requestID,
                resultCount: output.statementCount) { writer in
                    try write(output, into: &writer)
                })
        } catch let error as DatabaseWireError {
            try Self.throwResponseFailure(error)
        }
    }

    func encode(_ output: borrowing SQLBlockOutputView,
        into destination: inout MutableSpan<UInt8>) throws {
        do {
            try destination.withUnsafeMutableBufferPointer { buffer in
                try encoder.encodeSQLResponse(requestID: requestID,
                    resultCount: output.statementCount,
                    into: UnsafeMutableRawBufferPointer(buffer)) { writer in
                        try write(output, into: &writer)
                    }
            }
        } catch let error as DatabaseWireError {
            try Self.throwResponseFailure(error)
        }
    }

    static func throwResponseFailure(_ error: DatabaseWireError) throws -> Never {
        switch error {
        case .frameTooLarge, .stringTooLarge, .byteStringTooLarge,
             .collectionTooLarge, .nestingTooDeep, .objectBudgetExceeded,
             .invalidQueryValue(.resourceLimit),
             .invalidQueryStructure(.resourceLimitExceeded):
            throw SQLExecutionFailure(underlyingError: error,
                diagnostic: try SQLDiagnostic(sqlState: "54000", category: .resource,
                    message: "SQL response exceeds the configured Wire resource limits"))
        default:
            throw error
        }
    }

    private func write(_ output: borrowing SQLBlockOutputView,
        into writer: inout SQLResponseWriter) throws {
        for index in 0..<output.statementCount {
            try output.withStatement(at: index, command: { kind, count in
                try writer.writeCommand(kind, affectedRows: count)
            }, rows: { rows in
                let affectedRows: UInt64?
                if let count = rows.affectedRows {
                    guard let exact = UInt64(exactly: count) else {
                        throw DatabaseWireError.byteCountOverflow
                    }
                    affectedRows = exact
                } else { affectedRows = nil }
                try writer.writeRows(columnCount: rows.columnCount,
                    rowCount: rows.rowCount, affectedRows: affectedRows) { rowWriter in
                    for column in 0..<rows.columnCount {
                        try rows.withColumn(at: column) { try rowWriter.writeColumn($0) }
                    }
                    for index in 0..<rows.rowCount {
                        try rows.withRow(at: index) { row in
                            try rowWriter.beginRow()
                            for value in 0..<row.valueCount {
                                try row.withValue(at: value) { try rowWriter.writeValue($0) }
                            }
                            try row.withAnnotations { annotations in
                                // Framework charges these canonical per-row metadata temporaries.
                                let sorted = annotations.sorted { $0.key < $1.key }
                                let fields = try FieldObject(sorted.map { (key: $0.key, value: $0.value) })
                                try row.withVersion { version in
                                    let digest: ByteString?
                                    if let token = version {
                                        digest = try PersistableVersionTokenCodec.digest(from: token)
                                    } else { digest = nil }
                                    try rowWriter.endRow(annotations: fields, version: digest)
                                }
                            }
                        }
                    }
                }
            }, copy: { copy in
                try copy.withBytes { try writer.writeCopy(bytes: $0, affectedRows: copy.affectedRows) }
            })
        }
    }
}
