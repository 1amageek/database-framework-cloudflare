import CloudflareDatabase
import DatabaseKit
import DatabaseTypes
import DatabaseWire

/// Reused by the exact-target reactor driver without teaching TypeScript Wire.
enum SQLApplicationVerification {
    static func verify(session: RuntimeVerificationSession) async throws {
        let result = try await invoke(session, id: 1701, sql: """
            INSERT INTO "RuntimeVerificationDocument" (id, title) VALUES ('s17-reopen', 'committed');
            SELECT title AS value, title AS value FROM "RuntimeVerificationDocument" WHERE id = 's17-reopen';
            SELECT title FROM "RuntimeVerificationDocument" WHERE FALSE;
            COPY (SELECT title FROM "RuntimeVerificationDocument" WHERE id = 's17-reopen') TO STDOUT WITH (FORMAT csv);
            """).get()
        guard result.results.count == 4,
              case .command(.insert, let inserted) = result.results[0], inserted == 1,
              case .rows(let rows) = result.results[1], rows.columns.map(\.name) == ["value", "value"],
              case .rows(let empty) = result.results[2], empty.rowCount == 0,
              empty.columns.count == 1, empty.columns[0].type == .primitive(.string, isArray: false),
              case .copy(let bytes, let count) = result.results[3], count == 1,
              bytes == ByteString(utf8: "committed\n") else { throw RuntimeVerificationError.invalidApplicationRequest }
        var iterator = rows.makeRowIterator()
        guard try iterator.next()?.values == [.primitive(.string("committed")), .primitive(.string("committed"))],
              try iterator.next() == nil else { throw RuntimeVerificationError.invalidApplicationRequest }
        let syntax = try await invoke(session, id: 1702, sql: "SELECT FROM")
        guard case .failure(let syntaxFailure) = syntax,
              try syntaxFailure.sqlDiagnostic()?.sqlState == "42601" else { throw RuntimeVerificationError.invalidApplicationRequest }
        let failed = try await invoke(session, id: 1703, sql: """
            INSERT INTO "RuntimeVerificationDocument" (id, title) VALUES ('s17-rollback', 'hidden');
            SELECT 1 / 0;
            """)
        guard case .failure(let failure) = failed,
              try failure.sqlDiagnostic()?.sqlState == "22012" else { throw RuntimeVerificationError.invalidApplicationRequest }
        let oversized = try await invoke(session, id: 1704, sql: """
            INSERT INTO "RuntimeVerificationDocument" (id, title) VALUES ('s17-oversize', 'hidden');
            SELECT '\(String(repeating: "x", count: 8_192))';
            """)
        guard case .failure(let limit) = oversized, limit.category == .resourceLimit,
              try limit.sqlDiagnostic()?.sqlState == "54000" else { throw RuntimeVerificationError.invalidApplicationRequest }
        let absent = try await invoke(session, id: 1705, sql: """
            SELECT title FROM "RuntimeVerificationDocument" WHERE id IN ('s17-rollback', 's17-oversize');
            """).get()
        guard absent.results.count == 1, case .rows(let absentRows) = absent.results[0],
              absentRows.rowCount == 0 else { throw RuntimeVerificationError.invalidApplicationRequest }
    }

    static func verifyRestored(session: RuntimeVerificationSession) async throws {
        let result = try await invoke(session, id: 1706,
            sql: "SELECT title FROM \"RuntimeVerificationDocument\" WHERE id = 's17-reopen'").get()
        guard result.results.count == 1, case .rows(let rows) = result.results[0], rows.rowCount == 1 else {
            throw RuntimeVerificationError.invalidApplicationRequest
        }
        var iterator = rows.makeRowIterator()
        guard try iterator.next()?.values == [.primitive(.string("committed"))],
              try iterator.next() == nil else { throw RuntimeVerificationError.invalidApplicationRequest }
    }

    private static func invoke(_ session: RuntimeVerificationSession, id: UInt64,
        sql: String) async throws -> Result<SQLExecuteOperation.Response, RemoteOperationError> {
        let request = SQLExecuteOperation.Request(input: .text(sql))
        #if CLOUDFLARE_RUNTIME_MULTI_BASE
        let bytes = try DatabaseWireEncoder().encodeRequest(DatabaseOperationCatalog.sqlExecute,
            requestID: id, target: .base(try Base.ID("runtime-verification")), request: request)
        #else
        let bytes = try DatabaseWireEncoder().encodeRequest(DatabaseOperationCatalog.sqlExecute,
            requestID: id, request: request)
        #endif
        let response = try await session.respond(to: CloudflareDatabaseInvocation(
            context: ByteString(utf8: RuntimeVerificationSession.principalIdentifier + ":sql"), request: bytes))
        return try DatabaseWireDecoder().decodeResponse(DatabaseOperationCatalog.sqlExecute,
            from: response, matching: id)
    }
}
