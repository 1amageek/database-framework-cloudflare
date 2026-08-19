import CloudflareDurableObjectStorage
import CloudflareDurableObjectStorageWire
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseTypes
import StorageKit

/// Persistent, single-entry application database owned by one Durable Object.
public actor CloudflareDatabaseRuntime {
    private struct Invocation: Sendable {
        let callID: UInt32
        let contextBytes: ByteString
        let requestBytes: ByteString
    }

    private enum PendingOperation: Sendable {
        case invocation(Invocation)
        case alarm(callID: UInt32)
        case shutdown(callID: UInt32)
    }

    private let application: AnyCloudflareDatabaseApplication
    private let storageClient: CloudflareDurableObjectStorageClientComposition
    private let monotonicClock: any StorageMonotonicClock
    private let wallClock: any WallClock
    private let completion: CloudflareDatabaseCompletionChannel
    private let limits: CloudflareDatabaseRuntimeLimits
    private let createStorageEngine:
        @Sendable (
            CloudflareDurableObjectStorageConfiguration
        ) async throws -> any StorageEngine

    private var container: DBContainer?
    private var session: AnyCloudflareDatabaseSession?
    private var isStarting = false
    private var isShuttingDown = false
    private var isShutDown = false
    private var pendingStartupShutdownCallIDs: [UInt32] = []
    private var isProcessingOperations = false
    private var pendingOperations =
        CloudflareDatabasePendingQueue<PendingOperation>()

    public init<
        Application: CloudflareDatabaseApplication,
        StorageClient: CloudflareDurableObjectStorageClient,
        MonotonicClock: StorageMonotonicClock,
        AbsoluteClock: WallClock
    >(
        application: Application,
        storageClient: StorageClient,
        monotonicClock: MonotonicClock,
        wallClock: AbsoluteClock,
        completion: CloudflareDatabaseCompletionChannel,
        limits: CloudflareDatabaseRuntimeLimits = .default
    ) {
        self.application = AnyCloudflareDatabaseApplication(application)
        self.storageClient = CloudflareDurableObjectStorageClientComposition(
            storageClient
        )
        self.monotonicClock = monotonicClock
        self.wallClock = wallClock
        self.completion = completion
        self.limits = limits
        self.createStorageEngine = { configuration in
            try await CloudflareDurableObjectStorageEngine(
                configuration: configuration
            )
        }
    }

    package init<
        StorageClient: CloudflareDurableObjectStorageClient
    >(
        application: AnyCloudflareDatabaseApplication,
        storageClient: StorageClient,
        monotonicClock: any StorageMonotonicClock,
        wallClock: any WallClock,
        completion: CloudflareDatabaseCompletionChannel,
        limits: CloudflareDatabaseRuntimeLimits = .default,
        createStorageEngine:
            @escaping @Sendable (
                CloudflareDurableObjectStorageConfiguration
            ) async throws -> any StorageEngine = { configuration in
                try await CloudflareDurableObjectStorageEngine(
                    configuration: configuration
                )
            }
    ) {
        self.application = application
        self.storageClient = CloudflareDurableObjectStorageClientComposition(
            storageClient
        )
        self.monotonicClock = monotonicClock
        self.wallClock = wallClock
        self.completion = completion
        self.limits = limits
        self.createStorageEngine = createStorageEngine
    }

    /// Opens platform storage, DBContainer, and the application session.
    public func start(callID: UInt32) async {
        guard callID != 0 else {
            fail(
                callID: callID,
                status: .invalidCallID,
                message: "Call ID must be non-zero"
            )
            return
        }
        guard !isShuttingDown, !isShutDown else {
            fail(
                callID: callID,
                status: .notStarted,
                message: "Database runtime is shutting down"
            )
            return
        }
        guard session == nil, container == nil else {
            fail(
                callID: callID,
                status: .alreadyStarted,
                message: "Database runtime is already started"
            )
            return
        }
        guard !isStarting else {
            fail(
                callID: callID,
                status: .startupInProgress,
                message: "Database runtime startup is in progress"
            )
            return
        }

        isStarting = true
        do {
            let configuration = try await application.configuration
            try configuration.validateHostingCapabilities()
            let storageEngine = try await createStorageEngine(
                CloudflareDurableObjectStorageConfiguration(
                    partitionIdentity: configuration.partitionIdentity,
                    client: storageClient,
                    limits: configuration.storageLimits,
                    monotonicClock: monotonicClock
                )
            )

            let openedContainer: DBContainer
            #if CLOUDFLARE_DATABASE_MULTI_BASE
            let storageTopology: DatabaseStorageTopology
            do {
                storageTopology = try DatabaseStorageTopology(
                    controlDomainID: configuration.storageLayout.domainID,
                    domains: [
                        try DatabaseStorageDomain(
                            id: configuration.storageLayout.domainID,
                            namespacePath: configuration.storageLayout
                                .domainNamespacePath,
                            storageEngine: storageEngine
                        )
                    ],
                    placements: [
                        try DatabaseStoragePlacement(
                            id: configuration.storageLayout.placementID,
                            domainID: configuration.storageLayout.domainID,
                            path: configuration.storageLayout.baseNamespacePath
                        )
                    ],
                    defaultPlacementID: configuration.storageLayout.placementID
                )
            } catch {
                // Topology construction has not transferred engine ownership.
                storageEngine.requestShutdown()
                await storageEngine.waitUntilShutdown()
                throw error
            }
            openedContainer = try await configuration.open(
                storageTopology: storageTopology,
                monotonicClock: monotonicClock,
                wallClock: wallClock
            )
            #else
            openedContainer = try await configuration.open(
                storageEngine: storageEngine,
                databaseRoot: Subspace(),
                monotonicClock: monotonicClock,
                wallClock: wallClock
            )
            #endif

            let createdSession: AnyCloudflareDatabaseSession
            do {
                createdSession = try await application.makeSession(
                    for: openedContainer
                )
            } catch {
                await openedContainer.shutdown()
                throw error
            }

            guard !isShuttingDown else {
                await createdSession.shutdown()
                await openedContainer.shutdown()
                isStarting = false
                isShutDown = true
                fail(
                    callID: callID,
                    status: .cancelled,
                    message: "Database runtime startup was cancelled by shutdown"
                )
                completePendingStartupShutdowns()
                return
            }

            container = openedContainer
            session = createdSession
            isStarting = false
            completion.complete(callID: callID, status: .success, payload: [])
        } catch is CancellationError {
            finishFailedStartup()
            fail(
                callID: callID,
                status: .cancelled,
                message: "Database runtime startup was cancelled"
            )
        } catch let error as CloudflareDatabaseConfigurationError {
            finishFailedStartup()
            fail(
                callID: callID,
                status: .startupFailed,
                message: error.description
            )
        } catch {
            finishFailedStartup()
            fail(
                callID: callID,
                status: .startupFailed,
                message: "Database runtime startup failed"
            )
        }
    }

    /// Enqueues one opaque application invocation in FIFO order.
    public func invoke(
        callID: UInt32,
        contextBytes: ByteString,
        requestBytes: ByteString
    ) async {
        guard callID != 0 else {
            fail(
                callID: callID,
                status: .invalidCallID,
                message: "Call ID must be non-zero"
            )
            return
        }
        guard !isShuttingDown, !isShutDown, session != nil else {
            fail(
                callID: callID,
                status: .notStarted,
                message: "Database runtime is not started"
            )
            return
        }
        guard contextBytes.count <= limits.maximumContextBytes else {
            fail(
                callID: callID,
                status: .contextTooLarge,
                message: "Application context exceeds the runtime limit"
            )
            return
        }
        guard requestBytes.count <= limits.maximumRequestBytes else {
            fail(
                callID: callID,
                status: .requestTooLarge,
                message: "Application request exceeds the runtime limit"
            )
            return
        }
        guard admittedOperationCount < limits.maximumPendingInvocations else {
            fail(
                callID: callID,
                status: .queueCapacityExceeded,
                message: "Database invocation queue is full"
            )
            return
        }

        pendingOperations.append(
            .invocation(
                Invocation(
                    callID: callID,
                    contextBytes: contextBytes,
                    requestBytes: requestBytes
                )
            )
        )
        await processPendingOperationsIfNeeded()
    }

    /// Enqueues one Durable Object alarm in the same FIFO as invocations.
    public func alarm(callID: UInt32) async {
        guard callID != 0 else {
            fail(
                callID: callID,
                status: .invalidCallID,
                message: "Call ID must be non-zero"
            )
            return
        }
        guard !isShuttingDown, !isShutDown, session != nil else {
            fail(
                callID: callID,
                status: .notStarted,
                message: "Database runtime is not started"
            )
            return
        }
        guard admittedOperationCount < limits.maximumPendingInvocations else {
            fail(
                callID: callID,
                status: .queueCapacityExceeded,
                message: "Database runtime queue is full"
            )
            return
        }

        pendingOperations.append(.alarm(callID: callID))
        await processPendingOperationsIfNeeded()
    }

    /// Drains accepted work, shuts down the session, then shuts down DBContainer.
    public func shutdown(callID: UInt32) async {
        guard callID != 0 else {
            fail(
                callID: callID,
                status: .invalidCallID,
                message: "Call ID must be non-zero"
            )
            return
        }
        if isShutDown {
            completion.complete(callID: callID, status: .success, payload: [])
            return
        }
        if isShuttingDown {
            pendingStartupShutdownCallIDs.append(callID)
            return
        }

        isShuttingDown = true
        if isStarting {
            pendingStartupShutdownCallIDs.append(callID)
            return
        }
        guard session != nil || container != nil else {
            isShutDown = true
            completion.complete(callID: callID, status: .success, payload: [])
            return
        }
        pendingOperations.append(.shutdown(callID: callID))
        await processPendingOperationsIfNeeded()
    }

    private var admittedOperationCount: Int {
        pendingOperations.count + (isProcessingOperations ? 1 : 0)
    }

    private func processPendingOperationsIfNeeded() async {
        guard !isProcessingOperations else {
            return
        }
        isProcessingOperations = true
        while let operation = pendingOperations.popFirst() {
            switch operation {
            case .invocation(let invocation):
                guard let session else {
                    fail(
                        callID: invocation.callID,
                        status: .notStarted,
                        message: "Database runtime is not started"
                    )
                    continue
                }
                await execute(invocation, using: session)
            case .alarm(let callID):
                guard let session else {
                    fail(
                        callID: callID,
                        status: .notStarted,
                        message: "Database runtime is not started"
                    )
                    continue
                }
                do {
                    try await session.handleAlarm()
                    completion.complete(
                        callID: callID,
                        status: .success,
                        payload: []
                    )
                } catch is CancellationError {
                    fail(
                        callID: callID,
                        status: .cancelled,
                        message: "Application alarm handling was cancelled"
                    )
                } catch {
                    fail(
                        callID: callID,
                        status: .alarmFailed,
                        message: "Application alarm handling failed"
                    )
                }
            case .shutdown(let callID):
                await shutDownRuntime()
                completion.complete(
                    callID: callID,
                    status: .success,
                    payload: []
                )
                completePendingStartupShutdowns()
            }
        }
        isProcessingOperations = false
    }

    private func execute(
        _ invocation: Invocation,
        using session: AnyCloudflareDatabaseSession
    ) async {
        do {
            let responseBytes = try await session.respond(
                to: CloudflareDatabaseInvocation(
                    context: invocation.contextBytes,
                    request: invocation.requestBytes
                )
            )
            guard responseBytes.count <= limits.maximumResponseBytes else {
                fail(
                    callID: invocation.callID,
                    status: .responseTooLarge,
                    message: "Application response exceeds the runtime limit"
                )
                return
            }
            completion.complete(
                callID: invocation.callID,
                status: .success,
                payload: responseBytes
            )
        } catch is CancellationError {
            fail(
                callID: invocation.callID,
                status: .cancelled,
                message: "Application invocation was cancelled"
            )
        } catch {
            fail(
                callID: invocation.callID,
                status: .applicationFailed,
                message: "Application invocation failed"
            )
        }
    }

    private func shutDownRuntime() async {
        if let session {
            await session.shutdown()
        }
        if let container {
            await container.shutdown()
        }
        self.session = nil
        self.container = nil
        isShutDown = true
    }

    private func finishFailedStartup() {
        isStarting = false
        session = nil
        container = nil
        if isShuttingDown {
            isShutDown = true
            completePendingStartupShutdowns()
        }
    }

    private func completePendingStartupShutdowns() {
        let callIDs = pendingStartupShutdownCallIDs
        pendingStartupShutdownCallIDs.removeAll(keepingCapacity: false)
        for callID in callIDs {
            completion.complete(
                callID: callID,
                status: .success,
                payload: []
            )
        }
    }

    private func fail(
        callID: UInt32,
        status: CloudflareDatabaseCompletionStatus,
        message: String
    ) {
        completion.complete(
            callID: callID,
            status: status,
            payload: RuntimeFailurePayload.encode(
                message,
                maximumByteCount: limits.maximumErrorBytes
            )
        )
    }
}
