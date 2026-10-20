@_spi(DatabaseExecution) @testable import DatabaseEngine
import DatabaseKit
import DatabaseTypes

/// Exercises semantic DML through the admitted container and captured SQLite host.
enum SQLDMLVerification {
    typealias Failure = ParameterBindingVerification.Failure
    static let entities = ["S14PortableItem", "S14PortableSource", "S14PortableArchive"]
    static let names = ["s14_items", "s14_sources", "s14_archive"]
    static let markers = ["S14M01", "S14M02", "S14M03", "S14M04", "S14M05", "S14M06", "S14M07", "S14M08"]

    static func schemaEntities() throws -> [Schema.Entity] {
        try entities.enumerated().map { index, name in
            try Schema.Entity(name: name, identifierType: .string, fields: [
                FieldSchema(name: "id", fieldNumber: 1, type: .string),
                FieldSchema(name: "a", fieldNumber: 2, type: .int64, isOptional: true, queryType: .sql(.bigint)),
                FieldSchema(name: "b", fieldNumber: 3, type: .int64, isOptional: true, queryType: .sql(.bigint)),
                FieldSchema(name: "g", fieldNumber: 4, type: .int64, isOptional: true, queryType: .sql(.bigint))
            ], directoryComponents: [.staticPath("s14-portable-" + String(index))])
        }
    }

    static func verify(in context: DatabaseContext, container: DBContainer) async throws {
        try SQLMutationCarriageVerification.verify()
        let checks: [@Sendable () async throws -> Void] = [
            { try await insertSelect(context, container) },
            { try await updateFrom(context, container) },
            { try await deleteUsing(context, container) },
            { try await returning(context, container) },
            { try await conflict(context, container) },
            { try await writableCTE(context, container) },
            { try await merge(context, container) },
            { try await truncate(context, container) }
        ]
        for (index, check) in checks.enumerated() {
            print("ENGINE_S14_CASE " + markers[index] + " BEGIN")
            do { try await check() }
            catch { throw SQLTextPatternVerification.DiagnosticFailure(phase: markers[index], cause: error) }
            print("ENGINE_S14_CASE " + markers[index] + " PASS")
        }
        print("ENGINE_S14_PASS cases=8")
    }

    private static func insertSelect(_ context: DatabaseContext, _ container: DBContainer) async throws {
        let sequence = try SQLSequence(id: "s14_defaults", namespaceID: "public", name: "s14_defaults",
            start: 10, increment: 1, minimum: 1, maximum: 1000)
        _ = try await run(context, [.sequence(.create(sequence))])
        let columns = try [SQLColumn(id: "field:1", name: "id", fieldNumber: 1),
            SQLColumn(id: "field:2", name: "a", fieldNumber: 2),
            SQLColumn(id: "field:3", name: "b", backing: .field(number: 3),
                policy: .input(defaultExpression: call("nextval", [.string("s14_defaults")]))),
            SQLColumn(id: "field:4", name: "g", backing: .field(number: 4),
                policy: .generated(.add(.col("a"), .col("b"))))]
        try await publish(container, "insert-select", replacements: [relation(0, columns: columns)])
        _ = try await run(context, [.statement(insert(1, "first", 4, 0)), .statement(insert(1, "second", 5, 0))])
        let source = SelectQuery(projection: [.column("id"), .column("a")], source: table(1),
            orderBy: [SortKey(.col("id"))])
        let result = try await run(context, [.statement(.insert(InsertQuery(target: TableRef(names[0]),
            columns: ["id", "a"], source: .select(source), returning: [.column("id"), .column("b"), .column("g")])) )])
        try require(try rows(result).affectedRows == 2, "insert-select-count")
        try require(try await read(context, 0, "first", ["b", "g"]) == [[q(10), q(14)]], "first-row-default-generated")
        try require(try await read(context, 0, "second", ["b", "g"]) == [[q(11), q(16)]], "second-row-default-generated")
        try await clear(context)
    }

    private static func updateFrom(_ context: DatabaseContext, _ container: DBContainer) async throws {
        try await publish(container, "update-from")
        _ = try await run(context, [.statement(insert(0, "old", 3, 4)), .statement(insert(1, "source", 8, 9))])
        let query = UpdateQuery(target: ref(0, "t"), assignments: [
            Assignment(columns: ["a", "b"], value: .row([.col("t", "b"), .col("t", "a")])),
            Assignment(column: "id", value: .string("moved"))
        ], from: table(1, "s"), filter: .equal(.col("s", "a"), .int(8)),
            returning: [.expression(.col("old", "id")), .expression(.col("new", "id")), .expression(.col("s", "a"))])
        let result = try await run(context, [.statement(.update(query))])
        try require(try rows(result).affectedRows == 1, "update-from-count")
        try require(try rows(result).rows.first?.values == [.primitive(.string("old")), .primitive(.string("moved")), q(8)], "update-old-new-source")
        try require(try await read(context, 0, "old", ["a"]).isEmpty, "old-physical-key-absent")
        try require(try await read(context, 0, "moved", ["a", "b"]) == [[q(4), q(3)]], "tuple-old-snapshot-relocation")
        try await clear(context)
    }

    private static func deleteUsing(_ context: DatabaseContext, _ container: DBContainer) async throws {
        try await publish(container, "delete-using")
        _ = try await run(context, [.statement(insert(0, "target", 1, 2)),
            .statement(insert(1, "source-a", 1, 7)), .statement(insert(1, "source-b", 1, 8))])
        let result = try await run(context, [.statement(.delete(DeleteQuery(target: ref(0, "t"), using: table(1, "s"),
            filter: .equal(.col("t", "a"), .col("s", "a")), returning: [.expression(.col("t", "id")), .expression(.col("old", "a"))])))])
        try require(try rows(result).affectedRows == 1 && rows(result).rows.count == 1, "using-deduplicates-target")
        try require(try await read(context, 0, "target", ["a"]).isEmpty, "using-deleted-readback")
        try await clear(context)
    }

    private static func returning(_ context: DatabaseContext, _ container: DBContainer) async throws {
        try await publish(container, "returning")
        _ = try await run(context, [.statement(insert(0, "row", 1, 2))])
        let duplicate = [ProjectionItem.column("a", as: "same"), .column("a", as: "same")]
        let empty = try await run(context, [.statement(.update(UpdateQuery(target: TableRef(names[0]),
            assignments: [Assignment(column: "a", value: .col("a"))], filter: .bool(false), returning: duplicate)))])
        let response = try rows(empty)
        try require(response.rows.isEmpty && response.affectedRows == 0 && response.columns.map { $0.name } == ["same", "same"], "zero-returning-ordered-metadata")
        let update = try await run(context, [.statement(.update(UpdateQuery(target: TableRef(names[0]),
            assignments: [Assignment(column: "a", value: .col("a"))], returning: duplicate)))])
        try require(try rows(update).affectedRows == 1 && rows(update).rows.first?.values == [q(1), q(1)], "noop-update-count-duplicates")
        let limitedOptions = try SQLBlockExecutionOptions(checkpointLimits: SQLCheckpointVerification.limits(),
            budget: ExecutionBudget(maximumRows: 0))
        do {
            _ = try await SQLBlockExecutor(context: context).execute(SQLBlock(steps: [.statement(.update(UpdateQuery(
                target: TableRef(names[0]), assignments: [Assignment(column: "a", value: .int(99))], returning: [.column("a")])))]), options: limitedOptions)
            throw Failure.assertion("s14-returning-budget-must-fail")
        } catch is DatabaseWorkLimitError {}
        try require(try await read(context, 0, "row", ["a"]) == [[q(1)]], "returning-budget-atomic-rollback")
        try await clear(context)
    }

    private static func conflict(_ context: DatabaseContext, _ container: DBContainer) async throws {
        let unique = try constraint("s14_unique", .unique(columnIDs: ["field:2"], nulls: .distinct))
        try await publish(container, "conflict", replacements: [relation(0, constraints: [unique])])
        _ = try await run(context, [.statement(insert(0, "original", 1, 2))])
        func upsert(_ id: String, _ value: Int64, _ filter: Expression?) -> QueryStatement {
            .insert(InsertQuery(target: TableRef(names[0]), columns: ["id", "a", "b"],
                source: .values([[.string(id), .int(1), .int(value)]]),
                onConflict: .doUpdate(assignments: [Assignment(column: "b", value: .col("excluded", "b"))], where: filter),
                returning: [.column("b")], conflictTarget: .constraint("s14_unique")))
        }
        let updated = try await run(context, [.statement(upsert("ignored", 8, nil))])
        try require(try rows(updated).affectedRows == 1 && rows(updated).rows.first?.values == [q(8)], "logical-arbiter-excluded")
        let skipped = try await run(context, [.statement(upsert("ignored-too", 9, .bool(false)))])
        try require(try rows(skipped).affectedRows == 0 && rows(skipped).rows.isEmpty, "conflict-filter-count-zero")
        let duplicate = QueryStatement.insert(InsertQuery(target: TableRef(names[0]), columns: ["id", "a", "b"],
            source: .values([[.string("dup-a"), .int(1), .int(10)], [.string("dup-b"), .int(1), .int(11)]]),
            onConflict: .doUpdate(assignments: [Assignment(column: "b", value: .col("excluded", "b"))], where: nil),
            conflictTarget: .columns(["a"], where: nil)))
        try await mustFail(context, [.statement(duplicate)], "repeated-conflict-target")
        try require(try await read(context, 0, "original", ["b"]) == [[q(8)]], "duplicate-conflict-rollback")
        try await clear(context)
    }

    private static func writableCTE(_ context: DatabaseContext, _ container: DBContainer) async throws {
        try await publish(container, "writable-cte")
        _ = try await run(context, [.statement(insert(0, "row", 1, 2))])
        let change = QueryStatement.update(UpdateQuery(target: TableRef(names[0]),
            assignments: [Assignment(column: "a", value: .int(9))], returning: [.column("id"), .column("a"), .column("b")]))
        let pair = DataSource.join(JoinClause(type: .cross, left: table(0, "base"), right: .aliased(.table(TableRef("changed")), name: "delta")))
        let view = SelectQuery(projection: [.expression(.col("base", "a")), .expression(.col("delta", "a"))], source: pair)
        let snapshot = try await run(context, [.statement(.with(SQLWithStatement(statements: [SQLNamedStatement(name: "changed", statement: change)], body: .select(view))))])
        try require(try rows(snapshot).rows.first?.values == [q(1), q(9)], "base-old-returned-new")
        let increment = QueryStatement.update(UpdateQuery(target: TableRef(names[0]),
            assignments: [Assignment(column: "a", value: .add(.col("a"), .int(1)))], returning: [.column("a")]))
        let repeatedSource = DataSource.join(JoinClause(type: .cross,
            left: .aliased(.table(TableRef("once")), name: "left_result"),
            right: .aliased(.table(TableRef("once")), name: "right_result")))
        let repeated = try await run(context, [.statement(.with(SQLWithStatement(statements: [SQLNamedStatement(name: "once", statement: increment)],
            body: .select(SelectQuery(projection: [.expression(.col("left_result", "a")), .expression(.col("right_result", "a"))], source: repeatedSource)))) )])
        try require(try rows(repeated).rows.first?.values == [q(10), q(10)], "multiply-referenced-writer-once")
        let unused = QueryStatement.with(SQLWithStatement(statements: [SQLNamedStatement(name: "unused", statement:
            .update(UpdateQuery(target: TableRef(names[0]), assignments: [Assignment(column: "a", value: .int(11))], returning: [.column("a")])) )],
            body: .select(SelectQuery(projection: [.expression(.int(1))], source: .values([[]]), pagination: QueryPagination(limit: .count(.fixed(0), withTies: false))))))
        let zero = try await run(context, [.statement(unused)])
        let unusedReadback = try await read(context, 0, "row", ["a"])
        try require(try rows(zero).rows.isEmpty && unusedReadback == [[q(11)]], "unused-writer-completes-under-limit-zero")
        let removal = QueryStatement.delete(DeleteQuery(target: TableRef(names[0]), returning: [.column("id"), .column("a"), .column("b")]))
        let movement = QueryStatement.with(SQLWithStatement(statements: [SQLNamedStatement(name: "moved", statement: removal)],
            body: .insert(InsertQuery(target: TableRef(names[2]), columns: ["id", "a", "b"], source: .select(SelectQuery(
                projection: [.column("id"), .column("a"), .column("b")], source: .table(TableRef("moved"))))))))
        _ = try await run(context, [.savepoint("before-move"), .statement(movement), .rollbackTo("before-move")])
        try await requireMoveState(context, archived: false, "movement-savepoint-atomic")
        try await mustFail(context, [.statement(movement), .rollbackTo("missing")], "movement-later-failure")
        try await requireMoveState(context, archived: false, "movement-failure-atomic")
        let done = try await run(context, [.statement(movement)])
        try command(done, .insert, 1)
        try await requireMoveState(context, archived: true, "movement-final-readback")
        try await clear(context)
    }

    private static func merge(_ context: DatabaseContext, _ container: DBContainer) async throws {
        try await publish(container, "merge")
        _ = try await run(context, [.statement(insert(0, "update", 1, 1)), .statement(insert(0, "delete", 2, 2)),
            .statement(insert(0, "absent", 3, 3)), .statement(insert(1, "update", 1, 9)),
            .statement(insert(1, "delete", 2, 8)), .statement(insert(1, "insert", 4, 7))])
        let query = MergeQuery(target: ref(0, "t"), source: table(1, "s"), condition: .equal(.col("t", "id"), .col("s", "id")), clauses: [
            SQLMergeClause(match: .matched, condition: .equal(.col("t", "a"), .int(2)), action: .delete),
            SQLMergeClause(match: .matched, action: .update([Assignment(column: "b", value: .col("s", "b"))])),
            SQLMergeClause(match: .notMatchedByTarget, action: .insert(columns: ["id", "a", "b"], values: [.col("s", "id"), .col("s", "a"), .col("s", "b")], overriding: nil)),
            SQLMergeClause(match: .notMatchedBySource, action: .doNothing)
        ], returning: [.expression(call("merge_action", []), alias: "action")])
        let result = try await run(context, [.statement(.merge(query))])
        try require(try rows(result).affectedRows == 3 && rows(result).rows.count == 3, "merge-direct-count")
        let actions = try rows(result).rows.map { $0.values }
        for action in ["INSERT", "UPDATE", "DELETE"] {
            try require(actions.contains([.primitive(.string(action))]), "merge-action-" + action)
        }
        let updated = try await read(context, 0, "update", ["b"])
        let deleted = try await read(context, 0, "delete", ["b"])
        try require(updated == [[q(9)]] && deleted.isEmpty, "merge-action-readback")
        let repeated = MergeQuery(target: ref(0, "t"), source: table(1, "s"), condition: .bool(true), clauses: [
            SQLMergeClause(match: .matched, action: .update([Assignment(column: "b", value: .int(99))]))])
        try await mustFail(context, [.statement(.merge(repeated))], "merge-target-cardinality")
        try require(try await read(context, 0, "update", ["b"]) == [[q(9)]], "merge-cardinality-rollback")
        try await clear(context)
    }

    private static func truncate(_ context: DatabaseContext, _ container: DBContainer) async throws {
        let sequence = try SQLSequence(id: "s14_identity", namespaceID: "public", name: "s14_identity", start: 100,
            increment: 1, minimum: 1, maximum: 1000, ownedBy: SQLSequenceOwner(relationID: relationID(0), columnID: "field:2"))
        _ = try await run(context, [.sequence(.create(sequence))])
        let columns = try [SQLColumn(id: "field:1", name: "id", fieldNumber: 1),
            SQLColumn(id: "field:2", name: "a", backing: .field(number: 2), policy: .identity(SQLIdentityColumn(sequenceID: sequence.id, generation: .byDefault))),
            SQLColumn(id: "field:3", name: "b", fieldNumber: 3), SQLColumn(id: "field:4", name: "g", fieldNumber: 4)]
        let foreign = try constraint("s14_foreign", .foreignKey(SQLForeignKey(columnIDs: ["field:2"], referencedRelationID: relationID(0))))
        try await publish(container, "truncate", replacements: [relation(0, primary: ["field:2"], columns: columns), relation(2, constraints: [foreign])])
        let auto = QueryStatement.insert(InsertQuery(target: TableRef(names[0]), columns: ["id"], source: .values([[.string("parent")]])))
        _ = try await run(context, [.statement(auto), .statement(insert(2, "child", 100, 0))])
        try await mustFail(context, [.statement(.truncate(TruncateQuery(tables: [TableRef(names[0])])) )], "truncate-restrict")
        try require(try await read(context, 0, "parent", ["a"]) == [[q(100)]], "truncate-restrict-unchanged")
        let clear = QueryStatement.truncate(TruncateQuery(tables: [TableRef(names[0])], identity: .restart, references: .cascade))
        _ = try await run(context, [.savepoint("before-truncate"), .statement(clear), .rollbackTo("before-truncate")])
        let parentBefore = try await read(context, 0, "parent", ["a"])
        let childBefore = try await read(context, 2, "child", ["a"])
        try require(parentBefore == [[q(100)]] && childBefore == [[q(100)]], "truncate-closure-rollback")
        let afterRollback = QueryStatement.insert(InsertQuery(target: TableRef(names[0]), columns: ["id"], source: .values([[.string("after-rollback")]])))
        _ = try await run(context, [.statement(afterRollback)])
        try require(try await read(context, 0, "after-rollback", ["a"]) == [[q(101)]], "truncate-restart-head-rollback")
        _ = try await run(context, [.statement(clear), .statement(auto)])
        let parentAfter = try await read(context, 0, "parent", ["a"])
        let childAfter = try await read(context, 2, "child", ["a"])
        try require(parentAfter == [[q(100)]] && childAfter.isEmpty, "truncate-cascade-restart")
        try await self.clear(context)
    }

    private static func requireMoveState(_ context: DatabaseContext, archived: Bool, _ name: String) async throws {
        let source = try await read(context, 0, "row", ["a"])
        let destination = try await read(context, 2, "row", ["a"])
        try require(archived ? source.isEmpty && destination == [[q(11)]] : source == [[q(11)]] && destination.isEmpty, name)
    }

    private static func relationID(_ index: Int) -> String { "entity:" + entities[index] }
    private static func relation(_ index: Int, primary: [String]? = ["field:1"], columns: [SQLColumn]? = nil,
        constraints: [SQLConstraint] = []) throws -> SQLRelation {
        let fields = try columns ?? [SQLColumn(id: "field:1", name: "id", fieldNumber: 1), SQLColumn(id: "field:2", name: "a", fieldNumber: 2),
            SQLColumn(id: "field:3", name: "b", fieldNumber: 3), SQLColumn(id: "field:4", name: "g", fieldNumber: 4)]
        return try SQLRelation(id: relationID(index), namespaceID: "public", name: names[index], entityName: entities[index],
            columns: fields, primaryKeyColumnIDs: primary, constraints: constraints)
    }
    private static func constraint(_ name: String, _ kind: SQLConstraintKind) throws -> SQLConstraint {
        try SQLConstraint(attributes: SQLConstraintAttributes(id: name, name: name), kind: kind)
    }
    private static func publish(_ container: DBContainer, _ key: String, replacements: [SQLRelation] = []) async throws {
        let source = container.sqlCatalog
        let defaults = try (0..<3).map { index in try replacements.first(where: { $0.id == relationID(index) }) ?? relation(index) }
        let catalog = try SQLCatalog(namespaces: source.namespaces, relations: source.relations.map { old in
            defaults.first(where: { $0.id == old.id }) ?? old
        }, sequences: source.sequences)
        _ = try await container.publishSQLCatalog(catalog, expectedGeneration: container.schemaGeneration,
            idempotencyKey: "s14-portable-" + key, authorization: SQLCatalogVerification.authorization)
    }
    private static func ref(_ index: Int, _ alias: String) -> TableRef { TableRef(table: names[index], alias: alias) }
    private static func table(_ index: Int, _ alias: String? = nil) -> DataSource {
        let source = DataSource.table(TableRef(names[index]))
        return alias.map { .aliased(source, name: $0) } ?? source
    }
    private static func insert(_ table: Int, _ id: String, _ a: Int64, _ b: Int64) -> QueryStatement {
        .insert(InsertQuery(target: TableRef(names[table]), columns: ["id", "a", "b"], source: .values([[.string(id), .int(a), .int(b)]])))
    }
    private static func call(_ name: String, _ args: [Expression]) -> Expression { .function(FunctionCall(name: name, arguments: args)) }
    private static func q(_ value: Int64) -> QueryValue { .primitive(.int64(value)) }
    private static func clear(_ context: DatabaseContext) async throws {
        _ = try await run(context, [2, 1, 0].map { .statement(.delete(DeleteQuery(target: TableRef(names[$0])))) })
    }
    private static func run(_ context: DatabaseContext, _ steps: [SQLBlockStep]) async throws -> SQLBlockResult {
        try await SQLBlockExecutor(context: context).execute(SQLBlock(steps: steps), options:
            SQLBlockExecutionOptions(checkpointLimits: SQLCheckpointVerification.limits()))
    }
    private static func rows(_ result: SQLBlockResult) throws -> QueryResponse {
        guard case .rows(let response) = result.results[0] else { throw Failure.assertion("s14-rows-discriminant") }
        return response
    }
    private static func command(_ result: SQLBlockResult, _ kind: SQLCommandKind, _ count: UInt64) throws {
        guard case .command(let actualKind, let actualCount) = result.results[0] else { throw Failure.assertion("s14-command-discriminant") }
        try require(actualKind == kind && actualCount == count, "command-kind-count")
    }
    private static func read(_ context: DatabaseContext, _ table: Int, _ id: String, _ columns: [String]) async throws -> [[QueryValue]] {
        let result = try await run(context, [.statement(.select(SelectQuery(projection: columns.map { .column($0) }, source: self.table(table),
            filter: .equal(.col("id"), .string(id)))))])
        return try rows(result).rows.map { $0.values }
    }
    private static func mustFail(_ context: DatabaseContext, _ steps: [SQLBlockStep], _ name: String) async throws {
        do { _ = try await run(context, steps) }
        catch { return }
        throw Failure.assertion("s14-" + name + "-must-fail")
    }
    private static func require(_ condition: Bool, _ name: String) throws { try ParameterBindingVerification.require(condition, "s14-" + name) }
}
