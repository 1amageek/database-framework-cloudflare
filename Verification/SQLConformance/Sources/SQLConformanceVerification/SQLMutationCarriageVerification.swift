import DatabaseKit
import DatabaseTypes
import DatabaseWire

/// Runs the same canonical mutation carriage on the ordinary reactor stack.
enum SQLMutationCarriageVerification {
    typealias Failure = ParameterBindingVerification.Failure

    static func verify() throws {
        print("ENGINE_S14_CASE S14K01 BEGIN")
        let statement = mixed(.parameter(position: 1))
        try roundTrip(statement, limits: limits())
        let bytes = try QueryIRWireFormat.encode(statement, limits: limits())
        try require(try QueryIRWireFormat.encode(statement, limits: limits(frame: bytes.count)) == bytes, "exact-frame-encode")
        try require(try QueryIRWireFormat.decode(bytes, limits: limits(frame: bytes.count)) == statement, "exact-frame-decode")
        for restricted in [try limits(frame: bytes.count - 1), try limits(collection: 0), try limits(objects: 1)] {
            do {
                _ = try QueryIRWireFormat.encode(statement, limits: restricted)
                throw Failure.assertion("s14-kit-one-past-encode-must-fail")
            } catch is DatabaseWireError {}
            do {
                _ = try QueryIRWireFormat.decode(bytes, limits: restricted)
                throw Failure.assertion("s14-kit-one-past-decode-must-fail")
            } catch is DatabaseWireError {}
            try noEmission(statement, limits: restricted)
        }
        try noEmission(.truncate(TruncateQuery(tables: [])), limits: limits())
        do {
            _ = try QueryIRWireFormat.decode(ByteString([10, 2]), limits: limits())
            throw Failure.assertion("s14-kit-malformed-with-bool-must-fail")
        } catch is DatabaseWireError {}
        let deep = nested(.parameter(position: 1))
        let structural = QueryStructuralLimits(maximumNestingDepth: 1024)
        try QueryStructuralValidator.validate(deep, limits: structural)
        try roundTrip(deep, limits: limits())
        let equal = nested(.parameter(position: 1))
        try require(deep == equal && deep.hashValue == equal.hashValue, "deep-identity-hash")
        let binder = try QueryParameterBinder(parameters: [QueryParameter(position: 1, value: .primitive(.int64(7)))],
            structuralLimits: structural)
        try require(try binder.bind(deep) == nested(.int(7)), "deep-parameter-reconstruction")
        do {
            try QueryStructuralValidator.validate(deep, limits: QueryStructuralLimits(maximumNestingDepth: 200))
            throw Failure.assertion("s14-kit-deep-structural-limit-must-fail")
        } catch is QueryStructuralValidationError {}
        print("ENGINE_S14_CASE S14K01 PASS")
        print("ENGINE_S14_KIT_PASS cases=1 depth=200")
    }

    private static func mixed(_ value: Expression) -> QueryStatement {
        let change = QueryStatement.update(UpdateQuery(target: TableRef("target"),
            assignments: [Assignment(columns: ["a", "b"], value: .row([value, .defaultValue]))],
            returning: [.wildcard(qualifier: "next")], returningAliases: SQLReturningAliases(old: "prior", new: "next")))
        let merge = QueryStatement.merge(MergeQuery(target: TableRef("target"), source: .values([[value]]),
            condition: .bool(true), clauses: [SQLMergeClause(match: .matched, action: .update([Assignment(column: "a", value: value)])),
                SQLMergeClause(match: .notMatchedByTarget, action: .insert(columns: ["a"], values: [.defaultValue], overriding: .userValue)),
                SQLMergeClause(match: .notMatchedBySource, action: .doNothing)],
            returning: [.expression(value, alias: "parameter")]))
        return .with(SQLWithStatement(statements: [SQLNamedStatement(name: "changed", statement: change),
            SQLNamedStatement(name: "cleared", statement: .truncate(TruncateQuery(tables: [TableRef("archive")], identity: .restart, references: .cascade)))], body: merge))
    }

    private static func nested(_ value: Expression) -> QueryStatement {
        var statement = mixed(value)
        for _ in 0..<200 {
            statement = .with(SQLWithStatement(statements: [SQLNamedStatement(name: "q", statement:
                .truncate(TruncateQuery(tables: [TableRef("table")])) )], body: statement))
        }
        return statement
    }

    private static func limits(frame: Int = 100_000, collection: Int = 1000, objects: Int = 100_000) throws -> DatabaseWireLimits {
        try DatabaseWireLimits(maximumFrameBytes: frame, maximumStringBytes: 1000, maximumByteStringBytes: frame,
            maximumCollectionCount: collection, maximumNestingDepth: 1024, maximumObjectCount: objects)
    }

    private static func roundTrip(_ statement: QueryStatement, limits: DatabaseWireLimits) throws {
        let bytes = try QueryIRWireFormat.encode(statement, limits: limits)
        try require(try QueryIRWireFormat.decode(bytes, limits: limits) == statement, "owned-roundtrip")
        var expected = 0
        var streamed: [UInt8] = []
        try QueryIRWireFormat.emitCanonicalEncoding(statement, limits: limits,
            prepare: { expected = $0 }, consume: { streamed.append(contentsOf: $0) })
        try require(expected == bytes.count && ByteString(streamed) == bytes, "streamed-owned-equality")
    }

    private static func noEmission(_ statement: QueryStatement, limits: DatabaseWireLimits) throws {
        var prepared = false
        var emitted = 0
        do {
            try QueryIRWireFormat.emitCanonicalEncoding(statement, limits: limits,
                prepare: { _ in prepared = true }, consume: { emitted += $0.count })
            throw Failure.assertion("s14-kit-rejected-emission-must-fail")
        } catch is DatabaseWireEmissionError<Never> {}
        try require(!prepared && emitted == 0, "rejected-encoding-no-partial-output")
    }

    private static func require(_ condition: Bool, _ name: String) throws {
        try ParameterBindingVerification.require(condition, "s14-kit-" + name)
    }
}
