import CloudflareDatabase
import CloudflareDurableObjectStorage
import CloudflareDurableObjectStorageWire
import DatabaseEngine
import DatabaseOperations

final class SuspendedRuntimeVerificationApplication:
    CloudflareDatabaseOperationApplication
{
    private actor DefinitionGate {
        private var isRequested = false
        private var isReleased = false
        private var requestWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func waitUntilRequested() async {
            guard !isRequested else { return }
            await withCheckedContinuation { continuation in
                requestWaiters.append(continuation)
            }
        }

        func suspendUntilReleased() async {
            isRequested = true
            let waiters = requestWaiters
            requestWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters {
                waiter.resume()
            }
            guard !isReleased else { return }
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }

        func release() {
            guard !isReleased else { return }
            isReleased = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    let partitionIdentity: StoragePartitionIdentity
    let storageLimits: CloudflareDurableObjectLimits
    let storageLayout: CloudflareDatabaseStorageLayout
    let jobAuthorizationProvider:
        AnyCloudflareDatabaseJobAuthorizationProvider?

    private let wrapped: RuntimeVerificationApplication
    private let gate = DefinitionGate()

    init() throws {
        let wrapped = try RuntimeVerificationApplication()
        self.wrapped = wrapped
        self.partitionIdentity = wrapped.partitionIdentity
        self.storageLimits = wrapped.storageLimits
        self.storageLayout = wrapped.storageLayout
        self.jobAuthorizationProvider = wrapped.jobAuthorizationProvider
    }

    func waitUntilDefinitionIsRequested() async {
        await gate.waitUntilRequested()
    }

    func releaseDefinition() async {
        await gate.release()
    }

    func makeContainerDefinition() async throws
        -> DatabaseContainerDefinition
    {
        await gate.suspendUntilReleased()
        return try await wrapped.makeContainerDefinition()
    }

    func makeOperationConfiguration(
        for container: DBContainer
    ) async throws -> DatabaseOperationConfiguration {
        try await wrapped.makeOperationConfiguration(for: container)
    }
}
