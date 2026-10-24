@_spi(DatabaseExecution) import Database
@_spi(DatabaseExecution) @testable import DatabaseEngine
import DatabaseClient
import DatabaseKit
import DatabaseTypes
@_spi(DatabaseExecution) import DatabaseWire
import QueryAST
import StorageKit
import Synchronization

/// Adds only S17 graph-free execution witnesses to the retained S16 reactor.
enum S17SQLProjectionVerification {
    typealias Failure = ParameterBindingVerification.Failure

    static func verify(in context: DatabaseContext, container: DBContainer) async throws {
        print("ENGINE_S17_CASE projection-ready BEGIN")
        try await projectionReady(context, container)
        print("ENGINE_S17_CASE projection-ready PASS")
        print("ENGINE_S17_CASE projection-failure BEGIN")
        try await projectionFailure(context, container)
        print("ENGINE_S17_CASE projection-failure PASS")
        print("ENGINE_S17_WIRE_CASE scoped-writer BEGIN")
        try scopedWriter()
        print("ENGINE_S17_WIRE_CASE scoped-writer PASS")
        print("ENGINE_S17_CLIENT_CASE opaque-correlation BEGIN")
        try await opaqueCorrelation(context)
        print("ENGINE_S17_CLIENT_CASE opaque-correlation PASS")
        print("ENGINE_S17_PASS engine=2 wire=1 client=1 owner=DatabaseEngine.SQLBlockExecutor promotion=EncodedQueryResponse.Mutex")
    }

    private static func projectionReady(_ context: DatabaseContext, _ container: DBContainer) async throws {
        _ = try await run(context, "CREATE TABLE s17_projection (id integer, content text)")
        let block = try SQLParser().parseBlock("""
            INSERT INTO s17_projection VALUES (1, 'kept');
            SELECT content AS value, content AS value FROM s17_projection WHERE id = 1;
            SELECT content FROM s17_projection WHERE FALSE;
            COPY (SELECT content FROM s17_projection WHERE id = 1) TO STDOUT;
            """)
        let meter = DatabaseWorkMeter(budget: ExecutionBudget(), monotonicClock: container.monotonicClock)
        let probe = ProjectionProbe()
        let response = try await encoded(context, container, block, meter: meter,
            encoder: ObservedEncoder(base: .init(requestID: 1701, limits: .default), probe: probe))
        try require(probe.measurements == 1 && probe.encodings == 1, "single-measure-and-encode")
        try require(meter.retainedIntermediateBytes == UInt64(response.byteCount), "ready-exact-frame-claim")
        // Both tasks retain the same concrete owner. The production Mutex must
        // select one transfer on every target; this does not claim OS threading.
        let promotion = await withTaskGroup(of: Promotion.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do { return .bytes(try response.promoteToOutput()) }
                    catch SQLBlockProjectionError.alreadyPromoted { return .rejected }
                    catch { return .unexpectedFailure }
                }
            }
            var winner: ByteString?
            var rejected = 0
            var invalid = false
            for await result in group {
                switch result {
                case .bytes(let bytes):
                    if winner != nil { invalid = true }
                    winner = bytes
                case .rejected: rejected += 1
                case .unexpectedFailure: invalid = true
                }
            }
            return (winner, rejected, invalid)
        }
        guard let frame = promotion.0, promotion.1 == 1, !promotion.2 else {
            throw Failure.assertion("s17-promotion-missing-or-invalid-winner")
        }
        try require(meter.retainedIntermediateBytes == 0, "promotion-releases-frame-and-all-row-claims")
        let decoded = try DatabaseWireDecoder().decodeResponse(DatabaseOperationCatalog.queryExecute,
            from: frame, matching: 1701).get()
        guard decoded.results.count == 4,
              case .command(.insert, 1) = decoded.results[0],
              case .rows(let rows) = decoded.results[1],
              case .rows(let empty) = decoded.results[2],
              case .copy(let copy, 1) = decoded.results[3] else {
            throw Failure.assertion("s17-complete-ordered-frame")
        }
        try require(rows.columns.map { $0.name } == ["value", "value"] && empty.rowCount == 0
            && empty.columns.count == 1 && copy == ByteString(utf8: "kept\n"), "rows-schema-and-copy")
        var iterator = rows.makeRowIterator()
        try require(try iterator.next()?.values == [.primitive(.string("kept")), .primitive(.string("kept"))]
            && iterator.next() == nil, "borrowed-row-values")
        try require(try await rowCount(context, "SELECT id FROM s17_projection WHERE id = 1") == 1,
            "actual-committed-readback")
    }

    private static func projectionFailure(_ context: DatabaseContext, _ container: DBContainer) async throws {
        for mode in [Refusal.wireLimit, .encoding, .cancellation] {
            let id: Int
            switch mode { case .wireLimit: id = 2; case .encoding: id = 3; case .cancellation: id = 4 }
            let block = try SQLParser().parseBlock("INSERT INTO s17_projection VALUES (\(id), 'hidden'); SELECT content FROM s17_projection")
            let meter = DatabaseWorkMeter(budget: ExecutionBudget(), monotonicClock: container.monotonicClock)
            let probe = ProjectionProbe()
            let wire = DatabaseWireEncoder(limits: try limits(frame: mode == .wireLimit ? 1 : 100_000))
            let encoder = ObservedEncoder(base: .init(requestID: 1702, limits: wire.limits), probe: probe, refusal: mode)
            if mode == .cancellation {
                let task = Task {
                    do {
                        _ = try await encoded(context, container, block, meter: meter, encoder: encoder)
                        throw Failure.assertion("s17-cancellation-returned-ready")
                    } catch is CancellationError {}
                }
                try await task.value
            } else {
                do {
                    _ = try await encoded(context, container, block, meter: meter, encoder: encoder)
                    throw Failure.assertion("s17-refusal-returned-ready")
                } catch let failure as SQLExecutionFailure {
                    guard mode == .wireLimit,
                          let cause = failure.underlyingError as? QueryResponseEncodingError,
                          case .resourceLimit(.frameTooLarge) = cause else { throw failure }
                    try require(failure.diagnostic.sqlState == "54000" && failure.diagnostic.category == .resource,
                        "wire-measurement-native-limit")
                } catch ProjectionFailure.encoding {
                    try require(mode == .encoding, "exact-encoding-native-cause")
                }
            }
            try require(probe.measurements == 1 && probe.encodings == (mode == .wireLimit ? 0 : 1),
                "refusal-reached-owning-projection-stage")
            try require(meter.retainedIntermediateBytes == 0, "refusal-releases-unpublished-frame")
            try require(try await rowCount(context, "SELECT id FROM s17_projection WHERE id = \(id)") == 0,
                "refusal-actual-mutation-rollback")
        }
    }

    private static func scopedWriter() throws {
        func project(_ writer: inout QueryResponseWriter) throws {
            try writer.writeCopy(bytes: ByteString([0, 255, 10]), affectedRows: 1)
        }
        let size = try DatabaseWireEncoder().measureQueryResponse(requestID: 1703, resultCount: 1, body: project)
        let exact = try limits(frame: size, depth: 1, objects: 1, collection: 0)
        let wire = DatabaseWireEncoder(limits: exact)
        try require(try wire.measureQueryResponse(requestID: 1703, resultCount: 1, body: project) == size,
            "writer-exact-full-envelope-and-object-budget")
        let frame = try ByteString.copying(count: size) { destination in
            try wire.encodeQueryResponse(requestID: 1703, resultCount: 1, into: destination, body: project)
        }
        guard case .success(let response) = try DatabaseWireDecoder(limits: exact).decodeResponse(
            DatabaseOperationCatalog.queryExecute, from: frame, matching: 1703),
              case .copy(let copy, 1) = response.results.first else { throw Failure.assertion("s17-scoped-writer-roundtrip") }
        try require(copy == ByteString([0, 255, 10]), "scoped-writer-exact-bytes")
        for restrictive in [try limits(frame: size - 1), try limits(depth: 0), try limits(objects: 0),
                            try limits(bytes: 2)] {
            do {
                _ = try DatabaseWireEncoder(limits: restrictive).measureQueryResponse(requestID: 1703, resultCount: 1, body: project)
                throw Failure.assertion("s17-scoped-writer-limit-accepted")
            } catch is DatabaseWireError {}
            do {
                _ = try DatabaseWireDecoder(limits: restrictive).decodeResponse(DatabaseOperationCatalog.queryExecute,
                    from: frame, matching: 1703)
                throw Failure.assertion("s17-full-frame-decoder-limit-accepted")
            } catch is DatabaseWireError {}
        }
        func projectBlock(_ writer: inout QueryResponseWriter) throws {
            try project(&writer)
            try project(&writer)
        }
        let blockSize = try DatabaseWireEncoder().measureQueryResponse(requestID: 1703, resultCount: 2, body: projectBlock)
        let blockFrame = try ByteString.copying(count: blockSize) { destination in
            try DatabaseWireEncoder().encodeQueryResponse(requestID: 1703, resultCount: 2,
                into: destination, body: projectBlock)
        }
        for restrictive in [try limits(collection: 1), try limits(depth: 1), try limits(objects: 3)] {
            do {
                _ = try DatabaseWireEncoder(limits: restrictive).measureQueryResponse(requestID: 1703,
                    resultCount: 2, body: projectBlock)
                throw Failure.assertion("s17-block-writer-limit-accepted")
            } catch is DatabaseWireError {}
            do {
                _ = try DatabaseWireDecoder(limits: restrictive).decodeResponse(DatabaseOperationCatalog.queryExecute,
                    from: blockFrame, matching: 1703)
                throw Failure.assertion("s17-block-decoder-limit-accepted")
            } catch is DatabaseWireError {}
        }
        do {
            _ = try wire.measureQueryResponse(requestID: 1703, resultCount: 1) { _ in }
            throw Failure.assertion("s17-incomplete-writer-accepted")
        } catch DatabaseWireError.invalidSQLResponse {}
        do {
            _ = try DatabaseWireEncoder().measureQueryResponse(requestID: 1703, resultCount: 1) { writer in
                try writer.writeRows(columnCount: 0, rowCount: 0, affectedRows: nil) { _ in
                    throw ProjectionFailure.encoding
                }
            }
            throw Failure.assertion("s17-native-visitor-error-lost")
        } catch ProjectionFailure.encoding {}
    }

    private static func opaqueCorrelation(_ context: DatabaseContext) async throws {
        let endpoint = OpaqueEndpoint(context: context)
        let transport = OpaqueTransport(endpoint: endpoint, mismatch: false)
        let client = DatabaseClient(transport: transport)
        let connection = try await client.openConnection()
        defer { await connection.close() }
        let statement = try SQLParser().parse("SELECT content FROM s17_projection WHERE id = 1")
        let inputs: [QueryInput] = [.sql("SELECT content FROM s17_projection WHERE id = 1"),
            .statement(statement), .block(try SQLBlock(steps: [.statement(statement)]))]
        for input in inputs {
            let result = try await connection.execute(input)
            guard result.results.count == 1, case .rows(let rows) = result.results[0] else {
                throw Failure.assertion("s17-client-complete-result")
            }
            var iterator = rows.makeAsyncIterator()
            try require(try await iterator.next()?.values == [.primitive(.string("kept"))], "client-real-engine-value")
        }
        do {
            _ = try await connection.execute(SQL(text: "SELECT 1 / 0"))
            throw Failure.assertion("s17-client-native-diagnostic-became-success")
        } catch DatabaseClientError.call(.remote(let remote)) {
            try require(try remote.sqlDiagnostic()?.sqlState == "22012", "client-native-sqlstate")
        }
        let mismatch = DatabaseClient(transport: OpaqueTransport(endpoint: endpoint, mismatch: true))
        let mismatchedConnection = try await mismatch.openConnection()
        defer { await mismatchedConnection.close() }
        do {
            _ = try await mismatchedConnection.execute(statement)
            throw Failure.assertion("s17-client-mismatched-response-accepted")
        } catch DatabaseClientError.call(.wire(.unexpectedRequestIdentifier(expected: 1, actual: 2))) {}
        try require(await endpoint.requestCount == 5, "client-no-hidden-replay")
    }

    private static func encoded(_ context: DatabaseContext, _ container: DBContainer, _ block: SQLBlock,
        meter: DatabaseWorkMeter, encoder: any SQLBlockResponseEncoder) async throws -> EncodedQueryResponse {
        let budget = meter.budget
        return try await SQLBlockExecutor(context: context).executeEncoded(block,
            options: SQLBlockExecutionOptions(checkpointLimits: SQLCheckpointVerification.limits(), budget: budget),
            workMeter: meter, executionDeadline: TransactionExecutionDeadline(
                instant: container.monotonicClock.now.advanced(by: .milliseconds(Int64(budget.timeoutMilliseconds))),
                timeoutMilliseconds: budget.timeoutMilliseconds), encoder: encoder)
    }
    private static func run(_ context: DatabaseContext, _ sql: String) async throws -> SQLBlockResult {
        try await SQLBlockExecutor(context: context).execute(SQLParser().parseBlock(sql),
            options: SQLBlockExecutionOptions(checkpointLimits: SQLCheckpointVerification.limits()))
    }
    private static func rowCount(_ context: DatabaseContext, _ sql: String) async throws -> Int {
        let result = try await run(context, sql)
        guard case .rows(let rows) = result.results.first else { throw Failure.assertion("s17-native-readback") }
        return rows.rows.count
    }
    private static func limits(frame: Int = 100_000, depth: Int = 64, objects: Int = 100_000,
        bytes: Int = 100_000, collection: Int = 1_000) throws -> DatabaseWireLimits {
        try DatabaseWireLimits(maximumFrameBytes: frame, maximumStringBytes: 1_000,
            maximumByteStringBytes: bytes, maximumCollectionCount: collection,
            maximumNestingDepth: depth, maximumObjectCount: objects)
    }
    private static func require(_ condition: Bool, _ name: String) throws {
        try ParameterBindingVerification.require(condition, "s17-" + name)
    }

    private enum Promotion: Sendable { case bytes(ByteString), rejected, unexpectedFailure }
    private enum Refusal: Sendable, Equatable { case wireLimit, encoding, cancellation }
    private enum ProjectionFailure: Error { case encoding }

    private final class ProjectionProbe: Sendable {
        private struct State: Sendable { var measurements = 0; var encodings = 0 }
        private let state = Mutex(State())
        var measurements: Int { state.withLock { $0.measurements } }
        var encodings: Int { state.withLock { $0.encodings } }
        func measured() { state.withLock { $0.measurements += 1 } }
        func encoded() { state.withLock { $0.encodings += 1 } }
    }

    private struct ObservedEncoder: SQLBlockResponseEncoder {
        let base: QueryResponseEncoder
        let probe: ProjectionProbe
        var refusal: Refusal? = nil
        func measure(_ output: borrowing SQLBlockOutputView) throws -> UInt64 {
            probe.measured()
            return try base.measure(output)
        }
        func encode(_ output: borrowing SQLBlockOutputView, into destination: inout MutableSpan<UInt8>) throws {
            probe.encoded()
            try base.encode(output, into: &destination)
            if refusal == .encoding { throw ProjectionFailure.encoding }
            if refusal == .cancellation { withUnsafeCurrentTask { $0?.cancel() } }
        }
    }

    /// The transport forwards only immutable frames. Parsing and execution stay
    /// inside the application-owned endpoint, never in its byte-transfer method.
    private struct OpaqueTransport: DatabaseTransport {
        let endpoint: OpaqueEndpoint
        let mismatch: Bool
        func send(_ request: ByteString) async throws(DatabaseTransportError) -> ByteString {
            do { return try await endpoint.respond(request, mismatch: mismatch) }
            catch is CancellationError { throw .cancelled }
            catch { throw .invalidResponse("The S17 verification endpoint failed before producing a frame") }
        }
    }

    private actor OpaqueEndpoint {
        let context: DatabaseContext
        private(set) var requestCount = 0
        init(context: DatabaseContext) { self.context = context }
        func respond(_ frame: ByteString, mismatch: Bool) async throws -> ByteString {
            requestCount += 1
            let decoded = try DatabaseWireDecoder().decodeRequest(DatabaseOperationCatalog.queryExecute, from: frame)
            let wire = DatabaseWireEncoder()
            do {
                let result = try await context.executeQueryEncoded(decoded.request.input,
                    parameters: decoded.request.parameters,
                    options: .init(budget: decoded.request.budget, graphPartitions: decoded.request.graphPartitions),
                    requestID: decoded.requestID + (mismatch ? 1 : 0),
                    checkpointCeiling: SQLCheckpointVerification.limits())
                return try result.promoteToOutput()
            } catch {
                if error is CancellationError { throw error }
                let diagnostic = SQLDiagnostics.diagnostic(for: error)
                let remote = try RemoteOperationError(category: .invalidRequest, code: "s17.fixture.sql",
                    message: diagnostic.message, retryability: .never, sqlDiagnostic: diagnostic)
                return try wire.encodeFailure(requestID: decoded.requestID,
                    operation: DatabaseOperationCatalog.queryExecute.identifier, error: remote)
            }
        }
    }
}
