import Database
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit

enum SQLPreparationVerification {
    static func verify(
        in context: DatabaseContext,
        restricted: DatabaseContext
    ) async throws {
        let options = try blockOptions()
        _ = try await context.executeSQLBlock("CREATE TABLE preparation_probe(n INTEGER)", options: options)

        let definitions = (0..<100).map { "c\($0) AS (SELECT \($0) AS n)" }.joined(separator: ",")
        let subqueries = (0..<100).map { "(SELECT \($0))" }.joined(separator: ",")
        let prefix = "WITH " + definitions + " INSERT INTO preparation_probe VALUES "
        let wide = try await context.executeSQLBlock(
            prefix + "(cardinality(ARRAY[" + subqueries + "]))", options: options)
        try requireInsert(wide, count: 1)
        do {
            _ = try await context.executeSQLBlock(prefix + "(1 / 0)", options: options)
            throw RuntimeVerificationError.graphAssertion("preparation-late-failure-required")
        } catch let failure as SQLExecutionFailure {
            guard failure.diagnostic.sqlState == "22012" else { throw failure }
        }
        try await requireValues(context, sql: "SELECT COUNT(*),MAX(n) FROM preparation_probe",
            expected: [[.primitive(.int64(1)), .primitive(.int32(100))]])

        let widerDefinitions = (0..<256).map { "c\($0) AS (SELECT \($0) AS n)" }.joined(separator: ",")
        let wider = try await context.executeSQLBlock(
            "WITH " + widerDefinitions + " INSERT INTO preparation_probe VALUES (7)", options: options)
        try requireInsert(wider, count: 1)
        let array = (0..<1000).map(String.init).joined(separator: ",")
        try requireInsert(try await context.executeSQLBlock(
            "INSERT INTO preparation_probe VALUES (cardinality(ARRAY[" + array + "]))",
            options: options), count: 1)
        try await requireValues(context, sql: "SELECT COUNT(*),MAX(n) FROM preparation_probe",
            expected: [[.primitive(.int64(3)), .primitive(.int32(1000))]])

        try context.upsert(RuntimeVerificationDocument(id: "preparation-seed", title: "original"))
        try await context.save()
        try requireInsert(try await context.executeSQLBlock("""
            WITH source AS (SELECT title FROM "RuntimeVerificationDocument" WHERE id = 'preparation-seed'),
                 "RuntimeVerificationDocument" AS (SELECT 'shadowed' AS title)
            INSERT INTO "RuntimeVerificationDocument" (id, title) SELECT 'preparation-copy', title FROM source
            """, options: options), count: 1)
        try await requireValues(context,
            sql: "SELECT title FROM \"RuntimeVerificationDocument\" WHERE id = 'preparation-copy'",
            expected: [[.primitive(.string("original"))]])
        _ = try await context.executeSQLBlock("""
            WITH copied AS (INSERT INTO "RuntimeVerificationDocument" (id, title)
                    VALUES ('preparation-eager', (SELECT title FROM "RuntimeVerificationDocument" WHERE id = 'preparation-seed')) RETURNING title),
                 "RuntimeVerificationDocument" AS (SELECT 'shadowed' AS title)
            INSERT INTO "RuntimeVerificationDocument" (id, title) SELECT 'preparation-eager-copy', title FROM copied
            """, options: options)
        try await requireValues(context,
            sql: "SELECT title FROM \"RuntimeVerificationDocument\" WHERE id IN ('preparation-eager','preparation-eager-copy')",
            expected: [[.primitive(.string("original"))], [.primitive(.string("original"))]])

        for functionOnLeft in [true, false] {
            for orderColumn in ["public_key", "hidden_value"] {
                let sql: String
                if functionOnLeft {
                    sql = """
                        SELECT (SELECT j.hidden_value
                          FROM (generate_series(1,2) AS f(n) CROSS JOIN (SELECT r.title AS hidden_value) AS d)
                            AS j(public_key,hidden_value)
                          ORDER BY j.\(orderColumn) LIMIT 1)
                        FROM "RuntimeVerificationDocument" AS r WHERE r.id = 'preparation-seed'
                        """
                } else {
                    sql = """
                        SELECT (WITH d AS (SELECT r.title AS hidden_value) SELECT j.hidden_value
                          FROM (d CROSS JOIN generate_series(1,2) AS f(n)) AS j(hidden_value,public_key)
                          ORDER BY j.\(orderColumn) LIMIT 1)
                        FROM "RuntimeVerificationDocument" AS r WHERE r.id = 'preparation-seed'
                        """
                }
                try await requireValues(context, sql: sql, expected: [[.primitive(.string("original"))]])
                if orderColumn == "public_key" {
                    try await requireValues(restricted, sql: sql, expected: [[.primitive(.string("original"))]])
                } else {
                    do {
                        _ = try await restricted.executeSQL(sql)
                        throw RuntimeVerificationError.graphAssertion("preparation-secret-order-required-denial")
                    } catch is SecurityError {}
                }
            }
        }

        _ = try await context.executeSQLBlock("CREATE TABLE preparation_budget(n INTEGER)", options: options)
        let values = (0..<100).map { "(\($0))" }.joined(separator: ",")
        do {
            _ = try await context.executeSQLBlock("INSERT INTO preparation_budget VALUES " + values,
                options: blockOptions(budget: ExecutionBudget(maximumRows: 99)))
            throw RuntimeVerificationError.graphAssertion("preparation-budget-required-failure")
        } catch let failure as SQLExecutionFailure {
            guard failure.diagnostic.sqlState == "54000",
                  failure.diagnostic.category == .resource,
                  let cause = failure.underlyingError as? DatabaseEntityMutationError,
                  case .changeLimitExceeded(let actual, let maximum) = cause,
                  actual == 100, maximum == 99 else { throw failure }
        }
        try await requireValues(context, sql: "SELECT COUNT(*) FROM preparation_budget",
            expected: [[.primitive(.int64(0))]])
        try requireInsert(try await context.executeSQLBlock("INSERT INTO preparation_budget VALUES " + values,
            options: blockOptions(budget: ExecutionBudget(maximumRows: 100))), count: 100)
        try await requireValues(context, sql: "SELECT COUNT(*),MAX(n) FROM preparation_budget",
            expected: [[.primitive(.int64(100)), .primitive(.int32(99))]])
    }

    private static func blockOptions(budget: ExecutionBudget = ExecutionBudget()) throws -> SQLBlockExecutionOptions {
        SQLBlockExecutionOptions(checkpointLimits: try TransactionCheckpointLimits(
            maximumEntries: 10_000, maximumDepth: 32, maximumRetainedBytes: 16_000_000,
            maximumWorkUnits: 1_000_000, maximumReadPageRows: 1000), budget: budget)
    }

    private static func requireValues(
        _ context: DatabaseContext,
        sql: String,
        expected: [[QueryValue]]
    ) async throws {
        let result = try await context.executeSQL(sql)
        guard result.rows.map({ $0.values }) == expected else {
            throw RuntimeVerificationError.graphAssertion("preparation-values")
        }
    }

    private static func requireInsert(_ block: SQLBlockResult, count: UInt64) throws {
        guard block.results.count == 1,
              case .command(.insert, let actual) = block.results[0], actual == count else {
            throw RuntimeVerificationError.graphAssertion("preparation-insert-count")
        }
    }
}
