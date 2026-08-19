#if CLOUDFLARE_TEST_VECTOR_INDEXES
import CloudflareDatabase
import CloudflareDurableObjectStorage
import CloudflareDurableObjectStorageWire
import DatabaseEngine
import DatabaseKit
import DatabaseRuntime
import DatabaseTypes
import VectorIndex

final class CloudflareHNSWRejectionApplication:
    CloudflareDatabaseApplication,
    Sendable {
    private let partitionIdentity: StoragePartitionIdentity
    #if CLOUDFLARE_TEST_MULTI_BASE
    private let storageLayout: CloudflareDatabaseStorageLayout
    #endif
    private let indexConfiguration: any IndexRuntimeConfiguration

    init(
        indexConfiguration: (any IndexRuntimeConfiguration)? = nil
    ) throws {
        self.partitionIdentity = try StoragePartitionIdentity(
            databaseID: "cloudflare-hnsw-rejection"
        )
        #if CLOUDFLARE_TEST_MULTI_BASE
        self.storageLayout = try makeCloudflareTestStorageLayout(
            namespace: "hnsw-rejection"
        )
        #endif
        self.indexConfiguration =
            indexConfiguration
            ?? VectorIndexConfiguration(
                indexName: "CloudflareHNSWRejectionDocument_embedding",
                algorithm: .hnsw(.default)
            )
    }

    var configuration: CloudflareDatabaseConfiguration {
        get async throws {
            let schema = try Schema(
                entities: [try CloudflareHNSWRejectionDocument.schemaEntity]
            )
            let runtimeConfiguration = try DatabaseFrameworkRuntime.configuration(
                executionIdentity: DatabaseExecutionRuntimeIdentity(
                    identifier: "database-framework-cloudflare-tests",
                    revision: 1
                ),
                entityRuntimes: [
                    try DatabaseFrameworkRuntime.entity(
                        CloudflareHNSWRejectionDocument.self
                    )
                ],
                indexConfigurations: [indexConfiguration]
            )
            #if CLOUDFLARE_TEST_MULTI_BASE
            return CloudflareDatabaseConfiguration(
                partitionIdentity: partitionIdentity,
                storageLayout: storageLayout,
                schema: schema,
                runtimeConfiguration: runtimeConfiguration,
                security: .enabled()
            )
            #else
            return CloudflareDatabaseConfiguration(
                partitionIdentity: partitionIdentity,
                schema: schema,
                runtimeConfiguration: runtimeConfiguration,
                security: .enabled()
            )
            #endif
        }
    }

    func makeSession(
        for database: DBContainer
    ) async throws -> RejectedHNSWSession {
        _ = database
        return RejectedHNSWSession()
    }
}

struct RejectedHNSWSession: CloudflareDatabaseSession, Sendable {
    func respond(
        to invocation: CloudflareDatabaseInvocation
    ) async throws -> ByteString {
        _ = invocation
        throw RuntimeVerificationError.invalidApplicationRequest
    }

    func shutdown() async {}
}
#endif
