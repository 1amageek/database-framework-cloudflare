import CloudflareDurableObjectStorage
import CloudflareDurableObjectStorageWire
import DatabaseEngine
#if !arch(wasm32)
import DatabaseFoundation
#endif
import DatabaseKit
import DatabaseWireRuntime
import DatabaseTypes

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
    }

    private let application: AnyDatabaseApplication
    private let partitionIdentity: StoragePartitionIdentity
    private let storageLimits: CloudflareDurableObjectLimits
    private let storageLayout: CloudflareDatabaseStorageLayout
    private let storageClient: CloudflareDurableObjectStorageClientComposition
    private let jobScheduler: AnyDatabaseJobScheduler
    private let jobAuthorizationProvider:
        AnyCloudflareDatabaseJobAuthorizationProvider?
    private let completion: CloudflareDatabaseCompletionChannel
    private let limits: CloudflareDatabaseRuntimeLimits

    private var container: DBContainer?
    private var operationRuntime: DatabaseOperationRuntime?
    private var isStarting = false
    private var isProcessingOperations = false
    private var pendingOperations: [PendingOperation] = []

    public init<
        Application: CloudflareDatabaseApplication,
        StorageClient: CloudflareDurableObjectStorageClient,
        JobScheduler: DatabaseJobScheduler
    >(
        application: Application,
        storageClient: StorageClient,
        jobScheduler: JobScheduler,
        completion: CloudflareDatabaseCompletionChannel,
        limits: CloudflareDatabaseRuntimeLimits = .default
    ) {
        self.application = AnyDatabaseApplication(application)
        self.partitionIdentity = application.partitionIdentity
        self.storageLimits = application.storageLimits
        self.storageLayout = application.storageLayout
        self.storageClient = CloudflareDurableObjectStorageClientComposition(storageClient)
        self.jobScheduler = AnyDatabaseJobScheduler(jobScheduler)
        self.jobAuthorizationProvider = application.jobAuthorizationProvider
        self.completion = completion
        self.limits = limits
    }

    init<
        StorageClient: CloudflareDurableObjectStorageClient,
        JobScheduler: DatabaseJobScheduler
    >(
        application: AnyDatabaseApplication,
        partitionIdentity: StoragePartitionIdentity,
        storageLimits: CloudflareDurableObjectLimits,
        storageLayout: CloudflareDatabaseStorageLayout,
        storageClient: StorageClient,
        jobScheduler: JobScheduler,
        jobAuthorizationProvider:
            AnyCloudflareDatabaseJobAuthorizationProvider? = nil,
        completion: CloudflareDatabaseCompletionChannel,
        limits: CloudflareDatabaseRuntimeLimits = .default
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

    /// Bootstraps the StorageKit engine, application container, and operation runtime.
    public func start(callID: UInt32) async {
        guard callID != 0 else {
            fail(callID: callID, status: .invalidCallID, message: "Call ID must be non-zero")
            return
        }
        guard operationRuntime == nil else {
            fail(callID: callID, status: .alreadyStarted, message: "Database runtime is already started")
            return
        }
        guard !isStarting else {
            fail(callID: callID, status: .startupInProgress, message: "Database runtime startup is in progress")
            return
        }

        isStarting = true
        do {
            let container: DBContainer
            if let existingContainer = self.container {
                container = existingContainer
            } else {
                let definition = try await application.makeContainerDefinition()
                do {
                    try definition.validateCloudflareHostingCapabilities()
                } catch let error {
                    isStarting = false
                    operationRuntime = nil
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
                let storageTopology = try DatabaseStorageTopology(
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
                #else
                let controlDomain = try DatabaseStorageDomain(
                    id: storageLayout.domainID,
                    namespacePath: storageLayout.domainNamespacePath,
                    storageEngine: storageEngine
                )
                let storageTopology = DatabaseStorageTopology(
                    controlDomain: controlDomain
                )
                #endif
                let createdContainer = try await definition.open(
                    storageTopology: storageTopology
                )
                self.container = createdContainer
                container = createdContainer
            }
            let configuration = try await application.makeRuntimeConfiguration(
                for: container
            )
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
            operationRuntime = try await DatabaseOperationRuntime(
                container: container,
                configuration: configuration,
                hostServices: DatabaseHostServices(
                    jobScheduler: jobScheduler,
                    identifierGenerator: identifierGenerator,
                    jobAuthorizationValidator: authorizationValidator
                )
            )
            isStarting = false
            completion.complete(callID: callID, status: .success, payload: [])
        } catch is CancellationError {
            isStarting = false
            fail(callID: callID, status: .cancelled, message: "Database runtime startup was cancelled")
        } catch {
            isStarting = false
            operationRuntime = nil
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
        guard requestBytes.count <= limits.maximumRequestBytes else {
            fail(
                callID: callID,
                status: .requestTooLarge,
                message: "Database request exceeds the runtime limit"
            )
            return
        }
        guard operationRuntime != nil else {
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
        guard operationRuntime != nil else {
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

    private var admittedOperationCount: Int {
        pendingOperations.count + (isProcessingOperations ? 1 : 0)
    }

    private func processPendingOperationsIfNeeded() async {
        guard !isProcessingOperations else {
            return
        }
        isProcessingOperations = true
        while !pendingOperations.isEmpty {
            let operation = pendingOperations.removeFirst()
            guard let operationRuntime else {
                let callID = Self.callID(for: operation)
                fail(
                    callID: callID,
                    status: .notStarted,
                    message: "Database runtime is not started"
                )
                continue
            }
            switch operation {
            case .invocation(let invocation):
                await execute(invocation, using: operationRuntime)
            case .alarm(let callID):
                do {
                    try await operationRuntime.runScheduledWork()
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
            }
        }
        isProcessingOperations = false
    }

    private func execute(
        _ invocation: Invocation,
        using operationRuntime: DatabaseOperationRuntime
    ) async {
        do {
            let responseBytes = try await operationRuntime.execute(
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
        } catch DatabaseEndpointError.invalidRequestFrame {
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

    private static func callID(for operation: PendingOperation) -> UInt32 {
        switch operation {
        case .invocation(let invocation):
            return invocation.callID
        case .alarm(let callID):
            return callID
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
