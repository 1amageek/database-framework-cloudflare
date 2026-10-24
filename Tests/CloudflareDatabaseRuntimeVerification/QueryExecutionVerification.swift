import Database
import DatabaseEngine
import DatabaseKit
import DatabaseTypes
import QueryAST

/// Runs the common surface using the deployed host executor, clock and SQLite ABI.
enum QueryExecutionVerification {
    static func verify(in context: DatabaseContext, restricted: DatabaseContext) async throws {
        let connection = try await context.openConnection()
        defer { await connection.close() }
        for text in [
            "SELECT 1.2300::numeric AS value, '[0:1]={1,2}'::integer[] AS value",
            "WITH c AS (SELECT 2::integer AS n) SELECT sum(n)::bigint AS total FROM c LIMIT 1",
        ] {
            let statement = try SQLParser(preservesCastOutputNames: true).parse(text)
            let sql = try await connection.execute(SQL(text: text))
            let ir = try await connection.execute(statement)
            let block = try await connection.execute(SQLBlock(steps: [.statement(statement)]))
            try require(sql.columns == ir.columns && ir.columns == block.columns, "columns")
            let expected = try await values(sql.rows)
            let actualIR = try await values(ir.rows)
            let actualBlock = try await values(block.rows)
            try require(actualIR == expected && actualBlock == expected, "values")
        }
        #if CLOUDFLARE_RUNTIME_GRAPH_INDEXES
        for text in ["ASK {}", "CONSTRUCT { <urn:s> <urn:p> <urn:o> } WHERE {}"] {
            let source = try await connection.execute(QueryInput.text(language: .sparql, statement: text))
            let ir = try await connection.execute(SPARQLParser().parse(text))
            switch (source, ir) {
            case (.boolean(let first), .boolean(let second)):
                try require(first.value && second.value, "boolean")
            case (.rdfGraph(let first), .rdfGraph(let second)):
                try require(first.quadCount == 1 && second.quadCount == 1, "graph-count")
                try require(try first.materializedQuads(maximumCount: 1) == second.materializedQuads(maximumCount: 1), "graph-values")
            default: throw RuntimeVerificationError.graphAssertion("query-unified-graph-kind")
            }
        }
        try await verifyGraphFailures(in: context, connection: connection)
        #endif
        let created = try await connection.execute("CREATE TABLE query_unified(n integer)")
        try require(created.command == .createTable && created.affectedRows == nil, "ddl")
        let list = (0..<100).map { "(\($0))" }.joined(separator: ",")
        let inserted = try await connection.execute(SQL(text: "INSERT INTO query_unified VALUES " + list + " RETURNING n"))
        let insertedRows = try await values(inserted.rows)
        try require(inserted.affectedRows == 100 && insertedRows.count == 100, "bulk-returning")
        let copied = try await connection.execute("COPY (SELECT n FROM query_unified ORDER BY n LIMIT 1) TO STDOUT WITH (FORMAT csv)")
        guard case .copy(let bytes, let count) = copied, bytes == ByteString(utf8: "0\n"), count == 1 else {
            throw RuntimeVerificationError.graphAssertion("query-unified-copy")
        }
        do {
            _ = try await connection.execute("INSERT INTO query_unified VALUES (1000); SELECT 1 / 0; INSERT INTO query_unified VALUES (1001)")
            throw RuntimeVerificationError.graphAssertion("query-unified-rollback-required")
        } catch let failure as SQLExecutionFailure {
            try require(failure.diagnostic.sqlState == "22012", "rollback-state")
        }
        for budget in [ExecutionBudget(maximumRows: 0), ExecutionBudget(maximumWorkUnits: 0),
                       ExecutionBudget(maximumIntermediateBytes: 0)] {
            do {
                _ = try await connection.execute("INSERT INTO query_unified VALUES (1002)", options: .init(budget: budget))
                throw RuntimeVerificationError.graphAssertion("query-unified-budget-required")
            } catch let failure as SQLExecutionFailure {
                try require(failure.diagnostic.sqlState == "54000", "resource-state")
            }
        }
        let denied = try await restricted.openConnection()
        defer { await denied.close() }
        let forbidden = "SELECT title FROM \"RuntimeVerificationDocument\" ORDER BY title"
        for input in [QueryInput.sql(forbidden), .statement(try SQLParser().parse(forbidden))] {
            do {
                _ = try await denied.execute(input)
                throw RuntimeVerificationError.graphAssertion("query-unified-authorization-required")
            } catch let failure as SQLExecutionFailure {
                try require(failure.diagnostic.sqlState == "42501", "authority-state")
            }
        }
        let retained = try await connection.execute("SELECT max(n), count(*) FROM query_unified LIMIT 1")
        await connection.close()
        do {
            _ = try await connection.execute("SELECT 1")
            throw RuntimeVerificationError.graphAssertion("query-unified-close-required")
        } catch QueryConnectionError.closed {}
        try require(try await values(retained.rows) == [[.primitive(.int32(99)), .primitive(.int64(100))]], "retained-after-close")
        let independent = try await context.openConnection()
        defer { await independent.close() }
        let checked = try await independent.execute("SELECT count(*) FROM query_unified")
        try require(try await values(checked.rows) == [[.primitive(.int64(100))]], "container-after-close")
    }

    #if CLOUDFLARE_RUNTIME_GRAPH_INDEXES
    private static func verifyGraphFailures(in context: DatabaseContext,
        connection: QueryConnection) async throws {
        for (maximum, text) in [(1, "ASK {}"),
            (1_024, "CONSTRUCT { <urn:s> <urn:p> \"" + String(repeating: "g", count: 2_000) + "\" } WHERE {}")] {
            let limits = try DatabaseWireLimits(maximumFrameBytes: maximum, maximumStringBytes: 10_000,
                maximumByteStringBytes: 10_000, maximumCollectionCount: 1_000,
                maximumNestingDepth: 64, maximumObjectCount: 10_000)
            let bounded = try await context.openConnection(limits: limits)
            defer { await bounded.close() }
            do {
                _ = try await bounded.execute(QueryInput.text(language: .sparql, statement: text))
                throw RuntimeVerificationError.graphAssertion("query-unified-graph-limit-required")
            } catch let error as QueryResponseEncodingError {
                guard case .resourceLimit(.frameTooLarge(_, let actualMaximum)) = error,
                      actualMaximum == maximum else {
                    throw RuntimeVerificationError.graphAssertion("query-unified-graph-limit-cause")
                }
            }
            if maximum > 1 {
                let next = try await bounded.execute(QueryInput.text(language: .sparql, statement: "ASK {}"))
                guard case .boolean(let answer) = next, answer.value else {
                    throw RuntimeVerificationError.graphAssertion("query-unified-graph-failure-close")
                }
                do {
                    _ = try await connection.execute(QueryInput.text(language: .sparql, statement: text),
                        options: .init(budget: .init(maximumWorkUnits: 1)))
                    throw RuntimeVerificationError.graphAssertion("query-unified-namespace-work-required")
                } catch is DatabaseWorkLimitError {}
            }
        }
    }
    #endif

    private static func values<Rows: QueryRows>(_ rows: Rows) async throws -> [[QueryValue]] {
        var output: [[QueryValue]] = []
        for try await row in rows { output.append(row.values) }
        return output
    }

    private static func require(_ condition: Bool, _ name: String) throws {
        if !condition { throw RuntimeVerificationError.graphAssertion("query-unified-" + name) }
    }
}
