#if CLOUDFLARE_TEST_VECTOR_INDEXES
import CloudflareDatabase
import CloudflareDurableObjectStorage
import CloudflareDurableObjectStorageWire
import DatabaseEngine
import DatabaseKit
import DatabaseRuntime
import DatabaseServer
import DatabaseServerFoundation
import StorageKitSystemClock
import VectorIndex

final class CloudflareHNSWRejectionApplication:
    CloudflareDatabaseApplication {
    let partitionIdentity: StoragePartitionIdentity
    let storageLimits = CloudflareDurableObjectLimits.default
    let storageLayout: CloudflareDatabaseStorageLayout

    private let indexConfiguration: any IndexRuntimeConfiguration

    init(
        indexConfiguration: (any IndexRuntimeConfiguration)? = nil
    ) throws {
        partitionIdentity = try StoragePartitionIdentity(
            databaseID: "cloudflare-hnsw-rejection"
        )
        storageLayout = try CloudflareDatabaseStorageLayout(
            domainID: DatabaseStorageDomain.ID("primary"),
            domainNamespacePath: ["database", "hnsw-rejection"],
            placementID: Base.Placement.ID("default"),
            baseNamespacePath: ["bases"]
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
    ) async throws -> DatabaseServerRuntimeConfiguration {
        _ = container
        throw RuntimeVerificationError.unexpectedServiceOperation
    }
}
#endif
