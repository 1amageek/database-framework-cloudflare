import CloudflareDatabase
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseRuntime

final class RuntimeVerificationApplication:
    CloudflareDatabaseApplication,
    Sendable {
    private let partitionIdentity: StoragePartitionIdentity
    #if CLOUDFLARE_RUNTIME_MULTIPLE_BASES
    private let storageLayout: CloudflareDatabaseStorageLayout
    #endif

    init() throws {
        self.partitionIdentity = try StoragePartitionIdentity(
            databaseID: "runtime-verification"
        )
        #if CLOUDFLARE_RUNTIME_MULTIPLE_BASES
        self.storageLayout = try CloudflareDatabaseStorageLayout(
            domainID: DatabaseStorageDomain.ID("primary"),
            domainNamespacePath: ["database", "runtime-verification"],
            placementID: Base.Placement.ID("default"),
            baseNamespacePath: ["bases"]
        )
        #endif
    }

    func makeDefinition() async throws -> CloudflareDatabaseDefinition {
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
            try DatabaseFrameworkRuntime.entity(
                RuntimeVerificationIVFDocument.self
            ),
            try DatabaseFrameworkRuntime.entity(
                RuntimeVerificationPQDocument.self
            ),
            try DatabaseFrameworkRuntime.entity(
                RuntimeVerificationFlatDocument.self
            ),
        ])
        authorizationPolicies.append(contentsOf: [
            AuthorizationPolicyHandler(RuntimeVerificationIVFDocument.self),
            AuthorizationPolicyHandler(RuntimeVerificationPQDocument.self),
            AuthorizationPolicyHandler(RuntimeVerificationFlatDocument.self),
        ])
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

        let schema = try Schema(entities: entities)
        let runtimeConfiguration = try DatabaseFrameworkRuntime.configuration(
            entityRuntimes: entityRuntimes,
            authorizationPolicies: authorizationPolicies
        )
        #if CLOUDFLARE_RUNTIME_MULTIPLE_BASES
        let definition = CloudflareDatabaseDefinition(
            partitionIdentity: partitionIdentity,
            storageLayout: storageLayout,
            schema: schema,
            runtimeConfiguration: runtimeConfiguration,
            security: .enabled(),
            indexConfigurations: indexConfigurations,
            logging: .disabled
        )
        #else
        let definition = CloudflareDatabaseDefinition(
            partitionIdentity: partitionIdentity,
            schema: schema,
            runtimeConfiguration: runtimeConfiguration,
            security: .enabled(),
            indexConfigurations: indexConfigurations,
            logging: .disabled
        )
        #endif
        try definition.validateHostingCapabilities()
        return definition
    }

    func makeSession(
        for container: DBContainer
    ) async throws -> RuntimeVerificationSession {
        #if CLOUDFLARE_RUNTIME_MULTIPLE_BASES
        let baseID = try Base.ID("runtime-verification")
        _ = try await container.executionProvisionBaseRecord(
            baseID,
            placementID: container.executionDefaultBasePlacementID,
            initialGrants: [
                Security.Grant(
                    subject: .principal(
                        RuntimeVerificationSession.principalIdentifier
                    ),
                    resource: .base(baseID),
                    access: .all
                )
            ],
            expectedRevision: 0
        )
        return RuntimeVerificationSession(
            container: container,
            baseID: baseID
        )
        #else
        return RuntimeVerificationSession(container: container)
        #endif
    }
}
