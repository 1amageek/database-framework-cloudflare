@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit
import DatabaseTypes

/// Executes S05 scalar contracts through the production canonical session.
enum SQLTextPatternVerification {
    typealias Invocation = SelectedValueVerification.Invocation
    typealias Failure = ParameterBindingVerification.Failure
    static let groups = 5
    struct DiagnosticFailure: Error {
        let phase: String
        let cause: any Error
    }

    static func integer(_ value: Int32) -> Expression {
        .literal(.queryValue(.primitive(.int32(value)), type: .sql(.integer)))
    }
    static func bigint(_ value: Int64) -> Expression {
        .literal(.queryValue(.primitive(.int64(value)), type: .sql(.bigint)))
    }
    static func textArray(_ elements: [QueryValue]) throws -> QueryValue {
        .array(try QueryArrayValue(elementType: .text,
            dimensions: [QueryArrayDimension(lowerBound: 1, length: Int32(elements.count))],
            elements: elements, limits: QueryValueLimits(maximumRetainedBytes: 16_384, maximumTotalNodes: 1_024,
                maximumNestingDepth: 32, maximumCollectionElements: 256)))
    }
    static func verify(in context: DatabaseContext, container: DBContainer) async throws {
        let invocation = Invocation(context: context, container: container)
        func select(_ expressions: [Expression]) -> SelectQuery { ParameterBindingVerification.select(expressions) }
        func call(_ name: String, _ arguments: [Expression]) -> Expression {
            SelectedValueVerification.call(name, arguments)
        }
        func text(_ value: String) -> QueryValue { .primitive(.string(value)) }
        var phase = "codepoint-c-posix"
        do {
        let unicode = Expression.string("e\u{301}😀")
        try await invocation.verify(select([
            call("length", [unicode]), call("octet_length", [unicode]),
            call("substring", [unicode, integer(2), integer(1)]),
            call("reverse", [unicode]), call("lower", [.string("ÄİΣAZ")]),
            call("upper", [.string("ßéaz")]), .concatenate(.string("ab"), .string("雪")),
        ]), values: [.primitive(.int32(3)), .primitive(.int32(7)), text("\u{301}"),
            text("😀\u{301}e"), text("ÄİΣaz"), text("ßéAZ"), text("ab雪")],
            types: [.sql(.integer), .sql(.integer)] + Array(repeating: .sql(.text), count: 5))
        print("ENGINE_S05_CASE codepoint-c-posix PASS")
        phase = "lexical-char-numeric"

        let numeric = DataType.decimal(precision: nil, scale: nil)
        let timestamp = try Timestamp(secondsSinceUnixEpoch: 1, nanoseconds: 123_456_000)
        let unsigned = Expression.literal(.queryValue(.primitive(.uint64(.max)), type: .primitive(.uint64)))
        let unsignedNull = Expression.literal(.queryValue(.primitive(.null), type: .primitive(.uint64)))
        let commonCharacter = Expression.coalesce([
            .cast(.string("xy"), targetType: .char(length: 2)),
            .cast(.string("abc"), targetType: .char(length: 3)),
        ])
        try await invocation.verify(select([
            .cast(.string("é😀x"), targetType: .char(length: 2)),
            .cast(.string("é😀x"), targetType: .varchar(length: 2)),
            .cast(.string("x"), targetType: .char(length: 3)),
            .cast(.string("1.2300"), targetType: numeric),
            .cast(.string("-1.235"), targetType: .decimal(precision: 5, scale: 2)),
            .cast(.cast(.string("1.2300"), targetType: numeric), targetType: .text),
            .cast(.literal(.queryValue(.primitive(.null), type: .sql(.text))), targetType: .char(length: 2)),
            .cast(commonCharacter, targetType: .char(length: nil)),
            .coalesce([unsigned, unsignedNull]),
            .cast(.literal(.queryValue(.primitive(.timestamp(timestamp)),
                type: .sql(.timestamp(withTimeZone: true, precision: 6)))),
                targetType: .timestamp(withTimeZone: true)),
        ]), values: [text("é😀"), text("é😀"), text("x  "),
            try SelectedValueVerification.numeric(123, scale: 2, display: 4),
            try SelectedValueVerification.numeric(-124, scale: 2, display: 2),
            text("1.2300"), .primitive(.null), text("x"), .primitive(.uint64(.max)), .primitive(.timestamp(timestamp))],
            types: [.sql(.char(length: 2)), .sql(.varchar(length: 2)), .sql(.char(length: 3)),
                .sql(numeric), .sql(.decimal(precision: 5, scale: 2)), .sql(.text), .sql(.char(length: 2)),
                .sql(.char(length: nil)), .primitive(.uint64), .sql(.timestamp(withTimeZone: true))])
        try await invocation.fails(.cast(.string("9.995"), targetType: .decimal(precision: 3, scale: 2)),
                                   cause: .numericOverflow)
        print("ENGINE_S05_CASE lexical-char-numeric PASS")
        phase = "uuid-bytea"

        let binary = Expression.cast(.string("\\x0180"), targetType: .blob)
        let byteExpressions: [Expression] = [
            .cast(.cast(.string("{A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11}"), targetType: .uuid), targetType: .text),
            call("encode", [call("decode", [.string("AP9c"), .string("base64")]), .string("hex")]),
            call("encode", [.cast(.string("\\000\\377\\\\A"), targetType: .blob), .string("hex")]),
            call("get_byte", [binary, integer(1)]), call("get_bit", [binary, bigint(0)]),
            call("get_bit", [binary, bigint(15)]),
            call("encode", [call("set_byte", [binary, integer(1), integer(256)]), .string("hex")]),
            call("encode", [call("set_bit", [binary, bigint(9), integer(1)]), .string("hex")]),
        ]
        let byteValues: [QueryValue] = [text("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"), text("00ff5c"), text("00ff5c41"),
            .primitive(.int32(128)), .primitive(.int32(1)), .primitive(.int32(1)), text("0100"), text("0182")]
        phase = "uuid-bytea-combined"
        try await invocation.verify(select(byteExpressions), values: byteValues)
        phase = "uuid-bytea-invalid-offset"
        try await invocation.fails(call("get_byte", [binary, integer(2)]),
            cause: .invalidFunctionArgument(function: "get_byte", reason: "offset outside the input"))
        print("ENGINE_S05_CASE uuid-bytea PASS")
        phase = "pattern-operators"

        func pattern(_ subject: Expression, _ pattern: String, _ kind: PatternMatchKind,
                     escape: Expression? = nil) -> Expression {
            .patternMatch(subject: subject, pattern: .string(pattern), escape: escape, kind: kind)
        }
        try await invocation.verify(select([
            pattern(.string("e\u{301}"), "__", .like),
            pattern(.string("a%b"), "a#%b", .like, escape: .string("#")),
            pattern(.string("a\\b"), "a\\b", .like), pattern(.string("Ab"), "aB", .caseInsensitiveLike),
            pattern(.string("É"), "é", .caseInsensitiveLike), pattern(.string("abcd"), "(ab|xy)%", .similarTo),
            pattern(.string("zab"), "a|ab", .regularExpression),
            call("regexp_like", [.string("ab"), .string("^(a|ab)$"), .string("e")]),
            call("regexp_like", [.string("é"), .string("^[[:alpha:]]+$")]),
            pattern(.cast(.null, targetType: .text), "[", .regularExpression),
            pattern(.cast(.string("x"), targetType: .char(length: 3)), "x", .like),
            call("regexp_like", [.cast(.string("x"), targetType: .char(length: 3)), .string("^x$")]),
            call("regexp_like", [.string("["), .string("[[]")]),
            call("regexp_like", [.string("q"), .string("\\q")]),
        ]), values: [.primitive(.bool(true)), .primitive(.bool(true)), .primitive(.bool(true)),
            .primitive(.bool(true)), .primitive(.bool(false)), .primitive(.bool(true)),
            .primitive(.bool(true)), .primitive(.bool(true)), .primitive(.bool(false)), .primitive(.null),
            .primitive(.bool(false)), .primitive(.bool(true)), .primitive(.bool(true)), .primitive(.bool(true))],
            types: Array(repeating: .sql(.boolean), count: 14))
        print("ENGINE_S05_CASE pattern-operators PASS")
        phase = "pattern-results-failures-release"

        try await invocation.verify(select([
            call("regexp_match", [.string("zab"), .string("(a|ab)"), .string("e")]),
            call("regexp_match", [.string("b"), .string("(a)?(b*)")]),
            call("regexp_match", [.string("a"), .string("z")]),
            call("regexp_replace", [.string("ab"), .string(""), .string("X"), .string("g")]),
            call("regexp_replace", [.string("ab ab"), .string("(a)(b)"), .string("\\2\\1"), .string("g")]),
            call("regexp_split_to_array", [.string("ab"), .string("")]),
            call("substring", [.string("zabc"), .string("a(b)c")]),
        ]), values: [try textArray([text("ab")]), try textArray([.primitive(.null), text("b")]),
            .primitive(.null), text("XaXbX"), text("ba ba"), try textArray([text("a"), text("b")]), text("b")])
        try await invocation.fails(call("regexp_like", [.string("a"), .string("a{256}")]),
            cause: .invalidPattern(offset: 4, reason: "repetition bound must be between 0 and 255"))
        for (expression, category) in [
            (call("regexp_like", [.string("a"), .string("[")]), "invalid"),
            (call("regexp_like", [.string("a"), .string("(?=a)")]), "unsupported"),
            (call("regexp_like", [.string("a"), .string("a"), .string("g")]), "argument"),
        ] {
            let meter = invocation.meter()
            do {
                _ = try await invocation.query(select([expression]), meter: meter)
                throw Failure.assertion("s05-pattern-error-must-fail")
            } catch CanonicalReadError.expressionEvaluation(let cause, _) {
                let actual: String
                switch cause {
                case .invalidPattern: actual = "invalid"
                case .unsupportedPattern: actual = "unsupported"
                case .invalidFunctionArgument: actual = "argument"
                default: throw Failure.assertion("s05-pattern-error-category")
                }
                try ParameterBindingVerification.require(actual == category, "s05-pattern-error-category")
            }
            try ParameterBindingVerification.require(meter.retainedIntermediateBytes == 0
                && meter.retainedIntermediateRows == 0, "s05-pattern-failure-release")
        }
        let resourceQuery = select([call("regexp_replace", [.string(String(repeating: "ab", count: 64)),
            .string("(a|ab)+"), .string("X"), .string("g")])])
        let measured = invocation.meter()
        _ = try await invocation.query(resourceQuery, meter: measured)
        try ParameterBindingVerification.require(measured.retainedIntermediateBytes == 0
            && measured.retainedIntermediateRows == 0, "s05-pattern-success-release")
        let limited = DatabaseWorkMeter(budget: ExecutionBudget(maximumRows: 100,
            maximumWorkUnits: max(1, measured.consumedWorkUnits / 2), maximumIntermediateRows: 1_000,
            maximumIntermediateBytes: 8 * 1_024 * 1_024, timeoutMilliseconds: 60_000),
            monotonicClock: container.monotonicClock)
        do {
            _ = try await invocation.query(resourceQuery, meter: limited)
            throw Failure.assertion("s05-pattern-work-limit-must-fail")
        } catch is DatabaseWorkLimitError {}
        try ParameterBindingVerification.require(limited.retainedIntermediateBytes == 0
            && limited.retainedIntermediateRows == 0, "s05-pattern-limit-release")
        try await invocation.verify(select([call("regexp_like", [.string("ab"), .string("a|ab")])]),
                                    values: [.primitive(.bool(true))])
        print("ENGINE_S05_CASE pattern-results-failures-release PASS")
        print("ENGINE_S05_PASS cases=5")
        } catch { throw DiagnosticFailure(phase: phase, cause: error) }
    }
}
