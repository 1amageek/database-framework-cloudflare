#if arch(wasm32)
import CloudflareDurableObjectStorage
import CloudflareDurableObjectStorageWire
import DatabaseKit
import DatabaseOperations
import DatabaseTypes
import Synchronization

/// Application-facing owner of one persistent database runtime instance.
public final class CloudflareDatabaseRuntimeEntrypoint: Sendable {
    private let application: AnyDatabaseOperationApplication
    private let partitionIdentity: StoragePartitionIdentity
    private let storageLimits: CloudflareDurableObjectLimits
    private let storageLayout: CloudflareDatabaseStorageLayout
    private let jobAuthorizationProvider:
        AnyCloudflareDatabaseJobAuthorizationProvider?
    private let completion: CloudflareDatabaseCompletionChannel
    private let limits: CloudflareDatabaseOperationLimits
    private let storageTransportLimits: CloudflareDatabaseStorageTransportLimits
    private let invocationPayloadOwnership: DatabaseInvocationPayloadOwnership
    private let runtimeCommandChannel = Mutex<CloudflareDatabaseRuntimeCommandChannel?>(nil)

    public init<Application: CloudflareDatabaseOperationApplication>(
        application: Application,
        completion: CloudflareDatabaseCompletionChannel =
            CloudflareDatabaseCompletionChannel(),
        maximumRequestBytes: Int = 16 * 1_024 * 1_024,
        maximumResponseBytes: Int = 16 * 1_024 * 1_024,
        maximumErrorBytes: Int = 4 * 1_024,
        maximumPendingInvocations: Int = 64,
        maximumStorageRequestBytes: Int = 16 * 1_024 * 1_024,
        maximumStorageResponseBytes: Int = 16 * 1_024 * 1_024
    ) throws {
        try CloudflareDatabaseOperationLimits.validate(
            maximumRequestBytes,
            field: "maximumRequestBytes",
            maximum: CloudflareDatabaseOperationLimits
                .protocolMaximumFrameBytes
        )
        try CloudflareDatabaseOperationLimits.validate(
            maximumResponseBytes,
            field: "maximumResponseBytes",
            maximum: CloudflareDatabaseOperationLimits
                .protocolMaximumFrameBytes
        )
        try CloudflareDatabaseOperationLimits.validate(
            maximumErrorBytes,
            field: "maximumErrorBytes",
            minimum: CloudflareDatabaseOperationLimits
                .protocolMinimumErrorBytes,
            maximum: CloudflareDatabaseOperationLimits
                .protocolMaximumErrorBytes
        )
        try CloudflareDatabaseOperationLimits.validate(
            maximumPendingInvocations,
            field: "maximumPendingInvocations",
            maximum: CloudflareDatabaseOperationLimits
                .protocolMaximumPendingInvocations
        )
        try CloudflareDatabaseStorageTransportLimits.validate(
            maximumStorageRequestBytes,
            field: "maximumStorageRequestBytes"
        )
        try CloudflareDatabaseStorageTransportLimits.validate(
            maximumStorageResponseBytes,
            field: "maximumStorageResponseBytes"
        )
        self.application = AnyDatabaseOperationApplication(application)
        self.partitionIdentity = application.partitionIdentity
        self.storageLimits = application.storageLimits
        self.storageLayout = application.storageLayout
        self.jobAuthorizationProvider = application.jobAuthorizationProvider
        self.completion = completion
        self.limits = CloudflareDatabaseOperationLimits(
            maximumRequestBytes: maximumRequestBytes,
            maximumResponseBytes: maximumResponseBytes,
            maximumErrorBytes: maximumErrorBytes,
            maximumPendingInvocations: maximumPendingInvocations,
            validated: ()
        )
        self.storageTransportLimits = CloudflareDatabaseStorageTransportLimits(
            maximumRequestBytes: maximumStorageRequestBytes,
            maximumResponseBytes: maximumStorageResponseBytes,
            validated: ()
        )
        self.invocationPayloadOwnership = DatabaseInvocationPayloadOwnership(
            maximumPayloadBytes: max(
                maximumRequestBytes,
                maximumStorageResponseBytes + MemoryLayout<UInt32>.size
            ),
            maximumOwnedPayloadCount: 65_536,
            maximumOwnedPayloadBytes: 64 * 1_024 * 1_024
        )
    }

    public func reserveInvocationPayload(byteCount: UInt32) -> UInt32 {
        invocationPayloadOwnership.reservePayload(byteCount: byteCount)
    }

    public func releaseInvocationPayload(
        payloadAddress: UInt32,
        byteCount: UInt32
    ) {
        invocationPayloadOwnership.releasePayload(
            payloadAddress: payloadAddress,
            byteCount: byteCount
        )
    }

    public func start(callID: UInt32) {
        guard callID != 0 else {
            completeFailure(
                callID: callID,
                status: .invalidCallID,
                message: "Call ID must be non-zero"
            )
            return
        }
        CloudflareDatabaseTaskScheduler.install()
        guard storageTransportLimits.maximumRequestBytes > 0,
              storageTransportLimits.maximumResponseBytes > 0 else {
            completeFailure(
                callID: callID,
                status: .startupFailed,
                message: "Invalid storage transport limits: request=\(storageTransportLimits.maximumRequestBytes), response=\(storageTransportLimits.maximumResponseBytes)"
            )
            return
        }
        do {
            let commandChannel = try runtimeCommandChannel.withLock { channel in
                if let channel {
                    return channel
                }
                let createdChannel = try CloudflareDatabaseRuntimeCommandChannel(
                    application: application,
                    partitionIdentity: partitionIdentity,
                    storageLimits: storageLimits,
                    storageLayout: storageLayout,
                    jobAuthorizationProvider: jobAuthorizationProvider,
                    completion: completion,
                    limits: limits,
                    storageTransportLimits: storageTransportLimits
                )
                channel = createdChannel
                return createdChannel
            }
            commandChannel.start(callID: callID)
        } catch {
            completeFailure(
                callID: callID,
                status: .startupFailed,
                message: "Database runtime creation failed"
            )
        }
    }

    public func invoke(
        callID: UInt32,
        authorizationAddress: UInt32,
        authorizationByteCount: UInt32,
        requestAddress: UInt32,
        requestByteCount: UInt32
    ) {
        var authorizationBytes: ByteString?
        var requestBytes: ByteString?
        do {
            authorizationBytes = try invocationPayloadOwnership.consumePayload(
                payloadAddress: authorizationAddress,
                byteCount: authorizationByteCount
            )
        } catch {
            authorizationBytes = nil
        }
        do {
            requestBytes = try invocationPayloadOwnership.consumePayload(
                payloadAddress: requestAddress,
                byteCount: requestByteCount
            )
        } catch {
            requestBytes = nil
        }
        guard let authorizationBytes, let requestBytes else {
            completeFailure(
                callID: callID,
                status: .invalidPayload,
                message: "Database invocation payload is invalid"
            )
            return
        }
        let authorization: AuthorizationContext
        do {
            authorization = try CloudflareDatabaseAuthorizationCodec.decode(
                authorizationBytes
            )
        } catch {
            completeFailure(
                callID: callID,
                status: .invalidPayload,
                message: "Database authorization payload is invalid"
            )
            return
        }
        guard let commandChannel = runtimeCommandChannel.withLock({ $0 }) else {
            completeFailure(
                callID: callID,
                status: .notStarted,
                message: "Database runtime is not started"
            )
            return
        }
        commandChannel.invoke(
            callID: callID,
            requestBytes: requestBytes,
            authorization: authorization
        )
    }

    public func alarm(callID: UInt32) {
        guard callID != 0 else {
            completeFailure(
                callID: callID,
                status: .invalidCallID,
                message: "Call ID must be non-zero"
            )
            return
        }
        guard let commandChannel = runtimeCommandChannel.withLock({ $0 }) else {
            completeFailure(
                callID: callID,
                status: .notStarted,
                message: "Database runtime is not started"
            )
            return
        }
        commandChannel.alarm(callID: callID)
    }

    public func shutdown(callID: UInt32) {
        guard callID != 0 else {
            completeFailure(
                callID: callID,
                status: .invalidCallID,
                message: "Call ID must be non-zero"
            )
            return
        }
        guard let commandChannel = runtimeCommandChannel.withLock({ $0 }) else {
            completion.complete(callID: callID, status: .success, payload: [])
            return
        }
        commandChannel.shutdown(callID: callID)
    }

    public static func runScheduledTask(taskID: UInt32) {
        CloudflareDatabaseTaskScheduler.run(taskID: taskID)
    }

    public static func resumeScheduledWait(waitID: UInt32) {
        CloudflareDatabaseMonotonicClock.resume(waitID: waitID)
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
#endif
