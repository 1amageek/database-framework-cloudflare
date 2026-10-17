import CloudflareDatabase
import CloudflareDurableObjectStorageTesting
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit
import DatabaseTypes
import StorageKit
import StorageKitSystemClock
import Testing

@Suite("Cloudflare application database runtime")
struct CloudflareDatabaseRuntimeTests {
    @Test("application protocol persists and reads through DBContainer")
    func persistsAndReadsThroughApplicationSession() async throws {
        try await verifySQLDatabaseNameForwarding()
        let completion = RecordingCloudflareDatabaseCompletion()
        let runtime = try makeRuntime(completion: completion)

        await runtime.start(callID: 1)
        #expect(completion.completion(callID: 1)?.status == .success)

        await runtime.invoke(
            callID: 2,
            contextBytes: bytes("runtime-verification"),
            requestBytes: bytes("put:Cloudflare runtime")
        )
        let write = try #require(completion.completion(callID: 2))
        #expect(write.status == .success)
        #expect(string(from: write.payload) == "Cloudflare runtime")

        await runtime.invoke(
            callID: 3,
            contextBytes: bytes("runtime-verification"),
            requestBytes: bytes("get")
        )
        let read = try #require(completion.completion(callID: 3))
        #expect(read.status == .success)
        #expect(string(from: read.payload) == "Cloudflare runtime")

        await runtime.shutdown(callID: 4)
        #expect(completion.completion(callID: 4)?.status == .success)
    }

    @Test("application failures remain non-terminal")
    func applicationFailureDoesNotPoisonRuntime() async throws {
        let completion = RecordingCloudflareDatabaseCompletion()
        let runtime = try makeRuntime(completion: completion)
        await runtime.start(callID: 10)

        await runtime.invoke(
            callID: 11,
            contextBytes: bytes("runtime-verification"),
            requestBytes: bytes("unknown")
        )
        #expect(completion.completion(callID: 11)?.status == .applicationFailed)

        await runtime.invoke(
            callID: 12,
            contextBytes: bytes("runtime-verification"),
            requestBytes: bytes("cancel")
        )
        #expect(completion.completion(callID: 12)?.status == .cancelled)

        await runtime.invoke(
            callID: 13,
            contextBytes: bytes("runtime-verification"),
            requestBytes: bytes("echo:still-alive")
        )
        let response = try #require(completion.completion(callID: 13))
        #expect(response.status == .success)
        #expect(string(from: response.payload) == "still-alive")

        await runtime.shutdown(callID: 14)
    }

    @Test("opaque context is interpreted only by the application")
    func applicationOwnsContextInterpretation() async throws {
        let completion = RecordingCloudflareDatabaseCompletion()
        let runtime = try makeRuntime(completion: completion)
        await runtime.start(callID: 20)

        await runtime.invoke(
            callID: 21,
            contextBytes: bytes("untrusted-principal"),
            requestBytes: bytes("echo:secret")
        )
        #expect(completion.completion(callID: 21)?.status == .applicationFailed)

        await runtime.shutdown(callID: 22)
    }

    @Test("lifecycle and payload failures stay typed at the host boundary")
    func enforcesLifecycleAndPayloadLimits() async throws {
        let completion = RecordingCloudflareDatabaseCompletion()
        let limits = try CloudflareDatabaseRuntimeLimits(
            maximumContextBytes: 4,
            maximumRequestBytes: 4,
            maximumResponseBytes: 4,
            maximumErrorBytes: 256,
            maximumPendingInvocations: 4
        )
        let runtime = try makeRuntime(
            completion: completion,
            limits: limits
        )

        await runtime.invoke(
            callID: 30,
            contextBytes: bytes("ctx"),
            requestBytes: bytes("get")
        )
        #expect(completion.completion(callID: 30)?.status == .notStarted)

        await runtime.start(callID: 31)
        await runtime.invoke(
            callID: 32,
            contextBytes: bytes("large"),
            requestBytes: bytes("get")
        )
        #expect(completion.completion(callID: 32)?.status == .contextTooLarge)

        await runtime.invoke(
            callID: 33,
            contextBytes: bytes("ctx"),
            requestBytes: bytes("large")
        )
        #expect(completion.completion(callID: 33)?.status == .requestTooLarge)

        await runtime.shutdown(callID: 34)
        await runtime.invoke(
            callID: 35,
            contextBytes: bytes("ctx"),
            requestBytes: bytes("get")
        )
        #expect(completion.completion(callID: 35)?.status == .notStarted)
    }

    @Test("application alarm handling is explicit and unavailable handling is non-terminal")
    func handlesApplicationAlarmsAndReportsUnavailableHandling() async throws {
        let completion = RecordingCloudflareDatabaseCompletion()
        let runtime = try makeRuntime(completion: completion)
        await runtime.start(callID: 40)

        await runtime.alarm(callID: 41)
        #expect(completion.completion(callID: 41)?.status == .alarmFailed)

        await runtime.invoke(
            callID: 42,
            contextBytes: bytes("runtime-verification"),
            requestBytes: bytes("echo:available")
        )
        #expect(completion.completion(callID: 42)?.status == .success)
        await runtime.shutdown(callID: 43)

        let alarmApplication = try AlarmHandlingRuntimeApplication()
        let alarmCompletion = RecordingCloudflareDatabaseCompletion()
        let alarmRuntime = CloudflareDatabaseRuntime(
            application: alarmApplication,
            storageClient: InMemoryCloudflareDurableObjectStorageClient(),
            monotonicClock: SystemStorageClock(),
            wallClock: FixedCloudflareTestWallClock(),
            completion: CloudflareDatabaseCompletionChannel(
                completion: alarmCompletion
            )
        )
        await alarmRuntime.start(callID: 44)
        await alarmRuntime.alarm(callID: 45)
        #expect(alarmCompletion.completion(callID: 45)?.status == .success)
        #expect(await alarmApplication.handledAlarmCount() == 1)
        await alarmRuntime.shutdown(callID: 46)
    }

    @Test("startup failures release storage and readiness remains retryable")
    func releasesStorageAndRetriesStartupFailure() async throws {
        let completion = RecordingCloudflareDatabaseCompletion()
        let runtime = CloudflareDatabaseRuntime(
            application: try RuntimeVerificationApplication(),
            storageClient: FailingOnceReadinessClient(),
            monotonicClock: SystemStorageClock(),
            wallClock: FixedCloudflareTestWallClock(),
            completion: CloudflareDatabaseCompletionChannel(
                completion: completion
            )
        )

        await runtime.start(callID: 50)
        #expect(completion.completion(callID: 50)?.status == .startupFailed)
        await runtime.start(callID: 51)
        #expect(completion.completion(callID: 51)?.status == .success)
        await runtime.shutdown(callID: 52)

        let storageFailureCompletion = RecordingCloudflareDatabaseCompletion()
        let storageFailureRuntime = CloudflareDatabaseRuntime(
            application: AnyCloudflareDatabaseApplication(
                try RuntimeVerificationApplication()
            ),
            storageClient: InMemoryCloudflareDurableObjectStorageClient(),
            monotonicClock: SystemStorageClock(),
            wallClock: FixedCloudflareTestWallClock(),
            completion: CloudflareDatabaseCompletionChannel(
                completion: storageFailureCompletion
            ),
            createStorageEngine: { _ in
                throw StorageError(
                    code: .incompatibleStorageLayout,
                    operation: .open,
                    backend: .cloudflareDurableObject,
                    message: "private storage key",
                    underlyingDescription: "private credential"
                )
            }
        )
        await storageFailureRuntime.start(callID: 55)
        let storageFailure = try #require(
            storageFailureCompletion.completion(callID: 55)
        )
        #expect(storageFailure.status == .startupFailed)
        #expect(string(from: storageFailure.payload) ==
            "Database runtime startup failed: storage code=incompatible_storage_layout backend=cloudflare_durable_object operation=open")
        await storageFailureRuntime.shutdown(callID: 56)

        let preOpenProbe = ShutdownRecordingStorageEngine.Probe()
        let preOpenEngine = try await ShutdownRecordingStorageEngine(
            configuration: .init(
                probe: preOpenProbe,
                rejectsTransactionCreation: true
            )
        )
        let preOpenCompletion = RecordingCloudflareDatabaseCompletion()
        let preOpenRuntime = CloudflareDatabaseRuntime(
            application: AnyCloudflareDatabaseApplication(
                try StartupFailureApplication(
                    rejectsSessionCreation: false
                )
            ),
            storageClient: InMemoryCloudflareDurableObjectStorageClient(),
            monotonicClock: SystemStorageClock(),
            wallClock: FixedCloudflareTestWallClock(),
            completion: CloudflareDatabaseCompletionChannel(
                completion: preOpenCompletion
            ),
            createStorageEngine: { _ in preOpenEngine }
        )
        await preOpenRuntime.start(callID: 53)
        #expect(preOpenCompletion.completion(callID: 53)?.status == .startupFailed)
        #expect(
            preOpenProbe.shutdownState
                == .init(
                    wasRequested: true,
                    didComplete: true
                )
        )

        let postOpenProbe = ShutdownRecordingStorageEngine.Probe()
        let postOpenEngine = try await ShutdownRecordingStorageEngine(
            configuration: .init(
                probe: postOpenProbe,
                rejectsTransactionCreation: false
            )
        )
        let postOpenCompletion = RecordingCloudflareDatabaseCompletion()
        let postOpenRuntime = CloudflareDatabaseRuntime(
            application: AnyCloudflareDatabaseApplication(
                try StartupFailureApplication(
                    rejectsSessionCreation: true
                )
            ),
            storageClient: InMemoryCloudflareDurableObjectStorageClient(),
            monotonicClock: SystemStorageClock(),
            wallClock: FixedCloudflareTestWallClock(),
            completion: CloudflareDatabaseCompletionChannel(
                completion: postOpenCompletion
            ),
            createStorageEngine: { _ in postOpenEngine }
        )
        await postOpenRuntime.start(callID: 54)
        #expect(postOpenCompletion.completion(callID: 54)?.status == .startupFailed)
        #expect(
            postOpenProbe.shutdownState
                == .init(
                    wasRequested: true,
                    didComplete: true
                )
        )
    }

    @Test("command FIFO bounds admission and drains before shutdown")
    func commandFIFOAndShutdownDrain() async throws {
        let application = try SuspendedRuntimeVerificationApplication()
        let completion = RecordingCloudflareDatabaseCompletion()
        let channel = CloudflareDatabaseRuntimeCommandChannel(
            application: application,
            storageClient: InMemoryCloudflareDurableObjectStorageClient(),
            monotonicClock: SystemStorageClock(),
            wallClock: FixedCloudflareTestWallClock(),
            completion: CloudflareDatabaseCompletionChannel(
                completion: completion
            ),
            limits: try CloudflareDatabaseRuntimeLimits(
                maximumContextBytes: 1_024,
                maximumRequestBytes: 1_024,
                maximumResponseBytes: 1_024,
                maximumErrorBytes: 256,
                maximumPendingInvocations: 2
            )
        )

        channel.start(callID: 60)
        await application.waitUntilConfigurationIsRequested()
        channel.invoke(
            callID: 61,
            contextBytes: bytes("runtime-verification"),
            requestBytes: bytes("echo:queued-after-start")
        )
        await application.releaseConfiguration()

        #expect(
            try await completion.waitForCompletion(callID: 60).status
                == .success
        )
        let startupQueued = try await completion.waitForCompletion(callID: 61)
        #expect(startupQueued.status == .success)
        #expect(string(from: startupQueued.payload) == "queued-after-start")

        channel.invoke(
            callID: 62,
            contextBytes: bytes("runtime-verification"),
            requestBytes: bytes("suspend")
        )
        await application.waitUntilInvocationStarts()
        channel.invoke(
            callID: 63,
            contextBytes: bytes("runtime-verification"),
            requestBytes: bytes("echo:queued-before-shutdown")
        )
        channel.invoke(
            callID: 64,
            contextBytes: bytes("runtime-verification"),
            requestBytes: bytes("echo:over-capacity")
        )
        #expect(
            try await completion.waitForCompletion(callID: 64).status
                == .queueCapacityExceeded
        )

        channel.shutdown(callID: 65)
        channel.shutdown(callID: 67)
        channel.invoke(
            callID: 66,
            contextBytes: bytes("runtime-verification"),
            requestBytes: bytes("echo:after-shutdown")
        )
        #expect(
            try await completion.waitForCompletion(callID: 66).status
                == .notStarted
        )
        #expect(
            try await completion.waitForCompletion(callID: 67).status
                == .notStarted
        )

        await application.releaseInvocation()
        let active = try await completion.waitForCompletion(callID: 62)
        #expect(active.status == .success)
        #expect(string(from: active.payload) == "released")
        let queued = try await completion.waitForCompletion(callID: 63)
        #expect(queued.status == .success)
        #expect(string(from: queued.payload) == "queued-before-shutdown")
        #expect(
            try await completion.waitForCompletion(callID: 65).status
                == .success
        )
        await application.waitUntilSessionShutdown()
    }

    private func verifySQLDatabaseNameForwarding() async throws {
        let application = try RuntimeVerificationApplication()
        let original = try await application.configuration
        for sqlName in [String?("application-sql-database"), nil] {
            #if CLOUDFLARE_TEST_MULTI_BASE
            let configurations = [
                CloudflareDatabaseConfiguration(partitionIdentity: original.partitionIdentity,
                    storageLayout: original.storageLayout, schema: original.declaredSchema,
                    runtimeConfiguration: original.runtimeConfiguration, security: original.security,
                    databaseName: "diagnostic-name", sqlDatabaseName: sqlName),
                CloudflareDatabaseConfiguration(partitionIdentity: original.partitionIdentity,
                    storageLayout: original.storageLayout, schema: original.declaredSchema,
                    migrationPlan: RuntimeVerificationMigrationPlan.self,
                    runtimeConfiguration: original.runtimeConfiguration, security: original.security,
                    databaseName: "diagnostic-name", sqlDatabaseName: sqlName),
            ]
            #else
            let configurations = [
                CloudflareDatabaseConfiguration(partitionIdentity: original.partitionIdentity,
                    schema: original.declaredSchema, runtimeConfiguration: original.runtimeConfiguration,
                    security: original.security, databaseName: "diagnostic-name", sqlDatabaseName: sqlName),
                CloudflareDatabaseConfiguration(partitionIdentity: original.partitionIdentity,
                    schema: original.declaredSchema, migrationPlan: RuntimeVerificationMigrationPlan.self,
                    runtimeConfiguration: original.runtimeConfiguration, security: original.security,
                    databaseName: "diagnostic-name", sqlDatabaseName: sqlName),
            ]
            #endif
            for configuration in configurations {
                #expect(configuration.sqlDatabaseName == sqlName)
                #expect(configuration.databaseName == "diagnostic-name")
                let engine = InMemoryEngine(configuration: .init())
                let container: DBContainer
                #if CLOUDFLARE_TEST_MULTI_BASE
                let layout = configuration.storageLayout
                let topology = try DatabaseStorageTopology(controlDomainID: layout.domainID,
                    domains: [DatabaseStorageDomain(id: layout.domainID, rootPath: layout.domainRootPath,
                        storageEngine: engine)],
                    placements: [DatabaseStoragePlacement(id: layout.placementID, domainID: layout.domainID)],
                    defaultPlacementID: layout.placementID)
                container = try await configuration.open(storageTopology: topology,
                    monotonicClock: SystemStorageClock(), wallClock: FixedCloudflareTestWallClock())
                #else
                container = try await configuration.open(storageEngine: engine, databaseRootPath: [],
                    monotonicClock: SystemStorageClock(), wallClock: FixedCloudflareTestWallClock())
                #endif
                defer { await container.shutdown() }
                #expect(container.configuration.sqlDatabaseName == sqlName)
                #expect(container.configuration.name == "diagnostic-name")
                let session = try await application.makeSession(for: container)
                defer { await session.shutdown() }
                let authorization = AuthorizationContext.authenticated(Principal(
                    identifier: RuntimeVerificationSession.principalIdentifier, roles: ["admin"]))
                let context: DatabaseContext
                #if CLOUDFLARE_TEST_MULTI_BASE
                context = container.session(authorization: authorization)
                    .base(try Base.ID("runtime-verification")).newContext()
                #else
                context = container.newContext(authorization: authorization)
                #endif
                let query = SelectQuery(projection: [.expression(.function(FunctionCall(
                    name: "current_database", arguments: [])))], source: .values([[]]))
                if let sqlName {
                    let response = try await context.query(query)
                    #expect(response.rows.map(\.values) == [[.primitive(.string(sqlName))]])
                } else {
                    await #expect(throws: SQLSessionEvaluationError.missingDatabaseIdentity) {
                        try await context.query(query)
                    }
                }
            }
        }
    }

    private func makeRuntime(
        completion: RecordingCloudflareDatabaseCompletion,
        limits: CloudflareDatabaseRuntimeLimits = .default
    ) throws -> CloudflareDatabaseRuntime {
        CloudflareDatabaseRuntime(
            application: try RuntimeVerificationApplication(),
            storageClient: InMemoryCloudflareDurableObjectStorageClient(),
            monotonicClock: SystemStorageClock(),
            wallClock: FixedCloudflareTestWallClock(),
            completion: CloudflareDatabaseCompletionChannel(
                completion: completion
            ),
            limits: limits
        )
    }

    private func bytes(_ value: String) -> ByteString {
        ByteString(Array(value.utf8))
    }

    private func string(from bytes: ByteString) -> String {
        bytes.withUnsafeBytes { buffer in
            String(decoding: buffer, as: UTF8.self)
        }
    }
}
