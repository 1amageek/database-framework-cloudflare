import CloudflareDatabase
import CloudflareDurableObjectStorage
import CloudflareDurableObjectStorageWire
import DatabaseEngine
import DatabaseServerRuntime

final class InternalErrorRuntimeVerificationApplication:
    CloudflareDatabaseOperationApplication {
    let partitionIdentity: StoragePartitionIdentity
    let storageLimits = CloudflareDurableObjectLimits.default
    #if CLOUDFLARE_TEST_MULTIPLE_BASES
    let storageLayout: CloudflareDatabaseStorageLayout
    #endif
    let jobAuthorizationProvider:
        AnyCloudflareDatabaseJobAuthorizationProvider? = nil

    init() throws {
        partitionIdentity = try StoragePartitionIdentity(
            databaseID: "runtime-internal-error"
        )
        #if CLOUDFLARE_TEST_MULTIPLE_BASES
        storageLayout = try makeCloudflareTestStorageLayout(
            namespace: "runtime-internal-error"
        )
        #endif
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
