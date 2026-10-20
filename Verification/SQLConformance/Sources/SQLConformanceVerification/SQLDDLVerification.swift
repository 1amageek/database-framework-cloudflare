@_spi(DatabaseExecution) @testable import DatabaseEngine
import DatabaseKit
import DatabaseTypes
import DatabaseWire

/// Runs typed DDL through the authoritatively closed block on the real SQLite host.
enum SQLDDLVerification {
    typealias Failure = ParameterBindingVerification.Failure
    static let markers = ["S15D01", "S15D02", "S15D03", "S15D04", "S15D09", "S15D10", "S15D11", "S15SEQ"]
    static let groups = 9

    static func verify(in context: DatabaseContext, container: DBContainer) async throws {
        try verifyCarriage()
        for index in markers.indices {
            let marker = markers[index]
            print("ENGINE_S15_CASE " + marker + " BEGIN")
            do {
                switch index {
                case 0: try await schemas(context, container)
                case 1: try await tables(context, container)
                case 2: try await alterations(context, container)
                case 3: try await rollbackAndTemporary(context, container)
                case 4: try await indexes(context, container)
                case 5: try await views(context, container)
                case 6: try await materialized(context, container)
                case 7: try await sequences(context, container)
                default: throw Failure.assertion("s15-invalid-group")
                }
            } catch { throw SQLTextPatternVerification.DiagnosticFailure(phase: marker, cause: error) }
            print("ENGINE_S15_CASE " + marker + " PASS")
        }
        print("ENGINE_S15_PASS cases=8")
    }

    private static func schemas(_ context: DatabaseContext, _ container: DBContainer) async throws {
        let before = container.schemaGeneration
        try command(try await run(context, [ddl(.createSchema(name: "s15_namespace", ifNotExists: false))]), .createSchema)
        guard let namespace = container.sqlCatalog.namespaces.first(where: { $0.name == "s15_namespace" }) else {
            throw Failure.assertion("s15-created-namespace")
        }
        _ = try await run(context, [ddl(.createSchema(name: "s15_namespace", ifNotExists: true)),
            ddl(.renameSchema(name: "s15_namespace", to: "s15_namespace_renamed"))])
        try require(container.sqlCatalog.namespaces.contains { $0.id == namespace.id && $0.name == "s15_namespace_renamed" }, "schema-rename-stable-id")
        try require(container.schemaGeneration > before, "schema-authoritative-generation")
        _ = try await run(context, [ddl(.createTable(SQLCreateTable(name: TableRef(schema: "s15_namespace_renamed", table: "nested"),
            source: .columns([SQLColumnDefinition(name: "a", type: .bigint)], constraints: []))))])
        try await expectDDL(context, [ddl(.dropSchema(names: ["s15_namespace_renamed"], ifExists: false, behavior: .restrict))],
            .dependentObject("s15_namespace_renamed"))
        _ = try await run(context, [ddl(.dropSchema(names: ["s15_namespace_renamed"], ifExists: false, behavior: .cascade)),
            ddl(.dropSchema(names: ["s15_namespace_renamed"], ifExists: true, behavior: .restrict))])
        try require(!container.sqlCatalog.namespaces.contains { $0.id == namespace.id }, "schema-cascade-removed")
    }

    private static func tables(_ context: DatabaseContext, _ container: DBContainer) async throws {
        let definition = SQLCreateTable(name: TableRef("s15_table"), source: .columns([
            SQLColumnDefinition(name: "a", type: .bigint, policy: .input(defaultExpression: .int(4))),
            SQLColumnDefinition(name: "g", type: .bigint, policy: .generated(.add(.col("a"), .int(1)), stored: true)),
        ], constraints: [SQLTableConstraint(name: "s15_positive", kind: .check(.greaterThan(.col("a"), .int(0))))]))
        print("ENGINE_S15_STEP S15D02 create-table BEGIN")
        try command(try await run(context, [ddl(.createTable(definition))]), .createTable)
        print("ENGINE_S15_STEP S15D02 create-table PASS")
        let first = try relation(container, "s15_table")
        print("ENGINE_S15_STEP S15D02 default-insert BEGIN")
        _ = try await run(context, [ddl(.createTable(SQLCreateTable(name: TableRef("s15_table"), source: .columns([], constraints: []), ifNotExists: true))),
            .statement(.insert(InsertQuery(target: TableRef("s15_table"), source: .defaultValues)))])
        print("ENGINE_S15_STEP S15D02 default-insert PASS")
        print("ENGINE_S15_STEP S15D02 default-read BEGIN")
        try require(try await read(context, "s15_table", ["a", "g"]) == [[q(4), q(5)]], "table-default-stored-generated")
        try require(try relation(container, "s15_table").id == first.id, "if-not-exists-keeps-backing")
        print("ENGINE_S15_STEP S15D02 default-read PASS")
        let query = SelectQuery(projection: [.column("a"), .column("g")], source: .table(TableRef("s15_table")))
        print("ENGINE_S15_STEP S15D02 ctas BEGIN")
        _ = try await run(context, [ddl(.createTable(SQLCreateTable(name: TableRef("s15_ctas"), source: .query(query, columns: ["x", "y"], withData: true)))),
            ddl(.createTable(SQLCreateTable(name: TableRef("s15_ctas_empty"), source: .query(query, columns: ["x", "y"], withData: false))))])
        print("ENGINE_S15_STEP S15D02 ctas PASS")
        print("ENGINE_S15_STEP S15D02 ctas-read BEGIN")
        try require(try await read(context, "s15_ctas", ["x", "y"]) == [[q(4), q(5)]], "ctas-with-data")
        try require(try await read(context, "s15_ctas_empty", ["x", "y"]).isEmpty, "ctas-no-data")
        print("ENGINE_S15_STEP S15D02 ctas-read PASS")
        print("ENGINE_S15_STEP S15D02 drop BEGIN")
        _ = try await run(context, [ddl(.dropTable(names: [TableRef("s15_ctas_empty")], ifExists: false, behavior: .restrict))])
        try require(!container.sqlCatalog.relations.contains { $0.name == "s15_ctas_empty" }, "drop-table-authoritative")
        print("ENGINE_S15_STEP S15D02 drop PASS")
        let unknowns = SelectQuery(projection: [.expression(.null, alias: "n"),
            .expression(.literal(.sqlUnknownString("text literal")), alias: "t")], source: .values([[]]))
        print("ENGINE_S15_STEP S15D02 unknown-literals BEGIN")
        _ = try await run(context, [ddl(.createTable(SQLCreateTable(name: TableRef("s15_unknown_ctas"),
            source: .query(unknowns, columns: nil, withData: true))))])
        print("ENGINE_S15_STEP S15D02 unknown-literals PASS")
        print("ENGINE_S15_STEP S15D02 unknown-read BEGIN")
        let unknownResult = try await run(context, [.statement(.select(SelectQuery(projection: [.wildcard()],
            source: .table(TableRef("s15_unknown_ctas")))))])
        let unknownRows = try rows(unknownResult)
        try require(unknownRows.columns.map { $0.type } == [.sql(.text), .sql(.text)]
            && unknownRows.rows.map { $0.values } == [[.primitive(.null), .primitive(.string("text literal"))]], "ctas-unknown-literals-default-text")
        print("ENGINE_S15_STEP S15D02 unknown-read PASS")
    }

    private static func alterations(_ context: DatabaseContext, _ container: DBContainer) async throws {
        let before = try relation(container, "s15_ctas")
        guard let column = before.columns.first(where: { $0.name == "x" }) else { throw Failure.assertion("s15-alter-column") }
        _ = try await run(context, [ddl(.alterTable(SQLAlterTable(name: TableRef("s15_ctas"), actions: [
            .alterColumnType(name: "x", type: .text, using: .cast(.add(.col("x"), .int(10)), targetType: .text)),
            .renameColumn(name: "x", to: "renamed"), .renameTable(to: "s15_altered"),
        ])))])
        let renamed = try relation(container, "s15_altered")
        try require(renamed.id == before.id && renamed.entityName == before.entityName, "alter-table-stable-identity")
        let stable = renamed.columns.first { $0.name == "renamed" }
        try require(stable?.id == column.id && stable?.fieldNumber == column.fieldNumber, "alter-column-stable-field")
        try require(try await read(context, "s15_altered", ["renamed", "y"]) == [[.primitive(.string("14")), q(5)]], "alter-using-real-rewrite")
        let high = renamed.fieldNumberHighWaterMark
        _ = try await run(context, [ddl(.alterTable(SQLAlterTable(name: TableRef("s15_altered"), actions: [
            .dropColumn(name: "y", ifExists: false, behavior: .restrict),
            .addColumn(SQLColumnDefinition(name: "z", type: .bigint, policy: .input(defaultExpression: .int(9))), ifNotExists: false),
            .setNotNull(column: "z"), .dropNotNull(column: "z"),
            .setDefault(column: "z", expression: .int(11)), .dropDefault(column: "z"),
            .addConstraint(SQLTableConstraint(name: "s15_z_positive", kind: .check(.greaterThan(.col("z"), .int(0))))),
            .dropConstraint(name: "s15_z_positive", ifExists: false, behavior: .restrict),
        ])))])
        let after = try relation(container, "s15_altered")
        try require(after.fieldNumberHighWaterMark > high && after.columns.first(where: { $0.name == "z" })?.fieldNumber == high + 1, "field-number-never-reused")
        try require(try await read(context, "s15_altered", ["renamed", "z"]) == [[.primitive(.string("14")), q(9)]], "add-column-existing-row-backfill")
        _ = try await run(context, [ddl(.createTable(SQLCreateTable(name: TableRef("s15_added_generation"), source: .columns([
            SQLColumnDefinition(name: "a", type: .bigint),
        ], constraints: [])))), insert("s15_added_generation", ["a"], [[.int(7)], [.int(8)]]),
            ddl(.alterTable(SQLAlterTable(name: TableRef("s15_added_generation"), actions: [
                .addColumn(SQLColumnDefinition(name: "serial_value", type: .integer, policy: .serial), ifNotExists: false),
                .addColumn(SQLColumnDefinition(name: "identity_value", type: .integer,
                    policy: .identity(generation: .always, options: SQLSequenceOptions(start: 20))), ifNotExists: false),
            ])))])
        try require(try await read(context, "s15_added_generation", ["a"]) == [[q(7)], [q(8)]], "add-generated-preserves-existing-input")
        try require(try await read(context, "s15_added_generation", ["serial_value"]) == [[.primitive(.int32(1))], [.primitive(.int32(2))]], "add-serial-existing-row-backfill")
        try require(try await read(context, "s15_added_generation", ["identity_value"]) == [[.primitive(.int32(20))], [.primitive(.int32(21))]], "add-identity-existing-row-backfill")
        _ = try await run(context, [insert("s15_added_generation", ["a"], [[.int(9)]])])
        try require(try await read(context, "s15_added_generation", ["serial_value"]) == [[.primitive(.int32(1))], [.primitive(.int32(2))], [.primitive(.int32(3))]], "add-serial-next-insert-consumption")
        try require(try await read(context, "s15_added_generation", ["identity_value"]) == [[.primitive(.int32(20))], [.primitive(.int32(21))], [.primitive(.int32(22))]], "add-identity-next-insert-consumption")
    }

    private static func rollbackAndTemporary(_ context: DatabaseContext, _ container: DBContainer) async throws {
        let generation = container.schemaGeneration
        let original = try relation(container, "s15_table")
        let valid = ddl(.alterTable(SQLAlterTable(name: TableRef("s15_table"), actions: [.renameTable(to: "s15_rolled_back")])))
        try await expectDDL(context, [valid, ddl(.dropTable(names: [TableRef("s15_missing")], ifExists: false, behavior: .restrict))],
            .missingObject("s15_missing"))
        try require(container.schemaGeneration == generation && relation(container, "s15_table").id == original.id, "failed-block-no-publication")
        _ = try await run(context, [.savepoint("before-ddl"), valid, .rollbackTo("before-ddl")])
        try require(try relation(container, "s15_table").id == original.id, "savepoint-restores-catalog")
        let beforeUsing = try relation(container, "s15_altered")
        let beforeUsingGeneration = container.schemaGeneration
        do {
            _ = try await run(context, [ddl(.alterTable(SQLAlterTable(name: TableRef("s15_altered"), actions: [
                .alterColumnType(name: "z", type: .text, using: .divide(.col("z"), .subtract(.col("z"), .col("z")))),
            ])))])
            throw Failure.assertion("s15-alter-using-division-must-fail")
        } catch CanonicalReadError.expressionEvaluation(.divisionByZero, _) {}
        try require(container.schemaGeneration == beforeUsingGeneration && relation(container, "s15_altered") == beforeUsing,
            "failed-alter-using-schema-rollback")
        try require(try await read(context, "s15_altered", ["renamed", "z"]) == [[.primitive(.string("14")), q(9)]],
            "failed-alter-using-rows-rollback")
        let temporary = SQLCreateTable(name: TableRef("s15_temporary"), source: .columns([
            SQLColumnDefinition(name: "a", type: .bigint),
        ], constraints: []), temporary: true)
        let result = try await run(context, [ddl(.createTable(temporary)), insert("s15_temporary", ["a"], [[.int(12)]]),
            .statement(.select(SelectQuery(projection: [.column("a")], source: .table(TableRef("s15_temporary")))))])
        try require(try rows(result).rows.map { $0.values } == [[q(12)]], "temporary-readable-inside-block")
        try require(!container.sqlCatalog.relations.contains { $0.name == "s15_temporary" }
            && !container.sqlCatalog.namespaces.contains { $0.name.hasPrefix("sql_temp_") }, "temporary-cleanup-before-publication")
        guard let protected = container.sqlCatalog.relations.first(where: { $0.entityName == "RuntimeVerificationDocument" }),
              let namespace = container.sqlCatalog.namespaces.first(where: { $0.id == protected.namespaceID }),
              let selected = protected.columns.first else { throw Failure.assertion("s15-protected-fixture") }
        let protectedGeneration = container.schemaGeneration
        do {
            _ = try await run(context, [ddl(.alterTable(SQLAlterTable(name: TableRef(schema: namespace.name, table: protected.name), actions: [
                .dropColumn(name: selected.name, ifExists: false, behavior: .cascade),
            ])))])
        } catch is SQLCatalogBindingError {
            try require(container.schemaGeneration == protectedGeneration
                && container.sqlCatalog.relations.first(where: { $0.id == protected.id }) == protected, "static-protection-no-publication")
            return
        }
        throw Failure.assertion("s15-static-protection-must-fail")
    }

    private static func indexes(_ context: DatabaseContext, _ container: DBContainer) async throws {
        _ = try await run(context, [ddl(.createTable(SQLCreateTable(name: TableRef("s15_indexed"), source: .columns([
            SQLColumnDefinition(name: "a", type: .bigint), SQLColumnDefinition(name: "b", type: .bigint),
        ], constraints: [])))), insert("s15_indexed", ["a", "b"], [[.int(1), .int(1)], [.int(2), .int(0)]])])
        _ = try await run(context, [ddl(.createIndex(SQLCreateIndex(name: TableRef("s15_unique"), table: TableRef("s15_indexed"),
            keys: [SortKey(.col("a"))], unique: true)))])
        try await expectConstraint(context, [insert("s15_indexed", ["a", "b"], [[.int(1), .int(9)]])], "s15_unique")
        let unchanged = container.schemaGeneration
        try await expectConstraint(context, [ddl(.createIndex(SQLCreateIndex(name: TableRef("s15_bad_backfill"), table: TableRef("s15_indexed"),
            keys: [SortKey(.int(1))], unique: true)))], "s15_bad_backfill")
        try require(container.schemaGeneration == unchanged && !container.sqlCatalog.indexes.contains { $0.name == "s15_bad_backfill" }, "failed-index-backfill-atomic")
        _ = try await run(context, [ddl(.dropIndex(names: [TableRef("s15_unique")], ifExists: false, behavior: .restrict)),
            ddl(.createIndex(SQLCreateIndex(name: TableRef("s15_partial"), table: TableRef("s15_indexed"), keys: [SortKey(.col("a"))],
                predicate: .greaterThan(.col("b"), .int(0)), unique: true))),
            insert("s15_indexed", ["a", "b"], [[.int(1), .int(0)]])])
        func parameterizedRows(_ floor: Int64) async throws -> [[QueryValue]] {
            let query = SelectQuery(projection: [.column("a"), .column("b")], source: .table(TableRef("s15_indexed")),
                filter: .greaterThan(.col("b"), .parameter(name: "floor")), orderBy: [SortKey(.col("a")), SortKey(.col("b"))])
            let result = try await SQLBlockExecutor(context: context).execute(SQLBlock(steps: [.statement(.select(query))]),
                parameters: [QueryParameter(position: 1, name: "floor", value: q(floor))],
                options: SQLBlockExecutionOptions(checkpointLimits: SQLCheckpointVerification.limits()))
            return try rows(result).rows.map { $0.values }
        }
        try require(try await parameterizedRows(-1) == [[q(1), q(0)], [q(1), q(1)], [q(2), q(0)]],
            "partial-index-raw-parameter-keeps-outside-rows")
        _ = try await run(context, [ddl(.createIndex(SQLCreateIndex(name: TableRef("s15_parameter_full_b"), table: TableRef("s15_indexed"),
            keys: [SortKey(.col("b"))])))])
        try require(try await parameterizedRows(0) == [[q(1), q(1)]], "full-index-raw-parameter-filter")
        _ = try await run(context, [ddl(.dropIndex(names: [TableRef("s15_parameter_full_b")], ifExists: false, behavior: .restrict))])
        let upsert = QueryStatement.insert(InsertQuery(target: TableRef("s15_indexed"), columns: ["a", "b"], source: .values([[.int(1), .int(7)]]),
            onConflict: .doUpdate(assignments: [Assignment(column: "b", value: .col("excluded", "b"))], where: nil),
            returning: [.column("a"), .column("b")], conflictTarget: .columns(["a"], where: .greaterThan(.col("b"), .int(0)))))
        let updated = try await run(context, [.statement(upsert)])
        try require(try rows(updated).rows.map { $0.values } == [[q(1), q(7)]] && rows(updated).affectedRows == 1, "partial-index-conflict-inference")
        _ = try await run(context, [ddl(.createIndex(SQLCreateIndex(name: TableRef("s15_expression"), table: TableRef("s15_indexed"),
            keys: [SortKey(.add(.col("a"), .col("b")))], unique: true)))])
        try await expectConstraint(context, [insert("s15_indexed", ["a", "b"], [[.int(0), .int(8)]])], "s15_expression")
        let nothing = try await run(context, [.statement(.insert(InsertQuery(target: TableRef("s15_indexed"), columns: ["a", "b"],
            source: .values([[.int(0), .int(8)]]), onConflict: .doNothing)))])
        try require(try commandCount(nothing) == 0, "expression-index-untargeted-do-nothing")
        _ = try await run(context, [ddl(.createTable(SQLCreateTable(name: TableRef("s15_rich_indexed"), source: .columns([
            SQLColumnDefinition(name: "a", type: .bigint), SQLColumnDefinition(name: "b", type: .bigint),
        ], constraints: [])))), insert("s15_rich_indexed", ["a", "b"], [[.int(1), .int(2)], [.int(1), .int(2)]])])
        let richGeneration = container.schemaGeneration
        try await expectConstraint(context, [ddl(.createIndex(SQLCreateIndex(name: TableRef("s15_rich_unique"), table: TableRef("s15_rich_indexed"),
            keys: [SortKey(.row([.col("a"), .col("b")]))], unique: true)))], "s15_rich_unique")
        try require(container.schemaGeneration == richGeneration && !container.sqlCatalog.indexes.contains { $0.name == "s15_rich_unique" },
            "row-key-semantic-unique-backfill-atomic")
        try require(try await read(context, "s15_rich_indexed", ["a", "b"]) == [[q(1), q(2)], [q(1), q(2)]],
            "row-key-failed-backfill-preserves-rows")
    }

    private static func views(_ context: DatabaseContext, _ container: DBContainer) async throws {
        _ = try await run(context, [ddl(.createTable(SQLCreateTable(name: TableRef("s15_view_source"), source: .columns([
            SQLColumnDefinition(name: "a", type: .bigint), SQLColumnDefinition(name: "b", type: .bigint),
        ], constraints: [])))), insert("s15_view_source", ["a", "b"], [[.int(31), .int(41)]]),
            ddl(.createView(SQLCreateView(name: TableRef("s15_view"), columns: ["result"], query:
                SelectQuery(projection: [.column("a")], source: .table(TableRef("s15_view_source"))))))])
        guard let before = container.sqlCatalog.views.first(where: { $0.name == "s15_view" }) else { throw Failure.assertion("s15-view-catalog") }
        _ = try await run(context, [ddl(.createIndex(SQLCreateIndex(name: TableRef("s15_view_unreferenced_index"),
            table: TableRef("s15_view_source"), keys: [SortKey(.col("b"))])))])
        try require(try await read(context, "s15_view", ["result"]) == [[q(31)]], "view-read-after-unreferenced-column-index")
        _ = try await run(context, [ddl(.alterTable(SQLAlterTable(name: TableRef("s15_view_source"), actions: [
            .renameColumn(name: "a", to: "renamed"), .renameTable(to: "s15_view_source_renamed"),
        ]))), ddl(.createTable(SQLCreateTable(name: TableRef("s15_view_source"), source: .columns([
            SQLColumnDefinition(name: "a", type: .bigint),
        ], constraints: [])))), insert("s15_view_source", ["a"], [[.int(99)]])])
        try require(try await read(context, "s15_view", ["result"]) == [[q(31)]], "view-stable-source-and-column")
        try require(container.sqlCatalog.views.first(where: { $0.id == before.id })?.definition == before.definition, "view-definition-not-rebound")
        do { _ = try await run(context, [insert("s15_view", ["result"], [[.int(1)]])]) }
        catch SQLViewExecutionError.readOnly { return }
        throw Failure.assertion("s15-view-read-only-must-fail")
    }

    private static func materialized(_ context: DatabaseContext, _ container: DBContainer) async throws {
        _ = try await run(context, [ddl(.createTable(SQLCreateTable(name: TableRef("s15_mv_source"), source: .columns([
            SQLColumnDefinition(name: "a", type: .bigint), SQLColumnDefinition(name: "b", type: .bigint),
        ], constraints: [])))), insert("s15_mv_source", ["a", "b"], [[.int(3), .int(9)], [.int(3), .int(10)]]),
            ddl(.createMaterializedView(SQLCreateMaterializedView(name: TableRef("s15_mv"), query:
                SelectQuery(projection: [.column("a")], source: .table(TableRef("s15_mv_source"))), withData: false))),
            ddl(.createIndex(SQLCreateIndex(name: TableRef("s15_mv_unreferenced_index"),
                table: TableRef("s15_mv_source"), keys: [SortKey(.col("b"))])))])
        do { _ = try await read(context, "s15_mv", ["a"]) }
        catch SQLViewExecutionError.notPopulated {
            _ = try await run(context, [ddl(.refreshMaterializedView(name: TableRef("s15_mv"), withData: true))])
            try require(try await read(context, "s15_mv", ["a"]) == [[q(3)], [q(3)]], "materialized-bag-duplicates")
            _ = try await run(context, [insert("s15_mv_source", ["a"], [[.int(4)]])])
            let generation = container.schemaGeneration
            let bounded = try SQLBlockExecutionOptions(checkpointLimits: SQLCheckpointVerification.limits(), budget: ExecutionBudget(maximumRows: 0))
            do {
                _ = try await SQLBlockExecutor(context: context).execute(SQLBlock(steps: [ddl(.refreshMaterializedView(name: TableRef("s15_mv"), withData: true))]), options: bounded)
            } catch is DatabaseWorkLimitError {
                try require(container.schemaGeneration == generation, "failed-materialized-refresh-no-generation")
                try require(try await read(context, "s15_mv", ["a"]) == [[q(3)], [q(3)]], "failed-materialized-refresh-keeps-prior-bag")
                _ = try await run(context, [ddl(.refreshMaterializedView(name: TableRef("s15_mv"), withData: true))])
                try require(try await read(context, "s15_mv", ["a"]) == [[q(3)], [q(3)], [q(4)]], "materialized-refresh-new-bag")
                return
            }
            throw Failure.assertion("s15-materialized-budget-must-fail")
        }
        throw Failure.assertion("s15-materialized-no-data-read-must-fail")
    }

    private static func sequences(_ context: DatabaseContext, _ container: DBContainer) async throws {
        _ = try await run(context, [ddl(.createSequence(SQLCreateSequence(name: TableRef("s15_sequence"), options: SQLSequenceOptions(start: 40)))),
            ddl(.createTable(SQLCreateTable(name: TableRef("s15_sequence_table"), source: .columns([
                SQLColumnDefinition(name: "a", type: .bigint, policy: .input(defaultExpression:
                    .function(FunctionCall(name: "nextval", arguments: [.string("s15_sequence")])))),
            ], constraints: [])))), .statement(.insert(InsertQuery(target: TableRef("s15_sequence_table"), source: .defaultValues)))])
        guard let before = container.sqlCatalog.sequences.first(where: { $0.name == "s15_sequence" }) else { throw Failure.assertion("s15-sequence-created") }
        _ = try await run(context, [ddl(.alterSequence(SQLAlterSequence(name: TableRef("s15_sequence"), renameTo: "s15_sequence_renamed"))),
            .statement(.insert(InsertQuery(target: TableRef("s15_sequence_table"), source: .defaultValues)))])
        try require(container.sqlCatalog.sequences.first(where: { $0.id == before.id })?.name == "s15_sequence_renamed", "sequence-rename-stable-id")
        let column = try relation(container, "s15_sequence_table").columns[0]
        try require(column.sequenceBindings.contains { $0.originalName == "s15_sequence" && $0.sequenceID == before.id }, "sequence-default-durable-binding")
        try require(try await read(context, "s15_sequence_table", ["a"]) == [[q(40)], [q(41)]], "sequence-default-after-rename")
        _ = try await run(context, [ddl(.createSequence(SQLCreateSequence(name: TableRef("s15_small_sequence"),
            options: SQLSequenceOptions(type: .smallint, maximum: .value(100))))),
            ddl(.alterSequence(SQLAlterSequence(name: TableRef("s15_small_sequence"),
                options: SQLSequenceOptions(maximum: SQLSequenceBound.none))))])
        guard let small = container.sqlCatalog.sequences.first(where: { $0.name == "s15_small_sequence" }) else {
            throw Failure.assertion("s15-small-sequence-created")
        }
        try require(small.declaredType == .smallint && small.maximum == 32_767, "alter-no-max-preserves-sequence-type")
        _ = try await run(context, [sequenceCall("setval", [.string("s15_small_sequence"), .int(32_767)])])
        try await expectExhausted(context, small.id)
        _ = try await run(context, [ddl(.createTable(SQLCreateTable(name: TableRef("s15_sequence_owner"), source: .columns([
            SQLColumnDefinition(name: "id", type: .bigint, policy: .serial), SQLColumnDefinition(name: "keep", type: .bigint),
        ], constraints: [])))), insert("s15_sequence_owner", ["keep"], [[.int(7)]]),
            ddl(.createTable(SQLCreateTable(name: TableRef("s15_sequence_consumer"), source: .columns([
                SQLColumnDefinition(name: "x", type: .bigint, policy: .input(defaultExpression:
                    .function(FunctionCall(name: "nextval", arguments: [.string("s15_sequence_owner_id_seq")])))),
            ], constraints: [])))), .statement(.insert(InsertQuery(target: TableRef("s15_sequence_consumer"), source: .defaultValues)))])
        let consumerID = try relation(container, "s15_sequence_consumer").id
        try require(try await read(context, "s15_sequence_consumer", ["x"]) == [[q(2)]], "owned-sequence-consumer-default-before-drop")
        _ = try await run(context, [ddl(.alterTable(SQLAlterTable(name: TableRef("s15_sequence_owner"), actions: [
            .dropColumn(name: "id", ifExists: false, behavior: .cascade),
        ])))])
        let consumer = try relation(container, "s15_sequence_consumer")
        try require(consumer.id == consumerID && consumer.columns[0].policy == .input(defaultExpression: nil)
            && consumer.columns[0].sequenceBindings.isEmpty, "owned-sequence-cascade-clears-consumer-default")
        try require(!container.sqlCatalog.sequences.contains { $0.name == "s15_sequence_owner_id_seq" }, "owned-sequence-cascade-removes-sequence")
        try require(try await read(context, "s15_sequence_owner", ["keep"]) == [[q(7)]], "owned-sequence-cascade-preserves-owner-data")
        _ = try await run(context, [.statement(.insert(InsertQuery(target: TableRef("s15_sequence_consumer"), source: .defaultValues)))])
        let consumerRows = try await read(context, "s15_sequence_consumer", ["x"])
        try require(consumerRows.count == 2 && consumerRows.contains([q(2)]) && consumerRows.contains([.primitive(.null)]),
            "owned-sequence-cascade-preserves-consumer-and-null-default")
    }

    static func verifyRestored(in context: DatabaseContext, container: DBContainer) async throws {
        print("ENGINE_S15_CASE S15RESTART BEGIN")
        do {
            try require(try await read(context, "s15_view", ["result"]) == [[q(31)]], "restored-view-stable-binding")
            try require(try await read(context, "s15_mv", ["a"]) == [[q(3)], [q(3)], [q(4)]], "restored-materialized-bag")
            try require(try await read(context, "s15_altered", ["renamed", "z"]) == [[.primitive(.string("14")), q(9)]], "restored-physical-rewrite")
            try await expectConstraint(context, [insert("s15_indexed", ["a", "b"], [[.int(0), .int(8)]])], "s15_expression")
            _ = try await run(context, [.statement(.insert(InsertQuery(target: TableRef("s15_sequence_table"), source: .defaultValues)))])
            try require(try await read(context, "s15_sequence_table", ["a"]) == [[q(40)], [q(41)], [q(42)]], "restored-renamed-sequence-binding")
            guard let small = container.sqlCatalog.sequences.first(where: { $0.name == "s15_small_sequence" }) else {
                throw Failure.assertion("s15-restored-small-sequence")
            }
            try require(small.declaredType == .smallint && small.maximum == 32_767, "restored-sequence-declared-type")
            try await expectExhausted(context, small.id)
            let value = try relation(container, "s15_altered")
            try require(value.columns.first(where: { $0.name == "z" })?.fieldNumber == value.fieldNumberHighWaterMark, "restored-high-water-mark")
        } catch { throw SQLTextPatternVerification.DiagnosticFailure(phase: "S15RESTART", cause: error) }
        print("ENGINE_S15_CASE S15RESTART PASS")
        print("ENGINE_S15_RESTART_PASS cases=1")
    }

    private static func verifyCarriage() throws {
        print("ENGINE_S15_KIT_CASE S15K01 BEGIN")
        let structural = QueryStructuralLimits(maximumNestingDepth: 1024)
        let wire = try DatabaseWireLimits(maximumFrameBytes: 100_000, maximumStringBytes: 1000,
            maximumByteStringBytes: 100_000, maximumCollectionCount: 1000,
            maximumNestingDepth: 1024, maximumObjectCount: 100_000)
        let statement = nestedDDL(.parameter(position: 1))
        try QueryStructuralValidator.validate(statement, limits: structural)
        let bytes = try QueryIRWireFormat.encode(statement, limits: wire)
        try require(try QueryIRWireFormat.decode(bytes, limits: wire) == statement, "deep-ddl-query-wire")
        let independent = nestedDDL(.parameter(position: 1))
        try require(statement == independent && statement.hashValue == independent.hashValue, "deep-ddl-identity")
        let binder = try QueryParameterBinder(parameters: [QueryParameter(position: 1, value: q(7))], structuralLimits: structural)
        try require(try binder.bind(statement) == nestedDDL(.int(7)), "deep-ddl-parameter-reconstruction")
        var measured = 0
        var streamed: [UInt8] = []
        try QueryIRWireFormat.emitCanonicalEncoding(statement, limits: wire,
            prepare: { measured = $0 }, consume: { streamed.append(contentsOf: $0) })
        try require(measured == bytes.count && ByteString(streamed) == bytes, "deep-ddl-streamed-owned-equality")
        do {
            _ = try QueryIRWireFormat.decode(ByteString([13, 255]))
            throw Failure.assertion("s15-ddl-unknown-tag-must-fail")
        } catch DatabaseWireError.invalidValueTag(255) {}
        var prepared = false
        var emitted = 0
        do {
            try QueryIRWireFormat.emitCanonicalEncoding(.ddl(.alterTable(SQLAlterTable(name: TableRef("t"), actions: []))),
                prepare: { _ in prepared = true }, consume: { emitted += $0.count })
            throw Failure.assertion("s15-ddl-invalid-shape-must-fail")
        } catch is DatabaseWireEmissionError<Never> {}
        try require(!prepared && emitted == 0, "deep-ddl-rejected-no-emission")
        print("ENGINE_S15_KIT_CASE S15K01 PASS")
        print("ENGINE_S15_KIT_PASS cases=1 depth=200")
    }

    private static func nestedDDL(_ value: Expression) -> QueryStatement {
        var query = SelectQuery(projection: [.expression(value, alias: "value")], source: .values([]))
        for _ in 0..<200 {
            query = SelectQuery(projection: [.expression(.subquery(query), alias: "value")], source: .values([]))
        }
        return .ddl(.createView(SQLCreateView(name: TableRef("deep_view"), query: query)))
    }

    private static func sequenceCall(_ name: String, _ arguments: [Expression]) -> SQLBlockStep {
        .statement(.select(SelectQuery(projection: [.expression(.function(FunctionCall(name: name, arguments: arguments)))],
            source: .values([[]]))))
    }
    private static func expectExhausted(_ context: DatabaseContext, _ id: String) async throws {
        do { _ = try await run(context, [sequenceCall("nextval", [.string("s15_small_sequence")])]) }
        catch SQLSequenceExecutionError.exhausted(let actual) {
            try require(actual == id, "small-sequence-typed-exhaustion")
            return
        }
        throw Failure.assertion("s15-small-sequence-overflow-must-fail")
    }

    private static func ddl(_ value: SQLDDLStatement) -> SQLBlockStep { .statement(.ddl(value)) }
    private static func insert(_ name: String, _ columns: [String], _ values: [[Expression]]) -> SQLBlockStep {
        .statement(.insert(InsertQuery(target: TableRef(name), columns: columns, source: .values(values))))
    }
    private static func run(_ context: DatabaseContext, _ steps: [SQLBlockStep]) async throws -> SQLBlockResult {
        for step in steps {
            if case .statement(let statement) = step {
                let bytes = try QueryIRWireFormat.encode(statement)
                try require(try QueryIRWireFormat.decode(bytes) == statement, "canonical-statement-carriage")
            }
        }
        return try await SQLBlockExecutor(context: context).execute(SQLBlock(steps: steps), options:
            SQLBlockExecutionOptions(checkpointLimits: SQLCheckpointVerification.limits()))
    }
    private static func read(_ context: DatabaseContext, _ name: String, _ columns: [String]) async throws -> [[QueryValue]] {
        let result = try await run(context, [.statement(.select(SelectQuery(projection: columns.map { .column($0) },
            source: .table(TableRef(name)), orderBy: columns.map { SortKey(.col($0)) })))])
        return try rows(result).rows.map { $0.values }
    }
    private static func rows(_ result: SQLBlockResult) throws -> QueryResponse {
        guard let last = result.results.last, case .rows(let response) = last else { throw Failure.assertion("s15-rows-result") }
        return response
    }
    private static func command(_ result: SQLBlockResult, _ kind: SQLCommandKind) throws {
        guard let last = result.results.last, case .command(let actual, let count) = last else { throw Failure.assertion("s15-command-result") }
        try require(actual == kind && count == nil, "ddl-command-no-row-count")
    }
    private static func commandCount(_ result: SQLBlockResult) throws -> UInt64 {
        guard let last = result.results.last, case .command(_, let count?) = last else { throw Failure.assertion("s15-command-row-count") }
        return count
    }
    private static func relation(_ container: DBContainer, _ name: String) throws -> SQLRelation {
        guard let value = container.sqlCatalog.relations.first(where: { $0.name == name }) else { throw Failure.assertion("s15-relation-" + name) }
        return value
    }
    private static func expectDDL(_ context: DatabaseContext, _ steps: [SQLBlockStep], _ expected: SQLDDLExecutionError) async throws {
        do { _ = try await run(context, steps) }
        catch let error as SQLDDLExecutionError { try require(error == expected, "typed-ddl-failure"); return }
        throw Failure.assertion("s15-ddl-must-fail")
    }
    private static func expectConstraint(_ context: DatabaseContext, _ steps: [SQLBlockStep], _ name: String) async throws {
        do { _ = try await run(context, steps) }
        catch SQLConstraintError.violation(_, _, let constraint, _, _, _) { try require(constraint == name, "typed-index-violation"); return }
        throw Failure.assertion("s15-index-must-fail")
    }
    private static func q(_ value: Int64) -> QueryValue { .primitive(.int64(value)) }
    private static func require(_ condition: Bool, _ name: String) throws { try ParameterBindingVerification.require(condition, "s15-" + name) }
}
