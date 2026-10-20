@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit
import DatabaseTypes

/// S09 selected IR uses the existing real reactor session and operation meter.
enum SQLAnalyticVerification {
    static let groups = 4
    typealias Invocation = SelectedValueVerification.Invocation
    typealias Failure = ParameterBindingVerification.Failure
    static func integer(_ value: Int32) -> Expression { SQLRelationalVerification.integer(value) }
    static func value(_ value: Int32) -> QueryValue { .primitive(.int32(value)) }
    static func column(_ name: String) -> Expression { .column(ColumnRef(column: name)) }
    static func aggregate(_ name: SQLAggregateFunction, _ arguments: [Expression]) -> Expression {
        .aggregate(.sql(SQLAggregateCall(function: name, arguments: arguments)))
    }
    static func source(_ rows: [[Expression]], _ columns: [String]) -> DataSource {
        SQLRelationalVerification.relation(rows, columns: columns)
    }
    static func require(_ condition: Bool, _ name: String) throws {
        try ParameterBindingVerification.require(condition, "s09-" + name)
    }
    static func query(_ select: SelectQuery, _ invocation: Invocation) async throws -> QueryResponse {
        try await SQLRelationalVerification.query(select, invocation: invocation)
    }
    static func verify(in context: DatabaseContext, container: DBContainer) async throws {
        let invocation = Invocation(context: context, container: container)
        let checks: [(String, @Sendable (Invocation) async throws -> Void)] = [
            ("grouping-compound-duplicates", grouping),
            ("widened-aggregate-rich-owner", aggregates),
            ("window-peers-frames-lazy-default", windows),
            ("analytic-limits-cancel-release", ownership),
        ]
        for (name, check) in checks {
            do { try await check(invocation) }
            catch { throw SQLTextPatternVerification.DiagnosticFailure(phase: "s09-" + name, cause: error) }
            print("ENGINE_S09_CASE " + name + " PASS")
        }
        print("ENGINE_S09_PASS cases=4")
    }
    private static func grouping(_ invocation: Invocation) async throws {
        let k = column("k"), x = column("x"), bits = Expression.grouping([k])
        let input = source([[integer(1), integer(10)], [integer(1), integer(20)],
                            [integer(2), integer(30)]], ["k", "x"])
        let selected = SelectQuery(projection: [.expression(k), .expression(aggregate(.count, [])),
            .expression(bits)], source: input,
            groupBy: [.groupingSets([[.expression(k)], [], []])], orderBy: [SortKey(bits), SortKey(k)])
        let result = try await query(selected, invocation)
        try require(result.columns.map { $0.type } == [.sql(.integer), .sql(.bigint), .sql(.integer)],
                    "grouping-declarations")
        try require(result.rows.map { $0.values } == [
            [value(1), .primitive(.int64(2)), value(0)],
            [value(2), .primitive(.int64(1)), value(0)],
            [.primitive(.null), .primitive(.int64(3)), value(1)],
            [.primitive(.null), .primitive(.int64(3)), value(1)]], "duplicate-empty-sets")
        let compound = SelectQuery(projection: [.expression(k), .expression(x),
            .expression(aggregate(.count, [])), .expression(.grouping([k, x]))], source: input,
            groupBy: [.rollup([[k, x]])], orderBy: [SortKey(.grouping([k, x])), SortKey(k), SortKey(x)])
        let rolled = try await query(compound, invocation)
        try require(rolled.rows.map { $0.values } == [
            [value(1), value(10), .primitive(.int64(1)), value(0)],
            [value(1), value(20), .primitive(.int64(1)), value(0)],
            [value(2), value(30), .primitive(.int64(1)), value(0)],
            [.primitive(.null), .primitive(.null), .primitive(.int64(3)), value(3)]], "compound-rollup-bits")
    }
    private static func aggregates(_ invocation: Invocation) async throws {
        let large: Int128 = 100_000_000_000_000_000_000_000_000_000
        let input = source([[integer(1), try SelectedValueVerification.number(large + 1)],
                            [integer(3), try SelectedValueVerification.number(large + 3)]], ["x", "n"])
        let selected = SelectQuery(projection: [.expression(aggregate(.sum, [column("x")])),
            .expression(aggregate(.avg, [column("x")])), .expression(aggregate(.sum, [column("n")]))], source: input)
        let result = try await query(selected, invocation)
        try require(result.rows.map { $0.values } == [[.primitive(.int64(4)),
            try SelectedValueVerification.numeric(2, display: 16),
            try SelectedValueVerification.numeric(large * 2 + 4)]], "widened-sum-average")
        let rich = SelectQuery(projection: [.expression(aggregate(.arrayAgg, [.array([column("x")])]))], source: input)
        let retained = try await query(rich, invocation).rows[0].values[0]
        _ = try await query(selected, invocation)
        guard case .array(let array) = retained else { throw Failure.assertion("s09-rich-array-carrier") }
        try require(array.dimensions.map { $0.length } == [2, 1]
            && array.dimensions.map { $0.lowerBound } == [1, 1]
            && Array(array.elements) == [value(1), value(3)], "rich-array-outlives-operation")
        let intervals = source([[Expression.cast(.string("1 month"), targetType: .interval())],
                                [.cast(.string("30 days"), targetType: .interval())]], ["i"])
        let period = try await query(SelectQuery(projection: [.expression(aggregate(.sum, [column("i")]))], source: intervals), invocation)
        try require(period.rows[0].values[0] == .interval(try QueryIntervalValue(
            period: CalendarPeriod(months: 1, days: 30), time: TimeSpan(seconds: 0))), "interval-sum")
    }
    private static func windowQuery() -> SelectQuery {
        let k = column("k"), x = column("x")
        let order = [SortKey(k)]
        func analytic(_ function: SQLWindowFunction, _ arguments: [Expression], frame: WindowFrame? = nil) -> Expression {
            .window(WindowCall(function: .analytic(function, arguments: arguments),
                reference: .specification(WindowSpecification(orderBy: order, frame: frame))))
        }
        func sum(_ mode: WindowFrameMode, _ start: WindowFrameBound,
                 exclusion: WindowFrameExclusion = .noOthers) -> Expression {
            .window(WindowCall(function: .aggregate(SQLAggregateCall(function: .sum, arguments: [x])),
                reference: .specification(WindowSpecification(orderBy: mode == .rows ? [SortKey(k), SortKey(x)] : order,
                    frame: WindowFrame(mode: mode, start: start, end: .currentRow, exclusion: exclusion)))))
        }
        return SelectQuery(projection: [.expression(k), .expression(x),
            .expression(analytic(.rank, [])), .expression(analytic(.lastValue, [x])),
            .expression(sum(.rows, .preceding(integer(1)))),
            .expression(sum(.range, .preceding(integer(1)))),
            .expression(sum(.groups, .unboundedPreceding, exclusion: .ties)),
            .expression(analytic(.lag, [x, integer(0), .divide(integer(1), integer(0))]))],
            source: source([[integer(1), integer(10)], [integer(1), integer(20)],
                            [integer(2), integer(30)]], ["k", "x"]), orderBy: [SortKey(k), SortKey(x)])
    }
    private static func windows(_ invocation: Invocation) async throws {
        let result = try await query(windowQuery(), invocation)
        try require(result.rows.map { $0.values } == [
            [value(1), value(10), .primitive(.int64(1)), value(20), .primitive(.int64(10)), .primitive(.int64(30)), .primitive(.int64(10)), value(10)],
            [value(1), value(20), .primitive(.int64(1)), value(20), .primitive(.int64(30)), .primitive(.int64(30)), .primitive(.int64(20)), value(20)],
            [value(2), value(30), .primitive(.int64(3)), value(30), .primitive(.int64(50)), .primitive(.int64(60)), .primitive(.int64(60)), value(30)]], "peer-frame-navigation-values")
    }
    private static func ownership(_ invocation: Invocation) async throws {
        let selected = windowQuery(), measured = invocation.meter()
        _ = try await invocation.query(selected, meter: measured)
        try SQLCollectionVerification.released(measured, "s09-window-success-release")
        let limited = DatabaseWorkMeter(budget: ExecutionBudget(maximumRows: 100,
            maximumWorkUnits: max(1, measured.consumedWorkUnits / 2), maximumIntermediateRows: 1_000,
            maximumIntermediateBytes: 8 * 1_024 * 1_024, timeoutMilliseconds: 60_000),
            monotonicClock: invocation.container.monotonicClock)
        do {
            _ = try await invocation.query(selected, meter: limited)
            throw Failure.assertion("s09-window-work-limit-must-fail")
        } catch DatabaseWorkLimitError.maximumWorkUnits(_, _, _, _) {}
        try SQLCollectionVerification.released(limited, "s09-window-failure-release")
        let cancelledMeter = invocation.meter()
        let cancelled = Task { () async throws -> Void in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await invocation.query(selected, meter: cancelledMeter)
                throw Failure.assertion("s09-cancel-must-fail")
            } catch is CancellationError {}
        }
        try await cancelled.value
        try SQLCollectionVerification.released(cancelledMeter, "s09-window-cancel-release")
        try await windows(invocation)
    }
}
