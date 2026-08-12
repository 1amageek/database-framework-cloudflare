import CloudflareDatabase
import CloudflareDurableObjectStorage
import CloudflareDurableObjectStorageWire
import DatabaseEngine
import DatabaseOperations

final class InternalErrorRuntimeVerificationApplication:
    CloudflareDatabaseOperationApplication {
    let partitionIdentity: StoragePartitionIdentity
    let storageLimits = CloudflareDurableObjectLimits.default
    let storageLayout: CloudflareDatabaseStorageLayout
    let jobAuthorizationProvider:
        AnyCloudflareDatabaseJobAuthorizationProvider? = nil

    init() throws {
        partitionIdentity = try StoragePartitionIdentity(
            databaseID: "runtime-internal-error"
        )
        storageLayout = try makeCloudflareTestStorageLayout(
            namespace: "runtime-internal-error"
        )
    }

    func makeContainerDefinition() async throws
        -> DatabaseContainerDefinition {
        try await RuntimeVerificationApplication()
            .makeContainerDefinition()
    }

    func makeOperationConfiguration(
        for container: DBContainer
    ) async throws -> DatabaseOperationConfiguration {
        _ = container
        throw DatabaseRuntimeError.internalError(
            "sensitive-runtime-internal-detail"
        )
    }
}
