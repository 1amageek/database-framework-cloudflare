@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit

/// Executes the production prepared-query session SPI against the application's real container.
enum ParameterBindingVerification {
    enum Failure: Error { case assertion(String) }

    static func require(_ condition: Bool, _ name: String) throws {
        guard condition else { throw Failure.assertion(name) }
    }

    static func values(_ rows: [[Literal]], columns: [String]? = nil) -> DataSource {
        let source = DataSource.values(rows.map { $0.map(Expression.literal) })
        guard let columns else { return source }
        return .aliased(source, name: "fixture_values", columns: columns)
    }

    static func select(_ expressions: [Expression], empty: Bool = false) -> SelectQuery {
        SelectQuery(projection: expressions.map { ProjectionItem($0) },
                    source: ParameterBindingVerification.values(empty ? [] : [[]], columns: nil))
    }

    private struct Invocation: Sendable {
        let context: DatabaseContext
        let container: DBContainer

        func query(_ select: SelectQuery, parameters: [QueryParameter] = [],
                   options: ReadExecutionOptions = .default) async throws -> QueryResponse {
            let execution = ReadExecutionContext(options: options, monotonicClock: container.monotonicClock)
            return try await context.indexQueryContext.withSession(workMeter: execution.workMeter) { session in
                try await session.executeCanonical(select, execution: execution, parameters: parameters)
            }
        }
    }

    static func verify(in context: DatabaseContext, container: DBContainer) async throws {
        let invocation = Invocation(context: context, container: container)
        var phase = "unknown-vs-text"
        do {
        let parameter = Expression.parameter(.position(1))
        let untypedNull = [QueryParameter(position: 1, value: .primitive(.null))]
        let unknown = try await invocation.query(select([
            .equal(.literal(.sqlUnknownString("7")), .literal(.int(7))),
        ]))
        try require(unknown.rows.first?.values == [.primitive(.bool(true))], "unknown-coercion")
        do {
            _ = try await invocation.query(select([
                .equal(.literal(.string("7")), .literal(.int(7))),
            ]))
            throw Failure.assertion("typed-text-must-fail")
        } catch is DatabaseExpressionEvaluationError {
        } catch CanonicalReadError.expressionEvaluation {}
        for type: QueryColumnType in [.primitive(.bool), .sql(.boolean)] {
            let flag = Expression.column(ColumnRef("eligible"))
            let booleans = try await invocation.query(SelectQuery(
                projection: [
                    ProjectionItem(.equal(flag, .literal(.bool(true)))),
                    ProjectionItem(.equal(.literal(.bool(true)), flag)),
                ], source: ParameterBindingVerification.values([
                    [.queryValue(.primitive(.bool(true)), type: type)],
                    [.queryValue(.primitive(.bool(false)), type: type)],
                    [.queryValue(.primitive(.null), type: type)],
                ], columns: ["eligible"])))
            try require(booleans.columns.map { $0.type } == [.sql(.boolean), .sql(.boolean)],
                        "boolean-representation-schema")
            try require(booleans.rows.map { $0.values } == [
                [.primitive(.bool(true)), .primitive(.bool(true))],
                [.primitive(.bool(false)), .primitive(.bool(false))],
                [.primitive(.null), .primitive(.null)],
            ], "boolean-representation-values")
        }
        print("ENGINE_BINDING_CASE unknown-vs-text PASS")

        phase = "typed-null-casts"
        let typedNull = try await invocation.query(select([
            .cast(.literal(.queryValue(.primitive(.null), type: .sql(.smallint))), targetType: .integer),
        ]))
        try require(typedNull.columns.map { $0.type } == [.sql(.integer)], "typed-null-schema")
        try require(typedNull.rows.first?.values == [.primitive(.null)], "typed-null-value")
        do {
            _ = try await invocation.query(select([
                .cast(.literal(.queryValue(.primitive(.null), type: .sql(.integer))), targetType: .date),
            ], empty: true))
            throw Failure.assertion("typed-null-illegal-cast")
        } catch is DatabaseExpressionEvaluationError {
        } catch CanonicalReadError.expressionEvaluation {}
        print("ENGINE_BINDING_CASE typed-null-casts PASS")

        phase = "contextual-parameter"
        let output = try await invocation.query(select([parameter]), parameters: untypedNull)
        try require(output.columns.map { $0.type } == [.sql(.text)], "output-null-type")
        let contextual = try await invocation.query(select([
            .equal(parameter, .literal(.int(7))),
        ]), parameters: untypedNull)
        try require(contextual.columns.map { $0.type } == [.sql(.boolean)], "contextual-null-type")
        try require(contextual.rows.first?.values == [.primitive(.null)], "contextual-null-value")
        print("ENGINE_BINDING_CASE contextual-parameter PASS")

        phase = "ordered-parameter-empty-errors"
        let ordered = try await invocation.query(select([
            .cast(parameter, targetType: .integer), .cast(parameter, targetType: .text),
        ]), parameters: untypedNull)
        try require(ordered.columns.map { $0.type } == [.sql(.integer), .sql(.text)], "ordered-cast-columns")
        try require(ordered.rows.first?.values == [.primitive(.null), .primitive(.null)], "ordered-cast-values")
        for expressions in [[Expression.isNull(parameter)], [parameter, .isNull(parameter)],
                            [.isNull(parameter), .cast(parameter, targetType: .integer)]] {
            do {
                _ = try await invocation.query(select(expressions, empty: true), parameters: untypedNull)
                throw Failure.assertion("ordered-ambiguity-must-fail")
            } catch is DatabaseExpressionEvaluationError {
        } catch CanonicalReadError.expressionEvaluation {}
        }
        print("ENGINE_BINDING_CASE ordered-parameter-empty-errors PASS")

        phase = "cast-and-empty-schema"
        let cast = try await invocation.query(select([.cast(parameter, targetType: .text)]),
            parameters: [QueryParameter(position: 1, value: .primitive(.int32(7)))])
        try require(cast.rows.first?.values == [.primitive(.string("7"))], "non-null-cast")
        let empty = try await invocation.query(select([.cast(parameter, targetType: .integer)], empty: true),
            parameters: untypedNull)
        try require(empty.rows.isEmpty && empty.columns.map { $0.type } == [.sql(.integer)], "empty-schema")
        phase = "exact-decimal-aggregate"
        let amount = Expression.column(ColumnRef("amount"))
        let aggregates = try await invocation.query(SelectQuery(
            projection: [
                ProjectionItem(.aggregate(.sum(amount, distinct: false))),
                ProjectionItem(.aggregate(.avg(amount, distinct: false))),
            ], source: ParameterBindingVerification.values([
                [.decimal(ExactDecimal(coefficient: 1, scale: 0))],
                [.decimal(ExactDecimal(coefficient: 3, scale: 0))],
            ], columns: ["amount"])))
        try require(aggregates.columns.map { $0.type } == [
            .sql(.decimal(precision: nil, scale: nil)), .sql(.decimal(precision: nil, scale: nil)),
        ], "exact-decimal-aggregate-schema")
        try require(aggregates.rows.first?.values == [
            .numeric(try QueryNumericValue(value: ExactDecimal(coefficient: 4, scale: 0), displayScale: 0)),
            .numeric(try QueryNumericValue(value: ExactDecimal(coefficient: 2, scale: 0), displayScale: 16)),
        ], "exact-decimal-sum-average")
        print("ENGINE_BINDING_CASE cast-and-empty-schema PASS")

        phase = "budget-failure-followup"
        do {
            _ = try await invocation.query(select([.literal(.int(1))]),
                options: ReadExecutionOptions(budget: ExecutionBudget(maximumWorkUnits: 0)))
            throw Failure.assertion("zero-work-budget-must-fail")
        } catch is DatabaseWorkLimitError {}
        do {
            _ = try await invocation.query(select([
                .divide(.literal(.int(1)), .literal(.int(0))),
            ]))
            throw Failure.assertion("division-by-zero-must-fail")
        } catch CanonicalReadError.expressionEvaluation(.divisionByZero, _) {}
        let after = try await invocation.query(select([.cast(parameter, targetType: .integer)]),
            parameters: [QueryParameter(position: 1, value: .primitive(.int32(11)))])
        try require(after.rows.first?.values == [.primitive(.int32(11))], "failure-followup")
        print("ENGINE_BINDING_CASE budget-failure-followup PASS")

        phase = "concurrent-query-isolation"
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        let result = try await invocation.query(select([.cast(parameter, targetType: .integer)]),
                            parameters: [QueryParameter(position: 1, value: .primitive(.int32(Int32(index))))])
                        try require(result.columns.map { $0.type } == [.sql(.integer)], "concurrent-integer-type")
                        try require(result.rows.first?.values == [.primitive(.int32(Int32(index)))], "concurrent-integer-value")
                    } else {
                        let value = "query-\(index)"
                        let result = try await invocation.query(select([parameter]),
                            parameters: [QueryParameter(position: 1, value: .primitive(.string(value)))])
                        try require(result.columns.map { $0.type } == [.sql(.text)], "concurrent-text-type")
                        try require(result.rows.first?.values == [.primitive(.string(value))], "concurrent-text-value")
                    }
                }
            }
            try await group.waitForAll()
        }
        print("ENGINE_BINDING_CASE concurrent-query-isolation PASS operations=8")

        phase = "storage-roundtrip-and-primitive-unknown"
        let primitiveSource = SelectQuery(projection: [
            ProjectionItem(.add(.column(ColumnRef("rank")), .literal(.sqlUnknownString("1")))),
            ProjectionItem(.coalesce([.column(ColumnRef("rank")), .literal(.sqlUnknownString("1"))])),
        ], source: ParameterBindingVerification.values([[
            .queryValue(.primitive(.int64(7)), type: .primitive(.int64)),
        ]], columns: ["rank"]),
            filter: .equal(.column(ColumnRef("rank")), .literal(.sqlUnknownString("7"))))
        let primitiveResult = try await invocation.query(primitiveSource)
        try require(primitiveResult.rows.first?.values == [.primitive(.int64(8)), .primitive(.int64(7))],
                    "primitive-int64-unknown-context")
        let tableQuery = SelectQuery(projection: [ProjectionItem(.column(ColumnRef("title")))],
            source: .table(TableRef("RuntimeVerificationDocument")),
            filter: .equal(.column(ColumnRef("title")), parameter))
        let stored = try await invocation.query(tableQuery,
            parameters: [QueryParameter(position: 1, value: .primitive(.string("Cloudflare runtime")))])
        try require(stored.rows.first?.values == [.primitive(.string("Cloudflare runtime"))], "storage-parameter-query")
        print("ENGINE_BINDING_CASE storage-roundtrip-and-primitive-unknown PASS")
        phase = "expired-read-session-followup"
        let execution = ReadExecutionContext(monotonicClock: container.monotonicClock)
        let expired = try await context.indexQueryContext.withSession(workMeter: execution.workMeter) { session in
            session
        }
        do {
            _ = try await expired.executeCanonical(select([parameter]), execution: execution,
                parameters: [QueryParameter(position: 1, value: .primitive(.string("expired")))])
            throw Failure.assertion("expired-session-must-fail")
        } catch DatabaseTransactionError.invalidOperationContext {}
        let final = try await invocation.query(select([parameter]),
            parameters: [QueryParameter(position: 1, value: .primitive(.string("after-lifetime")))])
        try require(final.rows.first?.values == [.primitive(.string("after-lifetime"))], "lifetime-followup")
        print("ENGINE_BINDING_CASE expired-read-session-followup PASS")
        print("ENGINE_BINDING_PASS cases=9 concurrentOperations=8")
        } catch {
            throw SQLTextPatternVerification.DiagnosticFailure(phase: "binding-" + phase, cause: error)
        }
    }
}
