import CloudflareDurableObjectStorage
import CloudflareDurableObjectStorageTesting

actor FailingOnceReadinessClient: CloudflareDurableObjectStorageClient {
    nonisolated var callExecution: CloudflareDurableObjectCallExecution {
        .synchronous
    }

    private var hasFailed = false
    private let storageClient = InMemoryCloudflareDurableObjectStorageClient()

    func read(
        _ request: CloudflareDurableObjectReadRequest
    ) async throws -> CloudflareDurableObjectReadResponse {
        try await storageClient.read(request)
    }

    func range(
        _ request: CloudflareDurableObjectRangeRequest
    ) async throws -> CloudflareDurableObjectRangeResponse {
        try await storageClient.range(request)
    }

    func commit(
        _ request: CloudflareDurableObjectCommitRequest
    ) async throws -> CloudflareDurableObjectCommitResponse {
        try await storageClient.commit(request)
    }

    func readiness(
        _ request: CloudflareDurableObjectReadinessRequest
    ) async throws -> CloudflareDurableObjectReadinessResponse {
        guard hasFailed else {
            hasFailed = true
            throw RuntimeVerificationError.simulatedReadinessFailure
        }
        return try await storageClient.readiness(request)
    }

    func rangeSize(
        _ request: CloudflareDurableObjectRangeSizeRequest
    ) async throws -> CloudflareDurableObjectRangeSizeResponse {
        try await storageClient.rangeSize(request)
    }

    func rangeSplitPoints(
        _ request: CloudflareDurableObjectRangeSplitPointsRequest
    ) async throws -> CloudflareDurableObjectRangeSplitPointsResponse {
        try await storageClient.rangeSplitPoints(request)
    }
}
