#if CLOUDFLARE_TEST_VECTOR_INDEXES
import CloudflareDurableObjectStorage
import CloudflareDurableObjectStorageWire

actor UnexpectedStorageAccessClient: CloudflareDurableObjectStorageClient {
    nonisolated var callExecution: CloudflareDurableObjectCallExecution {
        .synchronous
    }

    private var accessCount = 0

    func read(
        _ request: StorageWireReadRequest
    ) async throws -> StorageWireReadResponse {
        _ = request
        try recordUnexpectedAccess()
    }

    func range(
        _ request: StorageWireRangeRequest
    ) async throws -> StorageWireRangeResponse {
        _ = request
        try recordUnexpectedAccess()
    }

    func commit(
        _ request: StorageWireCommitRequest
    ) async throws -> StorageWireCommitResponse {
        _ = request
        try recordUnexpectedAccess()
    }

    func readiness(
        _ request: StorageWireReadinessRequest
    ) async throws -> StorageWireReadinessResponse {
        _ = request
        try recordUnexpectedAccess()
    }

    func rangeSize(
        _ request: StorageWireRangeSizeRequest
    ) async throws -> StorageWireRangeSizeResponse {
        _ = request
        try recordUnexpectedAccess()
    }

    func rangeSplitPoints(
        _ request: StorageWireRangeSplitPointsRequest
    ) async throws -> StorageWireRangeSplitPointsResponse {
        _ = request
        try recordUnexpectedAccess()
    }

    func recordedAccessCount() -> Int {
        accessCount
    }

    private func recordUnexpectedAccess() throws -> Never {
        accessCount += 1
        throw RuntimeVerificationError.unexpectedStorageAccess
    }
}
#endif
