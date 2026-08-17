#if arch(wasm32)
import DatabaseTypes
import Synchronization

/// Application-facing owner of one persistent database runtime instance.
public final class CloudflareDatabaseRuntimeEntrypoint: Sendable {
    public static let abiVersion: UInt32 = 3

    private let application: AnyCloudflareDatabaseApplication
    private let completion: CloudflareDatabaseCompletionChannel
    private let limits: CloudflareDatabaseRuntimeLimits
    private let storageTransportLimits: CloudflareDatabaseStorageTransportLimits
    private let invocationPayloadOwnership: DatabaseInvocationPayloadOwnership
    private let runtimeCommandChannel =
        Mutex<CloudflareDatabaseRuntimeCommandChannel?>(nil)

    public init<Application: CloudflareDatabaseApplication>(
        application: Application,
        completion: CloudflareDatabaseCompletionChannel =
            CloudflareDatabaseCompletionChannel(),
        maximumContextBytes: Int = 1 * 1_024 * 1_024,
        maximumRequestBytes: Int = 4 * 1_024 * 1_024,
        maximumResponseBytes: Int = 4 * 1_024 * 1_024,
        maximumErrorBytes: Int = 4 * 1_024,
        maximumPendingInvocations: Int = 64,
        maximumStorageRequestBytes: Int = 16 * 1_024 * 1_024,
        maximumStorageResponseBytes: Int = 16 * 1_024 * 1_024
    ) throws {
        try CloudflareDatabaseRuntimeLimits.validate(
            maximumContextBytes,
            field: "maximumContextBytes",
            maximum: CloudflareDatabaseRuntimeLimits.maximumPayloadBytes
        )
        try CloudflareDatabaseRuntimeLimits.validate(
            maximumRequestBytes,
            field: "maximumRequestBytes",
            maximum: CloudflareDatabaseRuntimeLimits.maximumPayloadBytes
        )
        try CloudflareDatabaseRuntimeLimits.validate(
            maximumResponseBytes,
            field: "maximumResponseBytes",
            maximum: CloudflareDatabaseRuntimeLimits.maximumPayloadBytes
        )
        try CloudflareDatabaseRuntimeLimits.validate(
            maximumErrorBytes,
            field: "maximumErrorBytes",
            minimum: CloudflareDatabaseRuntimeLimits.minimumErrorBytes,
            maximum: CloudflareDatabaseRuntimeLimits.maximumErrorBytes
        )
        try CloudflareDatabaseRuntimeLimits.validate(
            maximumPendingInvocations,
            field: "maximumPendingInvocations",
            maximum: CloudflareDatabaseRuntimeLimits
                .maximumPendingInvocations
        )
        try CloudflareDatabaseStorageTransportLimits.validate(
            maximumStorageRequestBytes,
            field: "maximumStorageRequestBytes"
        )
        try CloudflareDatabaseStorageTransportLimits.validate(
            maximumStorageResponseBytes,
            field: "maximumStorageResponseBytes"
        )
        self.application = AnyCloudflareDatabaseApplication(application)
        self.completion = completion
        self.limits = CloudflareDatabaseRuntimeLimits(
            maximumContextBytes: maximumContextBytes,
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
                max(maximumContextBytes, maximumRequestBytes),
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
        do {
            let commandChannel = try runtimeCommandChannel.withLock { channel in
                if let channel {
                    return channel
                }
                let createdChannel = try CloudflareDatabaseRuntimeCommandChannel(
                    application: application,
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
        contextAddress: UInt32,
        contextByteCount: UInt32,
        requestAddress: UInt32,
        requestByteCount: UInt32
    ) {
        let contextBytes: ByteString
        let requestBytes: ByteString
        do {
            contextBytes = try invocationPayloadOwnership.consumePayload(
                payloadAddress: contextAddress,
                byteCount: contextByteCount
            )
        } catch {
            consumeOrReleaseRequestPayload(
                requestAddress: requestAddress,
                requestByteCount: requestByteCount
            )
            completeFailure(
                callID: callID,
                status: .invalidPayload,
                message: "Application context payload is invalid"
            )
            return
        }
        do {
            requestBytes = try invocationPayloadOwnership.consumePayload(
                payloadAddress: requestAddress,
                byteCount: requestByteCount
            )
        } catch {
            completeFailure(
                callID: callID,
                status: .invalidPayload,
                message: "Application request payload is invalid"
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
            contextBytes: contextBytes,
            requestBytes: requestBytes
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

    private func consumeOrReleaseRequestPayload(
        requestAddress: UInt32,
        requestByteCount: UInt32
    ) {
        do {
            _ = try invocationPayloadOwnership.consumePayload(
                payloadAddress: requestAddress,
                byteCount: requestByteCount
            )
        } catch {
            // The context failure remains authoritative. A malformed second
            // payload has already released any matching reservation.
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
#endif
