@_spi(DatabaseExecution) @testable import DatabaseEngine
import DatabaseKit
import DatabaseTypes

/// S07 public scalar execution and directly selected, production lower cursors.
enum SQLCollectionVerification {
    static let groups = 6
    typealias Invocation = SelectedValueVerification.Invocation
    typealias Failure = ParameterBindingVerification.Failure
    static let limits = QueryValueLimits(maximumRetainedBytes: 1_000_000, maximumTotalNodes: 10_000,
        maximumNestingDepth: 64, maximumCollectionElements: 10_000)

    static func i(_ n: Int32) -> QueryValue { .primitive(.int32(n)) }
    static func s(_ text: String) -> QueryValue { .primitive(.string(text)) }
    static func integer(_ n: Int32) -> Expression { SQLTextPatternVerification.integer(n) }
    static func literal(_ value: QueryValue, _ type: DataType) -> Expression {
        .literal(.queryValue(value, type: .sql(type)))
    }
    static func array(_ values: [QueryValue], element: DataType = .integer, lower: Int32 = 1) throws -> QueryValue {
        .array(try QueryArrayValue(elementType: element,
            dimensions: values.isEmpty ? [] : [QueryArrayDimension(lowerBound: lower, length: Int32(values.count))],
            elements: values, limits: limits))
    }
    static func json(_ text: String, binary: Bool = false) throws -> QueryValue {
        let lexical = try QueryJSONValue(bytes: ByteString(utf8: text), limits: limits)
        return binary ? .jsonb(try QueryJSONBValue(json: lexical, limits: limits)) : .json(lexical)
    }
    static func released(_ meter: DatabaseWorkMeter, _ name: String) throws {
        try ParameterBindingVerification.require(meter.retainedIntermediateBytes == 0
            && meter.retainedIntermediateRows == 0, name)
    }
    static func require(_ condition: Bool, _ name: String) throws {
        try ParameterBindingVerification.require(condition, name)
    }

    static func verify(in context: DatabaseContext, container: DBContainer) async throws {
        let environment = SQLTemporalEnvironment(transactionInstant: Timestamp(secondsSinceUnixEpoch: 0),
            statementInstant: Timestamp(secondsSinceUnixEpoch: 0), wallClock: SQLTemporalVerification.Clock(seconds: 0))
        let invocation = Invocation(context: context, container: container, temporalEnvironment: environment)
        func select(_ values: [Expression]) -> SelectQuery { ParameterBindingVerification.select(values) }
        func call(_ name: String, _ args: [Expression]) -> Expression { SelectedValueVerification.call(name, args) }
        func op(_ name: CollectionOperator, _ a: Expression, _ b: Expression) -> Expression {
            .collectionOperation(name, left: a, right: b)
        }
        let null = QueryValue.primitive(.null)
        var phase = "array-access-f08"
        do {
            let shifted = literal(try array([i(10), i(20), null], lower: -2), .array(.integer))
            try await invocation.verify(select([
                .array([integer(1), integer(2)]),
                .arrayAccess(shifted, subscripts: [.index(integer(-2))]),
                .arrayAccess(shifted, subscripts: [.index(integer(99))]),
                .arrayAccess(shifted, subscripts: [.slice(lower: integer(-9), upper: integer(-1))]),
                call("array_lower", [shifted, integer(1)]), call("array_upper", [shifted, integer(1)]),
                call("cardinality", [shifted]), call("array_position", [shifted, literal(null, .integer)]),
                call("array_to_string", [shifted, .string("|"), .string("N")]),
                op(.contains, .array([integer(1), integer(2)]), .array([integer(1), integer(1)])),
                .cast(.string("[-2:0]={10,20,NULL}"), targetType: .array(.integer)),
                .cast(shifted, targetType: .text),
            ]), values: [try array([i(1), i(2)]), i(10), null, try array([i(10), i(20)]),
                i(-2), i(0), i(3), i(0), s("10|20|N"), .primitive(.bool(true)),
                try array([i(10), i(20), null], lower: -2), s("[-2:0]={10,20,NULL}")],
                types: [.sql(.array(.integer)), .sql(.integer), .sql(.integer), .sql(.array(.integer)),
                    .sql(.integer), .sql(.integer), .sql(.integer), .sql(.integer), .sql(.text), .sql(.boolean),
                    .sql(.array(.integer)), .sql(.text)])
            let primitiveType = QueryColumnType.primitive(.int32, isArray: true)
            let primitiveRows: [[Literal]] = [
                [.queryValue(.primitive(.array([.int32(3), .int32(5)])), type: primitiveType)],
                [.queryValue(.primitive(.array([])), type: primitiveType)],
                [.queryValue(null, type: primitiveType)],
            ]
            let primitiveColumn = Expression.column(ColumnRef("numbers"))
            func variadic(_ name: String) -> Expression {
                .function(FunctionCall(name: name, arguments: [primitiveColumn], finalArrayIsVariadic: true))
            }
            let primitiveQuery = SelectQuery(projection: [
                ProjectionItem(.arrayAccess(primitiveColumn, subscripts: [.index(integer(1))])),
                ProjectionItem(.arrayAccess(primitiveColumn, subscripts: [.index(integer(4))])),
                ProjectionItem(.arrayAccess(primitiveColumn, subscripts: [.slice(lower: nil, upper: integer(1))])),
                ProjectionItem(variadic("json_build_array")), ProjectionItem(variadic("jsonb_build_array")),
                ProjectionItem(variadic("json_build_object")), ProjectionItem(variadic("jsonb_build_object")),
            ], source: ParameterBindingVerification.values(primitiveRows, columns: ["numbers"]))
            let primitiveMeter = invocation.meter()
            let primitiveResponse = try await invocation.query(primitiveQuery, meter: primitiveMeter)
            let primitiveExpected: [[QueryValue]] = [
                [i(3), null, try array([i(3)]), try json("[3, 5]"), try json("[3,5]", binary: true),
                    try json("{\"3\" : 5}"), try json("{\"3\":5}", binary: true)],
                [null, null, try array([]), try json("[]"), try json("[]", binary: true),
                    try json("{}"), try json("{}", binary: true)],
                Array(repeating: null, count: 7),
            ]
            try require(primitiveResponse.rows.map { $0.values } == primitiveExpected
                && primitiveResponse.columns.map { $0.type } == [.sql(.integer), .sql(.integer), .sql(.array(.integer)),
                    .sql(.json), .sql(.jsonb), .sql(.json), .sql(.jsonb)], "s07-primitive-array-access-final-variadic")
            try released(primitiveMeter, "s07-primitive-array-coercion-release")
            print("ENGINE_S07_CASE array-access-f08 PASS")
            phase = "json-lexical-f09"
            let lexical = Expression.cast(.string(" {\"x\": 0, \"x\": [ 1.2300 , null ]} "), targetType: .json)
            try await invocation.verify(select([
                op(.jsonField, lexical, .string("x")),
                op(.jsonFieldText, lexical, .string("x")),
                call("json_typeof", [literal(try json("null"), .json)]),
                op(.jsonFieldText, literal(try json("[\"e\\u0301\\ud83d\\ude00\",null]"), .json), integer(0)),
                op(.jsonFieldText, literal(try json("[1,null]"), .json), integer(-1)),
                call("json_build_object", [.string("x"), integer(1), .string("x"), integer(2)]),
            ]), values: [try json("[ 1.2300 , null ]"), s("[ 1.2300 , null ]"), s("null"),
                s("e\u{301}😀"), null, try json("{\"x\" : 1, \"x\" : 2}")])
            let paddedCharacter = Expression.cast(.string("x"), targetType: .char(length: 3))
            try await invocation.verify(select([
                call("json_build_array", [paddedCharacter]), call("jsonb_build_array", [paddedCharacter]),
                call("json_build_object", [paddedCharacter, integer(1)]),
                call("jsonb_build_object", [paddedCharacter, integer(1)]),
            ]), values: [try json("[\"x  \"]"), try json("[\"x  \"]", binary: true),
                try json("{\"x  \" : 1}"), try json("{\"x  \":1}", binary: true)],
                types: [.sql(.json), .sql(.jsonb), .sql(.json), .sql(.jsonb)])
            print("ENGINE_S07_CASE json-lexical-f09 PASS")
            phase = "jsonb-operators-f10"
            func b(_ text: String) throws -> Expression { .cast(.string(text), targetType: .jsonb) }
            try await invocation.verify(select([
                op(.contains, try b("{\"a\":[1,2]}"), try b("{\"a\":[2]}")),
                op(.jsonHasKey, try b("[1,\"x\"]"), .string("x")),
                op(.jsonPathText, try b("{\"a\":[10,20]}"), .array([.string("a"), .string("-1")])),
                .concatenate(try b("{\"a\":1}"), try b("{\"a\":2,\"b\":3}")),
                .subtract(try b("[1,2,3]"), integer(-1)),
                call("jsonb_set", [try b("{\"a\":[]}"), .array([.string("a"), .string("8")]), try b("9")]),
                call("jsonb_strip_nulls", [try b("{\"a\":null,\"b\":[null,1]}"), .literal(.bool(true))]),
                .equal(try b("1.00"), try b("1")),
            ]), values: [.primitive(.bool(true)), .primitive(.bool(true)), s("20"),
                try json("{\"a\":2,\"b\":3}", binary: true), try json("[1,2]", binary: true),
                try json("{\"a\":[9]}", binary: true), try json("{\"b\":[1]}", binary: true), .primitive(.bool(true))])
            print("ENGINE_S07_CASE jsonb-operators-f10 PASS")
            phase = "collection-semantic-identity"
            let numeric = DataType.decimal(precision: nil, scale: nil)
            let n0 = try SelectedValueVerification.numeric(1), n4 = try SelectedValueVerification.numeric(1, display: 4)
            let month = QueryValue.interval(try QueryIntervalValue(period: CalendarPeriod(months: 1), time: TimeSpan(seconds: 0)))
            let days = QueryValue.interval(try QueryIntervalValue(period: CalendarPeriod(days: 30), time: TimeSpan(seconds: 0)))
            let pairs: [(QueryValue, QueryValue, DataType)] = [
                (try array([n0], element: numeric), try array([n4], element: numeric), .array(numeric)),
                (try array([s("x ")], element: .char(length: nil)), try array([s("x")], element: .char(length: nil)), .array(.char(length: nil))),
                (try array([month], element: .interval()), try array([days], element: .interval()), .array(.interval())),
                (try json("{\"x\":1.00}", binary: true), try json("{\"x\":1}", binary: true), .jsonb),
            ]
            for (a, b, type) in pairs {
                let query = SelectQuery(projection: [ProjectionItem(.column(ColumnRef("v")))],
                    source: ParameterBindingVerification.values([[.queryValue(a, type: .sql(type))], [.queryValue(b, type: .sql(type))]], columns: ["v"]), quantifier: .distinct)
                let meter = invocation.meter()
                let response = try await invocation.query(query, meter: meter)
                try require(response.rows.count == 1 && response.columns[0].type == .sql(type), "s07-semantic-distinct")
                try released(meter, "s07-distinct-release")
            }
            // Both set branches traverse the selected schema descriptor boundary.
            let setA = try array([n0], element: numeric), setB = try array([n4], element: numeric)
            let setType = QueryColumnType.sql(.array(numeric))
            let leftSet = ParameterBindingVerification.values([[.queryValue(setA, type: setType), .queryValue(null, type: .sql(.integer))]],
                columns: ["v", "n"])
            let rightSet = ParameterBindingVerification.values([[.queryValue(setB, type: setType), .queryValue(null, type: .sql(.integer))]],
                columns: ["v", "n"])
            let leftQuery = SelectQuery(projection: [.wildcard()], source: leftSet)
            let rightQuery = SelectQuery(projection: [.wildcard()], source: rightSet)
            let setCases: [(DataSource, Int)] = [
                (.setOperation(operator: .union, quantifier: .distinct, left: leftQuery, right: rightQuery), 1),
                (.setOperation(operator: .union, quantifier: .all, left: leftQuery, right: rightQuery), 2),
            ]
            for (source, expectedCount) in setCases {
                let meter = invocation.meter()
                let response = try await invocation.query(SelectQuery(projection: [.wildcard()], source: source), meter: meter)
                try require(response.columns.map { $0.number } == [1, 2]
                    && response.columns.map { $0.name } == ["v", "n"]
                    && response.columns.map { $0.type } == [setType, .sql(.integer)]
                    && response.columns[1].isNullable, "s07-set-selected-metadata")
                try require(response.rows.count == expectedCount && response.rows.allSatisfy { row in
                    row.values.count == 2 && (row.values[0] == setA || row.values[0] == setB) && row.values[1].isNull
                }, "s07-set-values-null-arity")
                try released(meter, "s07-set-schema-release")
            }
            let lowerA = try array([i(1)], lower: 0), lowerB = try array([i(1)], lower: 1)
            try await invocation.verify(select([.equal(literal(lowerA, .array(.integer)), literal(lowerB, .array(.integer)))]),
                values: [.primitive(.bool(false))])
            print("ENGINE_S07_CASE collection-semantic-identity PASS")
            phase = "collection-failures-resources"
            try await invocation.fails(call("jsonb_array_length", [try b("{}")]),
                cause: .collection(.jsonArrayRootRequired(function: "jsonb_array_length")))
            let invalidEquality = select([.equal(literal(try json("{}"), .json), literal(try json("{}"), .json))])
            let empty = SelectQuery(projection: invalidEquality.projection, source: ParameterBindingVerification.values([], columns: nil))
            let emptyMeter = invocation.meter()
            do {
                _ = try await invocation.query(empty, meter: emptyMeter)
                throw Failure.assertion("s07-json-equality-before-empty-read")
            } catch let error as DatabaseExpressionEvaluationError {
                guard case .unsupportedExpression = error else { throw error }
            } catch CanonicalReadError.expressionEvaluation(let error, _) {
                guard case .unsupportedExpression = error else { throw error }
            } catch let failure as CanonicalSQLBindingFailure {
                guard case .expression(.unsupportedExpression) = failure.cause else { throw failure }
            }
            try released(emptyMeter, "s07-empty-binding-failure-release")
            let resourceQuery = select([call("jsonb_build_array", [.string(String(repeating: "ab", count: 128)), try b("{\"x\":[1,2]}")])])
            let measured = invocation.meter()
            _ = try await invocation.query(resourceQuery, meter: measured)
            try released(measured, "s07-success-release")
            let limited = DatabaseWorkMeter(budget: ExecutionBudget(maximumRows: 100,
                maximumWorkUnits: max(1, measured.consumedWorkUnits / 2), maximumIntermediateRows: 1_000,
                maximumIntermediateBytes: 8 * 1_024 * 1_024, timeoutMilliseconds: 60_000), monotonicClock: container.monotonicClock)
            do {
                _ = try await invocation.query(resourceQuery, meter: limited)
                throw Failure.assertion("s07-work-limit-must-fail")
            } catch is DatabaseWorkLimitError {}
            try released(limited, "s07-work-failure-release")
            try await invocation.verify(select([call("jsonb_build_array", [])]), values: [try json("[]", binary: true)])
            try await bindingPlanPrepass(invocation)
            print("ENGINE_S07_CASE collection-failures-resources PASS")
            phase = "lower-row-srf"
            try lowerCursors(invocation)
            print("ENGINE_S07_CASE lower-row-srf PASS")
            print("ENGINE_S07_PASS cases=6")
        } catch { throw SQLTextPatternVerification.DiagnosticFailure(phase: "s07-" + phase, cause: error) }
    }

    static func bindingPlanPrepass(_ invocation: Invocation) async throws {
        var expression = Expression.literal(.bool(true))
        for _ in 0..<62 { expression = .not(expression) }
        let deep = ParameterBindingVerification.select([expression])
        let structuralLimits = QueryStructuralLimits(maximumNestingDepth: 65)
        try QueryStructuralValidator.validate(deep, limits: structuralLimits)
        do {
            try QueryStructuralValidator.validate(deep)
            throw Failure.assertion("s07-r4-query-must-require-depth65")
        } catch QueryStructuralValidationError.resourceLimitExceeded(resource: .nestingDepth, actual: 65, maximum: 64) { }

        let generous = invocation.meter()
        let generousExecution = ReadExecutionContext(options: ReadExecutionOptions(budget: generous.budget),
            monotonicClock: invocation.container.monotonicClock, workMeter: generous,
            queryStructuralLimits: structuralLimits, temporalEnvironment: invocation.temporalEnvironment)
        let valid = try await invocation.context.indexQueryContext.withSession(workMeter: generous) { session in
            try await session.executeCanonical(deep, execution: generousExecution)
        }
        try require(valid.rows.count == 1 && valid.rows[0].values == [.primitive(.bool(true))]
            && valid.columns.map { $0.type } == [.sql(.boolean)], "s07-r4-depth65-public-rows")
        try released(generous, "s07-r4-depth65-success-release")

        let maximumBytes: UInt64 = 32 * 1024
        let limited = DatabaseWorkMeter(budget: ExecutionBudget(maximumRows: 100,
            maximumWorkUnits: 100_000_000, maximumIntermediateRows: 1_000,
            maximumIntermediateBytes: maximumBytes, timeoutMilliseconds: 60_000),
            monotonicClock: invocation.container.monotonicClock)
        let execution = ReadExecutionContext(options: ReadExecutionOptions(budget: limited.budget),
            monotonicClock: invocation.container.monotonicClock, workMeter: limited,
            queryStructuralLimits: structuralLimits, temporalEnvironment: invocation.temporalEnvironment)
        try await invocation.context.indexQueryContext.withSession(workMeter: limited) { session in
            let baselineBytes = limited.retainedIntermediateBytes
            let baselineRows = limited.retainedIntermediateRows
            do {
                _ = try await session.executeCanonical(deep, execution: execution)
                throw Failure.assertion("s07-r4-binding-plan-claim-must-fail")
            } catch let error as DatabaseWorkLimitError {
                guard case .maximumIntermediateBytes(let stage, _, let requested, let maximum) = error,
                      stage == .bindingCandidate, requested >= 64 * 1024, maximum == maximumBytes else { throw error }
                // This is the final prospective plan claim, after traversal scratch has unwound.
            }
            let actualBytes = limited.retainedIntermediateBytes
            let actualRows = limited.retainedIntermediateRows
            try require(actualBytes == baselineBytes && actualRows == baselineRows,
                "s07-r4-plan-claim-failure-scratch-release:baselineBytes=\(baselineBytes):actualBytes=\(actualBytes):baselineRows=\(baselineRows):actualRows=\(actualRows)")
            let shallow = try await session.executeCanonical(
                ParameterBindingVerification.select([.literal(.bool(true))]), execution: execution)
            try require(shallow.rows.count == 1 && shallow.rows[0].values == [.primitive(.bool(true))]
                && shallow.columns.map { $0.type } == [.sql(.boolean)], "s07-r4-same-meter-session-recovery")
        }
        try released(limited, "s07-r4-final-session-release")
    }

    static func bound(_ name: String, values: [QueryValue], types: [DataType], result: DataType) -> CanonicalBoundExpression {
        let children = zip(values, types).map { value, type in
            CanonicalBoundExpression(expression: literal(value, type), type: .sql(type), isNullable: true)
        }
        return CanonicalBoundExpression(expression: .function(FunctionCall(name: name, arguments: children.map { $0.expression })),
            type: .sql(result), isNullable: true, children: children)
    }

    static func lowerCursors(_ invocation: Invocation) throws {
        let meter = invocation.meter()
        var retainedRow: (values: [QueryValue], leases: [DatabaseQueryPayloadLease])?
        var retainedMetadata: (columns: [QueryColumn], lease: DatabaseQueryPayloadLease)?
        do {
            let values = [try array([s("kept"), s("second")], element: .text), try array([i(3)])]
            var footprint = DatabaseIntermediateFootprint()
            for value in values {
                footprint = try footprint.adding(CanonicalRelationalFootprintMeter.valueFootprint(of: value,
                    workMeter: meter, stage: .expressionEvaluation))
            }
            let input = try meter.reserveIntermediate(bytes: footprint.bytes, at: .expressionEvaluation)
            var cursor = try CanonicalSQLArrayEvaluator.makeRowCursor(
                bound("unnest", values: values, types: [.array(.text), .array(.integer)], result: .text),
                operands: values, inputLeases: [DatabaseQueryPayloadLease(retaining: input)], temporalEnvironment: nil,
                workMeter: meter, limits: limits)
            let metadata = try cursor.metadata()
            try require(metadata.columns.map { $0.number } == [1, 2]
                && metadata.columns.map { $0.type } == [.sql(.text), .sql(.integer)]
                && metadata.columns.allSatisfy { $0.isNullable }, "s07-unnest-metadata")
            guard let first = try cursor.next(), let second = try cursor.next() else { throw Failure.assertion("s07-unnest-rows") }
            try require(first.values == [s("kept"), i(3)] && second.values == [s("second"), .primitive(.null)], "s07-unnest-padding")
            cursor.close(); cursor.close()
            try require(try cursor.next() == nil, "s07-unnest-closed")
            try require(meter.retainedIntermediateBytes > 0, "s07-unnest-retained-after-close")
            retainedRow = first; retainedMetadata = metadata
            withExtendedLifetime(second) {}
        }
        try require(retainedRow?.values == [s("kept"), i(3)] && retainedMetadata?.columns.count == 2
            && meter.retainedIntermediateBytes > 0, "s07-array-row-lease-independent-of-cursor")
        retainedRow = nil; retainedMetadata = nil
        try released(meter, "s07-unnest-release")
        do {
            let value = try json("{\"x\": 1.2300, \"x\": null}")
            var cursor = try CanonicalSQLJSONEvaluator.makeRowCursor(
                bound("json_each_text", values: [value], types: [.json], result: .text), operands: [value],
                inputLeases: [], temporalEnvironment: nil, workMeter: meter, limits: limits)
            let metadata = try cursor.metadata()
            try require(metadata.columns.map { $0.name } == ["key", "value"]
                && metadata.columns.map { $0.type } == [.sql(.text), .sql(.text)], "s07-json-cursor-metadata")
            guard let first = try cursor.next(), let second = try cursor.next() else { throw Failure.assertion("s07-json-cursor-rows") }
            try require(first.values == [s("x"), s("1.2300")] && second.values == [s("x"), .primitive(.null)], "s07-json-cursor-duplicates")
            cursor.close(); cursor.close()
            try require(try cursor.next() == nil && first.values[1] == s("1.2300"), "s07-json-cursor-lifetime")
            retainedRow = first; retainedMetadata = metadata
            withExtendedLifetime(second) {}
        }
        try require(retainedRow?.values == [s("x"), s("1.2300")] && retainedMetadata?.columns.count == 2
            && meter.retainedIntermediateBytes > 0, "s07-json-row-lease-independent-of-cursor")
        retainedRow = nil; retainedMetadata = nil
        try released(meter, "s07-json-cursor-release")
        do {
            let columns = [try QueryColumn(number: 1, name: "z", type: .sql(.integer), isNullable: false),
                try QueryColumn(number: 2, name: "a", type: .sql(.text), isNullable: true)]
            let result = try CanonicalSQLJSONEvaluator.convertRow(columns: columns, values: [i(3), .primitive(.null)],
                resultType: .sql(.json), pretty: false, temporalEnvironment: nil, workMeter: meter, limits: limits)
            let expected = try json("{\"z\":3,\"a\":null}")
            try require(result.value == expected, "s07-row-ordered-descriptor")
            withExtendedLifetime(result.lease) {}
            do {
                _ = try CanonicalSQLJSONEvaluator.convertRow(columns: columns, values: [i(3)],
                    resultType: .sql(.json), pretty: false, temporalEnvironment: nil, workMeter: meter, limits: limits)
                throw Failure.assertion("s07-row-arity-must-fail")
            } catch DatabaseExpressionEvaluationError.typeMismatch(let operation) {
                try require(operation == "ROW conversion arity", "s07-row-arity-cause")
            }
        }
        try released(meter, "s07-row-conversion-release")
        do {
            let value = try json("[1,\"\\u0000\"]")
            var cursor = try CanonicalSQLJSONEvaluator.makeRowCursor(
                bound("json_array_elements_text", values: [value], types: [.json], result: .text), operands: [value],
                inputLeases: [], temporalEnvironment: nil, workMeter: meter, limits: limits)
            guard let first = try cursor.next() else { throw Failure.assertion("s07-json-first-row") }
            do {
                _ = try cursor.next()
                throw Failure.assertion("s07-json-decode-must-fail")
            } catch let error as QueryValueError {
                guard case .invalidJSON = error else { throw error }
            }
            try require(try cursor.next() == nil && first.values == [s("1")], "s07-json-failure-closes-retains-prior-row")
            withExtendedLifetime(first.leases) {}
        }
        try released(meter, "s07-json-cursor-failure-release")
        do {
            let value = try json("{\"z\":2,\"a\":1}", binary: true)
            var cursor = try CanonicalSQLJSONEvaluator.makeRowCursor(
                bound("jsonb_each", values: [value], types: [.jsonb], result: .jsonb), operands: [value],
                inputLeases: [], temporalEnvironment: nil, workMeter: meter, limits: limits)
            let metadata = try cursor.metadata()
            guard let first = try cursor.next() else { throw Failure.assertion("s07-jsonb-cursor-row") }
            let expected = try json("1", binary: true)
            try require(metadata.columns.map { $0.type } == [.sql(.text), .sql(.jsonb)]
                && first.values == [s("a"), expected], "s07-jsonb-cursor-order")
            cursor.close()
            withExtendedLifetime((metadata, first)) {}
        }
        try released(meter, "s07-jsonb-cursor-release")
        do {
            let value = QueryValue.primitive(.null)
            var cursor = try CanonicalSQLArrayEvaluator.makeRowCursor(
                bound("unnest", values: [value], types: [.array(.date)], result: .date), operands: [value],
                inputLeases: [], temporalEnvironment: nil, workMeter: meter, limits: limits)
            let metadata = try cursor.metadata()
            try require(metadata.columns[0].type == .sql(.date), "s07-null-srf-selected-metadata")
            try require(try cursor.next() == nil, "s07-null-srf-no-rows")
            withExtendedLifetime(metadata) {}
        }
        try released(meter, "s07-null-cursor-release")
        let tiny = DatabaseWorkMeter(budget: ExecutionBudget(maximumRows: 100,
            maximumWorkUnits: 100_000, maximumIntermediateRows: 1_000,
            maximumIntermediateBytes: 1, timeoutMilliseconds: 60_000), monotonicClock: invocation.container.monotonicClock)
        do {
            let value = try json("[1]")
            var cursor = try CanonicalSQLJSONEvaluator.makeRowCursor(
                bound("json_array_elements", values: [value], types: [.json], result: .json), operands: [value],
                inputLeases: [], temporalEnvironment: nil, workMeter: tiny, limits: limits)
            cursor.close()
            throw Failure.assertion("s07-cursor-admission-must-fail")
        } catch is DatabaseWorkLimitError {}
        try released(tiny, "s07-cursor-admission-failure-release")
        func rowMeter(_ maximum: UInt32) -> DatabaseWorkMeter {
            DatabaseWorkMeter(budget: ExecutionBudget(maximumRows: 100, maximumWorkUnits: 1_000_000,
                maximumIntermediateRows: maximum, maximumIntermediateBytes: 8 * 1_024 * 1_024,
                timeoutMilliseconds: 60_000), monotonicClock: invocation.container.monotonicClock)
        }
        let zeroRows = rowMeter(0)
        do {
            let value = try json("[1]")
            var cursor = try CanonicalSQLJSONEvaluator.makeRowCursor(
                bound("json_array_elements", values: [value], types: [.json], result: .json), operands: [value],
                inputLeases: [], temporalEnvironment: nil, workMeter: zeroRows, limits: limits)
            do {
                _ = try cursor.next()
                throw Failure.assertion("s07-cursor-zero-rows-must-fail")
            } catch let error as DatabaseWorkLimitError {
                try require(error == .maximumIntermediateRows(stage: .expressionEvaluation, consumed: 0, requested: 1, maximum: 0),
                    "s07-cursor-zero-rows-typed")
            }
            try require(try cursor.next() == nil, "s07-zero-row-failure-terminates")
            cursor.close()
        }
        try released(zeroRows, "s07-zero-row-cursor-release")
        let oneRow = rowMeter(1)
        do {
            let value = try json("[1,2]")
            var cursor = try CanonicalSQLJSONEvaluator.makeRowCursor(
                bound("json_array_elements", values: [value], types: [.json], result: .json), operands: [value],
                inputLeases: [], temporalEnvironment: nil, workMeter: oneRow, limits: limits)
            var retained = try cursor.next()
            try require(retained != nil && oneRow.retainedIntermediateRows == 1, "s07-cursor-exact-one-row")
            do {
                _ = try cursor.next()
                throw Failure.assertion("s07-cursor-second-outstanding-row-must-fail")
            } catch let error as DatabaseWorkLimitError {
                try require(error == .maximumIntermediateRows(stage: .expressionEvaluation, consumed: 1, requested: 1, maximum: 1),
                    "s07-cursor-onepast-row-typed")
            }
            cursor.close(); cursor.close()
            let expected = try json("1")
            try require(try cursor.next() == nil && retained?.values == [expected]
                && oneRow.retainedIntermediateRows == 1, "s07-cursor-row-survives-terminal-close")
            withExtendedLifetime(retained) {}
            retained = nil
            try released(oneRow, "s07-final-row-lease-release")
        }
        do {
            let value = try json("[3]")
            var cursor = try CanonicalSQLJSONEvaluator.makeRowCursor(
                bound("json_array_elements", values: [value], types: [.json], result: .json), operands: [value],
                inputLeases: [], temporalEnvironment: nil, workMeter: oneRow, limits: limits)
            var retained = try cursor.next()
            cursor.close()
            try require(retained != nil && oneRow.retainedIntermediateRows == 1, "s07-row-quota-recovery")
            retained = nil
        }
        try released(oneRow, "s07-row-quota-recovery-release")
    }
}
