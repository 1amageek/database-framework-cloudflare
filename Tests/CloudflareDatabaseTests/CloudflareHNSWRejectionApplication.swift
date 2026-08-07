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

    private let indexConfiguration: any IndexRuntimeConfiguration

    init(
        indexConfiguration: (any IndexRuntimeConfiguration)? = nil
    ) throws {
        partitionIdentity = try StoragePartitionIdentity(
            databaseID: "cloudflare-hnsw-rejection"
        )
        self.indexConfiguration = indexConfiguration
            ?? VectorIndexConfiguration<CloudflareHNSWRejectionDocument>(
                field: CloudflareHNSWRejectionDocument.fields.embedding,
                algorithm: .hnsw(.default)
            )
    }

    func makeContainerDefinition() async throws
        -> CloudflareDatabaseContainerDefinition {
        CloudflareDatabaseContainerDefinition(
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
            security: .disabled,
            monotonicClock: SystemStorageClock(),
            wallClock: RealtimeDatabaseWallClock(),
            indexConfigurations: [indexConfiguration]
        )
    }

    func makeServerConfiguration(
        container: DBContainer,
        jobScheduler: AnyDatabaseJobScheduler
    ) async throws -> DatabaseServerRuntimeConfiguration {
        _ = container
        _ = jobScheduler
        throw RuntimeVerificationError.unexpectedServiceOperation
    }
}
#endif
