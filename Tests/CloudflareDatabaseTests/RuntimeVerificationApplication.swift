import CloudflareDatabase
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseRuntime

final class RuntimeVerificationApplication:
    CloudflareDatabaseApplication,
    Sendable {
    private let partitionIdentity: StoragePartitionIdentity
    #if CLOUDFLARE_TEST_MULTIPLE_BASES
    private let storageLayout: CloudflareDatabaseStorageLayout
    #endif

    init() throws {
        self.partitionIdentity = try StoragePartitionIdentity(
            databaseID: "runtime-verification"
        )
        #if CLOUDFLARE_TEST_MULTIPLE_BASES
        self.storageLayout = try makeCloudflareTestStorageLayout(
            namespace: "runtime-verification"
        )
        #endif
    }

    func makeDefinition() async throws -> CloudflareDatabaseDefinition {
        let schema = try RuntimeVerificationSchemaV1.makeSchema()
        let runtimeConfiguration = try DatabaseFrameworkRuntime.configuration(
            entityRuntimes: [
                try DatabaseFrameworkRuntime.entity(
                    RuntimeVerificationDocument.self
                )
            ],
            authorizationPolicies: [
                AuthorizationPolicyHandler(RuntimeVerificationDocument.self)
            ]
        )
        #if CLOUDFLARE_TEST_MULTIPLE_BASES
        return CloudflareDatabaseDefinition(
            partitionIdentity: partitionIdentity,
            storageLayout: storageLayout,
            schema: schema,
            migrationPlan: RuntimeVerificationMigrationPlan.self,
            runtimeConfiguration: runtimeConfiguration,
            security: .enabled()
        )
        #else
        return CloudflareDatabaseDefinition(
            partitionIdentity: partitionIdentity,
            schema: schema,
            migrationPlan: RuntimeVerificationMigrationPlan.self,
            runtimeConfiguration: runtimeConfiguration,
            security: .enabled()
        )
        #endif
    }

    func makeSession(
        for container: DBContainer
    ) async throws -> RuntimeVerificationSession {
        #if CLOUDFLARE_TEST_MULTIPLE_BASES
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
