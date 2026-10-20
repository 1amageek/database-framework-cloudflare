@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit
import DatabaseTypes
import Synchronization

/// S06 runs only public selected execution; kernels and supplied rules are real.
enum SQLTemporalVerification {
    static let groups = 6
    typealias Invocation = SelectedValueVerification.Invocation
    typealias DiagnosticFailure = SQLTextPatternVerification.DiagnosticFailure

    final class Clock: WallClock, Sendable {
        private struct State: Sendable { var seconds: Int64; var reads: Int = 0 }
        private let state: Mutex<State>
        init(seconds: Int64) { state = Mutex(State(seconds: seconds)) }
        var now: Timestamp {
            state.withLock { state in
                let result = Timestamp(secondsSinceUnixEpoch: state.seconds)
                state.seconds += 1; state.reads += 1
                return result
            }
        }
        var reads: Int { state.withLock { $0.reads } }
    }

    static func verify(in context: DatabaseContext, container: DBContainer) async throws {
        let clock = Clock(seconds: 946_684_802)
        let env = SQLTemporalEnvironment(transactionInstant: try Timestamp(secondsSinceUnixEpoch: 946_684_800, nanoseconds: 123_456_789),
            statementInstant: Timestamp(secondsSinceUnixEpoch: 946_684_801), wallClock: clock)
        let invocation = Invocation(context: context, container: container, temporalEnvironment: env)
        func select(_ expressions: [Expression]) -> SelectQuery { ParameterBindingVerification.select(expressions) }
        func cast(_ text: String, _ type: DataType) -> Expression { .cast(.string(text), targetType: type) }
        func text(_ expression: Expression) -> Expression { .cast(expression, targetType: .text) }
        func call(_ name: String, _ arguments: [Expression] = []) -> Expression { SelectedValueVerification.call(name, arguments) }
        func integer(_ n: Int32) -> Expression { SQLTextPatternVerification.integer(n) }
        func double(_ n: Double) -> Expression { .literal(.queryValue(.primitive(.float64(n)), type: .sql(.doublePrecision))) }
        func strings(_ values: [String]) -> [QueryValue] { values.map { .primitive(.string($0)) } }
        func require(_ condition: Bool, _ name: String) throws { try ParameterBindingVerification.require(condition, name) }
        func fails(_ expression: Expression, _ expected: DatabaseExpressionEvaluationError, using invocation: Invocation) async throws {
            let meter = invocation.meter()
            do {
                _ = try await invocation.query(select([expression]), meter: meter)
                throw ParameterBindingVerification.Failure.assertion("s06-expected-failure")
            } catch CanonicalReadError.expressionEvaluation(let cause, _) { try require(cause == expected, "s06-exact-error") }
            catch let failure as CanonicalSQLBindingFailure {
                switch failure.cause {
                case .expression(let cause), .read(.expressionEvaluation(let cause, _)): try require(cause == expected, "s06-located-error")
                default: throw failure
                }
            }
            try require(meter.retainedIntermediateBytes == 0 && meter.retainedIntermediateRows == 0, "s06-failure-release")
        }
        var phase = "temporal-input-precision"
        do {
            try await invocation.verify(select([
                text(cast("0001-02-29 BC", .date)), text(cast("2000002", .date)), text(cast("J2451546", .date)),
                text(cast("24:00", .time(withTimeZone: false))),
                text(cast("2000-01-01 00:00:00.0000005", .timestamp(withTimeZone: false))),
                text(cast("2000-01-01 00:00:00.0000015", .timestamp(withTimeZone: false))),
                text(cast("1999-12-31 23:59:59.500000", .timestamp(withTimeZone: false, precision: 0))),
                text(cast("2000-01-01 00:00:00.500000", .timestamp(withTimeZone: false, precision: 0))),
                .equal(cast("P0001-02-03T04:05:06.5", .interval()), cast("1 year 2 months 3 days 04:05:06.5", .interval())),
                .equal(cast("294276-12-31 23:59:59.999999+00", .timestamp(withTimeZone: true)), cast("294276-12-31 23:59:59.999999+00", .timestamp(withTimeZone: true))),
            ]), values: strings(["0001-02-29 BC", "2000-01-02", "2000-01-02", "24:00:00", "2000-01-01 00:00:00", "2000-01-01 00:00:00.000002", "1999-12-31 23:59:59", "2000-01-01 00:00:01"]) + [.primitive(.bool(true)), .primitive(.bool(true))])
            try await fails(cast("294277-01-01", .timestamp(withTimeZone: false)), .temporalValueOutOfRange, using: invocation)
            print("ENGINE_S06_CASE temporal-input-precision PASS")

            phase = "temporal-arithmetic-identity"
            let timestamp = DataType.timestamp(withTimeZone: false)
            try await invocation.verify(select([
                text(.cast(.add(cast("2024-01-31", .date), cast("1 month", .interval())), targetType: .date)),
                .subtract(cast("2024-03-01", .date), cast("2024-02-28", .date)),
                text(.add(cast("23:00", .time(withTimeZone: false)), cast("2 hours", .interval()))),
                .equal(cast("1 month", .interval()), cast("30 days", .interval())),
                .lessThan(cast("12:00+02", .time(withTimeZone: true)), cast("10:00+00", .time(withTimeZone: true))),
                .equal(call("age", [cast("2004-06-01", timestamp), cast("2004-04-30", timestamp)]), cast("1 month 1 day", .interval())),
                text(call("date_bin", [cast("15 minutes", .interval()), cast("1999-12-31 23:59:59.999999", timestamp), cast("2000-01-01", timestamp)])),
                .equal(.cast(cast("1 year 2 months 3 days 04:05:06", .interval()), targetType: .interval(fields: .year)), cast("1 year", .interval())),
                .equal(.cast(cast("1 year 2 months 3 days 04:05:06", .interval()), targetType: .interval(fields: .dayToHour)), cast("1 year 2 months 3 days 04:00", .interval())),
            ]), values: [.primitive(.string("2024-02-29")), .primitive(.int32(2)), .primitive(.string("01:00:00")),
                .primitive(.bool(true)), .primitive(.bool(true)), .primitive(.bool(true)), .primitive(.string("1999-12-31 23:45:00")), .primitive(.bool(true)), .primitive(.bool(true))])
            let intervalColumn = Expression.column(ColumnRef("span"))
            let grouped = SelectQuery(projection: [ProjectionItem(.aggregate(.count(nil, distinct: false)))],
                source: ParameterBindingVerification.values([
                    [.queryValue(.interval(try QueryIntervalValue(period: CalendarPeriod(months: 1), time: TimeSpan(seconds: 0))), type: .sql(.interval()))],
                    [.queryValue(.interval(try QueryIntervalValue(period: CalendarPeriod(days: 30), time: TimeSpan(seconds: 0))), type: .sql(.interval()))]
                ], columns: ["span"]), groupBy: [.expression(intervalColumn)])
            try await invocation.verify(grouped, values: [.primitive(.int64(2))])
            print("ENGINE_S06_CASE temporal-arithmetic-identity PASS")

            phase = "temporal-functions-infinity"
            try await invocation.verify(select([
                call("extract", [.string("second"), cast("2000-01-01 00:00:12.345678", timestamp)]),
                call("date_part", [.string("year"), cast("2024-02-29", .date)]),
                text(call("date_trunc", [.string("week"), cast("2021-01-01 12:34", timestamp)])),
                text(call("make_date", [integer(2024), integer(2), integer(29)])),
                text(call("make_time", [integer(24), integer(0), double(0)])),
                text(call("make_timestamp", [integer(2024), integer(2), integer(29), integer(12), integer(34), double(56)])),
                text(call("make_timestamptz", [integer(2024), integer(2), integer(29), integer(12), integer(34), double(56), .string("UTC")])),
                .equal(call("make_interval", [integer(1), integer(2), integer(3), integer(4), integer(5), integer(6), double(7.25)]), cast("1 year 2 months 25 days 05:06:07.25", .interval())),
                text(call("to_timestamp", [double(0)])),
                .lessThan(cast("-infinity", timestamp), cast("2000-01-01", timestamp)),
                text(.add(cast("infinity", timestamp), cast("1 day", .interval()))),
                call("extract", [.string("day"), cast("infinity", timestamp)]),
            ]), values: [try SelectedValueVerification.numeric(12_345_678, scale: 6, display: 6), .primitive(.float64(2024))] +
                strings(["2020-12-28 00:00:00", "2024-02-29", "24:00:00", "2024-02-29 12:34:56", "2024-02-29 12:34:56+00"]) +
                [.primitive(.bool(true)), .primitive(.string("1970-01-01 00:00:00+00")), .primitive(.bool(true)), .primitive(.string("infinity")), .primitive(.null)])
            try await fails(call("extract", [.string("epoch"), cast("infinity", .date)]), .nonFiniteValue, using: invocation)
            print("ENGINE_S06_CASE temporal-functions-infinity PASS")

            phase = "temporal-rules-dst-admission"
            let rulesMeter = invocation.meter()
            let database = try SQLTimeZoneDatabase(definitions: [
                .init(name: "America/New_York", tzif: SQLTimeZoneFixtures.newYork()),
                .init(name: "Australia/Lord_Howe", tzif: SQLTimeZoneFixtures.lordHowe())],
                provenance: ByteString(utf8: "IANA2026e fixture manifest a9e6c102"),
                limits: .init(maximumInputBytes: 100000, maximumRetainedBytes: 1000000, maximumTransitions: 10000))
            let ny = try database.rules(named: "America/New_York", workMeter: rulesMeter)
            let configuration = try SQLTemporalConfiguration(timeZone: .named(name: "America/New_York", rules: ny), rulesProvider: database,
                limits: .init(maximumAbbreviations: 0, maximumRetainedBytes: 16))
            let zoned = Invocation(context: context, container: container, temporalEnvironment: SQLTemporalEnvironment(
                transactionInstant: env.transactionInstant, statementInstant: env.statementInstant, wallClock: clock, configuration: configuration))
            phase = "temporal-rules-dst-combined-ny-fold-lordhowe-day24-posix"
            try await zoned.verify(select([
                .equal(cast("2024-03-10 02:30 America/New_York", .timestamp(withTimeZone: true)), cast("2024-03-10 07:30+00", .timestamp(withTimeZone: true))),
                .equal(cast("2024-11-03 01:30 America/New_York", .timestamp(withTimeZone: true)), cast("2024-11-03 06:30+00", .timestamp(withTimeZone: true))),
                .equal(cast("2024-10-06 02:15 Australia/Lord_Howe", .timestamp(withTimeZone: true)), cast("2024-10-05 15:45+00", .timestamp(withTimeZone: true))),
                .equal(cast("2024-04-07 01:45 Australia/Lord_Howe", .timestamp(withTimeZone: true)), cast("2024-04-06 15:15+00", .timestamp(withTimeZone: true))),
                .equal(.add(cast("2024-03-09 12:00-05", .timestamp(withTimeZone: true)), cast("1 day", .interval())), cast("2024-03-10 16:00+00", .timestamp(withTimeZone: true))),
                .equal(.add(cast("2024-03-09 12:00-05", .timestamp(withTimeZone: true)), cast("24 hours", .interval())), cast("2024-03-10 17:00+00", .timestamp(withTimeZone: true))),
                .equal(call("timezone", [.string("+05:30"), cast("2000-01-01 12:00", timestamp)]), cast("2000-01-01 17:30+00", .timestamp(withTimeZone: true))),
            ]), values: Array(repeating: .primitive(.bool(true)), count: 7))
            phase = "temporal-rules-dst-expected-unknown-zone"
            try await fails(cast("2000-01-01 12:00 Invalid/NotSupplied", .timestamp(withTimeZone: true)), .timeZone(.unknownZone), using: zoned)
            phase = "temporal-rules-dst-expected-missing-provider"
            try await fails(cast("2000-01-01 12:00 America/New_York", .timestamp(withTimeZone: true)), .timeZone(.rulesUnavailable), using: invocation)
            print("ENGINE_S06_CASE temporal-rules-dst PASS")

            phase = "temporal-clock-scope"
            try await invocation.verify(select([
                text(.currentValue(kind: .date, precision: nil)),
                text(.currentValue(kind: .time, precision: 3)),
                text(.currentValue(kind: .localTimestamp, precision: 6)),
                call("extract", [.string("epoch"), call("now")]),
                .equal(call("now"), call("transaction_timestamp")),
                .equal(call("statement_timestamp"), cast("2000-01-01 00:00:01+00", .timestamp(withTimeZone: true))),
                text(call("clock_timestamp")), text(call("clock_timestamp")),
            ]), values: strings(["2000-01-01", "00:00:00.123+00", "2000-01-01 00:00:00.123456"]) +
                [try SelectedValueVerification.numeric(946_684_800_123_456, scale: 6, display: 6), .primitive(.bool(true)), .primitive(.bool(true))] + strings(["2000-01-01 00:00:02+00", "2000-01-01 00:00:03+00"]))
            try require(clock.reads == 2, "s06-live-clock-two-occurrences")
            let stableQuery = SelectQuery(projection: [ProjectionItem(.equal(call("now"), .subquery(select([call("now")]))))],
                source: ParameterBindingVerification.values([[.int(1)], [.int(2)]], columns: ["n"]))
            let stableMeter = invocation.meter()
            let stable = try await invocation.query(stableQuery, meter: stableMeter)
            try require(stable.rows.count == 2 && stable.rows.allSatisfy { $0.values == [.primitive(.bool(true))] }, "s06-clock-row-subquery-inheritance")
            try require(clock.reads == 2 && stableMeter.retainedIntermediateBytes == 0, "s06-stable-clock-no-live-read")
            print("ENGINE_S06_CASE temporal-clock-scope PASS")

            phase = "temporal-format-resource-release"
            try await invocation.verify(select([
                call("to_char", [cast("2021-01-01", timestamp), .string("IYYY-IW-ID YYYY-MM-DD")]),
                call("to_char", [cast("0001-01-01 BC", timestamp), .string("YYYY BC")]),
                call("to_char", [cast("2024-01-02", timestamp), .string("FMMonth FMDD")]),
                text(call("to_date", [.string("2024/02/29"), .string("FXYYYY-MM-DD")])),
                text(call("to_timestamp", [.string("2024-02-29 12:34:56.123"), .string("YYYY-MM-DD HH24:MI:SS.MS")])),
                call("to_char", [cast("infinity", timestamp), .string("YYYY")]),
                call("concat", [cast("2024-02-29", .date), .string("/"), cast("24:00", .time(withTimeZone: false))]),
            ]), values: strings(["2020-53-5 2021-01-01", "0001 BC", "January 2", "2024-02-29", "2024-02-29 12:34:56.123+00"]) + [.primitive(.null), .primitive(.string("2024-02-29/24:00:00"))])
            try await fails(call("to_char", [cast("2147483647 days", .interval()), .string("J")]), .temporalValueOutOfRange, using: invocation)
            let resourceQuery = select([call("to_char", [cast("2024-02-29 12:34:56.123456", timestamp), .string(String(repeating: "YYYY-MM-DD HH24:MI:SS.US|", count: 32))])])
            let measured = invocation.meter()
            _ = try await invocation.query(resourceQuery, meter: measured)
            try require(measured.retainedIntermediateBytes == 0 && measured.retainedIntermediateRows == 0, "s06-format-success-release")
            let exact = DatabaseWorkMeter(budget: ExecutionBudget(maximumRows: 100, maximumWorkUnits: measured.consumedWorkUnits,
                maximumIntermediateRows: 1000, maximumIntermediateBytes: measured.peakIntermediateBytes, timeoutMilliseconds: 60000), monotonicClock: container.monotonicClock)
            _ = try await invocation.query(resourceQuery, meter: exact)
            try require(exact.retainedIntermediateBytes == 0 && exact.retainedIntermediateRows == 0, "s06-format-exact-boundary-release")
            let workLimit = DatabaseWorkMeter(budget: ExecutionBudget(maximumRows: 100, maximumWorkUnits: measured.consumedWorkUnits - 1,
                maximumIntermediateRows: 1000, maximumIntermediateBytes: 8 * 1024 * 1024, timeoutMilliseconds: 60000), monotonicClock: container.monotonicClock)
            do { _ = try await invocation.query(resourceQuery, meter: workLimit); throw ParameterBindingVerification.Failure.assertion("s06-format-work-limit") }
            catch is DatabaseWorkLimitError { }
            try require(workLimit.retainedIntermediateBytes == 0 && workLimit.retainedIntermediateRows == 0, "s06-format-work-failure-release")
            let byteLimit = DatabaseWorkMeter(budget: ExecutionBudget(maximumRows: 100, maximumWorkUnits: 100_000_000,
                maximumIntermediateRows: 1000, maximumIntermediateBytes: measured.peakIntermediateBytes - 1, timeoutMilliseconds: 60000), monotonicClock: container.monotonicClock)
            do { _ = try await invocation.query(resourceQuery, meter: byteLimit); throw ParameterBindingVerification.Failure.assertion("s06-format-byte-limit") }
            catch is DatabaseWorkLimitError { }
            try require(byteLimit.retainedIntermediateBytes == 0 && byteLimit.retainedIntermediateRows == 0, "s06-format-byte-failure-release")
            try await invocation.verify(select([text(cast("2000-01-01", .date))]), values: strings(["2000-01-01"]))
            print("ENGINE_S06_CASE temporal-format-resource-release PASS")
            print("ENGINE_S06_PASS cases=6")
        } catch { throw DiagnosticFailure(phase: phase, cause: error) }
    }
}
