import CloudflareDatabase
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseRuntime

final class RuntimeVerificationApplication:
    CloudflareDatabaseApplication,
    Sendable {
    private let partitionIdentity: StoragePartitionIdentity
    #if CLOUDFLARE_TEST_MULTI_BASE
    private let storageLayout: CloudflareDatabaseStorageLayout
    #endif

    init() throws {
        self.partitionIdentity = try StoragePartitionIdentity(
            databaseID: "runtime-verification"
        )
        #if CLOUDFLARE_TEST_MULTI_BASE
        self.storageLayout = try makeCloudflareTestStorageLayout(
            namespace: "runtime-verification"
        )
        #endif
    }

    var configuration: CloudflareDatabaseConfiguration {
        get async throws {
            let schema = try RuntimeVerificationSchemaV1.makeSchema()
            let runtimeConfiguration = try DatabaseFrameworkRuntime.configuration(
                executionIdentity: DatabaseExecutionRuntimeIdentity(
                    identifier: "database-framework-cloudflare-tests",
                    revision: 1
                ),
                entityRuntimes: [
                    try DatabaseFrameworkRuntime.entity(
                        RuntimeVerificationDocument.self
                    )
                ],
                authorizationPolicies: [
                    AuthorizationPolicyHandler(RuntimeVerificationDocument.self)
                ]
            )
            #if CLOUDFLARE_TEST_MULTI_BASE
            return CloudflareDatabaseConfiguration(
                partitionIdentity: partitionIdentity,
                storageLayout: storageLayout,
                schema: schema,
                migrationPlan: RuntimeVerificationMigrationPlan.self,
                runtimeConfiguration: runtimeConfiguration,
                security: .enabled()
            )
            #else
            return CloudflareDatabaseConfiguration(
                partitionIdentity: partitionIdentity,
                schema: schema,
                migrationPlan: RuntimeVerificationMigrationPlan.self,
                runtimeConfiguration: runtimeConfiguration,
                security: .enabled()
            )
            #endif
        }
    }

    func makeSession(
        for database: DBContainer
    ) async throws -> RuntimeVerificationSession {
        let authorization = AuthorizationContext.authenticated(
            Principal(
                identifier: RuntimeVerificationSession.principalIdentifier,
                roles: ["admin"]
            )
        )
        #if CLOUDFLARE_TEST_MULTI_BASE
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
        try await database.session(authorization: authorization)
            .base(baseID)
            .admin()
            .migrateIfNeeded()
        return RuntimeVerificationSession(
            container: database,
            baseID: baseID
        )
        #else
        try await database.admin(authorization: authorization)
            .migrateIfNeeded()
        return RuntimeVerificationSession(container: database)
        #endif
    }
}
