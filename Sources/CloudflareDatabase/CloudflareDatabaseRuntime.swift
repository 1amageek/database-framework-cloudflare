import CloudflareDurableObjectStorage
import DatabaseEngine
import DatabaseServer
import DatabaseValue

/// Persistent, single-entry database runtime owned by one Durable Object.
public actor CloudflareDatabaseRuntime {
    private struct Invocation: Sendable {
        let callID: UInt32
        let requestBytes: DatabaseBytes
    }

    private enum PendingOperation: Sendable {
        case invocation(Invocation)
        case alarm(callID: UInt32)
    }

    private let application: CloudflareDatabaseApplicationComposition
    private let storageClient: CloudflareDurableObjectStorageClientComposition
    private let jobScheduler: AnyDatabaseJobScheduler
    private let completion: CloudflareDatabaseCompletionChannel
    private let limits: CloudflareDatabaseRuntimeLimits

    private var container: DBContainer?
    private var serverRuntime: DatabaseServerRuntime?
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
        self.application = CloudflareDatabaseApplicationComposition(application)
        self.storageClient = CloudflareDurableObjectStorageClientComposition(storageClient)
        self.jobScheduler = AnyDatabaseJobScheduler(jobScheduler)
        self.completion = completion
        self.limits = limits
    }

    /// Bootstraps the StorageKit engine, application container, and full server runtime.
    public func start(callID: UInt32) async {
        guard callID != 0 else {
            fail(callID: callID, status: .invalidCallID, message: "Call ID must be non-zero")
            return
        }
        guard serverRuntime == nil else {
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
                let storageEngine = try await CloudflareDurableObjectStorageEngine(
                    configuration: CloudflareDurableObjectStorageConfiguration(
                        scope: application.storageScope,
                        client: storageClient,
                        limits: application.storageLimits,
                        monotonicClock: CloudflareDatabaseMonotonicClock()
                    )
                )
                let createdContainer = try await application.makeContainer(
                    storageEngine: storageEngine
                )
                self.container = createdContainer
                container = createdContainer
            }
            try await container.migrateIfNeeded()
            let configuration = try await application.makeServerConfiguration(
                container: container,
                jobScheduler: jobScheduler
            )
            serverRuntime = try await DatabaseServerRuntime(
                container: container,
                configuration: configuration
            )
            isStarting = false
            completion.complete(callID: callID, status: .success, payload: [])
        } catch is CancellationError {
            isStarting = false
            fail(callID: callID, status: .cancelled, message: "Database runtime startup was cancelled")
        } catch {
            isStarting = false
            serverRuntime = nil
            fail(
                callID: callID,
                status: .startupFailed,
                message: "Database runtime startup failed: \(String(describing: error))"
            )
        }
    }

    /// Enqueues one DatabaseWire request without allowing concurrent runtime entry.
    public func invoke(callID: UInt32, requestBytes: DatabaseBytes) async {
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
        guard serverRuntime != nil else {
            fail(callID: callID, status: .notStarted, message: "Database runtime is not started")
            return
        }
        guard pendingOperations.count < limits.maximumPendingInvocations else {
            fail(
                callID: callID,
                status: .queueCapacityExceeded,
                message: "Database invocation queue is full"
            )
            return
        }

        pendingOperations.append(
            .invocation(
                Invocation(callID: callID, requestBytes: requestBytes)
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
        guard serverRuntime != nil else {
            fail(callID: callID, status: .notStarted, message: "Database runtime is not started")
            return
        }
        guard pendingOperations.count < limits.maximumPendingInvocations else {
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

    private func processPendingOperationsIfNeeded() async {
        guard !isProcessingOperations else {
            return
        }
        isProcessingOperations = true
        while !pendingOperations.isEmpty {
            let operation = pendingOperations.removeFirst()
            guard let serverRuntime else {
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
                await execute(invocation, using: serverRuntime)
            case .alarm(let callID):
                do {
                    try await serverRuntime.runScheduledWork()
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
                        status: .runtimeFailed,
                        message: "Database alarm execution failed: \(String(describing: error))"
                    )
                }
            }
        }
        isProcessingOperations = false
    }

    private func execute(
        _ invocation: Invocation,
        using serverRuntime: DatabaseServerRuntime
    ) async {
        do {
            let responseBytes = try await serverRuntime.execute(
                invocation.requestBytes
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
        } catch DatabaseEndpointError.invalidRequestFrame(let error) {
            fail(
                callID: invocation.callID,
                status: .invalidRequestFrame,
                message: "Database request frame is invalid: \(String(describing: error))"
            )
        } catch {
            fail(
                callID: invocation.callID,
                status: .runtimeFailed,
                message: "Database runtime failed: \(String(describing: error))"
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
            payload: DatabaseBytes.copyingUTF8(
                message,
                maximumByteCount: limits.maximumErrorBytes
            )
        )
    }
}
