import CloudflareDurableObjectStorage
import CloudflareDurableObjectStorageHostTransport
import CloudflareDurableObjectStorageWire
import DatabaseKit
import DatabaseServerRuntime
import DatabaseTypes
import Synchronization

/// Schedules database runtime lifecycle commands from the synchronous boundary.
public final class CloudflareDatabaseRuntimeCommandChannel: Sendable {
    private struct CommandState: Sendable {
        var isClosing = false
        var pendingCount = 0
        var tail: Task<Void, Never>?
    }

    private enum EnqueueRejection {
        case closing
        case capacity
    }

    private let runtime: CloudflareDatabaseRuntime

    private let completion: CloudflareDatabaseCompletionChannel
    private let limits: CloudflareDatabaseOperationLimits
    private let commandState = Mutex(CommandState())

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
        self.runtime = CloudflareDatabaseRuntime(
            application: application,
            storageClient: storageClient,
            jobScheduler: jobScheduler,
            completion: completion,
            limits: limits
        )
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
        self.runtime = CloudflareDatabaseRuntime(
            application: application,
            partitionIdentity: partitionIdentity,
            storageLimits: storageLimits,
            storageLayout: storageLayout,
            storageClient: storageClient,
            jobScheduler: jobScheduler,
            jobAuthorizationProvider: jobAuthorizationProvider,
            completion: completion,
            limits: limits
        )
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
        self.runtime = CloudflareDatabaseRuntime(
            application: application,
            partitionIdentity: partitionIdentity,
            storageLimits: storageLimits,
            storageClient: storageClient,
            jobScheduler: jobScheduler,
            jobAuthorizationProvider: jobAuthorizationProvider,
            completion: completion,
            limits: limits
        )
        self.completion = completion
        self.limits = limits
    }
    #endif

#if arch(wasm32)
    public convenience init<Application: CloudflareDatabaseOperationApplication>(
        application: Application,
        completion: CloudflareDatabaseCompletionChannel =
            CloudflareDatabaseCompletionChannel(),
        limits: CloudflareDatabaseOperationLimits = .default,
        storageTransportLimits: CloudflareDatabaseStorageTransportLimits = .default
    ) throws {
        let transport = try CloudflareDurableObjectStorageHostTransport(
            maximumRequestBytes: storageTransportLimits.maximumRequestBytes,
            maximumResponseBytes: storageTransportLimits.maximumResponseBytes
        )
        self.init(
            application: application,
            storageClient: CloudflareDurableObjectStorageWireClient(
                transport: transport
            ),
            jobScheduler: CloudflareDatabaseAlarmScheduler(),
            completion: completion,
            limits: limits
        )
    }

    #if CLOUDFLARE_DATABASE_MULTIPLE_BASES
    convenience init(
        application: AnyDatabaseOperationApplication,
        partitionIdentity: StoragePartitionIdentity,
        storageLimits: CloudflareDurableObjectLimits,
        storageLayout: CloudflareDatabaseStorageLayout,
        jobAuthorizationProvider:
            AnyCloudflareDatabaseJobAuthorizationProvider? = nil,
        completion: CloudflareDatabaseCompletionChannel =
            CloudflareDatabaseCompletionChannel(),
        limits: CloudflareDatabaseOperationLimits = .default,
        storageTransportLimits: CloudflareDatabaseStorageTransportLimits = .default
    ) throws {
        let transport = try CloudflareDurableObjectStorageHostTransport(
            maximumRequestBytes: storageTransportLimits.maximumRequestBytes,
            maximumResponseBytes: storageTransportLimits.maximumResponseBytes
        )
        self.init(
            application: application,
            partitionIdentity: partitionIdentity,
            storageLimits: storageLimits,
            storageLayout: storageLayout,
            storageClient: CloudflareDurableObjectStorageWireClient(
                transport: transport
            ),
            jobScheduler: CloudflareDatabaseAlarmScheduler(),
            jobAuthorizationProvider: jobAuthorizationProvider,
            completion: completion,
            limits: limits
        )
    }
    #else
    convenience init(
        application: AnyDatabaseOperationApplication,
        partitionIdentity: StoragePartitionIdentity,
        storageLimits: CloudflareDurableObjectLimits,
        jobAuthorizationProvider:
            AnyCloudflareDatabaseJobAuthorizationProvider? = nil,
        completion: CloudflareDatabaseCompletionChannel =
            CloudflareDatabaseCompletionChannel(),
        limits: CloudflareDatabaseOperationLimits = .default,
        storageTransportLimits: CloudflareDatabaseStorageTransportLimits = .default
    ) throws {
        let transport = try CloudflareDurableObjectStorageHostTransport(
            maximumRequestBytes: storageTransportLimits.maximumRequestBytes,
            maximumResponseBytes: storageTransportLimits.maximumResponseBytes
        )
        self.init(
            application: application,
            partitionIdentity: partitionIdentity,
            storageLimits: storageLimits,
            storageClient: CloudflareDurableObjectStorageWireClient(
                transport: transport
            ),
            jobScheduler: CloudflareDatabaseAlarmScheduler(),
            jobAuthorizationProvider: jobAuthorizationProvider,
            completion: completion,
            limits: limits
        )
    }
    #endif
#endif

    public func start(callID: UInt32) {
        guard validate(callID: callID) else { return }
        enqueue(callID: callID) { [runtime] in
            await runtime.start(callID: callID)
        }
    }

    public func invoke(
        callID: UInt32,
        requestBytes: ByteString,
        authorization: AuthorizationContext
    ) {
        guard validate(callID: callID) else { return }
        guard requestBytes.count <= limits.maximumRequestBytes else {
            completeFailure(
                callID: callID,
                status: .requestTooLarge,
                message: "Database request exceeds the runtime limit"
            )
            return
        }
        enqueue(callID: callID) { [runtime] in
            await runtime.invoke(
                callID: callID,
                requestBytes: requestBytes,
                authorization: authorization
            )
        }
    }

    public func alarm(callID: UInt32) {
        guard validate(callID: callID) else { return }
        enqueue(callID: callID) { [runtime] in
            await runtime.alarm(callID: callID)
        }
    }

    public func shutdown(callID: UInt32) {
        guard validate(callID: callID) else { return }
        let isAccepted = commandState.withLock { state -> Bool in
            // The first shutdown must enter even when normal work already
            // fills the queue. Later joiners remain bounded by the same
            // pending-command budget instead of creating unbounded Tasks.
            guard !state.isClosing
                    || state.pendingCount < limits.maximumPendingInvocations
            else {
                return false
            }
            state.isClosing = true
            let predecessor = state.tail
            state.pendingCount += 1
            state.tail = Task { [self, runtime] in
                if let predecessor {
                    await predecessor.value
                }
                await runtime.shutdown(callID: callID)
                finishCommand()
            }
            return true
        }
        guard isAccepted else {
            completeFailure(
                callID: callID,
                status: .queueCapacityExceeded,
                message: "Database runtime shutdown queue is full"
            )
            return
        }
    }

    private func enqueue(
        callID: UInt32,
        operation: @escaping @Sendable () async -> Void
    ) {
        let rejection = commandState.withLock { state -> EnqueueRejection? in
            guard !state.isClosing else {
                return .closing
            }
            guard state.pendingCount < limits.maximumPendingInvocations else {
                return .capacity
            }
            let predecessor = state.tail
            state.pendingCount += 1
            state.tail = Task { [self] in
                if let predecessor {
                    await predecessor.value
                }
                await operation()
                finishCommand()
            }
            return nil
        }
        switch rejection {
        case nil:
            return
        case .closing:
            completeFailure(
                callID: callID,
                status: .notStarted,
                message: "Database runtime is shutting down"
            )
        case .capacity:
            completeFailure(
                callID: callID,
                status: .queueCapacityExceeded,
                message: "Database runtime queue is full"
            )
        }
    }

    private func finishCommand() {
        commandState.withLock { state in
            precondition(state.pendingCount > 0)
            state.pendingCount -= 1
            if state.pendingCount == 0 {
                state.tail = nil
            }
        }
    }

    private func validate(callID: UInt32) -> Bool {
        guard callID != 0 else {
            completeFailure(
                callID: callID,
                status: .invalidCallID,
                message: "Call ID must be non-zero"
            )
            return false
        }
        return true
    }

    private func completeFailure(
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
