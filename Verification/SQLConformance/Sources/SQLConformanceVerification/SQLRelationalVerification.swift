@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit
import DatabaseTypes

/// S08 canonical IR executed by the application's real session and request meter.
enum SQLRelationalVerification {
    static let groups = 5
    typealias Invocation = SelectedValueVerification.Invocation
    typealias Failure = ParameterBindingVerification.Failure

    static func integer(_ value: Int32) -> Expression { SQLTextPatternVerification.integer(value) }
    static func value(_ value: Int32) -> QueryValue { .primitive(.int32(value)) }
    static func column(_ name: String, table: String? = nil) -> Expression {
        .column(ColumnRef(table: table, column: name))
    }
    static func relation(_ rows: [[Expression]], name: String = "v", columns: [String]) -> DataSource {
        .aliased(.values(rows), name: name, columns: columns)
    }
    static func rows(_ rows: [[Expression]], columns: [String]) -> SelectQuery {
        SelectQuery(projection: [.wildcard()], source: relation(rows, columns: columns))
    }
    static func require(_ condition: Bool, _ name: String) throws {
        try ParameterBindingVerification.require(condition, name)
    }
    static func released(_ meter: DatabaseWorkMeter, _ name: String) throws {
        try SQLCollectionVerification.released(meter, "s08-" + name)
    }
    static func query(_ query: SelectQuery, invocation: Invocation,
                      parameters: [QueryParameter] = []) async throws -> QueryResponse {
        let meter = invocation.meter()
        let response = try await invocation.query(query, meter: meter, parameters: parameters)
        try released(meter, "response-promotion-release")
        return response
    }

    static func verify(in context: DatabaseContext, container: DBContainer) async throws {
        let invocation = Invocation(context: context, container: container)
        let checks: [(String, @Sendable (Invocation) async throws -> Void)] = [
            ("expression-values-aliases", expressionValues),
            ("derived-cte-demand", derivedDemand),
            ("set-distinct-pagination", setAndPagination),
            ("composite-presence-json", compositePresence),
            ("array-subquery-resources", arrayAndResources),
        ]
        for (name, check) in checks {
            do { try await check(invocation) }
            catch { throw SQLTextPatternVerification.DiagnosticFailure(phase: "s08-" + name, cause: error) }
            print("ENGINE_S08_CASE " + name + " PASS")
        }
        print("ENGINE_S08_PASS cases=5")
    }

    private static func expressionValues(_ invocation: Invocation) async throws {
        let source = relation([[.add(.parameter(.position(1)), integer(1)), .cast(.null, targetType: .text)]], columns: ["a", "b"])
        let selected = SelectQuery(projection: [.wildcard(), .wildcard(qualifier: "v"),
            .expression(integer(9), alias: "a"), .expression(.cast(.null, targetType: .text), alias: "b")], source: source)
        let response = try await query(selected, invocation: invocation,
            parameters: [QueryParameter(position: 1, value: value(0), type: .sql(.integer))])
        try require(response.columns.map { $0.name } == ["a", "b", "a", "b", "a", "b"], "mixed-projection-names")
        try require(response.rows.map { $0.values } == [[value(1), .primitive(.null), value(1), .primitive(.null), value(9), .primitive(.null)]], "expression-values-parameter")
        let expanded = SelectQuery(projection: [.wildcard()], source: .values([
            [.fieldExpansion(.row([integer(1), integer(2)]))], [integer(3), integer(4)]
        ]))
        let expansion = try await query(expanded, invocation: invocation)
        try require(expansion.rows.map { $0.values } == [[value(1), value(2)], [value(3), value(4)]],
            "values-direct-expanded-width")
        let rejected = expanded.replacing(source: .values([
            [.fieldExpansion(.row([integer(1), integer(2)]))], [integer(3)]
        ]))
        let invalidMeter = invocation.meter()
        do {
            _ = try await invocation.query(rejected, meter: invalidMeter)
            throw Failure.assertion("values-expanded-mismatch-must-fail")
        } catch CanonicalReadError.invalidQueryStructure(.columnCount, let reason) {
            try require(reason == "VALUES expanded row arity differs", "values-expanded-mismatch-cause")
        }
        try released(invalidMeter, "values-expanded-mismatch-release")
        let inner = SelectQuery(projection: [.expression(integer(1), alias: "a"),
            .expression(.cast(.null, targetType: .text), alias: "b")], source: .values([[]]))
        let empty = SelectQuery(projection: [.wildcard()], source: .aliased(.subquery(inner), name: "v", columns: ["x"]), filter: .literal(.bool(false)))
        let descriptor = try await query(empty, invocation: invocation)
        try require(descriptor.rows.isEmpty && descriptor.columns.map { $0.name } == ["x", "b"]
            && descriptor.columns.map { $0.type } == [.sql(.integer), .sql(.text)], "empty-derived-partial-alias")
        try await invocation.verify(ParameterBindingVerification.select([
            .equal(.collate(.string("é"), collation: .c), .collate(.string("é"), collation: .c)),
            .equal(.collate(.string("é"), collation: .posix), .collate(.string("é"), collation: .posix)),
        ]), values: [.primitive(.bool(true)), .primitive(.bool(true))], types: [.sql(.boolean), .sql(.boolean)])
        try await physicalEqualityJoin(invocation)
    }

    private static func physicalEqualityJoin(_ invocation: Invocation) async throws {
        let table = RuntimeVerificationDocument.persistableType
        let selected = SelectQuery(projection: [.wildcard()], source: .join(JoinClause(
            type: .inner,
            left: .aliased(.table(TableRef(table)), name: "left_entity"),
            right: .aliased(.table(TableRef(table)), name: "right_entity"),
            condition: .on(.equal(column("id", table: "left_entity"), column("id", table: "right_entity"))))))
        let publicBudget = ExecutionBudget()
        func meter(_ maximum: UInt64, intermediateRows: UInt32? = nil) -> DatabaseWorkMeter {
            DatabaseWorkMeter(budget: ExecutionBudget(maximumRows: 100,
                maximumWorkUnits: maximum,
                maximumIntermediateRows: intermediateRows ?? publicBudget.maximumIntermediateRows,
                maximumIntermediateBytes: publicBudget.maximumIntermediateBytes,
                timeoutMilliseconds: 30_000),
                monotonicClock: invocation.container.monotonicClock)
        }
        func execute(_ count: Int) async throws -> UInt64 {
            let work = meter(100_000)
            let response = try await invocation.query(selected, meter: work)
            try require(response.rows.count == count && response.continuation == nil,
                "physical-equality-join-complete-rows")
            for row in response.rows {
                try require(row.values.count == 4 && row.values[0] == row.values[2],
                    "physical-equality-join-matching-identities")
            }
            try released(work, "physical-equality-join-success-release")
            return work.consumedWorkUnits
        }
        // The reactor's existing put/get fixture owns document-1; add only this witness's rows.
        let baseline = try await query(SelectQuery(projection: [.wildcard()], source: .table(TableRef(table))),
            invocation: invocation)
        try require(baseline.rows.count == 1, "physical-equality-join-initial-row")
        for index in 1..<50 {
            try invocation.context.insert(RuntimeVerificationDocument(id: "s08-hash-\(index)", title: "Hash \(index)"))
        }
        try await invocation.context.save()
        let half = try await execute(50)
        for index in 50..<100 {
            try invocation.context.insert(RuntimeVerificationDocument(id: "s08-hash-\(index)", title: "Hash \(index)"))
        }
        try await invocation.context.save()
        let full = try await execute(100)
        try require(full < half * 3, "physical-equality-join-bounded-candidates")
        let rowLimited = meter(100_000, intermediateRows: 1_000)
        do {
            _ = try await invocation.query(selected, meter: rowLimited)
            throw Failure.assertion("physical-equality-join-row-limit-must-fail")
        } catch DatabaseWorkLimitError.maximumIntermediateRows(_, let consumed, let requested, let maximum) {
            try require(maximum == 1_000 && consumed <= maximum && requested > maximum - consumed,
                "physical-equality-join-row-limit-cause")
        }
        try released(rowLimited, "physical-equality-join-row-limit-release")
        let maximum = max(1, full / 2)
        let limited = meter(maximum)
        do {
            _ = try await invocation.query(selected, meter: limited)
            throw Failure.assertion("physical-equality-join-work-limit-must-fail")
        } catch DatabaseWorkLimitError.maximumWorkUnits(_, let consumed, let requested, let actualMaximum) {
            try require(actualMaximum == maximum && consumed <= maximum && requested > maximum - consumed,
                "physical-equality-join-work-limit-cause")
        }
        try released(limited, "physical-equality-join-failure-release")
        _ = try await execute(100)
    }

    private static func derivedDemand(_ invocation: Invocation) async throws {
        let clock = SQLTemporalVerification.Clock(seconds: 1_704_067_200)
        let environment = SQLTemporalEnvironment(transactionInstant: Timestamp(secondsSinceUnixEpoch: 0),
            statementInstant: Timestamp(secondsSinceUnixEpoch: 0), wallClock: clock)
        let selected = Invocation(context: invocation.context, container: invocation.container, temporalEnvironment: environment)
        let inner = SelectQuery(projection: [.expression(SelectedValueVerification.call("clock_timestamp", []), alias: "t")],
            source: relation([[integer(3)], [integer(2)], [integer(1)]], columns: ["n"]),
            orderBy: [SortKey(column("n"))])
        let cte = NamedSubquery(name: "c", query: inner, materialized: .materialized)
        let prefix = SelectQuery(projection: [.wildcard()], source: .table(TableRef("c")),
            pagination: QueryPagination(limit: .count(.fixed(1), withTies: false)), subqueries: [cte])
        var before = clock.reads
        let result = try await query(prefix, invocation: selected)
        try require(result.rows.count == 1 && clock.reads - before == 1, "materialized-prefix-demand")
        let unused = ParameterBindingVerification.select([integer(1)]).replacing(subqueries: [cte])
        before = clock.reads
        try await selected.verify(unused, values: [value(1)])
        try require(clock.reads == before, "unused-cte-never-opened")
        let derived = SelectQuery(projection: [.wildcard()], source: .subquery(inner),
            pagination: QueryPagination(limit: .count(.fixed(1), withTies: false)))
        before = clock.reads
        let derivedResult = try await query(derived, invocation: selected)
        try require(derivedResult.rows.count == 1 && clock.reads - before == 1, "derived-prefix-demand-close")
        let throwing = ParameterBindingVerification.select([.divide(integer(1), integer(0))])
        let existence = ParameterBindingVerification.select([.exists(throwing),
            .exists(throwing.replacing(pagination: QueryPagination(limit: .count(.fixed(0), withTies: false))))])
        try await selected.verify(existence, values: [.primitive(.bool(true)), .primitive(.bool(false))])
        try await sourceOccurrences(invocation)
    }

    private static func setAndPagination(_ invocation: Invocation) async throws {
        let null = Expression.cast(.null, targetType: .integer)
        let left = rows([[integer(1)], [integer(1)], [integer(2)], [null]], columns: ["x"])
        let right = rows([[integer(1)], [integer(1)], [integer(1)], [null]], columns: ["x"])
        let set = SelectQuery(projection: [.wildcard()], source: .setOperation(operator: .intersect,
            quantifier: .all, left: left, right: right), orderBy: [SortKey(column("x"), nulls: .last)])
        let bag = try await query(set, invocation: invocation)
        try require(bag.rows.map { $0.values[0] } == [value(1), value(1), .primitive(.null)], "intersect-all-multiplicity")
        for cell in [integer(1), null] {
            let duplicate = rows([[cell], [cell]], columns: ["x"])
            let single = rows([[cell]], columns: ["x"])
            let except = SelectQuery(projection: [.wildcard()], source: .setOperation(
                operator: .except, quantifier: .distinct, left: duplicate, right: single))
            let excluded = try await query(except, invocation: invocation)
            try require(excluded.rows.isEmpty, "except-distinct-retains-right-presence")
            let all = except.replacing(source: .setOperation(operator: .except, quantifier: .all,
                left: duplicate, right: single))
            let remaining = try await query(all, invocation: invocation)
            try require(remaining.rows.count == 1, "except-all-subtracts-multiplicity")
        }
        try await contextualNullSets(invocation)
        try await sourceScalarAlignment(invocation)
        try await reviewedSetAlignment(invocation)
        let distinct = SelectQuery(projection: [.wildcard()], source: relation([
            [integer(1), integer(1), integer(2)], [integer(1), integer(1), integer(1)], [integer(1), integer(2), integer(3)],
        ], columns: ["a", "b", "c"]), orderBy: [SortKey(column("b")), SortKey(column("a")), SortKey(column("c"))],
            quantifier: .distinctOn([column("a"), column("b")]))
        let dedup = try await query(distinct, invocation: invocation)
        try require(dedup.rows.map { $0.values[2] } == [value(1), value(3)], "distinct-on-after-order")
        for qualifiedDistinct in [false, true] {
            let key = column("a", table: qualifiedDistinct ? "v" : nil)
            let order = column("a", table: qualifiedDistinct ? nil : "v")
            let selected = SelectQuery(projection: [.expression(column("a"))],
                source: relation([[integer(1)], [integer(1)]], columns: ["a"]),
                orderBy: [SortKey(order)], quantifier: .distinctOn([key]))
            let result = try await query(selected, invocation: invocation)
            try require(result.rows.map { $0.values } == [[value(1)]], "qualified-distinct-source-identity")
        }
        let sharedAlias = SelectQuery(projection: [.expression(column("n"), alias: "same"),
            .expression(column("n", table: "v"), alias: "same")],
            source: relation([[integer(2)], [integer(1)]], columns: ["n"]),
            orderBy: [SortKey(column("same"))])
        let shared = try await query(sharedAlias, invocation: invocation)
        try require(shared.rows.map { $0.values } == [[value(1), value(1)], [value(2), value(2)]],
            "duplicate-aliases-share-identical-source-slot")
        let ties = SelectQuery(projection: [.wildcard()], source: relation([
            [integer(1)], [integer(1)], [integer(2)], [integer(2)], [integer(3)],
        ], columns: ["x"]), orderBy: [SortKey(column("x"))],
            pagination: QueryPagination(limit: .count(.fixed(2), withTies: true), offset: .fixed(1)))
        let peers = try await query(ties, invocation: invocation)
        try require(peers.rows.map { $0.values[0] } == [value(1), value(2), value(2)], "fetch-ties-after-offset")
        let parameterized = ties.replacing(pagination: QueryPagination(
            limit: .count(.expression(.parameter(.position(2))), withTies: false), offset: .expression(.parameter(.position(1)))))
        let page = try await query(parameterized, invocation: invocation,
            parameters: [QueryParameter(position: 1, value: .primitive(.int64(2))), QueryParameter(position: 2, value: .primitive(.int64(1)))])
        try require(page.rows.map { $0.values[0] } == [value(2)], "expression-pagination")
    }

    private static func contextualNullSets(_ invocation: Invocation) async throws {
        func nativeDepthQuery(_ selected: SelectQuery) async throws -> QueryResponse {
            // Match the originating Native depth fixture's default budget, using the same request meter.
            let meter = DatabaseWorkMeter(budget: ExecutionBudget(), monotonicClock: invocation.container.monotonicClock)
            let response = try await invocation.query(selected, meter: meter)
            try released(meter, "native-depth-response-release")
            return response
        }
        func singleton(_ expression: Expression) -> SelectQuery {
            SelectQuery(projection: [.expression(expression, alias: "value")], source: .values([[]]))
        }
        let nullQuery = singleton(.literal(.null))
        // Preserve the Native counterexample's Int64 literal and every source/query wrapper.
        let strong = DataSource.aliased(.values([[.literal(.int(1))]]), name: "input_1", columns: ["other"])
        let weakQueries = [
            nullQuery,
            singleton(.coalesce([.literal(.null), .literal(.null)])),
            singleton(.caseWhen(cases: [
                CaseWhenPair(condition: .literal(.bool(true)), result: .literal(.null))
            ], elseResult: .literal(.null))),
            SelectQuery(projection: [.wildcard()], source: .subquery(SelectQuery(projection: [.wildcard()],
                source: .setOperation(operator: .union, quantifier: .all,
                    left: SelectQuery(projection: [.wildcard()], source: .aliased(.subquery(nullQuery), name: "first_null")),
                    right: SelectQuery(projection: [.wildcard()], source: .aliased(.subquery(nullQuery), name: "second_null"))))))
        ]
        var queries = weakQueries.map { weak in
            SelectQuery(projection: [.wildcard()], source: .subquery(SelectQuery(projection: [.wildcard()],
                source: .setOperation(operator: .union, quantifier: .all,
                    left: SelectQuery(projection: [.wildcard()], source: .aliased(.subquery(weak), name: "weak_values")),
                    right: SelectQuery(projection: [.wildcard()], source: strong)))))
        }
        queries.append(SelectQuery(projection: [.wildcard()], source: .subquery(SelectQuery(projection: [.wildcard()],
            source: .setOperation(operator: .union, quantifier: .all,
                left: SelectQuery(projection: [.wildcard()], source: .table(TableRef("weak"))),
                right: SelectQuery(projection: [.wildcard()], source: strong)))),
            subqueries: [NamedSubquery(name: "weak", query: nullQuery)]))
        for (index, selected) in queries.enumerated() {
            let response = try await nativeDepthQuery(selected)
            let expected: [QueryValue] = index == 3
                ? [.primitive(.null), .primitive(.null), .primitive(.int64(1))]
                : [.primitive(.null), .primitive(.int64(1))]
            try require(response.columns.count == 1 && response.columns[0].type == .sql(.bigint)
                && response.columns[0].isNullable && response.rows.map { $0.values[0] } == expected,
                "nested-contextual-null-set-type-and-values")
        }
        var nested = singleton(.literal(.int(1)))
        for _ in 0..<30 {
            nested = SelectQuery(projection: [.wildcard()], source: .subquery(nested))
        }
        let nearLimit = try await nativeDepthQuery(nested)
        try require(nearLimit.columns.map { $0.type } == [.sql(.bigint)]
            && nearLimit.rows.map { $0.values } == [[.primitive(.int64(1))]], "admitted-thirty-query-wrappers")
        var nestedSet = singleton(.literal(.int(1)))
        for _ in 0..<30 {
            nestedSet = SelectQuery(projection: [.wildcard()], source: .setOperation(operator: .union,
                quantifier: .all, left: nestedSet, right: singleton(.literal(.int(1)))))
        }
        let setDepth = try await nativeDepthQuery(nestedSet)
        try require(setDepth.columns.map { $0.type } == [.sql(.bigint)]
            && setDepth.rows.map { $0.values } == Array(repeating: [.primitive(.int64(1))], count: 31),
            "admitted-thirty-left-set-operands")
        var nestedJoin = DataSource.values([[]])
        for _ in 0..<60 { nestedJoin = .join(JoinClause(type: .cross, left: nestedJoin, right: .values([[]]))) }
        let joinDepth = try await nativeDepthQuery(SelectQuery(projection: [.wildcard()], source: nestedJoin))
        try require(joinDepth.columns.isEmpty && joinDepth.rows.map { $0.values } == [[]], "admitted-sixty-source-joins")
        var nestedScalar = singleton(.literal(.int(1)))
        for _ in 0..<20 { nestedScalar = singleton(.subquery(nestedScalar)) }
        let scalarDepth = try await nativeDepthQuery(nestedScalar)
        try require(scalarDepth.columns.map { $0.type } == [.sql(.bigint)]
            && scalarDepth.rows.map { $0.values } == [[.primitive(.int64(1))]], "admitted-twenty-scalar-queries")
        let scalarBeyondLimit = singleton(.subquery(nestedScalar))
        let scalarRejectedMeter = invocation.meter()
        do {
            _ = try await invocation.query(scalarBeyondLimit, meter: scalarRejectedMeter)
            throw Failure.assertion("twenty-first-scalar-query-must-fail")
        } catch QueryStructuralValidationError.resourceLimitExceeded(let resource, let actual, let maximum) {
            try require(resource == .nestingDepth && maximum == QueryStructuralLimits.default.maximumNestingDepth
                && actual > maximum, "scalar-query-depth-admission-cause")
        }
        try released(scalarRejectedMeter, "scalar-query-depth-admission-release")
        var nestedCTE = singleton(.literal(.int(1)))
        for index in 0..<30 {
            let name = "depth_\(index)"
            nestedCTE = SelectQuery(projection: [.wildcard()], source: .table(TableRef(name)),
                subqueries: [NamedSubquery(name: name, query: nestedCTE)])
        }
        let cteDepth = try await nativeDepthQuery(nestedCTE)
        try require(cteDepth.columns.map { $0.type } == [.sql(.bigint)]
            && cteDepth.rows.map { $0.values } == [[.primitive(.int64(1))]], "admitted-thirty-nested-ctes")
        let beyondLimit = SelectQuery(projection: [.wildcard()], source: .subquery(nested))
        let rejectedMeter = invocation.meter()
        do {
            _ = try await invocation.query(beyondLimit, meter: rejectedMeter)
            throw Failure.assertion("thirty-first-wrapper-must-fail")
        } catch QueryStructuralValidationError.resourceLimitExceeded(let resource, let actual, let maximum) {
            try require(resource == .nestingDepth && maximum == QueryStructuralLimits.default.maximumNestingDepth
                && actual > maximum, "wrapper-depth-admission-cause")
        }
        try released(rejectedMeter, "wrapper-depth-admission-release")
    }

    private static func sourceScalarAlignment(_ invocation: Invocation) async throws {
        let characters = DataSource.aliased(.values([
            [.literal(.queryValue(.primitive(.string("a")), type: .sql(.char(length: 1))))],
            [.literal(.queryValue(.primitive(.string("a   ")), type: .sql(.char(length: 4))))],
            [.literal(.queryValue(.primitive(.string("b ")), type: .sql(.char(length: 2))))],
        ]), name: "values", columns: ["c"])
        let characterAggregate = SelectQuery(projection: [
            .expression(.aggregate(.count(column("c"), distinct: true))),
            .expression(.aggregate(.min(column("c")))), .expression(.aggregate(.max(column("c"))))
        ], source: characters)
        let characterResult = try await query(characterAggregate, invocation: invocation)
        try require(characterResult.rows.map { $0.values } == [[.primitive(.int64(2)),
            .primitive(.string("a")), .primitive(.string("b "))]], "char-source-preserves-padding-and-identity")
        let numeric = DataSource.aliased(.values([
            [.literal(.int(1))], [.literal(.uint(1))],
            [.literal(.decimal(ExactDecimal(coefficient: 10, scale: 1)))], [.literal(.int(2))],
        ]), name: "input_3", columns: ["value"])
        let numericDistinct = try await query(SelectQuery(projection: [.expression(column("value"))],
            source: numeric, quantifier: .distinct), invocation: invocation)
        try require(numericDistinct.rows.count == 2, "numeric-source-exact-representation-identity")
        let count = Expression.aggregate(.count(nil, distinct: false))
        let grouped = try await query(SelectQuery(projection: [.expression(column("value")), .expression(count)],
            source: numeric, groupBy: [.expression(column("value"))], orderBy: [SortKey(count)]), invocation: invocation)
        try require(grouped.rows.map { $0.values[1] } == [.primitive(.int64(1)), .primitive(.int64(3))],
            "numeric-source-group-counts")
        let largeFloat: Double = 95_367_431_640_625 * 0x1p100
        let largeDecimal = ExactDecimal(coefficient: Int128(1) << 80, scale: -20)
        let large = DataSource.aliased(.values([[.literal(.decimal(largeDecimal))], [.literal(.double(largeFloat))]]),
            name: "input_9", columns: ["value"])
        let largeDistinct = try await query(SelectQuery(projection: [.expression(column("value"))],
            source: large, quantifier: .distinct), invocation: invocation)
        try require(largeDistinct.rows.count == 1, "numeric-source-large-exact-alignment")
    }

    private static func reviewedSetAlignment(_ invocation: Invocation) async throws {
        func singleton(_ expression: Expression) -> SelectQuery {
            SelectQuery(projection: [.expression(expression, alias: "x")], source: .values([[]]))
        }
        func union(_ left: Expression, _ right: Expression) -> SelectQuery {
            SelectQuery(projection: [.wildcard()], source: .setOperation(operator: .union,
                quantifier: .all, left: singleton(left), right: singleton(right)))
        }
        let json = try await query(union(.cast(.string("{}"), targetType: .json),
            .cast(.string("{}"), targetType: .json)), invocation: invocation)
        try require(json.rows.count == 2, "json-union-all-has-no-equality-requirement")
        for row in json.rows { try require(try jsonText(row.values[0]) == "{}", "json-union-all-value") }
        let arrays = try await query(union(.array([.cast(integer(1), targetType: .smallint)]),
            .array([.cast(integer(2), targetType: .bigint)])), invocation: invocation)
        try require(arrays.columns.map { $0.type } == [.sql(.array(.bigint))] && arrays.rows.count == 2,
            "set-array-common-declaration")
        for (index, row) in arrays.rows.enumerated() {
            guard case .array(let array) = row.values[0] else { throw Failure.assertion("set-array-carrier") }
            try require(array.elementType == .bigint && Array(array.elements) == [.primitive(.int64(Int64(index + 1)))],
                "set-array-converted-elements")
        }
        let records = try await query(union(.row([.cast(integer(1), targetType: .smallint)]),
            .row([.cast(integer(2), targetType: .bigint)])), invocation: invocation)
        try require(records.rows.count == 2, "set-record-count")
        for (index, row) in records.rows.enumerated() {
            guard case .composite(let record) = row.values[0] else { throw Failure.assertion("set-record-carrier") }
            try require(record.type.columns.map { $0.type } == [.sql(.bigint)]
                && Array(record.fields) == [.primitive(.int64(Int64(index + 1)))], "set-record-converted-fields")
        }
        let date = Expression.cast(.string("2020-01-01"), targetType: .date)
        let timestamp = Expression.cast(.string("2020-01-02 00:00:00"), targetType: .timestamp(withTimeZone: false))
        let temporal = try await query(union(date, timestamp), invocation: invocation)
        try require(temporal.columns.map { $0.type } == [.sql(.timestamp(withTimeZone: false))]
            && temporal.rows.count == 2, "set-temporal-common-declaration")
        for (index, row) in temporal.rows.enumerated() {
            guard case .primitive(.dateTime(let time)) = row.values[0] else {
                throw Failure.assertion("set-temporal-converted-carrier")
            }
            try require(time.date.year == 2020 && time.date.month == 1 && time.date.day == index + 1,
                "set-temporal-converted-value")
        }
        let using = SelectQuery(projection: [.wildcard()], source: .join(JoinClause(type: .full,
            left: relation([[date]], name: "l", columns: ["k"]),
            right: relation([[timestamp]], name: "r", columns: ["k"]), condition: .using(["k"]))),
            orderBy: [SortKey(column("k"))])
        let merged = try await query(using, invocation: invocation)
        try require(merged.columns.map { $0.type } == [.sql(.timestamp(withTimeZone: false))]
            && merged.rows.map { $0.values } == temporal.rows.map { $0.values }, "using-common-temporal-conversion")
    }

    private static func sourceOccurrences(_ invocation: Invocation) async throws {
        let values = SelectQuery(projection: [.wildcard()], source: .values([
            [integer(1), integer(1)], [integer(2), .divide(integer(7), integer(0))]
        ]))
        let source = relation([[integer(1)]], columns: ["x"])
        let order = SelectQuery(projection: [.expression(integer(1))], source: source,
            orderBy: [SortKey(.divide(integer(11), .subtract(column("x"), integer(1))))])
        let distinct = SelectQuery(projection: [.expression(integer(1))], source: source,
            quantifier: .distinctOn([.divide(integer(13), .subtract(column("x"), integer(1)))]))
        for (index, selected) in [values, order, distinct].enumerated() {
            let outer = SelectQuery(projection: [.wildcard()], source: .subquery(selected))
            var arena = QueryOccurrenceArena()
            let root = try arena.append()
            let derived = try arena.append(parent: root, field: .source)
            let nested = try arena.append(parent: derived, field: .subquery)
            let expected: QueryOccurrenceID
            if index == 0 {
                let source = try arena.append(parent: nested, field: .source)
                let row = try arena.append(parent: source, field: .valuesRow, index: 1)
                expected = try arena.append(parent: row, field: .valuesCell, index: 1)
            } else {
                expected = try arena.append(parent: nested, field: index == 1 ? .orderBy : .distinctOn, index: 0)
            }
            let meter = invocation.meter()
            do {
                _ = try await invocation.query(outer, meter: meter, occurrences: arena, occurrence: root)
                throw Failure.assertion("source-occurrence-must-fail")
            } catch CanonicalReadError.expressionEvaluation(let cause, let occurrence) {
                try require(cause == .divisionByZero && occurrence == expected, "source-failure-exact-occurrence")
            }
            try released(meter, "source-failure-release")
        }
    }

    private static func compositePresence(_ invocation: Invocation) async throws {
        let left = relation([[integer(1)], [integer(2)]], name: "l", columns: ["key"])
        let rightQuery = SelectQuery(projection: [.expression(.cast(.null, targetType: .integer), alias: "a"),
            .expression(.cast(.null, targetType: .text), alias: "b")], source: .values([[]]))
        let right = DataSource.aliased(.subquery(rightQuery), name: "r")
        let joined = DataSource.join(JoinClause(type: .left, left: left, right: right,
            condition: .on(.equal(column("key", table: "l"), integer(1)))))
        let row = Expression.wholeRow("r")
        let selected = SelectQuery(projection: [.expression(row),
            .expression(SelectedValueVerification.call("row_to_json", [row])),
            .expression(.isNull(row)), .expression(.isDistinctFrom(row, .null, negated: false)),
            .expression(SelectedValueVerification.call("row_to_json", [.row([.fieldExpansion(row)])]))],
            source: joined, orderBy: [SortKey(column("key", table: "l"))])
        let response = try await query(selected, invocation: invocation)
        try require(response.rows.count == 2, "outer-join-row-count")
        guard case .composite(let present) = response.rows[0].values[0] else { throw Failure.assertion("present-composite-carrier") }
        try require(present.fields.count == 2 && present.fields.allSatisfy { $0.isNull }
            && response.rows[1].values[0].isNull, "present-all-null-versus-absent")
        try require(try jsonText(response.rows[0].values[1]) == "{\"a\":null,\"b\":null}"
            && response.rows[1].values[1].isNull, "whole-row-json-presence")
        try require(response.rows[0].values[2...3] == [.primitive(.bool(true)), .primitive(.bool(true))]
            && response.rows[1].values[2...3] == [.primitive(.bool(true)), .primitive(.bool(false))], "row-null-tests")
        for row in response.rows {
            try require(try jsonText(row.values[4]) == "{\"f1\":null,\"f2\":null}", "row-constructor-expansion")
        }
    }

    private static func arrayAndResources(_ invocation: Invocation) async throws {
        let scalar = rows([[integer(1)], [.cast(.null, targetType: .integer)], [integer(2)]], columns: ["x"])
            .replacing(orderBy: [SortKey(column("x"), nulls: .first)])
        let nested = rows([[.cast(.string("[0:1]={1,2}"), targetType: .array(.integer))],
            [.cast(.string("[0:1]={3,4}"), targetType: .array(.integer))]], columns: ["a"])
        let selected = ParameterBindingVerification.select([.arraySubquery(scalar),
            .arraySubquery(scalar.replacing(filter: .literal(.bool(false)))), .arraySubquery(nested)])
        let response = try await query(selected, invocation: invocation)
        guard case .array(let a) = response.rows[0].values[0], case .array(let empty) = response.rows[0].values[1],
              case .array(let outer) = response.rows[0].values[2] else { throw Failure.assertion("array-subquery-carriers") }
        try require(Array(a.elements) == [.primitive(.null), value(1), value(2)] && empty.dimensions.isEmpty,
            "scalar-and-empty-array-subquery")
        try require(outer.dimensions.map { $0.lowerBound } == [1, 0] && outer.dimensions.map { $0.length } == [2, 2]
            && Array(outer.elements) == [value(1), value(2), value(3), value(4)], "inner-bounds-outer-one")
        let measured = invocation.meter()
        _ = try await invocation.query(selected, meter: measured)
        try released(measured, "array-success-release")
        let limited = DatabaseWorkMeter(budget: ExecutionBudget(maximumRows: 100,
            maximumWorkUnits: max(1, measured.consumedWorkUnits / 2), maximumIntermediateRows: 1_000,
            maximumIntermediateBytes: 8 * 1_024 * 1_024, timeoutMilliseconds: 60_000),
            monotonicClock: invocation.container.monotonicClock)
        do {
            _ = try await invocation.query(selected, meter: limited)
            throw Failure.assertion("array-work-limit-must-fail")
        } catch is DatabaseWorkLimitError {}
        try released(limited, "array-failure-release")
        try await joinRowBudget(invocation)
    }

    private static func joinRowBudget(_ invocation: Invocation) async throws {
        let selected = SelectQuery(projection: [.wildcard()], source: .join(JoinClause(type: .cross,
            left: .aliased(.values([[.literal(.string("left"))]]), name: "left_source", columns: ["left_value"]),
            right: .aliased(.values([[.literal(.string("right"))]]), name: "right_source", columns: ["right_value"]))))
        let meter = DatabaseWorkMeter(budget: ExecutionBudget(maximumIntermediateRows: 4,
            maximumIntermediateBytes: 1_024 * 1_024), monotonicClock: invocation.container.monotonicClock)
        do {
            _ = try await invocation.query(selected, meter: meter)
            throw Failure.assertion("join-merged-row-claim-must-fail")
        } catch let failure as DatabaseWorkLimitError {
            try require(failure == .maximumIntermediateRows(stage: .joinCandidate, consumed: 4,
                requested: 1, maximum: 4), "join-merged-row-exact-claim")
        }
        try released(meter, "join-merged-row-failure-release")
    }

    private static func jsonText(_ value: QueryValue) throws -> String {
        guard case .json(let json) = value else { throw Failure.assertion("expected-json") }
        return String(decoding: json.bytes, as: UTF8.self)
    }
}
