import CloudflareDatabase
import CloudflareDurableObjectStorage
import CloudflareDurableObjectStorageWire
import DatabaseEngine
import DatabaseWireRuntime

final class InternalErrorRuntimeVerificationApplication:
    CloudflareDatabaseApplication {
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

    func makeRuntimeConfiguration(
        for container: DBContainer
    ) async throws -> DatabaseOperationRuntimeConfiguration {
        _ = container
        throw DatabaseRuntimeError.internalError(
            "sensitive-runtime-internal-detail"
        )
    }
}
