import Database
import DatabaseEngine
import DatabaseKit
import DatabaseTypes

enum SQLExecutionOptimizationVerification {
    static func verify(in context: DatabaseContext, restricted: DatabaseContext) async throws {
        for n in 1...3 {
            var document = RuntimeVerificationDocument()
            document.id = "sql-opt-\(n)"
            document.title = String(repeating: "x", count: n)
            try context.upsert(document)
        }
        try await context.save()
        let aggregate = try await context.executeSQL("SELECT max(title),count(*) FROM \"RuntimeVerificationDocument\" WHERE id LIKE 'sql-opt-%' LIMIT 1")
        try require(aggregate.rows.map { $0.values } == [[.primitive(.string("xxx")), .primitive(.int64(3))]], "aggregate-window")
        let columns = try await context.executeSQL("WITH c(a,b) AS (SELECT 1,2 UNION ALL SELECT 3,4) SELECT b,a,b FROM c WHERE a > 1 LIMIT 1")
        try require(columns.rows.map { $0.values } == [[.primitive(.int32(4)), .primitive(.int32(3)), .primitive(.int32(4))]], "column-transfer")
        var body = "SELECT n FROM (VALUES(1),(2),(3),(4),(5),(6),(7),(8)) v(n)"
        for n in 0..<16 { body = "WITH c\(n) AS (\(body)) SELECT n FROM c\(n)" }
        let nested = try await context.executeSQL("SELECT n FROM (\(body)) d ORDER BY n DESC LIMIT 1")
        try require(nested.rows.map { $0.values } == [[.primitive(.int32(8))]], "nested-demand")
        do {
            _ = try await context.query(SelectQuery(projection: [.expression(.col("column1"), alias: "projected")],
                source: .values([[.string("first")], [.string("second")]])),
                options: ReadExecutionOptions(budget: ExecutionBudget(maximumIntermediateRows: 4,
                    maximumIntermediateBytes: 1_024 * 1_024)))
            throw RuntimeVerificationError.graphAssertion("sql-opt-resource-must-fail")
        } catch let error as DatabaseWorkLimitError {
            guard case .maximumIntermediateRows(let stage, _, _, _) = error, stage == .projection else {
                throw RuntimeVerificationError.graphAssertion("sql-opt-resource-stage")
            }
        }
        do {
            _ = try await restricted.executeSQL("SELECT (SELECT n FROM (VALUES(1),(2)) t(n) ORDER BY n * length(r.title) LIMIT 1) FROM \"RuntimeVerificationDocument\" r WHERE id LIKE 'sql-opt-%'")
            throw RuntimeVerificationError.graphAssertion("sql-opt-order-must-deny")
        } catch is SecurityError { }
        let allowed = try await restricted.executeSQL("SELECT (SELECT n FROM (VALUES(1),(2)) t(n) ORDER BY n * length(r.id) LIMIT 1) FROM \"RuntimeVerificationDocument\" r WHERE id LIKE 'sql-opt-%'")
        try require(allowed.rows.count == 3, "correlated-order-allow")
        for sql in [
            "SELECT (SELECT title FROM (VALUES(2),(1)) t(title) ORDER BY title LIMIT 1) FROM \"RuntimeVerificationDocument\" r WHERE id LIKE 'sql-opt-%'",
            "SELECT (SELECT title FROM generate_series(1,2) t(title) ORDER BY title LIMIT 1) FROM \"RuntimeVerificationDocument\" r WHERE id LIKE 'sql-opt-%'",
            "SELECT (SELECT u.n FROM (SELECT id AS source_id FROM \"RuntimeVerificationDocument\") z CROSS JOIN unnest(ARRAY[r.id,'public']) WITH ORDINALITY u(title,n) ORDER BY title LIMIT 1) FROM \"RuntimeVerificationDocument\" r WHERE id LIKE 'sql-opt-%'"
        ] {
            let expected = try await context.executeSQL(sql)
            try require(expected.rows.count == 3, "local-order-control")
            let actual = try await restricted.executeSQL(sql)
            try require(actual.rows.map { $0.values } == expected.rows.map { $0.values }, "local-order-allow")
        }
        for sql in [
            "SELECT (SELECT u.n FROM (SELECT id AS source_id FROM \"RuntimeVerificationDocument\") z CROSS JOIN unnest(ARRAY[r.title,'public']) WITH ORDINALITY u(id,n) ORDER BY id LIMIT 1) FROM \"RuntimeVerificationDocument\" r WHERE id LIKE 'sql-opt-%'",
            "SELECT (WITH c AS (SELECT id AS source_id FROM \"RuntimeVerificationDocument\") SELECT u.n FROM c CROSS JOIN unnest(ARRAY[r.title,'public']) WITH ORDINALITY u(id,n) ORDER BY id LIMIT 1) FROM \"RuntimeVerificationDocument\" r WHERE id LIKE 'sql-opt-%'"
        ] {
            let expected = try await context.executeSQL(sql)
            try require(expected.rows.count == 3, "opaque-order-control")
            do {
                _ = try await restricted.executeSQL(sql)
                throw RuntimeVerificationError.graphAssertion("opaque-order-must-deny")
            } catch is SecurityError { }
        }
        let block = SQLBlockExecutionOptions(checkpointLimits: try TransactionCheckpointLimits(
            maximumEntries: 1000, maximumDepth: 16, maximumRetainedBytes: 8_000_000,
            maximumWorkUnits: 1_000_000, maximumReadPageRows: 128))
        _ = try await context.executeSQLBlock("CREATE TABLE portable_zero_demand(n INTEGER)", options: block)
        let values = (0..<100).map { "(\($0))" }.joined(separator: ",")
        let inserted = try await context.executeSQLBlock("INSERT INTO portable_zero_demand VALUES " + values, options: block)
        try require(inserted.results.count == 1, "bulk-one-statement")
        guard case .command(.insert, let affected) = inserted.results[0], affected == 100 else {
            throw RuntimeVerificationError.graphAssertion("sql-opt-bulk-affected-count")
        }
        _ = try await context.executeSQLBlock("CREATE TABLE portable_bulk_rollback(n INTEGER)", options: block)
        let validPrefix = (0..<99).map { "(\($0))" }.joined(separator: ",")
        do {
            _ = try await context.executeSQLBlock("INSERT INTO portable_bulk_rollback VALUES "
                + validPrefix + ",(1 / 0)", options: block)
            throw RuntimeVerificationError.graphAssertion("sql-opt-bulk-late-value-must-fail")
        } catch let failure as SQLExecutionFailure {
            guard failure.diagnostic.sqlState == "22012" else { throw failure }
        }
        let rolledBack = try await context.executeSQL("SELECT COUNT(*) FROM portable_bulk_rollback")
        try require(rolledBack.rows.map { $0.values } == [[.primitive(.int64(0))]], "bulk-rollback")
        let budget = ReadExecutionOptions(budget: ExecutionBudget(maximumRows: 1000, maximumWorkUnits: 1_000_000,
            maximumIntermediateRows: 32, maximumIntermediateBytes: 8_000_000, timeoutMilliseconds: 30_000))
        let complete = try await context.executeSQL("SELECT MAX(n),COUNT(*) FROM portable_zero_demand LIMIT 1")
        try require(complete.rows.map { $0.values } == [[.primitive(.int32(99)), .primitive(.int64(100))]], "zero-demand-control")
        for indexed in [false, true] {
            if indexed { _ = try await context.executeSQLBlock("CREATE INDEX portable_zero_n ON portable_zero_demand(n)", options: block) }
            let zero = try await context.executeSQL("SELECT MAX(n),COUNT(*) FROM portable_zero_demand LIMIT 0", options: budget)
            try require(zero.rows.isEmpty && zero.columns == complete.columns, "aggregate-zero-demand")
        }
    }
    private static func require(_ condition: Bool, _ name: String) throws {
        guard condition else { throw RuntimeVerificationError.graphAssertion("sql-opt-" + name) }
    }
}
