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
    #if CLOUDFLARE_TEST_MULTIPLE_BASES
    private let storageLayout: CloudflareDatabaseStorageLayout
    #endif
    private let indexConfiguration: any IndexRuntimeConfiguration

    init(
        indexConfiguration: (any IndexRuntimeConfiguration)? = nil
    ) throws {
        self.partitionIdentity = try StoragePartitionIdentity(
            databaseID: "cloudflare-hnsw-rejection"
        )
        #if CLOUDFLARE_TEST_MULTIPLE_BASES
        self.storageLayout = try makeCloudflareTestStorageLayout(
            namespace: "hnsw-rejection"
        )
        #endif
        self.indexConfiguration = indexConfiguration
            ?? VectorIndexConfiguration<CloudflareHNSWRejectionDocument>(
                field: CloudflareHNSWRejectionDocument.fields.embedding,
                algorithm: .hnsw(.default)
            )
    }

    func makeDefinition() async throws -> CloudflareDatabaseDefinition {
        let schema = try Schema(
            entities: [try CloudflareHNSWRejectionDocument.schemaEntity]
        )
        let runtimeConfiguration = try DatabaseFrameworkRuntime.configuration(
            entityRuntimes: [
                try DatabaseFrameworkRuntime.entity(
                    CloudflareHNSWRejectionDocument.self
                )
            ]
        )
        let indexConfigurations: [any IndexRuntimeConfiguration] = [
            indexConfiguration
        ]
        #if CLOUDFLARE_TEST_MULTIPLE_BASES
        return CloudflareDatabaseDefinition(
            partitionIdentity: partitionIdentity,
            storageLayout: storageLayout,
            schema: schema,
            runtimeConfiguration: runtimeConfiguration,
            security: .enabled(),
            indexConfigurations: indexConfigurations
        )
        #else
        return CloudflareDatabaseDefinition(
            partitionIdentity: partitionIdentity,
            schema: schema,
            runtimeConfiguration: runtimeConfiguration,
            security: .enabled(),
            indexConfigurations: indexConfigurations
        )
        #endif
    }

    func makeSession(
        for container: DBContainer
    ) async throws -> RejectedHNSWSession {
        _ = container
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
