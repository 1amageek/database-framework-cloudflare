import CloudflareDurableObjectStorage
import CloudflareDurableObjectStorageHostTransport
import CloudflareDurableObjectStorageWire
import DatabaseEngine
import DatabaseTypes
import StorageKit
import Synchronization

/// Schedules database runtime lifecycle commands from the synchronous ABI.
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
    private let limits: CloudflareDatabaseRuntimeLimits
    private let commandState = Mutex(CommandState())

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
        self.runtime = CloudflareDatabaseRuntime(
            application: application,
            storageClient: storageClient,
            monotonicClock: monotonicClock,
            wallClock: wallClock,
            completion: completion,
            limits: limits
        )
        self.completion = completion
        self.limits = limits
    }

    package init<StorageClient: CloudflareDurableObjectStorageClient>(
        application: AnyCloudflareDatabaseApplication,
        storageClient: StorageClient,
        monotonicClock: any StorageMonotonicClock,
        wallClock: any WallClock,
        completion: CloudflareDatabaseCompletionChannel,
        limits: CloudflareDatabaseRuntimeLimits = .default
    ) {
        self.runtime = CloudflareDatabaseRuntime(
            application: application,
            storageClient: storageClient,
            monotonicClock: monotonicClock,
            wallClock: wallClock,
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
        storageTransportLimits: CloudflareDatabaseStorageTransportLimits =
            .default
    ) throws {
        try self.init(
            application: AnyCloudflareDatabaseApplication(application),
            completion: completion,
            limits: limits,
            storageTransportLimits: storageTransportLimits
        )
    }

    package convenience init(
        application: AnyCloudflareDatabaseApplication,
        completion: CloudflareDatabaseCompletionChannel =
            CloudflareDatabaseCompletionChannel(),
        limits: CloudflareDatabaseRuntimeLimits = .default,
        storageTransportLimits: CloudflareDatabaseStorageTransportLimits =
            .default
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
            monotonicClock: CloudflareDatabaseMonotonicClock(),
            wallClock: CloudflareDatabaseWallClock(),
            completion: completion,
            limits: limits
        )
    }
    #endif

    public func start(callID: UInt32) {
        guard validate(callID: callID) else { return }
        enqueue(callID: callID) { [runtime] in
            await runtime.start(callID: callID)
        }
    }

    public func invoke(
        callID: UInt32,
        contextBytes: ByteString,
        requestBytes: ByteString
    ) {
        guard validate(callID: callID) else { return }
        guard contextBytes.count <= limits.maximumContextBytes else {
            completeFailure(
                callID: callID,
                status: .contextTooLarge,
                message: "Application context exceeds the runtime limit"
            )
            return
        }
        guard requestBytes.count <= limits.maximumRequestBytes else {
            completeFailure(
                callID: callID,
                status: .requestTooLarge,
                message: "Application request exceeds the runtime limit"
            )
            return
        }
        enqueue(callID: callID) { [runtime] in
            await runtime.invoke(
                callID: callID,
                contextBytes: contextBytes,
                requestBytes: requestBytes
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
            guard !state.isClosing else {
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
                status: .notStarted,
                message: "Database runtime is shutting down"
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
