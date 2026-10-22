import CloudflareDatabase
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseRuntime

final class RuntimeVerificationApplication:
    CloudflareDatabaseApplication,
    Sendable {
    private let partitionIdentity: StoragePartitionIdentity
    #if CLOUDFLARE_RUNTIME_MULTI_BASE
    private let storageLayout: CloudflareDatabaseStorageLayout
    #endif

    init() throws {
        self.partitionIdentity = try StoragePartitionIdentity(
            databaseID: "runtime-verification"
        )
        #if CLOUDFLARE_RUNTIME_MULTI_BASE
        self.storageLayout = try CloudflareDatabaseStorageLayout(
            domainID: DatabaseStorageDomain.ID("primary"),
            domainRootPath: ["database", "runtime-verification"],
            placementID: Base.Placement.ID("default")
        )
        #endif
    }

    var configuration: CloudflareDatabaseConfiguration {
        get async throws {
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
                VectorIndexConfiguration(
                    indexName: "RuntimeVerificationIVFDocument_embedding",
                    algorithm: .ivf(
                        try VectorIVFParameters(
                            nlist: 2,
                            nprobe: 2,
                            kmeansIterations: 4
                        )
                    )
                ),
                VectorIndexConfiguration(
                    indexName: "RuntimeVerificationPQDocument_embedding",
                    algorithm: .pq(
                        try VectorPQParameters(m: 1, niter: 4)
                    )
                ),
                VectorIndexConfiguration(
                    indexName: "RuntimeVerificationFlatDocument_embedding",
                    algorithm: .flat
                ),
            ]
            #else
            let indexConfigurations: [any IndexRuntimeConfiguration] = []
            #endif
            #if CLOUDFLARE_RUNTIME_GRAPH_INDEXES
            entities.append(contentsOf: [
                try RuntimeVerificationGraphUser.schemaEntity,
                try RuntimeVerificationGraphStatement.schemaEntity,
            ])
            entityRuntimes.append(contentsOf: [
                try DatabaseFrameworkRuntime.entity(RuntimeVerificationGraphUser.self),
                try DatabaseFrameworkRuntime.entity(RuntimeVerificationGraphStatement.self),
            ])
            authorizationPolicies.append(contentsOf: [
                AuthorizationPolicyHandler(RuntimeVerificationGraphUser.self),
                AuthorizationPolicyHandler(RuntimeVerificationGraphStatement.self),
            ])
            #endif

            let schema = try Schema(entities: entities)
            let runtimeConfiguration = try DatabaseFrameworkRuntime.configuration(
                executionIdentity: DatabaseExecutionRuntimeIdentity(
                    identifier: "database-framework-cloudflare-tests",
                    revision: 1
                ),
                entityRuntimes: entityRuntimes,
                authorizationPolicies: authorizationPolicies,
                indexConfigurations: indexConfigurations,
                sqlAuthorizationPolicyFactory: { entity, _, _ in
                    AuthorizationPolicyHandler(schemaDriven: entity) { _, authorization in
                        authorization.principal?.identifier == "runtime-verification"
                    }
                }
            )
            #if CLOUDFLARE_RUNTIME_MULTI_BASE
            let configuration = CloudflareDatabaseConfiguration(
                partitionIdentity: partitionIdentity,
                storageLayout: storageLayout,
                schema: schema,
                runtimeConfiguration: runtimeConfiguration,
                security: .enabled(),
                logging: .disabled
            )
            #else
            let configuration = CloudflareDatabaseConfiguration(
                partitionIdentity: partitionIdentity,
                schema: schema,
                runtimeConfiguration: runtimeConfiguration,
                security: .enabled(),
                logging: .disabled
            )
            #endif
            try configuration.validateHostingCapabilities()
            return configuration
        }
    }

    func makeSession(
        for database: DBContainer
    ) async throws -> RuntimeVerificationSession {
        #if CLOUDFLARE_RUNTIME_MULTI_BASE
        let baseID = try Base.ID("runtime-verification")
        _ = try await database.executionProvisionBaseRecord(
            baseID,
            placementID: database.executionDefaultBasePlacementID,
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
            container: database,
            baseID: baseID
        )
        #else
        return RuntimeVerificationSession(container: database)
        #endif
    }
}
