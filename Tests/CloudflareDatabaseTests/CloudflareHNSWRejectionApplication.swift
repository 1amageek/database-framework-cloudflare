#if CLOUDFLARE_TEST_VECTOR_INDEXES
import CloudflareDatabase
import CloudflareDurableObjectStorage
import CloudflareDurableObjectStorageWire
import DatabaseEngine
import DatabaseKit
import DatabaseRuntime
import DatabaseWireRuntime
import DatabaseFoundation
import StorageKitSystemClock
import VectorIndex

final class CloudflareHNSWRejectionApplication:
    CloudflareDatabaseApplication {
    let partitionIdentity: StoragePartitionIdentity
    let storageLimits = CloudflareDurableObjectLimits.default
    let storageLayout: CloudflareDatabaseStorageLayout
    let jobAuthorizationProvider:
        AnyCloudflareDatabaseJobAuthorizationProvider? = nil

    private let indexConfiguration: any IndexRuntimeConfiguration

    init(
        indexConfiguration: (any IndexRuntimeConfiguration)? = nil
    ) throws {
        partitionIdentity = try StoragePartitionIdentity(
            databaseID: "cloudflare-hnsw-rejection"
        )
        storageLayout = try makeCloudflareTestStorageLayout(
            namespace: "hnsw-rejection"
        )
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

    func makeRuntimeConfiguration(
        for container: DBContainer
    ) async throws -> DatabaseOperationRuntimeConfiguration {
        _ = container
        throw RuntimeVerificationError.unexpectedServiceOperation
    }
}
#endif
