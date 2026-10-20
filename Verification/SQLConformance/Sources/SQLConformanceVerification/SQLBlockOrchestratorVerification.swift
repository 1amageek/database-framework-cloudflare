@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit

/// Uses the same graph-free executor called by the native semantic facade.
enum SQLBlockOrchestratorVerification {
    typealias Failure = ParameterBindingVerification.Failure

    static func verify(in context: DatabaseContext) async throws {
        let executor = SQLBlockExecutor(context: context)
        let options = try options()
        let result = try await executor.execute(SQLBlock(steps: [
            .statement(insert("s12-block", "first")), .savepoint("same"),
            .statement(update("second")), .savepoint("same"),
            .statement(update("third")), .statement(read(duplicate: true)),
            .rollbackTo("same"), .statement(read()), .release("same"),
            .rollbackTo("same"), .statement(read()), .statement(read(empty: true)),
            .release("same"),
            .statement(.select(SelectQuery(projection: [ProjectionItem(.parameter(.position(1)))],
                source: .values([[]]))))
        ]), parameters: [QueryParameter(position: 1, value: .primitive(.int32(77)), type: .sql(.integer))],
            options: options)
        try require(result.results.count == 14, "ordered-result-count")
        try command(result.results[0], .insert, 1)
        try command(result.results[2], .update, 1)
        try command(result.results[6], .rollbackTo, nil)
        try command(result.results[8], .release, nil)
        let beforeRollback = try rows(result.results[5])
        try require(beforeRollback.columns.map { $0.name } == ["value", "value"], "duplicate-labels")
        try require(beforeRollback.rows.first?.values == [.primitive(.string("third")), .primitive(.string("third"))],
            "earlier-results-survive-rollback")
        try require(try rows(result.results[7]).rows.first?.values == [.primitive(.string("second"))],
            "nearest-repeated-name")
        try require(try rows(result.results[10]).rows.first?.values == [.primitive(.string("first"))],
            "release-reveals-older-name")
        let empty = try rows(result.results[11])
        try require(empty.rows.isEmpty && empty.columns.count == 1
            && empty.columns[0].type == .primitive(.string, isArray: false) && !empty.columns[0].isNullable,
            "empty-result-retains-schema")
        let parameter = try rows(result.results[13])
        try require(parameter.rows.first?.values == [.primitive(.int32(77))]
            && parameter.columns.map { $0.type } == [.sql(.integer)], "typed-parameter")
        let committed = try await context.model(for: "s12-block", as: RuntimeVerificationDocument.self)
        try require(committed?.title == "first", "independent-final-state")
        let zero = try self.options(budget: ExecutionBudget(maximumRows: 0))
        let zeroRows = try await executor.execute(SQLBlock(steps: [
            .savepoint("zero"), .statement(read(empty: true)), .statement(read(zeroLimit: true)),
            .rollbackTo("zero"), .release("zero")
        ]), options: zero)
        for index in [1, 2] {
            let retained = try rows(zeroRows.results[index])
            try require(retained.rows.isEmpty && retained.columns.count == 1
                && retained.columns[0].name == "title"
                && retained.columns[0].type == .primitive(.string, isArray: false)
                && !retained.columns[0].isNullable, "zero-budget-empty-metadata")
        }
        do {
            _ = try await executor.execute(SQLBlock(steps: [.statement(read())]), options: zero)
            throw Failure.assertion("s12-block-nonempty-zero-budget-must-throw")
        } catch is DatabaseWorkLimitError {}
        print("ENGINE_S12_BLOCK_CHECK retained-order-names-typed-rows PASS")

        do {
            _ = try await executor.execute(SQLBlock(steps: [
                .statement(insert("s12-block-before", "uncommitted")), .savepoint("point"),
                .statement(insert("s12-block", "duplicate")), .rollbackTo("point"),
                .statement(insert("s12-block-after", "must-not-run"))
            ]), options: options)
            throw Failure.assertion("s12-block-first-error-must-throw")
        } catch {
            guard case DatabaseContextError.preconditionFailed(let identity, .notExists, _) = error,
                identity.entity == RuntimeVerificationDocument.persistableType else { throw error }
        }
        let before = try await context.model(for: "s12-block-before", as: RuntimeVerificationDocument.self)
        let after = try await context.model(for: "s12-block-after", as: RuntimeVerificationDocument.self)
        let survivor = try await context.model(for: "s12-block", as: RuntimeVerificationDocument.self)
        try require(before == nil && after == nil && survivor?.title == "first", "first-error-entire-rollback")
        print("ENGINE_S12_BLOCK_CHECK first-error-stops-later-recovery PASS")

        do {
            _ = try await executor.execute(SQLBlock(steps: [
                .statement(insert("s12-block-unknown", "uncommitted")),
                .savepoint("released"), .release("released"), .rollbackTo("released")
            ]), options: options)
            throw Failure.assertion("s12-block-released-name-must-throw")
        } catch SQLBlockExecutionError.unknownCheckpoint("released") {}
        let unknown = try await context.model(for: "s12-block-unknown", as: RuntimeVerificationDocument.self)
        try require(unknown == nil, "released-name-whole-rollback")
        print("ENGINE_S12_BLOCK_CHECK released-name-whole-rollback PASS")

        do {
            _ = try await executor.execute(SQLBlock(steps: [
                .statement(insert("s12-block-budget", "uncommitted")),
                .statement(constant(1)), .statement(constant(2))
            ]), options: try self.options(budget: ExecutionBudget(maximumRows: 2)))
            throw Failure.assertion("s12-block-cumulative-output-must-throw")
        } catch is DatabaseWorkLimitError {}
        let limited = try await context.model(for: "s12-block-budget", as: RuntimeVerificationDocument.self)
        try require(limited == nil, "cumulative-output-whole-rollback")
        let followup = try await executor.execute(SQLBlock(steps: [.statement(constant(3))]), options: options)
        try require(try rows(followup.results[0]).rows.first?.values == [.primitive(.int64(3))], "failed-block-followup")
        print("ENGINE_S12_BLOCK_CHECK cumulative-output-and-followup PASS")
    }

    private static func options(budget: ExecutionBudget = ExecutionBudget()) throws -> SQLBlockExecutionOptions {
        SQLBlockExecutionOptions(checkpointLimits: try SQLCheckpointVerification.limits(), budget: budget)
    }

    private static func insert(_ id: String, _ title: String) -> QueryStatement {
        .insert(InsertQuery(target: TableRef(RuntimeVerificationDocument.persistableType),
            columns: ["id", "title"], source: .values([[.string(id), .string(title)]])))
    }

    private static func update(_ title: String) -> QueryStatement {
        .update(UpdateQuery(target: TableRef(RuntimeVerificationDocument.persistableType),
            assignments: [Assignment(column: "title", value: .string(title))],
            filter: .equal(.col("id"), .string("s12-block"))))
    }

    private static func read(duplicate: Bool = false, empty: Bool = false, zeroLimit: Bool = false) -> QueryStatement {
        .select(SelectQuery(projection: duplicate ? [.column("title", as: "value"), .column("title", as: "value")]
                : [.column("title")], source: .table(TableRef(RuntimeVerificationDocument.persistableType)),
            filter: empty ? .literal(.bool(false)) : .equal(.col("id"), .string("s12-block")),
            pagination: QueryPagination(limit: zeroLimit ? .count(.fixed(0), withTies: false) : nil)))
    }

    private static func constant(_ value: Int64) -> QueryStatement {
        .select(SelectQuery(projection: [ProjectionItem(.literal(
            .queryValue(.primitive(.int64(value)), type: .sql(.bigint))))], source: .values([[]])))
    }

    private static func rows(_ result: SQLStatementResult) throws -> QueryResponse {
        guard case .rows(let rows) = result else { throw Failure.assertion("s12-block-expected-rows") }
        return rows
    }

    private static func command(_ result: SQLStatementResult, _ expected: SQLCommandKind, _ affected: UInt64?) throws {
        guard case .command(let kind, let count) = result else { throw Failure.assertion("s12-block-expected-command") }
        try require(kind == expected && count == affected, "command-kind-and-count")
    }

    private static func require(_ condition: Bool, _ name: String) throws {
        try SQLCheckpointVerification.require(condition, "block-" + name)
    }
}
