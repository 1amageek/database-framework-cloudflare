@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit

/// Runs selected SQL behavior through the production canonical read session.
enum SelectedValueVerification {
    typealias Failure = ParameterBindingVerification.Failure
    static let decimal = DataType.decimal(precision: nil, scale: nil)

    static func numeric(_ coefficient: Int128, scale: Int32 = 0, display: Int32 = 0) throws -> QueryValue {
        .numeric(try QueryNumericValue(value: ExactDecimal(coefficient: coefficient, scale: scale), displayScale: display))
    }

    static func number(_ coefficient: Int128, scale: Int32 = 0, display: Int32 = 0) throws -> Expression {
        .literal(.queryValue(try numeric(coefficient, scale: scale, display: display), type: .sql(decimal)))
    }

    static func call(_ name: String, _ arguments: [Expression]) -> Expression {
        .function(FunctionCall(name: name, arguments: arguments))
    }

    struct Invocation: Sendable {
        let context: DatabaseContext
        let container: DBContainer
        let temporalEnvironment: SQLTemporalEnvironment?

        init(context: DatabaseContext, container: DBContainer, temporalEnvironment: SQLTemporalEnvironment? = nil) {
            self.context = context
            self.container = container
            self.temporalEnvironment = temporalEnvironment
        }

        func query(_ query: SelectQuery, meter: DatabaseWorkMeter, parameters: [QueryParameter] = [],
                   occurrences: QueryOccurrenceArena? = nil, occurrence: QueryOccurrenceID? = nil) async throws -> QueryResponse {
            let execution = ReadExecutionContext(options: ReadExecutionOptions(budget: meter.budget),
                monotonicClock: container.monotonicClock, workMeter: meter, temporalEnvironment: temporalEnvironment)
            if let temporalEnvironment {
                return try await context.withSQLTemporalStatement(environment: temporalEnvironment) {
                    try await context.indexQueryContext.withSession(workMeter: meter) { session in
                        try await session.executeCanonical(query, execution: execution, parameters: parameters,
                            occurrences: occurrences, occurrence: occurrence)
                    }
                }
            }
            return try await context.indexQueryContext.withSession(workMeter: meter) { session in
                try await session.executeCanonical(query, execution: execution, parameters: parameters,
                            occurrences: occurrences, occurrence: occurrence)
            }
        }

        func meter() -> DatabaseWorkMeter {
            DatabaseWorkMeter(budget: ExecutionBudget(maximumRows: 100,
                maximumWorkUnits: 100_000_000, maximumIntermediateRows: 1_000,
                maximumIntermediateBytes: 8 * 1_024 * 1_024, timeoutMilliseconds: 60_000),
                monotonicClock: container.monotonicClock)
        }

        func verify(_ query: SelectQuery, values: [QueryValue], types: [QueryColumnType]? = nil,
                    parameters: [QueryParameter] = [], workMeter: DatabaseWorkMeter? = nil) async throws {
            let work = workMeter ?? meter()
            let result = try await self.query(query, meter: work, parameters: parameters)
            try ParameterBindingVerification.require(result.rows.count == 1 && result.rows[0].values == values,
                                                       "selected-values")
            if let types {
                try ParameterBindingVerification.require(result.columns.map { $0.type } == types,
                                                           "selected-declarations")
            }
            // Public response promotion ends every operation-local intermediate owner.
            try ParameterBindingVerification.require(work.retainedIntermediateBytes == 0
                && work.retainedIntermediateRows == 0, "selected-public-promotion-release")
        }

        func fails(_ expression: Expression, cause: DatabaseExpressionEvaluationError) async throws {
            let work = meter()
            do {
                _ = try await query(ParameterBindingVerification.select([expression]), meter: work)
                throw Failure.assertion("selected-expression-must-fail")
            } catch CanonicalReadError.expressionEvaluation(let actual, _) {
                try ParameterBindingVerification.require(actual == cause, "selected-typed-cause")
            }
            try ParameterBindingVerification.require(work.retainedIntermediateBytes == 0
                && work.retainedIntermediateRows == 0, "selected-failure-release")
        }
    }

    static func verify(in context: DatabaseContext, container: DBContainer) async throws {
        let invocation = Invocation(context: context, container: container)
        var phase = "selected-numeric-scale"
        do {
        func select(_ expressions: [Expression]) -> SelectQuery {
            ParameterBindingVerification.select(expressions)
        }
        let one = try number(1), three = try number(3)
        try await invocation.verify(select([
            .divide(one, three), .divide(try number(1), try number(10)),
            .add(try number(12, scale: 1, display: 2), try number(23, scale: 1, display: 3)),
            .multiply(try number(12, scale: 1, display: 2), try number(23, scale: 1, display: 3)),
            .cast(.literal(.queryValue(.primitive(.float64(1.2345678901234567)), type: .sql(.doublePrecision))), targetType: decimal),
        ]), values: [
            try numeric(33_333_333_333_333_333_333, scale: 20, display: 20),
            try numeric(1, scale: 1, display: 20), try numeric(35, scale: 1, display: 3),
            try numeric(276, scale: 2, display: 5), try numeric(123456789012346, scale: 14, display: 14),
        ], types: Array(repeating: .sql(decimal), count: 5))
        try await invocation.fails(.divide(one, try number(0)), cause: .divisionByZero)
        print("ENGINE_SELECTED_CASE selected-numeric-scale PASS")

        try await invocation.verify(select([
            call("sqrt", [try number(25, scale: 1, display: 4)]),
            call("exp", [try number(25, scale: 1, display: 4)]),
            call("ln", [try number(25, scale: 1, display: 4)]),
            call("power", [try number(2, display: 3), try number(5, scale: 1, display: 2)]),
        ]), values: [
            try numeric(158113883008419, scale: 14, display: 15),
            try numeric(12182493960703473, scale: 15, display: 15),
            try numeric(9162907318741551, scale: 16, display: 16),
            try numeric(1414213562373095, scale: 15, display: 16),
        ], types: Array(repeating: .sql(decimal), count: 4))
        try await invocation.fails(call("sqrt", [try number(-1)]), cause: .numericDomain(operation: "SQRT"))
        // Retained R2 vectors use exact integer powers and selected display scales.
        let tinyPowerQuery = select([
            call("power", [try number(1, scale: 15, display: 15), try number(-2)]),
            call("power", [try number(-1, scale: 10, display: 10), try number(-3)]),
            call("power", [try number(1, scale: 15, display: 15), try number(2)]),
        ])
        let powerMeter = invocation.meter()
        try await invocation.verify(tinyPowerQuery, values: [
            try numeric(1, scale: -30, display: 15),
            try numeric(-1, scale: -30, display: 10),
            try numeric(1, scale: 30, display: 46),
        ], types: Array(repeating: .sql(decimal), count: 3), workMeter: powerMeter)
        // Derive the work admission from the completed query instead of guessing a limit.
        let limitedPowerMeter = DatabaseWorkMeter(budget: ExecutionBudget(maximumRows: 100,
            maximumWorkUnits: max(1, powerMeter.consumedWorkUnits / 2),
            maximumIntermediateRows: 1_000, maximumIntermediateBytes: 8 * 1_024 * 1_024,
            timeoutMilliseconds: 60_000), monotonicClock: container.monotonicClock)
        do {
            _ = try await invocation.query(tinyPowerQuery, meter: limitedPowerMeter)
            throw Failure.assertion("review-power-work-limit-must-fail")
        } catch is DatabaseWorkLimitError {}
        try ParameterBindingVerification.require(limitedPowerMeter.retainedIntermediateBytes == 0
            && limitedPowerMeter.retainedIntermediateRows == 0, "review-power-work-limit-release")
        print("ENGINE_SELECTED_CASE decimal-math PASS")

        phase = "aggregate-prepare-max38"
        let amount = Expression.column(ColumnRef("amount"))
        let maximum: Int128 = 99_999_999_999_999_999_999_999_999_999_999_999_999
        let twoMaximum = SelectQuery(projection: [ProjectionItem(.aggregate(.avg(amount, distinct: false)))],
            source: ParameterBindingVerification.values([[.queryValue(try numeric(maximum), type: .sql(decimal))],
                             [.queryValue(try numeric(maximum), type: .sql(decimal))]], columns: ["amount"]))
        phase = "aggregate-avg-max38-pair"
        try await invocation.verify(twoMaximum, values: [try numeric(maximum)], types: [.sql(decimal)])
        phase = "aggregate-sum-max38-pair-expected-failure"
        let overflow = SelectQuery(projection: [ProjectionItem(.aggregate(.sum(amount, distinct: false)))],
            source: twoMaximum.source)
        let overflowMeter = invocation.meter()
        do {
            _ = try await invocation.query(overflow, meter: overflowMeter)
            throw Failure.assertion("final-sum-overflow-must-fail")
        } catch CanonicalReadError.expressionEvaluation(.numericOverflow, _) {}
        try ParameterBindingVerification.require(overflowMeter.retainedIntermediateBytes == 0
            && overflowMeter.retainedIntermediateRows == 0, "aggregate-failure-release")
        phase = "aggregate-distinct"
        let distinct = SelectQuery(projection: [
            ProjectionItem(.aggregate(.sum(amount, distinct: true))),
            ProjectionItem(.aggregate(.avg(amount, distinct: true))),
        ], source: ParameterBindingVerification.values([
            [.queryValue(try numeric(12, scale: 1, display: 3), type: .sql(decimal))],
            [.queryValue(try numeric(12, scale: 1, display: 3), type: .sql(decimal))],
            [.queryValue(try numeric(24, scale: 1, display: 3), type: .sql(decimal))],
        ], columns: ["amount"]))
        try await invocation.verify(distinct, values: [try numeric(36, scale: 1, display: 3),
            try numeric(18, scale: 1, display: 16)], types: [.sql(decimal), .sql(decimal)])
        phase = "aggregate-primitive-carriers"
        for (sourceType, value, total, average): (QueryColumnType, QueryValue, QueryValue, QueryValue) in [
            (.primitive(.int64), .primitive(.int64(2)), try numeric(4), try numeric(2, display: 16)),
            (.primitive(.uint64), .primitive(.uint64(.max)),
             try numeric(Int128(UInt64.max) * 2), try numeric(Int128(UInt64.max))),
        ] {
            let query = SelectQuery(projection: [
                ProjectionItem(.aggregate(.sum(amount, distinct: false))),
                ProjectionItem(.aggregate(.avg(amount, distinct: false))),
            ], source: ParameterBindingVerification.values([
                [.queryValue(value, type: sourceType)], [.queryValue(value, type: sourceType)],
            ], columns: ["amount"]))
            try await invocation.verify(query, values: [total, average], types: [.sql(decimal), .sql(decimal)])
            let ownerMeter = invocation.meter()
            do {
                var accumulator = DatabaseNumericAggregateAccumulator(inputType: sourceType, workMeter: ownerMeter)
                try accumulator.add(value)
                try accumulator.add(value)
                try ParameterBindingVerification.require(try accumulator.sum() == total
                    && accumulator.average() == average, "primitive-selected-aggregate-values")
                try ParameterBindingVerification.require(ownerMeter.retainedIntermediateBytes > 0,
                    "primitive-selected-aggregate-owner")
            }
            try ParameterBindingVerification.require(ownerMeter.retainedIntermediateBytes == 0
                && ownerMeter.retainedIntermediateRows == 0, "primitive-selected-aggregate-release")
        }
        phase = "aggregate-wrong-carriers"
        for (sourceType, wrongCarrier): (QueryColumnType, QueryValue) in [
            (.primitive(.int64), .primitive(.int32(1))),
            (.sql(.integer), .primitive(.int64(1))),
        ] {
            let strictMeter = invocation.meter()
            do {
                var accumulator = DatabaseNumericAggregateAccumulator(inputType: sourceType, workMeter: strictMeter)
                do {
                    try accumulator.add(wrongCarrier)
                    throw Failure.assertion("aggregate-carrier-must-fail")
                } catch DatabaseNumericAggregateAccumulator.Failure.incompatibleNumericKinds {}
            }
            try ParameterBindingVerification.require(strictMeter.retainedIntermediateBytes == 0
                && strictMeter.retainedIntermediateRows == 0, "aggregate-carrier-failure-release")
        }
        print("ENGINE_SELECTED_CASE widened-aggregates PASS")

        phase = "lazy-conditional-truth"
        let zeroDivision = Expression.divide(one, try number(0))
        try await invocation.verify(select([
            .caseWhen(cases: [CaseWhenPair(condition: .literal(.bool(true)), result: try number(123, scale: 2, display: 4))], elseResult: zeroDivision),
            .coalesce([try number(42, scale: 1, display: 3), zeroDivision]),
            .nullIf(try number(12, scale: 1, display: 3), try number(12, scale: 1, display: 2)),
            .greatest([.null, try number(12, scale: 1, display: 3), try number(23, scale: 1, display: 3)]),
            .truthTest(.cast(.null, targetType: .boolean), value: .unknown, negated: false),
            .isDistinctFrom(.null, .null, negated: true),
            .isDistinctFrom(try number(1, display: 2), .literal(.int(1)), negated: false),
            .and(.literal(.bool(false)), .equal(zeroDivision, one)),
            .or(.literal(.bool(true)), .cast(.null, targetType: .boolean)),
        ]), values: [try numeric(123, scale: 2, display: 4), try numeric(42, scale: 1, display: 3),
            .primitive(.null), try numeric(23, scale: 1, display: 3), .primitive(.bool(true)),
            .primitive(.bool(true)), .primitive(.bool(false)), .primitive(.bool(false)), .primitive(.bool(true))])
        try await invocation.fails(.nullIf(.cast(.null, targetType: decimal), zeroDivision), cause: .divisionByZero)
        // Each WHEN comparison selects its own type without changing the saved operand.
        let independentWhenTypes = Expression.caseWhen(
            operand: try number(9_007_199_254_740_993),
            cases: [
                CaseWhenPair(
                    condition: .literal(.queryValue(.primitive(.float64(0)), type: .sql(.doublePrecision))),
                    result: .literal(.queryValue(.primitive(.int32(1)), type: .sql(.integer)))),
                CaseWhenPair(condition: try number(9_007_199_254_740_992),
                    result: .literal(.queryValue(.primitive(.int32(2)), type: .sql(.integer)))),
            ], elseResult: .literal(.queryValue(.primitive(.int32(3)), type: .sql(.integer))))
        try await invocation.verify(select([independentWhenTypes]), values: [.primitive(.int32(3))],
            types: [.sql(.integer)])
        print("ENGINE_SELECTED_CASE lazy-conditional-truth PASS")

        let parameter = Expression.parameter(.position(1))
        let arrayLimits = QueryValueLimits(maximumRetainedBytes: 16384, maximumTotalNodes: 1024,
            maximumNestingDepth: 32, maximumCollectionElements: 256)
        let arrays: [([QueryValue]?, [QueryValue])] = [
            ([], [.primitive(.bool(false)), .primitive(.bool(true))]),
            (nil, [.primitive(.null), .primitive(.null)]),
            ([.primitive(.int32(1)), .primitive(.null)], [.primitive(.bool(true)), .primitive(.null)]),
            ([.primitive(.int32(2))], [.primitive(.bool(false)), .primitive(.bool(true))]),
        ]
        for (elements, expected) in arrays {
            let value: QueryValue
            if let elements {
                value = .array(try QueryArrayValue(elementType: .integer,
                    dimensions: elements.isEmpty ? [] : [QueryArrayDimension(lowerBound: -2, length: Int32(elements.count))],
                    elements: elements, limits: arrayLimits))
            } else { value = .primitive(.null) }
            try await invocation.verify(select([
                .quantifiedComparison(one, comparison: .equal, quantifier: .any, source: .array(parameter)),
                .quantifiedComparison(.literal(.int(0)), comparison: .lessThan, quantifier: .all, source: .array(parameter)),
            ]), values: expected, types: [.sql(.boolean), .sql(.boolean)],
                parameters: [QueryParameter(position: 1, value: value, type: .sql(.array(.integer)))])
        }
        let candidate = Expression.column(ColumnRef("candidate"))
        let candidates = SelectQuery(projection: [ProjectionItem(candidate)],
            source: ParameterBindingVerification.values([[.int(1)], [.int(2)]], columns: ["candidate"]))
        // An empty source still has a declared candidate type.
        let typedEmpty = SelectQuery(projection: [ProjectionItem(.cast(.null, targetType: .integer))],
            source: ParameterBindingVerification.values([], columns: nil))
        try await invocation.verify(select([
            .quantifiedComparison(one, comparison: .equal, quantifier: .any, source: .subquery(candidates)),
            .quantifiedComparison(.literal(.int(0)), comparison: .lessThan, quantifier: .all, source: .subquery(candidates)),
            .quantifiedComparison(.cast(.null, targetType: .integer), comparison: .equal, quantifier: .any, source: .subquery(typedEmpty)),
            .quantifiedComparison(.cast(.null, targetType: .integer), comparison: .equal, quantifier: .all, source: .subquery(typedEmpty)),
        ]), values: [.primitive(.bool(true)), .primitive(.bool(true)), .primitive(.bool(false)), .primitive(.bool(true))])
        print("ENGINE_SELECTED_CASE quantified-array-subquery PASS")
        print("ENGINE_SELECTED_PASS cases=5")
        } catch {
            throw SQLTextPatternVerification.DiagnosticFailure(phase: "selected-" + phase, cause: error)
        }
    }
}
