import CloudflareDatabase
import CloudflareDurableObjectStorageTesting
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit
import DatabaseTypes
import DatabaseWire
import StorageKit
import StorageKitSystemClock
import Testing

@Suite("Application-owned SQL over the opaque Cloudflare host")
struct SQLApplicationSessionTests {
    @Test("One text block retains ordered rows, COPY, command and empty metadata", .timeLimit(.minutes(1)))
    func orderedResultsThroughOpaqueInvocation() async throws {
        let fixture = try makeRuntime()
        defer { await fixture.runtime.shutdown(callID: 99) }
        await fixture.runtime.start(callID: 1)
        let result = try await invoke(fixture, callID: 2, sql: """
            INSERT INTO "RuntimeVerificationDocument" (id, title) VALUES ('ordered', 'kept');
            SELECT title AS value, title AS value FROM "RuntimeVerificationDocument" WHERE id = $1;
            SELECT title FROM "RuntimeVerificationDocument" WHERE FALSE;
            COPY "RuntimeVerificationDocument" (title) TO STDOUT WITH (FORMAT csv);
            """, parameters: [QueryParameter(position: 1, value: .primitive(.string("ordered")),
                type: .primitive(.string, isArray: false))]).get()
        #expect(result.results.count == 4)
        guard case .command(.insert, let count) = result.results[0],
              case .rows(let rows) = result.results[1],
              case .rows(let empty) = result.results[2],
              case .copy(let bytes, let copied) = result.results[3] else {
            Issue.record("Expected ordered command, rows, empty rows and COPY"); return
        }
        #expect(count == 1)
        #expect(rows.columns.map(\.name) == ["value", "value"])
        #expect(rows.rowCount == 1)
        var iterator = rows.makeRowIterator()
        #expect(try iterator.next()?.values == [.primitive(.string("kept")), .primitive(.string("kept"))])
        #expect(try iterator.next() == nil)
        #expect(empty.rowCount == 0)
        #expect(empty.columns.map(\.name) == ["title"])
        #expect(empty.columns[0].type == .primitive(.string, isArray: false))
        #expect(!empty.columns[0].isNullable)
        #expect(bytes == ByteString(utf8: "kept\n"))
        #expect(copied == 1)
    }

    @Test("Typed diagnostics follow whole-request rollback and the host stays usable", .timeLimit(.minutes(1)))
    func typedDiagnosticAndRollback() async throws {
        let fixture = try makeRuntime()
        defer { await fixture.runtime.shutdown(callID: 99) }
        await fixture.runtime.start(callID: 1)
        let syntax = try await invoke(fixture, callID: 2, sql: "SELECT FROM")
        guard case .failure(let syntaxFailure) = syntax else {
            Issue.record("Expected syntax failure"); return
        }
        #expect(try syntaxFailure.sqlDiagnostic()?.sqlState == "42601")
        let failed = try await invoke(fixture, callID: 3, sql: """
            INSERT INTO "RuntimeVerificationDocument" (id, title) VALUES ('rollback', 'hidden');
            SELECT 1 / 0;
            """)
        guard case .failure(let executionFailure) = failed else {
            Issue.record("Expected execution failure without partial outcomes"); return
        }
        #expect(try executionFailure.sqlDiagnostic()?.sqlState == "22012")
        let absent = try await invoke(fixture, callID: 4,
            sql: "SELECT title FROM \"RuntimeVerificationDocument\" WHERE id = 'rollback'").get()
        #expect(try rows(absent).rowCount == 0)

        let cancelledBytes = try requestBytes(callID: 5, sql: "SELECT 1")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await fixture.runtime.invoke(callID: 5,
                contextBytes: ByteString(utf8: RuntimeVerificationSession.principalIdentifier),
                requestBytes: cancelledBytes)
        }
        await cancelled.value
        #expect(fixture.completion.completion(callID: 5)?.status == .cancelled)

        let cleanup = StorageTransactionCleanupError(operationError: CancellationError(),
            cancellationError: RuntimeVerificationError.invalidApplicationRequest)
        let composite = SQLExecutionFailure(underlyingError: cleanup,
            diagnostic: SQLDiagnostics.diagnostic(for: cleanup))
        let cleanupBytes = try SQLApplicationInvocation.failureResponse(for: composite,
            requestID: 6, encoder: DatabaseWireEncoder())
        let cleanupResponse = try DatabaseWireDecoder().decodeResponse(DatabaseOperationCatalog.sqlExecute,
            from: cleanupBytes, matching: 6)
        guard case .failure(let cleanupFailure) = cleanupResponse else {
            Issue.record("Expected a typed cleanup failure rather than cancellation"); return
        }
        #expect(try cleanupFailure.sqlDiagnostic()?.sqlState == "57014")
        #expect(cleanupFailure.retryability == .never)
    }

    @Test("Complete-frame admission rejects before commit", .timeLimit(.minutes(1)))
    func frameRejectionRollsBackMutation() async throws {
        let fixture = try makeRuntime(maximumFrameBytes: 512)
        defer { await fixture.runtime.shutdown(callID: 99) }
        await fixture.runtime.start(callID: 1)
        let payload = String(repeating: "x", count: 4_096)
        let failed = try await invoke(fixture, callID: 2, sql: """
            INSERT INTO "RuntimeVerificationDocument" (id, title) VALUES ('oversize', 'hidden');
            SELECT '\(payload)';
            """)
        guard case .failure(let failure) = failed else {
            Issue.record("Expected precommit frame rejection"); return
        }
        #expect(failure.category == .resourceLimit)
        #expect(try failure.sqlDiagnostic()?.sqlState == "54000")
        let absent = try await invoke(fixture, callID: 3,
            sql: "SELECT title FROM \"RuntimeVerificationDocument\" WHERE id = 'oversize'").get()
        #expect(try rows(absent).rowCount == 0)

        let wireLimit = DatabaseWireError.stringTooLarge(actual: 1_048_580, maximum: 1_048_576)
        do {
            try SQLApplicationResponseEncoder.throwResponseFailure(wireLimit)
        } catch let failure as SQLExecutionFailure {
            #expect(failure.underlyingError as? DatabaseWireError == wireLimit)
            #expect(failure.diagnostic.sqlState == "54000")
        }
        do {
            try SQLApplicationResponseEncoder.throwResponseFailure(.invalidSQLResponse)
        } catch let failure as DatabaseWireError {
            #expect(failure == .invalidSQLResponse)
        }
        let stringLimit = try await invoke(fixture, callID: 4, sql: """
            INSERT INTO "RuntimeVerificationDocument" (id, title) VALUES ('string-limit', 'hidden');
            SELECT repeat('0123456789', 104858);
            """, budget: ExecutionBudget(maximumWorkUnits: 50_000_000,
                maximumIntermediateBytes: 64 * 1_024 * 1_024))
        guard case .failure(let stringFailure) = stringLimit else {
            Issue.record("Expected a typed string limit failure"); return
        }
        #expect(stringFailure.category == .resourceLimit)
        #expect(try stringFailure.sqlDiagnostic()?.sqlState == "54000")
        let stringAbsent = try await invoke(fixture, callID: 5,
            sql: "SELECT title FROM \"RuntimeVerificationDocument\" WHERE id = 'string-limit'").get()
        #expect(try rows(stringAbsent).rowCount == 0)
    }

    @Test("A new session reopens committed state after authoritative shutdown", .timeLimit(.minutes(1)))
    func referenceReopenAfterShutdown() async throws {
        let storage = InMemoryCloudflareDurableObjectStorageClient()
        let initial = try makeRuntime(storage: storage)
        await initial.runtime.start(callID: 1)
        _ = try await invoke(initial, callID: 2, sql: """
            INSERT INTO "RuntimeVerificationDocument" (id, title) VALUES ('reopen', 'committed');
            """).get()
        await initial.runtime.shutdown(callID: 3)
        #expect(initial.completion.completion(callID: 3)?.status == .success)
        let reopened = try makeRuntime(storage: storage)
        defer { await reopened.runtime.shutdown(callID: 99) }
        await reopened.runtime.start(callID: 1)
        let result = try await invoke(reopened, callID: 2,
            sql: "SELECT title FROM \"RuntimeVerificationDocument\" WHERE id = 'reopen'").get()
        var iterator = try rows(result).makeRowIterator()
        #expect(try iterator.next()?.values == [.primitive(.string("committed"))])
        #expect(try iterator.next() == nil)
    }

    private typealias Fixture = (runtime: CloudflareDatabaseRuntime, completion: RecordingCloudflareDatabaseCompletion)

    private func makeRuntime(maximumFrameBytes: Int = 4_096,
        storage: InMemoryCloudflareDurableObjectStorageClient = .init()) throws -> Fixture {
        let completion = RecordingCloudflareDatabaseCompletion()
        let limits = CloudflareDatabaseRuntimeLimits.default
        #expect(maximumFrameBytes <= limits.maximumResponseBytes)
        let runtime = CloudflareDatabaseRuntime(
            application: try RuntimeVerificationApplication(sqlFrameByteLimit: maximumFrameBytes),
            storageClient: storage, monotonicClock: SystemStorageClock(),
            wallClock: FixedCloudflareTestWallClock(),
            completion: CloudflareDatabaseCompletionChannel(completion: completion), limits: limits)
        return (runtime, completion)
    }

    private func invoke(_ fixture: Fixture, callID: UInt32, sql: String,
        parameters: [QueryParameter] = [], budget: ExecutionBudget = ExecutionBudget())
        async throws -> Result<SQLExecuteOperation.Response, RemoteOperationError> {
        let bytes = try requestBytes(callID: callID, sql: sql, parameters: parameters, budget: budget)
        await fixture.runtime.invoke(callID: callID,
            contextBytes: ByteString(utf8: RuntimeVerificationSession.principalIdentifier), requestBytes: bytes)
        let completion = try #require(fixture.completion.completion(callID: callID))
        #expect(completion.status == .success)
        return try DatabaseWireDecoder().decodeResponse(DatabaseOperationCatalog.sqlExecute,
            from: completion.payload, matching: UInt64(callID))
    }

    private func requestBytes(callID: UInt32, sql: String, parameters: [QueryParameter] = [],
        budget: ExecutionBudget = ExecutionBudget()) throws -> ByteString {
        let request = SQLExecuteOperation.Request(input: .text(sql), parameters: parameters, budget: budget)
        #if CLOUDFLARE_TEST_MULTI_BASE
        return try DatabaseWireEncoder().encodeRequest(DatabaseOperationCatalog.sqlExecute,
            requestID: UInt64(callID), target: .base(try Base.ID("runtime-verification")), request: request)
        #else
        return try DatabaseWireEncoder().encodeRequest(DatabaseOperationCatalog.sqlExecute,
            requestID: UInt64(callID), request: request)
        #endif
    }

    private func rows(_ response: SQLExecuteOperation.Response) throws -> SQLExecuteOperation.Rows {
        guard response.results.count == 1, case .rows(let rows) = response.results[0] else {
            throw RuntimeVerificationError.invalidApplicationRequest
        }
        return rows
    }
}
