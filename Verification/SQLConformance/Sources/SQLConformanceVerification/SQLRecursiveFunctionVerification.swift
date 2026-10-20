@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit
import DatabaseTypes

/// S10 selected IR executes through the existing application session and meter.
enum SQLRecursiveFunctionVerification {
    static let groups = 4
    typealias Invocation = SelectedValueVerification.Invocation
    typealias Failure = ParameterBindingVerification.Failure

    static func integer(_ value: Int32) -> Expression { SQLRelationalVerification.integer(value) }
    static func value(_ value: Int32) -> QueryValue { .primitive(.int32(value)) }
    static func column(_ name: String, table: String? = nil) -> Expression {
        SQLRelationalVerification.column(name, table: table)
    }
    static func require(_ condition: Bool, _ name: String) throws {
        try ParameterBindingVerification.require(condition, "s10-" + name)
    }
    static func query(_ selected: SelectQuery, _ invocation: Invocation) async throws -> QueryResponse {
        try await SQLRelationalVerification.query(selected, invocation: invocation)
    }
    static func function(_ name: String, _ arguments: [Expression],
                         ordinality: Bool = false, columns: [String]? = nil) -> DataSource {
        .aliased(.tableFunction(TableFunctionSource(function: FunctionCall(name: name,
            arguments: arguments), withOrdinality: ordinality)), name: "f", columns: columns)
    }
    static func select(_ source: DataSource, projection: [ProjectionItem] = [.wildcard()]) -> SelectQuery {
        SelectQuery(projection: projection, source: source)
    }
    static func recursive(quantifier: SetQuantifier = .all, duplicateSeed: Bool = false,
                          infinite: Bool = false, search: CTESearchClause? = nil,
                          cycle: CTECycleClause? = nil, cycleStep: Bool = false,
                          limit: UInt64? = nil) -> SelectQuery {
        let seed = SQLRelationalVerification.rows(duplicateSeed ? [[integer(1)], [integer(1)]] : [[integer(1)]], columns: ["n"])
        let next = cycleStep ? Expression.subtract(integer(3), column("n")) : .add(column("n"), integer(1))
        let term = SelectQuery(projection: [.expression(next, alias: "n")], source: .table(TableRef("t")),
            filter: infinite || cycleStep ? nil : .lessThan(column("n"), integer(3)))
        let body = select(.setOperation(operator: .union, quantifier: quantifier, left: seed, right: term))
        return SelectQuery(projection: [.wildcard()], source: .table(TableRef("t")),
            pagination: QueryPagination(limit: limit.map { .count(.fixed($0), withTies: false) }),
            subqueries: [NamedSubquery(name: "t", columns: ["n"], query: body, search: search, cycle: cycle)],
            withRecursive: true)
    }
    static func verify(in context: DatabaseContext, container: DBContainer) async throws {
        let invocation = Invocation(context: context, container: container)
        let checks: [(String, @Sendable (Invocation) async throws -> Void)] = [
            ("recursive-generated-demand", recursion),
            ("functions-lateral-ordinality", functions),
            ("series-overloads-boundaries-dst", series),
            ("recursive-function-resources", resources),
        ]
        for (name, check) in checks {
            do { try await check(invocation) }
            catch { throw SQLTextPatternVerification.DiagnosticFailure(phase: "s10-" + name, cause: error) }
            print("ENGINE_S10_CASE " + name + " PASS")
        }
        print("ENGINE_S10_PASS cases=4")
    }
    private static func recursion(_ invocation: Invocation) async throws {
        let unique = try await query(recursive(quantifier: .distinct, duplicateSeed: true), invocation)
        try require(unique.rows.map { $0.values } == [[value(1)], [value(2)], [value(3)]], "union-distinct")
        let bag = try await query(recursive(duplicateSeed: true), invocation)
        try require(bag.rows.map { $0.values } == [[value(1)], [value(1)], [value(2)], [value(2)], [value(3)], [value(3)]], "union-all")
        let prefix = try await query(recursive(infinite: true, limit: 3), invocation)
        try require(prefix.rows.map { $0.values } == [[value(1)], [value(2)], [value(3)]], "unbounded-demand-prefix")
        let generated = try await query(recursive(search: CTESearchClause(order: .depthFirst,
            columns: ["n"], sequenceColumn: "ord"), cycle: CTECycleClause(columns: ["n"],
            markColumn: "cyclic", pathColumn: "path"), cycleStep: true), invocation)
        try require(generated.columns.map { $0.name } == ["n", "ord", "cyclic", "path"]
            && generated.rows.map { $0.values[0] } == [value(1), value(2), value(1)]
            && generated.rows.map { $0.values[2] } == [.primitive(.bool(false)), .primitive(.bool(false)), .primitive(.bool(true))], "search-cycle-columns")
        for (index, row) in generated.rows.enumerated() {
            guard case .array(let order) = row.values[1], case .array(let path) = row.values[3],
                  case .composite(let key) = path.elements[0] else { throw Failure.assertion("s10-generated-record-array") }
            try require(order.elements.count == index + 1 && path.elements.count == index + 1
                && key.fields[0] == value(1), "generated-path-identity")
        }
    }
    private static func functions(_ invocation: Invocation) async throws {
        let left = SQLRelationalVerification.relation([[integer(2)], [integer(3)]], name: "v", columns: ["n"])
        let right = function("unnest", [.array([column("n", table: "v"), .add(column("n", table: "v"), integer(1))])],
            ordinality: true, columns: ["x", "o"])
        let lateral = SelectQuery(projection: [.expression(column("n", table: "v")),
            .expression(column("x", table: "f")), .expression(column("o", table: "f"))],
            source: .join(JoinClause(type: .cross, left: left, right: right)))
        let result = try await query(lateral, invocation)
        try require(result.rows.map { $0.values } == [[value(2), value(2), .primitive(.int64(1))],
            [value(2), value(3), .primitive(.int64(2))], [value(3), value(3), .primitive(.int64(1))],
            [value(3), value(4), .primitive(.int64(2))]], "implicit-lateral-ordinality")
        let json = try await query(select(function("json_each_text", [.cast(.string("{\"a\":1,\"a\":2,\"b\":null}"), targetType: .json)],
            ordinality: true)), invocation)
        try require(json.rows.map { $0.values } == [[.primitive(.string("a")), .primitive(.string("1")), .primitive(.int64(1))],
            [.primitive(.string("a")), .primitive(.string("2")), .primitive(.int64(2))],
            [.primitive(.string("b")), .primitive(.null), .primitive(.int64(3))]], "json-order-null")
        let split = try await query(select(function("regexp_split_to_table", [.string("a,,b,"), .string(",")], ordinality: true)), invocation)
        try require(split.rows.map { $0.values[0] } == ["a", "", "b", ""].map { .primitive(.string($0)) }, "regexp-empty-fields")
    }
    private static func series(_ invocation: Invocation) async throws {
        let endpoints = try await query(select(function("generate_series", [integer(Int32.max), integer(Int32.max), integer(1)])), invocation)
        try require(endpoints.rows.map { $0.values } == [[value(Int32.max)]], "integer-endpoint-before-overflow")
        let numeric = try await query(select(function("generate_series", [try SelectedValueVerification.number(11, scale: 1, display: 1),
            try SelectedValueVerification.number(38, scale: 1, display: 1), try SelectedValueVerification.number(13, scale: 1, display: 1)])), invocation)
        try require(numeric.rows.map { $0.values[0] } == [try SelectedValueVerification.numeric(11, scale: 1, display: 1),
            try SelectedValueVerification.numeric(24, scale: 1, display: 1), try SelectedValueVerification.numeric(37, scale: 1, display: 1)], "numeric-step")
        let null = try await query(select(function("generate_series", [.cast(.null, targetType: .integer), integer(3), integer(0)])), invocation)
        try require(null.rows.isEmpty && null.columns.map { $0.type } == [.sql(.integer)], "null-before-zero-step")
        let monthly = function("generate_series", [.cast(.string("2024-01-30"), targetType: .timestamp(withTimeZone: false)),
            .cast(.string("2024-04-30"), targetType: .timestamp(withTimeZone: false)), .cast(.string("1 month"), targetType: .interval())], columns: ["n"])
        let dates = try await query(select(monthly, projection: [.expression(.cast(column("n"), targetType: .text))]), invocation)
        try require(dates.rows.map { $0.values[0] } == ["2024-01-30 00:00:00", "2024-02-29 00:00:00",
            "2024-03-29 00:00:00", "2024-04-29 00:00:00"].map { .primitive(.string($0)) }, "month-step-clipping")
        let database = try SQLTimeZoneDatabase(definitions: [.init(name: "America/New_York", tzif: SQLTimeZoneFixtures.newYork())],
            provenance: ByteString(utf8: "S10 IANA fixture"), limits: .init(maximumInputBytes: 100_000,
                maximumRetainedBytes: 1_000_000, maximumTransitions: 10_000))
        let configuration = try SQLTemporalConfiguration(rulesProvider: database,
            limits: .init(maximumAbbreviations: 0, maximumRetainedBytes: 0))
        let instant = Timestamp(secondsSinceUnixEpoch: 0)
        let zoned = Invocation(context: invocation.context, container: invocation.container,
            temporalEnvironment: SQLTemporalEnvironment(transactionInstant: instant, statementInstant: instant,
                wallClock: invocation.container.wallClock, configuration: configuration))
        let dst = function("generate_series", [.cast(.string("2024-03-09 17:00+00"), targetType: .timestamp(withTimeZone: true)),
            .cast(.string("2024-03-12 16:00+00"), targetType: .timestamp(withTimeZone: true)),
            .cast(.string("1 day"), targetType: .interval()), .string("America/New_York")], columns: ["n"])
        let values = try await query(select(dst, projection: [.expression(.cast(column("n"), targetType: .text))]), zoned)
        try require(values.rows.map { $0.values[0] } == ["2024-03-09 17:00:00+00", "2024-03-10 16:00:00+00",
            "2024-03-11 16:00:00+00", "2024-03-12 16:00:00+00"].map { .primitive(.string($0)) }, "dst-step")
    }
    private static func resources(_ invocation: Invocation) async throws {
        let selected = recursive(infinite: true, limit: 4), measured = invocation.meter()
        let retained = try await invocation.query(selected, meter: measured)
        try SQLCollectionVerification.released(measured, "s10-early-close")
        let matches = try await query(select(function("regexp_matches",
            [.string("a1 b22"), .string("([a-z])([0-9]+)"), .string("g")], ordinality: true)), invocation)
        guard matches.rows.count == 2, case .array(let retainedMatch) = matches.rows[1].values[0] else {
            throw Failure.assertion("s10-retained-match-array")
        }
        let limited = DatabaseWorkMeter(budget: ExecutionBudget(maximumRows: 100,
            maximumWorkUnits: max(1, measured.consumedWorkUnits / 2), maximumIntermediateRows: 1_000,
            maximumIntermediateBytes: 8 * 1_024 * 1_024, timeoutMilliseconds: 60_000), monotonicClock: invocation.container.monotonicClock)
        do {
            _ = try await invocation.query(selected, meter: limited)
            throw Failure.assertion("s10-work-quota-must-fail")
        } catch DatabaseWorkLimitError.maximumWorkUnits(_, _, _, _) {}
        try SQLCollectionVerification.released(limited, "s10-work-quota-release")
        let cancelledMeter = invocation.meter()
        let cancelled = Task { () async throws -> Void in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await invocation.query(selected, meter: cancelledMeter)
                throw Failure.assertion("s10-cancel-must-fail")
            } catch is CancellationError {}
        }
        try await cancelled.value
        try SQLCollectionVerification.released(cancelledMeter, "s10-cancel-release")
        _ = try await query(select(function("unnest", [.array([.string("retained"), .string("value")])], ordinality: true)), invocation)
        try require(retained.rows.map { $0.values } == [[value(1)], [value(2)], [value(3)], [value(4)]], "retained-response-followup")
        try require(Array(retainedMatch.elements) == [.primitive(.string("b")), .primitive(.string("22"))],
            "retained-rich-match-followup")
        let zero = select(function("generate_series", [integer(1), integer(2), integer(0)]))
        do {
            _ = try await query(zero, invocation)
            throw Failure.assertion("s10-zero-step-must-fail")
        } catch CanonicalReadError.expressionEvaluation(_, _) {}
        _ = try await query(recursive(), invocation)
    }
}
