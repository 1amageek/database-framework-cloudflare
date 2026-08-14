#if CLOUDFLARE_TEST_VECTOR_INDEXES
import CloudflareDatabase
import CloudflareDurableObjectStorage
import CloudflareDurableObjectStorageWire
import DatabaseEngine
import DatabaseKit
import DatabaseRuntime
import DatabaseServerRuntime
import DatabaseServerFoundation
import StorageKitSystemClock
import VectorIndex

final class CloudflareHNSWRejectionApplication:
    CloudflareDatabaseOperationApplication {
    let partitionIdentity: StoragePartitionIdentity
    let storageLimits = CloudflareDurableObjectLimits.default
    #if CLOUDFLARE_TEST_MULTIPLE_BASES
    let storageLayout: CloudflareDatabaseStorageLayout
    #endif
    let jobAuthorizationProvider:
        AnyCloudflareDatabaseJobAuthorizationProvider? = nil

    private let indexConfiguration: any IndexRuntimeConfiguration

    init(
        indexConfiguration: (any IndexRuntimeConfiguration)? = nil
    ) throws {
        partitionIdentity = try StoragePartitionIdentity(
            databaseID: "cloudflare-hnsw-rejection"
        )
        #if CLOUDFLARE_TEST_MULTIPLE_BASES
        storageLayout = try makeCloudflareTestStorageLayout(
            namespace: "hnsw-rejection"
        )
        #endif
        self.indexConfiguration = indexConfiguration
            ?? VectorIndexConfiguration<CloudflareHNSWRejectionDocument>(
                field: CloudflareHNSWRejectionDocument.fields.embedding,
                algorithm: .hnsw(.default)
            )
    }

    func makeContainerDefinition() async throws
        -> DatabaseContainerDefinition {
        DatabaseContainerDefinition(
            schema: try Schema(
                entities: [try CloudflareHNSWRejectionDocument.schemaEntity]
            ),
            runtimeConfiguration: try DatabaseFrameworkRuntime.configuration(
                entityRuntimes: [
                    try DatabaseFrameworkRuntime.entity(
                        CloudflareHNSWRejectionDocument.self
                    )
                ]
            ),
            security: .enabled(),
            monotonicClock: SystemStorageClock(),
            wallClock: RealtimeDatabaseWallClock(),
            indexConfigurations: [indexConfiguration]
        )
    }

    func makeOperationConfiguration(
        for container: DBContainer
    ) async throws -> DatabaseOperationConfiguration {
        _ = container
        throw RuntimeVerificationError.unexpectedServiceOperation
    }
}
#endif
