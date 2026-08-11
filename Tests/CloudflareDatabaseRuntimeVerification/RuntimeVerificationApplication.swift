import CloudflareDatabase
import CloudflareDurableObjectStorage
import CloudflareDurableObjectStorageWire
import DatabaseKit
import DatabaseEngine
import DatabaseRuntime
import DatabaseWireRuntime
import StorageKit
#if CLOUDFLARE_RUNTIME_VECTOR_INDEXES
import DatabaseTypes
import VectorIndex
#endif
#if !arch(wasm32)
import DatabaseFoundation
import StorageKitSystemClock
#endif

final class RuntimeVerificationApplication: CloudflareDatabaseApplication {
    let partitionIdentity: StoragePartitionIdentity
    let storageLimits = CloudflareDurableObjectLimits.default
    let storageLayout: CloudflareDatabaseStorageLayout
    #if CLOUDFLARE_RUNTIME_MULTIPLE_BASES
    let jobAuthorizationProvider:
        AnyCloudflareDatabaseJobAuthorizationProvider? =
            AnyCloudflareDatabaseJobAuthorizationProvider(
                RuntimeVerificationJobAuthorizationProvider()
            )
    #else
    let jobAuthorizationProvider:
        AnyCloudflareDatabaseJobAuthorizationProvider? = nil
    #endif

    init() throws {
        partitionIdentity = try StoragePartitionIdentity(
            databaseID: "runtime-verification"
        )
        #if CLOUDFLARE_RUNTIME_MULTIPLE_BASES
        storageLayout = try CloudflareDatabaseStorageLayout(
            domainID: DatabaseStorageDomain.ID("primary"),
            domainNamespacePath: ["database", "runtime-verification"],
            placementID: Base.Placement.ID("default"),
            baseNamespacePath: ["bases"]
        )
        #else
        storageLayout = try CloudflareDatabaseStorageLayout(
            domainID: DatabaseStorageDomain.ID("primary"),
            domainNamespacePath: ["database", "runtime-verification"]
        )
        #endif
    }

    func makeContainerDefinition() async throws
        -> DatabaseContainerDefinition {
        #if arch(wasm32)
        let monotonicClock = CloudflareDatabaseMonotonicClock()
        let wallClock = CloudflareDatabaseWallClock()
        #else
        let monotonicClock = SystemStorageClock()
        let wallClock = RealtimeDatabaseWallClock()
        #endif
        var entities = [try RuntimeVerificationDocument.schemaEntity]
        var entityRuntimes = [
            try DatabaseFrameworkRuntime.entity(
                RuntimeVerificationDocument.self
            )
        ]
        var authorizationPolicies = [
            AuthorizationPolicyHandler(RuntimeVerificationDocument.self)
        ]
        #if CLOUDFLARE_RUNTIME_VECTOR_INDEXES
        entities.append(contentsOf: [
            try RuntimeVerificationIVFDocument.schemaEntity,
            try RuntimeVerificationPQDocument.schemaEntity,
            try RuntimeVerificationFlatDocument.schemaEntity,
        ])
        entityRuntimes.append(contentsOf: [
            try DatabaseFrameworkRuntime.entity(RuntimeVerificationIVFDocument.self),
            try DatabaseFrameworkRuntime.entity(RuntimeVerificationPQDocument.self),
            try DatabaseFrameworkRuntime.entity(RuntimeVerificationFlatDocument.self),
        ])
        authorizationPolicies.append(contentsOf: [
            AuthorizationPolicyHandler(RuntimeVerificationIVFDocument.self),
            AuthorizationPolicyHandler(RuntimeVerificationPQDocument.self),
            AuthorizationPolicyHandler(RuntimeVerificationFlatDocument.self),
        ])
        #endif

        #if CLOUDFLARE_RUNTIME_VECTOR_INDEXES
        let indexConfigurations: [any IndexRuntimeConfiguration] = [
            VectorIndexConfiguration<RuntimeVerificationIVFDocument>(
                field: RuntimeVerificationIVFDocument.fields.embedding,
                algorithm: .ivf(
                    try VectorIVFParameters(
                        nlist: 2,
                        nprobe: 2,
                        kmeansIterations: 4
                    )
                )
            ),
            VectorIndexConfiguration<RuntimeVerificationPQDocument>(
                field: RuntimeVerificationPQDocument.fields.embedding,
                algorithm: .pq(
                    try VectorPQParameters(m: 1, niter: 4)
                )
            ),
            VectorIndexConfiguration<RuntimeVerificationFlatDocument>(
                field: RuntimeVerificationFlatDocument.fields.embedding,
                algorithm: .flat
            ),
        ]
        #else
        let indexConfigurations: [any IndexRuntimeConfiguration] = []
        #endif

        #if CLOUDFLARE_RUNTIME_VECTOR_INDEXES
        try verifyHNSWRejection(
            monotonicClock: monotonicClock,
            wallClock: wallClock
        )
        #endif

        return DatabaseContainerDefinition(
            schema: try Schema(
                entities: entities
            ),
            runtimeConfiguration: try DatabaseFrameworkRuntime.configuration(
                entityRuntimes: entityRuntimes,
                authorizationPolicies: authorizationPolicies
            ),
            security: .enabled(),
            monotonicClock: monotonicClock,
            wallClock: wallClock,
            indexConfigurations: indexConfigurations,
            logging: .disabled
        )
    }

    #if CLOUDFLARE_RUNTIME_VECTOR_INDEXES
    private func verifyHNSWRejection(
        monotonicClock: any StorageMonotonicClock,
        wallClock: any WallClock
    ) throws {
        let definition = DatabaseContainerDefinition(
            schema: try Schema(
                entities: [try RuntimeVerificationVectorDocument.schemaEntity]
            ),
            runtimeConfiguration: try DatabaseFrameworkRuntime.configuration(
                entityRuntimes: [
                    try DatabaseFrameworkRuntime.entity(
                        RuntimeVerificationVectorDocument.self
                    )
                ]
            ),
            security: .enabled(),
            monotonicClock: monotonicClock,
            wallClock: wallClock,
            indexConfigurations: [
                VectorIndexConfiguration<RuntimeVerificationVectorDocument>(
                    field: RuntimeVerificationVectorDocument.fields.embedding,
                    algorithm: .hnsw(.default)
                )
            ]
        )
        do {
            try definition.validateCloudflareHostingCapabilities()
        } catch let error {
            guard error == .unsupportedHNSW(
                indexName: "RuntimeVerificationVectorDocument_embedding"
            ) else {
                throw RuntimeVerificationError.hnswCapabilityErrorMismatch
            }
            return
        }
        throw RuntimeVerificationError.hnswCapabilityWasAccepted
    }

    #endif

    func makeRuntimeConfiguration(
        for container: DBContainer
    ) async throws -> DatabaseOperationRuntimeConfiguration {
        #if arch(wasm32)
        let clock = CloudflareDatabaseWallClock()
        let identifierGenerator = CloudflareDatabaseUUIDGenerator()
        #else
        let clock = RealtimeDatabaseWallClock()
        let identifierGenerator = RandomDatabaseUUIDGenerator()
        #endif
        let jobServiceFactory = try DatabasePersistentJobServiceFactory(
            registry: DatabaseResumableOperationRegistry(operations: []),
            identifierGenerator: identifierGenerator,
            storageLimits: DatabasePersistentJobStorageLimits(
                maximumStorageValueBytes: 1_048_576
            )
        )
        return try DatabaseOperationRuntimeConfiguration(
            identity: DatabaseRuntimeIdentity(
                version: "cloudflare-runtime-verification"
            ),
            serviceFactory: AnyDatabaseOperationServiceFactory(
                CanonicalDatabaseOperationServiceFactory(
                    maintenanceServiceFactory:
                        DatabaseMaintenanceOperationServiceFactory(
                            identifierGenerator: identifierGenerator
                        ),
                    jobServiceFactory: jobServiceFactory
                )
            ),
            admissionPolicy: AnyDatabaseOperationAdmissionPolicy(
                UnrestrictedDatabaseOperationAdmissionPolicy()
            ),
            clock: clock
        )
    }
}

#if CLOUDFLARE_RUNTIME_MULTIPLE_BASES
private struct RuntimeVerificationJobAuthorizationProvider:
    CloudflareDatabaseJobAuthorizationProviding {
    private static let principalIdentifier = "runtime-verification"

    func reference(
        for authorization: AuthorizationContext
    ) throws -> DatabaseJobAuthorizationReference {
        guard authorization.principal?.identifier == Self.principalIdentifier
        else {
            throw DatabaseJobAuthorizationError.revalidationFailed
        }
        return try DatabaseJobAuthorizationReference(Self.principalIdentifier)
    }

    func revalidate(
        _ reference: DatabaseJobAuthorizationReference
    ) async throws -> AuthorizationContext {
        guard reference.value == Self.principalIdentifier else {
            throw DatabaseJobAuthorizationError.revalidationFailed
        }
        return .authenticated(
            Principal(
                identifier: Self.principalIdentifier,
                roles: ["admin"]
            )
        )
    }
}
#endif
