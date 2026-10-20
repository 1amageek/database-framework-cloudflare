@_spi(DatabaseExecution) @testable import DatabaseEngine
import DatabaseKit
import DatabaseTypes

/// Runs S13 against the host-owned container and its persistent SQLite ABI.
enum SQLConstraintSequenceVerification {
    typealias Failure = ParameterBindingVerification.Failure
    static let markers = ["immediate-integrity", "deferred-checkpoint", "foreign-key-actions",
        "default-generated", "identity-overrides", "sequence-request-history", "sequence-nonrollback-replay",
        "sequence-reactor-restoration"]
    static let entities = ["S13PortableItem", "S13PortableParent", "S13PortableChild"]
    static let names = ["s13_items", "s13_parents", "s13_children"]

    static func schemaEntities() throws -> [Schema.Entity] {
        try entities.enumerated().map { index, name in
            try Schema.Entity(name: name, identifierType: .string, fields: [
                FieldSchema(name: "id", fieldNumber: 1, type: .string),
                FieldSchema(name: "a", fieldNumber: 2, type: .int64, isOptional: true, queryType: .sql(.bigint)),
                FieldSchema(name: "b", fieldNumber: 3, type: .int64, isOptional: true, queryType: .sql(.bigint)),
                FieldSchema(name: "g", fieldNumber: 4, type: .int64, isOptional: true, queryType: .sql(.bigint))
            ], directoryComponents: [.staticPath("s13-portable-" + String(index))])
        }
    }

    static func verify(in context: DatabaseContext, container: DBContainer) async throws {
        let checks: [(String, @Sendable () async throws -> Void)] = [
            (markers[0], { try await immediate(context, container) }),
            (markers[1], { try await deferred(context, container) }),
            (markers[2], { try await foreignKeys(context, container) }),
            (markers[3], { try await generated(context, container) }),
            (markers[4], { try await identity(context, container) }),
            (markers[5], { try await sequenceHistory(context) }),
            (markers[6], { try await sequenceRollback(context) })
        ]
        for (name, check) in checks {
            do { try await check() }
            catch { throw SQLTextPatternVerification.DiagnosticFailure(phase: "s13-" + name, cause: error) }
            print("ENGINE_S13_CASE " + name + " PASS")
        }
    }

    static func verifyRestored(in context: DatabaseContext, container: DBContainer) async throws {
        do {
            try require(container.sqlCatalog.sequences.contains(where: { $0.id == "s13_counter" }), "restored-declaration")
            do {
                _ = try await run(context, [call("currval", [.string("s13_counter")])])
                throw Failure.assertion("s13-restored-request-history-must-be-empty")
            } catch is SQLSequenceExecutionError {}
            let result = try await run(context, [call("nextval", [.string("s13_counter")]),
                call("currval", [.string("s13_counter")]), call("lastval", [])])
            for index in 0..<3 { try require(try value(result, index) == 27, "restored-allocator-27") }
            let persisted = try await read(context, table: 0, id: "identity-default", columns: ["a"])
            try require(persisted == [[.primitive(.int64(102))]], "restored-identity-row")
        } catch { throw SQLTextPatternVerification.DiagnosticFailure(phase: "s13-" + markers[7], cause: error) }
        print("ENGINE_S13_CASE " + markers[7] + " PASS")
        print("ENGINE_S13_PASS cases=8 allocator=27")
    }

    private static func immediate(_ context: DatabaseContext, _ container: DBContainer) async throws {
        let unique = try constraint("s13_unique", kind: .unique(columnIDs: ["field:2"], nulls: .distinct))
        let positive = try constraint("s13_positive", kind: .check(.greaterThan(.col("a"), .int(0))))
        try await publish(container, key: "immediate", item: relation(0, constraints: [unique, positive]))
        _ = try await run(context, [.statement(insert(0, "one", .int(1), .int(0))),
            .statement(insert(0, "two", .int(2), .int(0))),
            .statement(insert(0, "unknown", .null, .int(0)))])
        do {
            _ = try await run(context, [.statement(.update(UpdateQuery(target: TableRef(names[0]),
                assignments: [Assignment(column: "a", value: .subtract(.int(3), .col("a")))])))])
            throw Failure.assertion("s13-nondeferrable-swap-must-fail")
        } catch SQLConstraintError.violation(_, _, "s13_unique", _, _, _) {}
        try require(try await read(context, table: 0, id: "one", columns: ["a"]) == [[.primitive(.int64(1))]], "failed-swap-atomic")
        do {
            _ = try await run(context, [.statement(insert(0, "negative", .int(-1), .int(0)))])
            throw Failure.assertion("s13-check-false-must-fail")
        } catch SQLConstraintError.violation(_, _, "s13_positive", _, _, _) {}
        try require(try await read(context, table: 0, id: "negative", columns: ["a"]).isEmpty, "failed-check-absent")
        try await clear(context)
    }

    private static func deferred(_ context: DatabaseContext, _ container: DBContainer) async throws {
        let unique = try constraint("s13_deferred", timing: .deferrable(initiallyDeferred: false),
            kind: .unique(columnIDs: ["field:2"], nulls: .distinct))
        try await publish(container, key: "deferred", item: relation(0, constraints: [unique]))
        _ = try await run(context, [.statement(insert(0, "one", .int(1), .int(0))),
            .statement(insert(0, "two", .int(2), .int(0)))])
        _ = try await run(context, [.statement(.update(UpdateQuery(target: TableRef(names[0]),
            assignments: [Assignment(column: "a", value: .subtract(.int(3), .col("a")))])))])
        try require(try await read(context, table: 0, id: "one", columns: ["a"]) == [[.primitive(.int64(2))]], "statement-result-swap")
        let delay = try SQLSetConstraints(selection: .named(["s13_deferred"]), deferred: true)
        let immediate = try SQLSetConstraints(selection: .named(["s13_deferred"]), deferred: false)
        for retroactive in [false, true] {
            var steps: [SQLBlockStep] = [.setConstraints(delay), .statement(insert(0, "conflict", .int(2), .int(0)))]
            if retroactive { steps.append(.setConstraints(immediate)) }
            do {
                _ = try await run(context, steps)
                throw Failure.assertion("s13-deferred-violation-must-fail")
            } catch SQLConstraintError.violation(_, _, "s13_deferred", _, _, _) {}
            try require(try await read(context, table: 0, id: "conflict", columns: ["a"]).isEmpty, "deferred-request-rollback")
        }
        _ = try await run(context, [.savepoint("before-delay"), .setConstraints(delay),
            .statement(insert(0, "abandoned", .int(2), .int(0))), .rollbackTo("before-delay"),
            .statement(insert(0, "survivor", .int(3), .int(0)))])
        try require(try await read(context, table: 0, id: "abandoned", columns: ["a"]).isEmpty, "checkpoint-removes-pending")
        try require(try await read(context, table: 0, id: "survivor", columns: ["a"]) == [[.primitive(.int64(3))]], "checkpoint-survivor")
        try await clear(context)
    }

    private static func foreignKeys(_ context: DatabaseContext, _ container: DBContainer) async throws {
        for match: SQLForeignKeyMatch in [.simple, .full] {
            let key = try SQLForeignKey(columnIDs: ["field:2", "field:3"],
                referencedRelationID: relationID(1), match: match, onUpdate: .cascade,
                onDelete: .setNull, onDeleteColumnIDs: ["field:3"])
            let foreign = try constraint("s13_fk", kind: .foreignKey(key))
            try await publish(container, key: match == .simple ? "fk-simple" : "fk-full",
                item: relation(0), parent: relation(1, primary: ["field:2", "field:3"]),
                child: relation(2, constraints: [foreign]))
            _ = try await run(context, [.statement(insert(1, "parent", .int(1), .int(2))),
                .statement(insert(2, "child", .int(1), .int(2))),
                .statement(insert(2, "null", .null, .null))])
            if match == .simple {
                _ = try await run(context, [.statement(insert(2, "partial", .int(1), .null))])
            } else {
                do {
                    _ = try await run(context, [.statement(insert(2, "partial", .int(1), .null))])
                    throw Failure.assertion("s13-full-partial-null-must-fail")
                } catch SQLConstraintError.violation(_, _, "s13_fk", _, _, _) {}
            }
            do {
                _ = try await run(context, [.statement(insert(2, "missing", .int(9), .int(9)))])
                throw Failure.assertion("s13-missing-parent-must-fail")
            } catch SQLConstraintError.violation(_, _, "s13_fk", _, _, _) {}
            _ = try await run(context, [.statement(.update(UpdateQuery(target: TableRef(names[1]),
                assignments: [Assignment(column: "a", value: .int(3))])))])
            try require(try await read(context, table: 2, id: "child", columns: ["a", "b"])
                == [[.primitive(.int64(3)), .primitive(.int64(2))]], "update-cascade")
            if match == .simple {
                _ = try await run(context, [.statement(.delete(DeleteQuery(target: TableRef(names[1]))))])
                try require(try await read(context, table: 2, id: "child", columns: ["a", "b"])
                    == [[.primitive(.int64(3)), .primitive(.null)]], "delete-set-null-subset")
            }
            try await clear(context)
        }
    }

    private static func generated(_ context: DatabaseContext, _ container: DBContainer) async throws {
        guard let principal = context.authorization.principal?.identifier else {
            throw Failure.assertion("s13-host-principal-required")
        }
        try require(principal == RuntimeVerificationSession.principalIdentifier
            && container.sqlCatalog.namespaces.contains(where: { $0.name == principal }), "admitted-host-session")
        func sessionValue(_ name: String) -> Expression {
            .function(FunctionCall(name: name, arguments: []))
        }
        let session = try await run(context, [.statement(.select(SelectQuery(projection:
            ["current_user", "session_user", "current_schema", "current_database"].map {
                .expression(sessionValue($0))
            }, source: .values([[]]))))])
        guard case .rows(let sessionRows) = session.results[0] else {
            throw Failure.assertion("s13-session-result-discriminant")
        }
        try require(sessionRows.rows.map { $0.values } == [[.primitive(.string(principal)),
            .primitive(.string(principal)), .primitive(.string(principal)),
            .primitive(.string("portable-verification"))]], "selected-admitted-session-values")
        let sessionCheck = try constraint("s13_session_principal", kind: .check(.and(
            .equal(sessionValue("current_user"), .string(principal)),
            .and(.equal(sessionValue("session_user"), .string(principal)),
                .equal(sessionValue("current_schema"), .string(principal))))))
        let columns = try [SQLColumn(id: "field:1", name: "id", fieldNumber: 1),
            SQLColumn(id: "field:2", name: "a", backing: .field(number: 2), policy: .input(defaultExpression: .int(7))),
            SQLColumn(id: "field:3", name: "b", fieldNumber: 3),
            SQLColumn(id: "field:4", name: "g", backing: .field(number: 4), policy: .generated(.add(.col("a"), .int(1)))),
            SQLColumn(id: "virtual", name: "derived", backing: .virtual(type: .sql(.bigint)),
                policy: .generated(.multiply(.col("a"), .int(2))))]
        try await publish(container, key: "generated", item: relation(0, columns: columns, constraints: [sessionCheck]))
        _ = try await run(context, [.statement(.insert(InsertQuery(target: TableRef(names[0]),
            columns: ["id", "a"], source: .values([[.string("generated"), .defaultValue]]))))])
        try require(try await read(context, table: 0, id: "generated", columns: ["a", "g", "derived"])
            == [[.primitive(.int64(7)), .primitive(.int64(8)), .primitive(.int64(14))]], "default-stored-virtual")
        _ = try await run(context, [.statement(.update(UpdateQuery(target: TableRef(names[0]),
            assignments: [Assignment(column: "a", value: .int(9))])))])
        try require(try await read(context, table: 0, id: "generated", columns: ["g", "derived"])
            == [[.primitive(.int64(10)), .primitive(.int64(18))]], "generated-update")
        do {
            _ = try await run(context, [.statement(.update(UpdateQuery(target: TableRef(names[0]),
                assignments: [Assignment(column: "g", value: .int(99))])))])
            throw Failure.assertion("s13-generated-explicit-must-fail")
        } catch SQLConstraintError.generatedAssignment(_, "g") {}
        try await clear(context)
    }

    private static func identity(_ context: DatabaseContext, _ container: DBContainer) async throws {
        let sequence = try SQLSequence(id: "s13_identity", namespaceID: "public", name: "s13_identity",
            start: 100, increment: 1, minimum: 1, maximum: 1_000)
        _ = try await run(context, [.sequence(.create(sequence))])
        func columns(_ generation: SQLIdentityGeneration) throws -> [SQLColumn] {
            try [SQLColumn(id: "field:1", name: "id", fieldNumber: 1),
                SQLColumn(id: "field:2", name: "a", backing: .field(number: 2),
                    policy: .identity(SQLIdentityColumn(sequenceID: sequence.id, generation: generation))),
                SQLColumn(id: "field:3", name: "b", fieldNumber: 3), SQLColumn(id: "field:4", name: "g", fieldNumber: 4)]
        }
        try await publish(container, key: "identity-always", item: relation(0, columns: columns(.always)))
        _ = try await run(context, [.statement(.insert(InsertQuery(target: TableRef(names[0]),
            columns: ["id"], source: .values([[.string("identity-auto")]]))))])
        do {
            _ = try await run(context, [.statement(insert(0, "identity-rejected", .int(500), .null))])
            throw Failure.assertion("s13-identity-always-must-reject-explicit")
        } catch SQLConstraintError.identityAssignment(_, "a") {}
        _ = try await run(context, [.statement(.insert(InsertQuery(target: TableRef(names[0]),
            columns: ["id", "a"], source: .values([[.string("identity-system"), .int(500)]]), overriding: .systemValue))),
            .statement(.insert(InsertQuery(target: TableRef(names[0]), columns: ["id", "a"],
                source: .values([[.string("identity-user"), .int(501)]]), overriding: .userValue)))])
        try require(try await read(context, table: 0, id: "identity-auto", columns: ["a"]) == [[.primitive(.int64(100))]], "identity-omission")
        try require(try await read(context, table: 0, id: "identity-system", columns: ["a"]) == [[.primitive(.int64(500))]], "identity-system-override")
        try require(try await read(context, table: 0, id: "identity-user", columns: ["a"]) == [[.primitive(.int64(101))]], "identity-user-override")
        try await publish(container, key: "identity-by-default", item: relation(0, columns: columns(.byDefault)))
        _ = try await run(context, [.statement(insert(0, "identity-explicit", .int(700), .null)),
            .statement(insert(0, "identity-default", .defaultValue, .null))])
        try require(try await read(context, table: 0, id: "identity-explicit", columns: ["a"]) == [[.primitive(.int64(700))]], "identity-by-default-explicit")
        try require(try await read(context, table: 0, id: "identity-default", columns: ["a"]) == [[.primitive(.int64(102))]], "identity-default-allocation")
    }

    private static func counter() throws -> SQLSequence {
        try SQLSequence(id: "s13_counter", namespaceID: "public", name: "s13_counter",
            start: 1, increment: 1, minimum: 1, maximum: 100)
    }

    private static func sequenceHistory(_ context: DatabaseContext) async throws {
        let result = try await run(context, [.sequence(.create(counter())), call("nextval", [.string("s13_counter")]),
            .savepoint("history"), call("nextval", [.string("s13_counter")]), .rollbackTo("history"),
            call("currval", [.string("s13_counter")]), call("lastval", []), call("nextval", [.string("s13_counter")]),
            call("setval", [.string("s13_counter"), .int(20), .literal(.bool(false))]),
            call("currval", [.string("s13_counter")]), call("nextval", [.string("s13_counter")])])
        for (index, expected): (Int, Int64) in [(1, 1), (3, 2), (5, 2), (6, 2), (7, 3), (8, 20), (9, 3), (10, 20)] {
            try require(try value(result, index) == expected, "sequence-history-" + String(index))
        }
        do {
            _ = try await run(context, [call("currval", [.string("s13_counter")])])
            throw Failure.assertion("s13-new-request-history-must-be-empty")
        } catch is SQLSequenceExecutionError {}
    }

    private static func sequenceRollback(_ context: DatabaseContext) async throws {
        do {
            _ = try await run(context, [call("nextval", [.string("s13_counter")]), .rollbackTo("missing")])
            throw Failure.assertion("s13-sequence-failed-request-must-throw")
        } catch SQLBlockExecutionError.unknownCheckpoint("missing") {}
        let followup = try await run(context, [call("nextval", [.string("s13_counter")])])
        try require(try value(followup, 0) == 22, "failed-request-consumption-persists")
        let restart = try await run(context, [.savepoint("restart"), .sequence(.alter(counter(), restart: 80)),
            call("nextval", [.string("s13_counter")]), .rollbackTo("restart"), call("nextval", [.string("s13_counter")])])
        try require(try value(restart, 2) == 80 && value(restart, 4) == 23, "restart-incarnation-rollback")
        let replay = try await run(context, [call("nextval", [.string("s13_counter")]),
            call("nextval", [.string("s13_counter")]), call("nextval", [.string("s13_counter")])],
            configuration: TransactionConfiguration(maximumAttempts: 1))
        for index in 0..<3 { try require(try value(replay, index) == Int64(24 + index), "allocation-replay-budget") }
    }

    private static func relationID(_ index: Int) -> String { "entity:" + entities[index] }

    private static func relation(_ index: Int, primary: [String]? = ["field:1"], columns: [SQLColumn]? = nil,
        constraints: [SQLConstraint] = []) throws -> SQLRelation {
        let fields = try columns ?? [SQLColumn(id: "field:1", name: "id", fieldNumber: 1),
            SQLColumn(id: "field:2", name: "a", fieldNumber: 2), SQLColumn(id: "field:3", name: "b", fieldNumber: 3),
            SQLColumn(id: "field:4", name: "g", fieldNumber: 4)]
        return try SQLRelation(id: relationID(index), namespaceID: "public", name: names[index],
            entityName: entities[index], columns: fields, primaryKeyColumnIDs: primary, constraints: constraints)
    }

    private static func constraint(_ name: String, timing: SQLConstraintTiming = .immediate,
        kind: SQLConstraintKind) throws -> SQLConstraint {
        try SQLConstraint(attributes: SQLConstraintAttributes(id: name, name: name, timing: timing), kind: kind)
    }

    private static func publish(_ container: DBContainer, key: String, item: SQLRelation,
        parent: SQLRelation? = nil, child: SQLRelation? = nil) async throws {
        let source = container.sqlCatalog
        let replacements = try [item, parent ?? relation(1), child ?? relation(2)]
        let catalog = try SQLCatalog(namespaces: source.namespaces, relations: source.relations.map { old in
            replacements.first(where: { $0.id == old.id }) ?? old
        }, sequences: source.sequences)
        _ = try await container.publishSQLCatalog(catalog, expectedGeneration: container.schemaGeneration,
            idempotencyKey: "s13-portable-" + key, authorization: SQLCatalogVerification.authorization)
    }

    private static func insert(_ table: Int, _ id: String, _ a: Expression, _ b: Expression) -> QueryStatement {
        .insert(InsertQuery(target: TableRef(names[table]), columns: ["id", "a", "b"], source: .values([[.string(id), a, b]])))
    }

    private static func clear(_ context: DatabaseContext) async throws {
        _ = try await run(context, [2, 1, 0].map { .statement(.delete(DeleteQuery(target: TableRef(names[$0])))) })
    }

    private static func call(_ name: String, _ arguments: [Expression]) -> SQLBlockStep {
        .statement(.select(SelectQuery(projection: [.expression(.function(FunctionCall(name: name, arguments: arguments)))],
            source: .values([[]]))))
    }

    private static func read(_ context: DatabaseContext, table: Int, id: String, columns: [String]) async throws -> [[QueryValue]] {
        let result = try await run(context, [.statement(.select(SelectQuery(projection: columns.map { .column($0) },
            source: .table(TableRef(names[table])), filter: .equal(.col("id"), .string(id)))))])
        guard case .rows(let rows) = result.results[0] else { throw Failure.assertion("s13-select-result-discriminant") }
        return rows.rows.map { $0.values }
    }

    private static func run(_ context: DatabaseContext, _ steps: [SQLBlockStep],
        configuration: TransactionConfiguration = .default) async throws -> SQLBlockResult {
        try await SQLBlockExecutor(context: context).execute(SQLBlock(steps: steps), options:
            SQLBlockExecutionOptions(checkpointLimits: SQLCheckpointVerification.limits(), configuration: configuration))
    }

    private static func value(_ result: SQLBlockResult, _ index: Int) throws -> Int64 {
        guard case .rows(let response) = result.results[index], response.rows.count == 1,
              case .primitive(.int64(let value)) = response.rows[0].values.first else {
            throw Failure.assertion("s13-sequence-bigint-row-discriminant")
        }
        return value
    }

    private static func require(_ condition: Bool, _ name: String) throws {
        try ParameterBindingVerification.require(condition, "s13-" + name)
    }
}
