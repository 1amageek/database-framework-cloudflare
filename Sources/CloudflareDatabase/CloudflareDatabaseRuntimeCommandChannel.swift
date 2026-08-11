import CloudflareDurableObjectStorage
import CloudflareDurableObjectStorageHostTransport
import CloudflareDurableObjectStorageWire
import DatabaseKit
import DatabaseWireRuntime
import DatabaseTypes

/// Schedules database runtime lifecycle commands from the synchronous boundary.
public final class CloudflareDatabaseRuntimeCommandChannel: Sendable {
    public let runtime: CloudflareDatabaseRuntime

    private let completion: CloudflareDatabaseCompletionChannel
    private let limits: CloudflareDatabaseRuntimeLimits

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

#if arch(wasm32)
    public convenience init<Application: CloudflareDatabaseApplication>(
        application: Application,
        completion: CloudflareDatabaseCompletionChannel =
            CloudflareDatabaseCompletionChannel(),
        limits: CloudflareDatabaseRuntimeLimits = .default,
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

    convenience init(
        application: AnyDatabaseApplication,
        partitionIdentity: StoragePartitionIdentity,
        storageLimits: CloudflareDurableObjectLimits,
        storageLayout: CloudflareDatabaseStorageLayout,
        jobAuthorizationProvider:
            AnyCloudflareDatabaseJobAuthorizationProvider? = nil,
        completion: CloudflareDatabaseCompletionChannel =
            CloudflareDatabaseCompletionChannel(),
        limits: CloudflareDatabaseRuntimeLimits = .default,
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
#endif

    public func start(callID: UInt32) {
        Task {
            await runtime.start(callID: callID)
        }
    }

    public func invoke(
        callID: UInt32,
        requestBytes: ByteString,
        authorization: AuthorizationContext
    ) {
        guard callID != 0 else {
            completeFailure(
                callID: callID,
                status: .invalidCallID,
                message: "Call ID must be non-zero"
            )
            return
        }
        guard requestBytes.count <= limits.maximumRequestBytes else {
            completeFailure(
                callID: callID,
                status: .requestTooLarge,
                message: "Database request exceeds the runtime limit"
            )
            return
        }
        Task {
            await runtime.invoke(
                callID: callID,
                requestBytes: requestBytes,
                authorization: authorization
            )
        }
    }

    public func alarm(callID: UInt32) {
        Task {
            await runtime.alarm(callID: callID)
        }
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
