@_spi(DatabaseExecution) @testable import DatabaseEngine
import DatabaseKit
import DatabaseTypes
import DatabaseWire
import QueryAST
import StorageKit

/// Executes graph-free SQL operations on the reactor's real SQLite-backed container.
enum S16SQLOperationsVerification {
    typealias Failure = ParameterBindingVerification.Failure
    static let markers = ["S16O01", "S16O02", "S16O03", "S16O04", "S16O05", "S16O06", "S16O07", "S16O08"]
    static let groups = 9
    static let kitGroups = 1

    static func verify(in context: DatabaseContext, container: DBContainer) async throws {
        try carriage()
        for index in markers.indices {
            let marker = markers[index]
            print("ENGINE_S16_CASE " + marker + " BEGIN")
            do {
                switch index {
                case 0: try await transactionsAndText(context)
                case 1: try await checkpointSettings(context)
                case 2: try await preparation(context)
                case 3: try await deadlinesAndCancellation(context, container)
                case 4: try await explain(context)
                case 5: try await copy(context)
                case 6: try await metadata(context, container)
                case 7: try await diagnostics(context)
                default: throw Failure.assertion("s16-invalid-group")
                }
            } catch { throw SQLTextPatternVerification.DiagnosticFailure(phase: marker, cause: error) }
            print("ENGINE_S16_CASE " + marker + " PASS")
        }
        print("ENGINE_S16_PASS cases=8 owner=DatabaseEngine.SQLBlockExecutor parser=QueryAST.SQLParser")
    }

    private static func transactionsAndText(_ context: DatabaseContext) async throws {
        _ = try await text(context, "CREATE TABLE s16_items (id integer NOT NULL, content text, extra integer DEFAULT 17)")
        let parsed = try SQLParser().parseBlockWithSource("BEGIN; INSERT INTO s16_items (id, content) VALUES (1, 'discarded'); SELECT id FROM s16_items; ROLLBACK;")
        try require(parsed.roots.count == 4 && parsed.stepRanges.count == 4, "text-step-source-alignment")
        let result = try await run(context, parsed.block)
        try require(result.results.count == 4 && rows(result, 2).rows.map { $0.values } == [[i(1)]], "rollback-prior-observations")
        try command(result.results[3], .rollback, nil)
        try require(try await read(context, "SELECT id FROM s16_items").rows.isEmpty, "rollback-persistent-state-absent")
        _ = try await text(context, "BEGIN; INSERT INTO s16_items (id, content) VALUES (2, 'committed'); COMMIT;")
        try require(try await read(context, "SELECT id FROM s16_items").rows.map { $0.values } == [[i(2)]], "explicit-commit-persists")
        for source in ["BEGIN; SELECT 1", "COMMIT; SELECT 1", "BEGIN; COMMIT; BEGIN; COMMIT", "BEGIN; ROLLBACK AND CHAIN"] {
            do { _ = try SQLParser().parseBlock(source); throw Failure.assertion("s16-invalid-transaction-order") }
            catch is QueryStructuralValidationError {}
            catch is SQLParser.ParseError {}
        }
    }

    private static func checkpointSettings(_ context: DatabaseContext) async throws {
        let result = try await text(context, "SET statement_timeout = '1000ms'; SAVEPOINT policy; SET LOCAL statement_timeout = '2s'; SHOW statement_timeout; ROLLBACK TO policy; SHOW statement_timeout; SET TimeZone = '+02:00'; RELEASE policy; SHOW TimeZone;")
        try require(try string(result, 3) == "2000" && string(result, 5) == "1000", "checkpoint-restores-settings")
        try require(contains(try string(result, 8), "+02"), "release-keeps-timezone")
        let reset = try await text(context, "SHOW statement_timeout; SHOW TimeZone;")
        try require(try string(reset, 0) == "0" && string(reset, 1) == "UTC", "request-local-setting-lifetime")
        do {
            _ = try await text(context, "INSERT INTO s16_items (id) VALUES (30); SAVEPOINT later; SET statement_timeout = '-1ms'; ROLLBACK TO later; INSERT INTO s16_items (id) VALUES (31)")
            throw Failure.assertion("s16-invalid-setting-must-fail")
        } catch SQLBlockExecutionError.invalidSettingValue(.statementTimeout) {}
        try require(try await read(context, "SELECT id FROM s16_items WHERE id >= 30").rows.isEmpty, "first-error-whole-request-rollback")
    }

    private static func preparation(_ context: DatabaseContext) async throws {
        let result = try await text(context, "SAVEPOINT before_prepare; PREPARE supplied(integer) AS SELECT $1; ROLLBACK TO before_prepare; EXECUTE supplied(7); DEALLOCATE supplied;")
        try require(try rows(result, 3).rows.first?.values == [i(7)], "prepared-survives-savepoint-rollback")
        let body = try SQLParser().parse("SELECT nextval('s16_prepared_sequence')")
        _ = try await text(context, "CREATE SEQUENCE s16_prepared_sequence")
        _ = try await run(context, SQLBlock(steps: [.prepare(.init(name: "unused", statement: body))]))
        try require(try await read(context, "SELECT nextval('s16_prepared_sequence')").rows.first?.values == [.primitive(.int64(1))], "prepare-has-no-sequence-effects")
        do {
            _ = try await text(context, "PREPARE stale(integer) AS SELECT $1; SET search_path = 'other, public'; EXECUTE stale(1)")
            throw Failure.assertion("s16-stale-prepare-must-fail")
        } catch SQLPreparedExecutionError.staleBinding("stale") {}
        do {
            _ = try await text(context, "PREPARE duplicate AS SELECT 1; PREPARE duplicate AS SELECT 2")
            throw Failure.assertion("s16-duplicate-prepare-must-fail")
        } catch SQLPreparedExecutionError.duplicateName("duplicate") {}
        do { _ = try await text(context, "EXECUTE supplied(7)"); throw Failure.assertion("s16-prepared-request-lifetime") }
        catch SQLPreparedExecutionError.unknownName("supplied") {}
        do {
            _ = try await text(context, "PREPARE schema_stale AS SELECT id FROM s16_items; CREATE TABLE s16_abandoned (id integer); EXECUTE schema_stale")
            throw Failure.assertion("s16-prepared-schema-staleness")
        } catch SQLPreparedExecutionError.staleBinding("schema_stale") {}
        try require(try await read(context, "SELECT table_name FROM information_schema.tables WHERE table_name = 's16_abandoned'").rows.isEmpty,
            "stale-definition-ddl-rollback")
        for (index, deallocation) in ["DEALLOCATE reused", "DEALLOCATE ALL"].enumerated() {
            let id = 42 + index
            let reused = try await text(context, "PREPARE reused AS INSERT INTO s16_items (id, content) VALUES (\(id), 'prepared'); EXECUTE reused; \(deallocation); PREPARE reused AS SELECT 1; EXECUTE reused")
            try command(reused.results[1], .insert, 1)
            try require(try rows(reused, 4).rows.first?.values == [i(1)], "reprepared-live-definition")
            try require(try await read(context, "SELECT content FROM s16_items WHERE id = \(id)").rows.first?.values
                == [.primitive(.string("prepared"))], "prepared-write-access-persists")
        }
    }

    private static func deadlinesAndCancellation(_ context: DatabaseContext, _ container: DBContainer) async throws {
        // This is the actual SQLBlock timeout owner and actual host monotonic timer.
        // No synthetic clock, engine or SQL runtime replaces the production path.
        do {
            _ = try await SQLBlockStatementDeadline.run(milliseconds: 1, clock: container.monotonicClock) {
                try await container.monotonicClock.sleep(until: container.monotonicClock.now.advanced(by: .milliseconds(100)))
                return 1
            }
            throw Failure.assertion("s16-live-host-statement-deadline")
        } catch SQLBlockExecutionError.statementTimeout {}
        let cancellation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await text(context, "INSERT INTO s16_items (id) VALUES (40)")
                throw Failure.assertion("s16-cancelled-block-must-fail")
            } catch is CancellationError {}
        }
        try await cancellation.value
        try require(try await read(context, "SELECT id FROM s16_items WHERE id = 40").rows.isEmpty, "cancelled-block-no-effects")
        _ = try await text(context, "SET statement_timeout = '0'; SELECT 1")
        print("ENGINE_S16_TIMEOUT owner=SQLBlockStatementDeadline timer=StorageMonotonicClock cancellation=SQLBlockExecutor")
    }

    private static func explain(_ context: DatabaseContext) async throws {
        let before = try await read(context, "SELECT id FROM s16_items")
        let plan = try await text(context, "EXPLAIN (FORMAT JSON, VERBOSE) SELECT count(*) FROM s16_items")
        let response = try rows(plan, 0)
        try require(response.columns.first?.type == .sql(.json), "explain-json-typed-output")
        let serialized = try string(plan, 0)
        _ = try QueryJSONValue(bytes: ByteString(utf8: serialized), limits: SQLCollectionVerification.limits)
        try require(contains(serialized, "Aggregate") && contains(serialized, "Plan") && !contains(serialized, "Cost"), "explain-selected-aggregate")
        _ = try await text(context, "EXPLAIN INSERT INTO s16_items (id) VALUES (50)")
        try require(try await read(context, "SELECT id FROM s16_items").rows == before.rows, "explain-no-mutation-effects")
        let analyzed = try await text(context, "SAVEPOINT before_analyze; EXPLAIN (ANALYZE, FORMAT JSON) INSERT INTO s16_items (id) VALUES (51); ROLLBACK TO before_analyze")
        let measured = try string(analyzed, 1)
        try require(contains(measured, "\"Actual Rows\":1") && contains(measured, "\"Work Units\":")
            && contains(measured, "\"Execution Time ms\":"), "explain-actual-measurements")
        try require(try await read(context, "SELECT id FROM s16_items WHERE id >= 50").rows.isEmpty, "analyze-same-transaction-rollback")
        _ = try await text(context, "CREATE TABLE s16_explain_source (id integer); INSERT INTO s16_explain_source VALUES (7); CREATE VIEW s16_explain_view AS SELECT id FROM s16_explain_source; ALTER TABLE s16_explain_source RENAME TO s16_explain_renamed")
        try require(try await read(context, "SELECT id FROM s16_explain_view").rows.first?.values == [i(7)], "captured-view-read-after-rename")
        let captured = try await text(context, "EXPLAIN (FORMAT JSON) SELECT id FROM s16_explain_view")
        try require(contains(try string(captured, 0), "View"), "explain-captured-view-resolution")
        _ = try await text(context, "CREATE INDEX s16_explain_by_id ON s16_explain_renamed (id)")
        let indexed = try await text(context, "EXPLAIN (ANALYZE, FORMAT JSON) SELECT id FROM s16_explain_view WHERE id = 7")
        let indexedText = try string(indexed, 0)
        try require(contains(indexedText, "Index Scan") && contains(indexedText, "s16_explain_by_id")
            && contains(indexedText, "\"Actual Rows\":1"), "explain-captured-index-resolution")
    }

    private static func copy(_ context: DatabaseContext) async throws {
        _ = try await text(context, "CREATE TABLE s16_copy (id integer, content text, extra integer DEFAULT 17)")
        let options = try SQLCopyOptions(format: .csv, header: true)
        let result = try await run(context, SQLBlock(steps: [
            .copy(.init(target: .table(TableRef("s16_copy"), columns: ["content", "id"]), direction: .from, options: options,
                data: ByteString(utf8: "content,id\r\n\"line\nnext\",1\r\n\"\",2\r\n,3\r\n"))),
            .copy(.init(target: .query(select("SELECT id, content, extra FROM s16_copy ORDER BY id")), direction: .to, options: options))]))
        try command(result.results[0], .copy, 3)
        guard case .copy(let output) = result.results[1] else { throw Failure.assertion("s16-copy-typed-output") }
        try require(output.affectedRows == 3 && output.bytes == ByteString(utf8: "id,content,extra\n1,\"line\nnext\",17\n2,\"\",17\n3,,17\n"),
            "csv-null-empty-multiline-defaults")
        _ = try await text(context, "CREATE TABLE s16_copy_text (id integer, content text)")
        let textPayload = "1\t\\N\n2\t\n3\tline\\nnext\n4\t\\\\N\n"
        let roundTrip = try await run(context, SQLBlock(steps: [
            .copy(.init(target: .table(TableRef("s16_copy_text"), columns: []), direction: .from, data: ByteString(utf8: textPayload))),
            .copy(.init(target: .query(select("SELECT id, content FROM s16_copy_text ORDER BY id")), direction: .to))]))
        guard case .copy(let textOutput) = roundTrip.results[1] else { throw Failure.assertion("s16-copy-text-output") }
        try require(textOutput.bytes == ByteString(utf8: textPayload) && textOutput.affectedRows == 4, "text-null-empty-escaped-roundtrip")
        do {
            _ = try await run(context, SQLBlock(steps: [.copy(.init(target: .table(TableRef("s16_copy_text"), columns: []),
                direction: .from, options: SQLCopyOptions(format: .csv), data: ByteString(utf8: "5,good\n6,\"unfinished")))]))
            throw Failure.assertion("s16-copy-late-malformed-must-fail")
        } catch is SQLCopyExecutionError {}
        try require(try await read(context, "SELECT id FROM s16_copy_text WHERE id >= 5").rows.isEmpty, "late-malformed-copy-full-rollback")
        do {
            _ = try await run(context, SQLBlock(steps: [.copy(.init(target: .table(TableRef("s16_copy_text"), columns: []),
                direction: .from, data: ByteString(utf8: "5\tgood\ninvalid\tbad\n")))]))
            throw Failure.assertion("s16-copy-late-conversion-must-fail")
        } catch let failure as Failure { throw failure }
        catch {}
        try require(try await read(context, "SELECT id FROM s16_copy_text WHERE id >= 5").rows.isEmpty, "late-conversion-copy-full-rollback")
        let inline = "COPY s16_copy_text FROM STDIN;\n7\tinline\n\\.\nSELECT id FROM s16_copy_text WHERE id = 7;"
        let parsed = try SQLParser().parseBlockWithSource(inline)
        try require(parsed.copyDataRanges.first.flatMap { $0 } != nil && parsed.roots.count == 2, "inline-copy-source-ranges")
        let imported = try await run(context, parsed.block)
        try require(try rows(imported, 1).rows.first?.values == [i(7)], "text-parser-inline-copy-real-effects")
        let bounded = SQLCopyCommand(target: .table(TableRef("s16_copy_text"), columns: []), direction: .from,
            data: ByteString(utf8: "8\tbounded\n9\tbounded\n"))
        let exact = try await run(context, SQLBlock(steps: [.transaction(.begin), .copy(bounded), .transaction(.rollback)]),
            budget: ExecutionBudget(maximumRows: 2))
        try command(exact.results[1], .copy, 2)
        do {
            _ = try await run(context, SQLBlock(steps: [.copy(bounded)]), budget: ExecutionBudget(maximumRows: 1))
            throw Failure.assertion("s16-copy-one-past-row-limit")
        } catch is DatabaseWorkLimitError {}
        try require(try await read(context, "SELECT id FROM s16_copy_text WHERE id >= 8").rows.isEmpty,
            "copy-row-budget-failure-atomic")
    }

    private static func metadata(_ context: DatabaseContext, _ container: DBContainer) async throws {
        let required = try await read(context, "SELECT constraint_type FROM information_schema.table_constraints WHERE table_name = 's16_items'")
        try require(required.rows.map { $0.values } == [[.primitive(.string("CHECK"))]],
            "not-null-metadata-projection-matches-postgresql")
        let result = try await text(context, "CREATE TABLE s16_visible (value integer); INSERT INTO s16_visible VALUES (72); SAVEPOINT metadata; CREATE TABLE s16_transient (value integer); SELECT table_name FROM information_schema.tables WHERE table_name = 's16_transient'; ROLLBACK TO metadata; SELECT table_name FROM information_schema.tables WHERE table_name = 's16_transient'; CREATE VIEW s16_metadata_view AS SELECT table_name FROM information_schema.tables WHERE table_name = 's16_visible'; CREATE VIEW s16_value_view AS SELECT value FROM s16_visible;")
        try require(try rows(result, 4).rows.first?.values == [.primitive(.string("s16_transient"))]
            && rows(result, 6).rows.isEmpty, "metadata-own-ddl-and-rollback")
        guard let view = container.sqlCatalog.views.first(where: { $0.name == "s16_metadata_view" }) else {
            throw Failure.assertion("s16-created-virtual-source-view")
        }
        try require(view.definition.bindings.contains { $0.kind == .informationSchema }, "durable-view-virtual-source-kind")
        let restored = try SQLCatalogCodec.decode(SQLCatalogCodec.encode(container.acquirePublishedSchemaLease().sqlCatalog))
        try require(restored.catalog.views.first(where: { $0.id == view.id })?.definition.bindings == view.definition.bindings,
            "catalog-codec-preserves-source-kind")
        let denied = container.newContext(authorization: .authenticated(Principal(identifier: "s16-denied", roles: [])))
        let hidden = try await read(denied, "SELECT table_name FROM information_schema.tables WHERE table_name = 's16_visible'")
        try require(hidden.rows.isEmpty, "metadata-denied-relation-hidden")
        let hiddenView = try await read(denied, "SELECT table_name FROM \"runtime-verification\".s16_metadata_view")
        try require(hiddenView.rows.isEmpty, "durable-virtual-view-invoker-policy")
        try require(try await read(context, "SELECT table_name FROM s16_metadata_view").rows.first?.values
            == [.primitive(.string("s16_visible"))], "allowed-metadata-view-visible")
        let largeLiteral = String(repeating: "a", count: 1_024 * 1_024)
        _ = try await text(context, "CREATE VIEW s16_large_definition AS SELECT '\(largeLiteral)' AS value")
        do {
            _ = try await run(context, SQLParser().parseBlock("SELECT view_definition FROM information_schema.views"),
                budget: ExecutionBudget(maximumIntermediateBytes: 128 * 1_024))
            throw Failure.assertion("s16-metadata-definition-budget-must-fail")
        } catch let failure as Failure { throw failure }
        catch {
            let diagnostic = SQLDiagnostics.diagnostic(for: error)
            try require(diagnostic.sqlState == "54000" && diagnostic.category == .resource,
                "metadata-definition-request-budget")
        }
        try require(try await read(context, "SELECT table_name FROM information_schema.views WHERE table_name = 's16_metadata_view'").rows.first?.values
            == [.primitive(.string("s16_metadata_view"))], "metadata-after-render-budget-failure")
    }

    private static func contains(_ text: String, _ fragment: String) -> Bool {
        let needle = fragment.utf8
        if needle.isEmpty { return true }
        var remaining = text.utf8[...]
        while !remaining.isEmpty {
            if remaining.starts(with: needle) { return true }
            remaining = remaining.dropFirst()
        }
        return false
    }

    private static func diagnostics(_ context: DatabaseContext) async throws {
        let cases: [(any Error, String)] = [
            (SQLConstraintError.violation(kind: .notNull, relation: "opaque", constraint: "required", schema: "public", table: "s16_items", column: "id"), "23502"),
            (SQLConstraintError.violation(kind: .unique, relation: "opaque", constraint: "unique"), "23505"),
            (SQLMutationError.cardinalityViolation, "21000"), (DatabaseExpressionEvaluationError.numericOverflow, "22003"),
            (DatabaseExpressionEvaluationError.typeMismatch(operation: "ADD"), "42804"),
            (StorageError.transactionConflict, "40001"), (CancellationError(), "57014"),
            (StorageError.unsupportedOperation("feature"), "0A000")]
        for (cause, state) in cases { try require(SQLDiagnostics.diagnostic(for: cause).sqlState == state, "typed-sqlstate-" + state) }
        do { _ = try await text(context, "SELECT $1"); throw Failure.assertion("s16-missing-parameter-must-fail") }
        catch let failure as Failure { throw failure }
        catch {
            try require((error as? QueryParameterBindingError) == .missingPosition(1), "missing-parameter-original-cause")
            let diagnostic = SQLDiagnostics.diagnostic(for: error)
            try require(diagnostic.sqlState == "42P02" && diagnostic.category == .name && diagnostic.position == nil,
                "missing-parameter-classification")
        }
        do {
            _ = try await text(context, "INSERT INTO s16_items (id) VALUES (80); SELECT 1 / 0")
            throw Failure.assertion("s16-division-must-fail")
        } catch let failure as Failure { throw failure }
        catch { try require(SQLDiagnostics.diagnostic(for: error).sqlState == "22012", "real-expression-diagnostic") }
        try require(try await read(context, "SELECT id FROM s16_items WHERE id = 80").rows.isEmpty, "diagnostic-failure-rollback")
        do {
            _ = try await text(context, "INSERT INTO s16_items (id) VALUES (NULL)")
            throw Failure.assertion("s16-not-null-must-fail")
        } catch let failure as Failure { throw failure }
        catch {
            let diagnostic = SQLDiagnostics.diagnostic(for: error)
            try require(diagnostic.sqlState == "23502" && diagnostic.table == "s16_items" && diagnostic.column == "id"
                && diagnostic.position == nil, "real-constraint-identifiers-without-invented-position")
        }
        let source = "SELECT 'é'; SELECT missing FROM s16_items"
        let parsed = try SQLParser().parseBlockWithSource(source)
        try require(parsed.stepRanges.count == 2 && parsed.stepRanges[1].start > 10 && parsed.roots[1] != nil,
            "multibyte-parser-original-byte-source")
        do { _ = try await run(context, parsed.block); throw Failure.assertion("s16-missing-column-must-fail") }
        catch let failure as Failure { throw failure }
        catch { try require(SQLDiagnostics.diagnostic(for: error).sqlState == "42703", "real-name-diagnostic") }
    }

    static func verifyRestored(in context: DatabaseContext, container: DBContainer) async throws {
        print("ENGINE_S16_CASE S16RESTART BEGIN")
        do {
            try require(try await read(context, "SELECT value FROM s16_value_view").rows.first?.values == [i(72)], "fresh-reactor-durable-view-data")
            try require(try await read(context, "SELECT table_name FROM s16_metadata_view").rows.first?.values
                == [.primitive(.string("s16_visible"))], "fresh-reactor-durable-information-schema-view")
            guard let view = container.sqlCatalog.views.first(where: { $0.name == "s16_metadata_view" }) else {
                throw Failure.assertion("s16-restored-virtual-view")
            }
            try require(view.definition.bindings.contains { $0.kind == .informationSchema }, "fresh-reactor-restored-source-kind")
            try require(try await read(context, "SELECT id FROM s16_copy_text ORDER BY id").rows.map { $0.values }
                == [[i(1)], [i(2)], [i(3)], [i(4)], [i(7)]], "fresh-reactor-copy-committed-state")
            let settings = try await text(context, "SHOW statement_timeout; SHOW TimeZone")
            try require(try string(settings, 0) == "0" && string(settings, 1) == "UTC", "fresh-reactor-no-request-settings")
            do { _ = try await text(context, "EXECUTE supplied(7)"); throw Failure.assertion("s16-restored-prepared-must-not-exist") }
            catch SQLPreparedExecutionError.unknownName("supplied") {}
        } catch { throw SQLTextPatternVerification.DiagnosticFailure(phase: "S16RESTART", cause: error) }
        print("ENGINE_S16_CASE S16RESTART PASS")
        print("ENGINE_S16_RESTART_PASS cases=1 viewSource=informationSchema")
    }

    private static func carriage() throws {
        print("ENGINE_S16_CASE S16K01 BEGIN")
        let query = SelectQuery(projection: [.expression(.parameter(position: 1), alias: "é")], source: .values([[]]))
        let block = try SQLBlock(steps: [.transaction(.begin), .setting(.show(.timeZone)),
            .prepare(.init(name: "p", parameterTypes: [.integer], statement: .select(query))),
            .execute(.init(name: "p", arguments: [.int(7)])), .explain(.init(statement: .select(query), options: .init(verbose: true, format: .json))),
            .copy(.init(target: .table(TableRef("t"), columns: ["a"]), direction: .from,
                options: SQLCopyOptions(format: .csv), data: ByteString(utf8: "1\n"))), .transaction(.rollback)])
        let bytes = try QueryIRWireFormat.encode(block)
        try require(try QueryIRWireFormat.decodeBlock(bytes) == block, "block-owned-wire-roundtrip")
        var measured = 0
        var streamed: [UInt8] = []
        try QueryIRWireFormat.emitCanonicalEncoding(block, prepare: { measured = $0 }, consume: { streamed.append(contentsOf: $0) })
        try require(measured == bytes.count && ByteString(streamed) == bytes, "block-streamed-equals-owned")
        let exact = try wireLimits(frame: bytes.count)
        try require(try QueryIRWireFormat.encode(block, limits: exact) == bytes && QueryIRWireFormat.decodeBlock(bytes, limits: exact) == block,
            "block-exact-frame")
        do { _ = try QueryIRWireFormat.decodeBlock(bytes, limits: wireLimits(frame: bytes.count - 1)); throw Failure.assertion("s16-frame-one-past") }
        catch is DatabaseWireError {}
        var deep = DataType.integer
        for _ in 0..<200 { deep = .array(deep) }
        let nested = try SQLBlock(steps: [.prepare(.init(name: "deep", parameterTypes: [deep], statement: .select(query)))],
            limits: .init(maximumNestingDepth: 512))
        let generous = try wireLimits(depth: 512)
        let nestedBytes = try QueryIRWireFormat.encode(nested, limits: generous)
        try require(try QueryIRWireFormat.decodeBlock(nestedBytes, limits: generous) == nested, "deep-iterative-block-wire")
        do { _ = try QueryIRWireFormat.decodeBlock(nestedBytes, limits: wireLimits(depth: 200)); throw Failure.assertion("s16-deep-wire-limit") }
        catch is DatabaseWireError {}
        let virtual = try SQLViewSourceBinding(kind: .informationSchema, schema: "information_schema", table: "tables", relationID: "tables", columns: [])
        let ordinary = try SQLViewSourceBinding(kind: .catalog, schema: "information_schema", table: "tables", relationID: "tables", columns: [])
        try require(virtual != ordinary && Set([virtual, ordinary]).count == 2, "view-source-kind-distinct-identity")
        print("ENGINE_S16_CASE S16K01 PASS")
        print("ENGINE_S16_KIT_PASS cases=1 depth=200 sourceKinds=2")
    }

    private static func wireLimits(frame: Int = 100_000, depth: Int = 512) throws -> DatabaseWireLimits {
        try DatabaseWireLimits(maximumFrameBytes: frame, maximumStringBytes: 1_000, maximumByteStringBytes: frame,
            maximumCollectionCount: 1_000, maximumNestingDepth: depth, maximumObjectCount: 100_000)
    }
    private static func run(_ context: DatabaseContext, _ block: SQLBlock,
        budget: ExecutionBudget = ExecutionBudget()) async throws -> SQLBlockResult {
        let carried = try QueryIRWireFormat.decodeBlock(QueryIRWireFormat.encode(block))
        return try await SQLBlockExecutor(context: context).execute(carried,
            options: SQLBlockExecutionOptions(checkpointLimits: SQLCheckpointVerification.limits(), budget: budget))
    }
    private static func text(_ context: DatabaseContext, _ source: String) async throws -> SQLBlockResult {
        try await run(context, SQLParser().parseBlock(source))
    }
    private static func select(_ source: String) throws -> SelectQuery {
        guard case .select(let query) = try SQLParser().parse(source) else { throw Failure.assertion("s16-select-fixture") }
        return query
    }
    private static func read(_ context: DatabaseContext, _ source: String) async throws -> QueryResponse {
        try rows(await text(context, source), 0)
    }
    private static func rows(_ result: SQLBlockResult, _ index: Int) throws -> QueryResponse {
        guard result.results.indices.contains(index), case .rows(let rows) = result.results[index] else { throw Failure.assertion("s16-rows-fixture") }
        return rows
    }
    private static func string(_ result: SQLBlockResult, _ index: Int) throws -> String {
        let response = try rows(result, index)
        guard let value = response.rows.first?.values.first else { throw Failure.assertion("s16-scalar-fixture") }
        switch value {
        case .primitive(.string(let text)): return text
        case .json(let json): return String(decoding: json.bytes, as: UTF8.self)
        default: throw Failure.assertion("s16-text-or-json-fixture")
        }
    }
    private static func command(_ outcome: SQLStatementResult, _ kind: SQLCommandKind, _ count: UInt64?) throws {
        guard case .command(let actual, let affected) = outcome, actual == kind, affected == count else {
            throw Failure.assertion("s16-command-fixture")
        }
    }
    private static func i(_ value: Int32) -> QueryValue { .primitive(.int32(value)) }
    private static func require(_ condition: Bool, _ name: String) throws {
        try ParameterBindingVerification.require(condition, "s16-" + name)
    }
}
