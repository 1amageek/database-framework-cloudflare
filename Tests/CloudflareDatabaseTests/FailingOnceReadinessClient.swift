import CloudflareDurableObjectStorage
import CloudflareDurableObjectStorageTesting
import CloudflareDurableObjectStorageWire

actor FailingOnceReadinessClient: CloudflareDurableObjectStorageClient {
    nonisolated var callExecution: CloudflareDurableObjectCallExecution {
        .synchronous
    }

    private var hasFailed = false
    private let storageClient = InMemoryCloudflareDurableObjectStorageClient()

    func read(
        _ request: StorageWireReadRequest
    ) async throws -> StorageWireReadResponse {
        try await storageClient.read(request)
    }

    func range(
        _ request: StorageWireRangeRequest
    ) async throws -> StorageWireRangeResponse {
        try await storageClient.range(request)
    }

    func commit(
        _ request: StorageWireCommitRequest
    ) async throws -> StorageWireCommitResponse {
        try await storageClient.commit(request)
    }

    func readiness(
        _ request: StorageWireReadinessRequest
    ) async throws -> StorageWireReadinessResponse {
        guard hasFailed else {
            hasFailed = true
            throw RuntimeVerificationError.simulatedReadinessFailure
        }
        return try await storageClient.readiness(request)
    }

    func rangeSize(
        _ request: StorageWireRangeSizeRequest
    ) async throws -> StorageWireRangeSizeResponse {
        try await storageClient.rangeSize(request)
    }

    func rangeSplitPoints(
        _ request: StorageWireRangeSplitPointsRequest
    ) async throws -> StorageWireRangeSplitPointsResponse {
        try await storageClient.rangeSplitPoints(request)
    }
}
