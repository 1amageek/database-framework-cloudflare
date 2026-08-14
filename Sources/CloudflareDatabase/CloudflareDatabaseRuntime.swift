import CloudflareDurableObjectStorage
import CloudflareDurableObjectStorageWire
import DatabaseEngine
#if !arch(wasm32)
import DatabaseServerFoundation
#endif
import DatabaseKit
import DatabaseServerRuntime
import DatabaseTypes
import DatabaseWire
import StorageKit

/// Persistent, single-entry database runtime owned by one Durable Object.
public actor CloudflareDatabaseRuntime {
    private struct Invocation: Sendable {
        let callID: UInt32
        let requestBytes: ByteString
        let executionContext: DatabaseRequestExecutionContext
    }

    private enum PendingOperation: Sendable {
        case invocation(Invocation)
        case alarm(callID: UInt32)
        case shutdown(callID: UInt32)
    }

    private let application: AnyDatabaseOperationApplication
    private let partitionIdentity: StoragePartitionIdentity
    private let storageLimits: CloudflareDurableObjectLimits
    #if CLOUDFLARE_DATABASE_MULTIPLE_BASES
    private let storageLayout: CloudflareDatabaseStorageLayout
    #endif
    private let storageClient: CloudflareDurableObjectStorageClientComposition
    private let jobScheduler: AnyDatabaseJobScheduler
    private let jobAuthorizationProvider:
        AnyCloudflareDatabaseJobAuthorizationProvider?
    private let completion: CloudflareDatabaseCompletionChannel
    private let limits: CloudflareDatabaseOperationLimits

    private var operationInstance: DatabaseOperationInstance?
    private var wireEndpoint: DatabaseWireEndpoint?
    private var isStarting = false
    private var isShuttingDown = false
    private var isShutDown = false
    private var pendingStartupShutdownCallIDs: [UInt32] = []
    private var isProcessingOperations = false
    private var pendingOperations =
        CloudflareDatabasePendingQueue<PendingOperation>()

    public init<
        Application: CloudflareDatabaseOperationApplication,
        StorageClient: CloudflareDurableObjectStorageClient,
        JobScheduler: DatabaseJobScheduler
    >(
        application: Application,
        storageClient: StorageClient,
        jobScheduler: JobScheduler,
        completion: CloudflareDatabaseCompletionChannel,
        limits: CloudflareDatabaseOperationLimits = .default
    ) {
        self.application = AnyDatabaseOperationApplication(application)
        self.partitionIdentity = application.partitionIdentity
        self.storageLimits = application.storageLimits
        #if CLOUDFLARE_DATABASE_MULTIPLE_BASES
        self.storageLayout = application.storageLayout
        #endif
        self.storageClient = CloudflareDurableObjectStorageClientComposition(storageClient)
        self.jobScheduler = AnyDatabaseJobScheduler(jobScheduler)
        self.jobAuthorizationProvider = application.jobAuthorizationProvider
        self.completion = completion
        self.limits = limits
    }

    #if CLOUDFLARE_DATABASE_MULTIPLE_BASES
    init<
        StorageClient: CloudflareDurableObjectStorageClient,
        JobScheduler: DatabaseJobScheduler
    >(
        application: AnyDatabaseOperationApplication,
        partitionIdentity: StoragePartitionIdentity,
        storageLimits: CloudflareDurableObjectLimits,
        storageLayout: CloudflareDatabaseStorageLayout,
        storageClient: StorageClient,
        jobScheduler: JobScheduler,
        jobAuthorizationProvider:
            AnyCloudflareDatabaseJobAuthorizationProvider? = nil,
        completion: CloudflareDatabaseCompletionChannel,
        limits: CloudflareDatabaseOperationLimits = .default
    ) {
        self.application = application
        self.partitionIdentity = partitionIdentity
        self.storageLimits = storageLimits
        self.storageLayout = storageLayout
        self.storageClient = CloudflareDurableObjectStorageClientComposition(
            storageClient
        )
        self.jobScheduler = AnyDatabaseJobScheduler(jobScheduler)
        self.jobAuthorizationProvider = jobAuthorizationProvider
        self.completion = completion
        self.limits = limits
    }
    #else
    init<
        StorageClient: CloudflareDurableObjectStorageClient,
        JobScheduler: DatabaseJobScheduler
    >(
        application: AnyDatabaseOperationApplication,
        partitionIdentity: StoragePartitionIdentity,
        storageLimits: CloudflareDurableObjectLimits,
        storageClient: StorageClient,
        jobScheduler: JobScheduler,
        jobAuthorizationProvider:
            AnyCloudflareDatabaseJobAuthorizationProvider? = nil,
        completion: CloudflareDatabaseCompletionChannel,
        limits: CloudflareDatabaseOperationLimits = .default
    ) {
        self.application = application
        self.partitionIdentity = partitionIdentity
        self.storageLimits = storageLimits
        self.storageClient = CloudflareDurableObjectStorageClientComposition(
            storageClient
        )
        self.jobScheduler = AnyDatabaseJobScheduler(jobScheduler)
        self.jobAuthorizationProvider = jobAuthorizationProvider
        self.completion = completion
        self.limits = limits
    }
    #endif

    /// Bootstraps the StorageKit engine, application container, and operation runtime.
    public func start(callID: UInt32) async {
        guard callID != 0 else {
            fail(callID: callID, status: .invalidCallID, message: "Call ID must be non-zero")
            return
        }
        guard !isShuttingDown, !isShutDown else {
            fail(callID: callID, status: .notStarted, message: "Database runtime is shutting down")
            return
        }
        guard operationInstance == nil else {
            fail(callID: callID, status: .alreadyStarted, message: "Database runtime is already started")
            return
        }
        guard !isStarting else {
            fail(callID: callID, status: .startupInProgress, message: "Database runtime startup is in progress")
            return
        }

        isStarting = true
        let requestWireLimits: DatabaseWireLimits
        let responseWireLimits: DatabaseWireLimits
        do {
            requestWireLimits = try limits.requestWireLimits()
            responseWireLimits = try limits.responseWireLimits()
        } catch {
            isStarting = false
            fail(
                callID: callID,
                status: .startupFailed,
                message: "Database Wire limits are invalid"
            )
            return
        }
        do {
            let definition = try await application.makeContainerDefinition()
            do {
                try definition.validateCloudflareHostingCapabilities()
            } catch let error {
                isStarting = false
                operationInstance = nil
                wireEndpoint = nil
                if isShuttingDown {
                    isShutDown = true
                    completePendingStartupShutdowns()
                }
                fail(
                    callID: callID,
                    status: .startupFailed,
                    message: error.description
                )
                return
            }
            let storageEngine = try await CloudflareDurableObjectStorageEngine(
                configuration: CloudflareDurableObjectStorageConfiguration(
                    partitionIdentity: partitionIdentity,
                    client: storageClient,
                    limits: storageLimits,
                    monotonicClock: CloudflareDatabaseMonotonicClock()
                )
            )
            #if CLOUDFLARE_DATABASE_MULTIPLE_BASES
            let storageTopology: DatabaseStorageTopology
            do {
                storageTopology = try DatabaseStorageTopology(
                    controlDomainID: storageLayout.domainID,
                    domains: [
                        try DatabaseStorageDomain(
                            id: storageLayout.domainID,
                            namespacePath: storageLayout.domainNamespacePath,
                            storageEngine: storageEngine
                        )
                    ],
                    placements: [
                        try DatabaseStoragePlacement(
                            id: storageLayout.placementID,
                            domainID: storageLayout.domainID,
                            path: storageLayout.baseNamespacePath
                        )
                    ],
                    defaultPlacementID: storageLayout.placementID
                )
            } catch {
                // Topology construction has not transferred engine ownership
                // to DBContainer, so this host remains the authoritative owner.
                storageEngine.requestShutdown()
                await storageEngine.waitUntilShutdown()
                throw error
            }
            // DatabaseContainerDefinition claims the complete topology at this
            // call boundary and owns cleanup on both success and failure.
            let container = try await definition.open(
                storageTopology: storageTopology
            )
            #else
            // The Durable Object already identifies one isolated database.
            // The trait-free runtime transfers its single engine directly and
            // carries no Base topology or placement metadata.
            let container = try await definition.open(
                storageEngine: storageEngine,
                databaseRoot: Subspace()
            )
            #endif
            let configuration: DatabaseOperationConfiguration
            do {
                configuration = try await application.makeOperationConfiguration(
                    for: container
                )
            } catch {
                await container.shutdown()
                throw error
            }
            let authorizationValidator = jobAuthorizationProvider.map {
                AnyDatabaseJobAuthorizationValidator($0)
            }
            #if arch(wasm32)
            let identifierGenerator = AnyDatabaseUUIDGenerator(
                CloudflareDatabaseUUIDGenerator()
            )
            #else
            let identifierGenerator = AnyDatabaseUUIDGenerator(
                RandomDatabaseUUIDGenerator()
            )
            #endif
            let createdInstance = try await DatabaseOperationInstance.open(
                container: container,
                configuration: configuration,
                hostServices: DatabaseOperationHostServices(
                    jobScheduler: jobScheduler,
                    identifierGenerator: identifierGenerator,
                    jobAuthorizationValidator: authorizationValidator
                )
            )
            guard !isShuttingDown else {
                await createdInstance.shutdown()
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
            operationInstance = createdInstance
            wireEndpoint = DatabaseWireEndpoint(
                instance: createdInstance,
                requestLimits: requestWireLimits,
                responseLimits: responseWireLimits
            )
            isStarting = false
            completion.complete(callID: callID, status: .success, payload: [])
        } catch is CancellationError {
            isStarting = false
            if isShuttingDown {
                isShutDown = true
                completePendingStartupShutdowns()
            }
            fail(callID: callID, status: .cancelled, message: "Database runtime startup was cancelled")
        } catch {
            isStarting = false
            operationInstance = nil
            wireEndpoint = nil
            if isShuttingDown {
                isShutDown = true
                completePendingStartupShutdowns()
            }
            fail(
                callID: callID,
                status: .startupFailed,
                message: "Database runtime startup failed"
            )
        }
    }

    /// Enqueues one DatabaseWire request without allowing concurrent runtime entry.
    public func invoke(
        callID: UInt32,
        requestBytes: ByteString,
        authorization: AuthorizationContext
    ) async {
        guard callID != 0 else {
            fail(callID: callID, status: .invalidCallID, message: "Call ID must be non-zero")
            return
        }
        guard !isShuttingDown, !isShutDown else {
            fail(callID: callID, status: .notStarted, message: "Database runtime is shutting down")
            return
        }
        guard requestBytes.count <= limits.maximumRequestBytes else {
            fail(
                callID: callID,
                status: .requestTooLarge,
                message: "Database request exceeds the runtime limit"
            )
            return
        }
        guard operationInstance != nil, wireEndpoint != nil else {
            fail(callID: callID, status: .notStarted, message: "Database runtime is not started")
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

        let jobAuthorizationReference: DatabaseJobAuthorizationReference?
        do {
            jobAuthorizationReference = try jobAuthorizationProvider?
                .reference(for: authorization)
        } catch {
            fail(
                callID: callID,
                status: .runtimeFailed,
                message: "Database job authorization reference is invalid"
            )
            return
        }
        pendingOperations.append(
            .invocation(
                Invocation(
                    callID: callID,
                    requestBytes: requestBytes,
                    executionContext: DatabaseRequestExecutionContext(
                        authorization: authorization,
                        jobAuthorizationReference: jobAuthorizationReference
                    )
                )
            )
        )
        await processPendingOperationsIfNeeded()
    }

    /// Enqueues one Durable Object alarm without allowing concurrent runtime entry.
    public func alarm(callID: UInt32) async {
        guard callID != 0 else {
            fail(callID: callID, status: .invalidCallID, message: "Call ID must be non-zero")
            return
        }
        guard !isShuttingDown, !isShutDown else {
            fail(callID: callID, status: .notStarted, message: "Database runtime is shutting down")
            return
        }
        guard operationInstance != nil else {
            fail(callID: callID, status: .notStarted, message: "Database runtime is not started")
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

    /// Stops admission, drains FIFO work, and waits for authoritative storage
    /// shutdown before completing the host call.
    public func shutdown(callID: UInt32) async {
        guard callID != 0 else {
            fail(callID: callID, status: .invalidCallID, message: "Call ID must be non-zero")
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
        guard operationInstance != nil else {
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
                guard operationInstance != nil, let wireEndpoint else {
                    fail(
                        callID: invocation.callID,
                        status: .notStarted,
                        message: "Database runtime is not started"
                    )
                    continue
                }
                await execute(invocation, using: wireEndpoint)
            case .alarm(let callID):
                guard let operationInstance else {
                    fail(
                        callID: callID,
                        status: .notStarted,
                        message: "Database runtime is not started"
                    )
                    continue
                }
                do {
                    try await operationInstance.runScheduledWork()
                    completion.complete(
                        callID: callID,
                        status: .success,
                        payload: []
                    )
                } catch is CancellationError {
                    fail(
                        callID: callID,
                        status: .cancelled,
                        message: "Database alarm execution was cancelled"
                    )
                } catch {
                    fail(
                        callID: callID,
                        status: .scheduledWorkFailed,
                        message: ScheduledWorkDiagnostic.message(for: error)
                    )
                }
            case .shutdown(let callID):
                if let operationInstance {
                    await operationInstance.shutdown()
                }
                self.operationInstance = nil
                wireEndpoint = nil
                isShutDown = true
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
        using wireEndpoint: DatabaseWireEndpoint
    ) async {
        do {
            let responseBytes = try await wireEndpoint.execute(
                invocation.requestBytes,
                context: invocation.executionContext
            )
            guard responseBytes.count <= limits.maximumResponseBytes else {
                fail(
                    callID: invocation.callID,
                    status: .responseTooLarge,
                    message: "Database response exceeds the runtime limit"
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
                message: "Database invocation was cancelled"
            )
        } catch DatabaseServerFrameError.invalidRequestFrame {
            fail(
                callID: invocation.callID,
                status: .invalidRequestFrame,
                message: "Database request frame is invalid"
            )
        } catch {
            fail(
                callID: invocation.callID,
                status: .runtimeFailed,
                message: "Database runtime failed"
            )
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
