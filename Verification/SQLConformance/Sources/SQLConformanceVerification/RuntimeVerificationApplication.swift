import CloudflareDatabase
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseRuntime

final class RuntimeVerificationApplication:
    CloudflareDatabaseApplication,
    Sendable {
    private let partitionIdentity: StoragePartitionIdentity

    init() throws {
        self.partitionIdentity = try StoragePartitionIdentity(
            databaseID: "runtime-verification"
        )
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
            let policyEntities = try SQLConstraintSequenceVerification.schemaEntities() + SQLDMLVerification.schemaEntities()
            entities.append(contentsOf: policyEntities)
            entityRuntimes.append(contentsOf: policyEntities.map {
                EntityRuntimeDefinition(schemaDriven: $0).registration()
            })
            authorizationPolicies.append(contentsOf: policyEntities.map { entity in
                AuthorizationPolicyHandler(schemaDriven: entity) { _, authorization in
                    authorization.principal?.identifier == RuntimeVerificationSession.principalIdentifier
                }
            })
            let indexConfigurations: [any IndexRuntimeConfiguration] = []

            let schema = try Schema(entities: entities)
            let runtimeConfiguration = try DatabaseFrameworkRuntime.configuration(
                executionIdentity: DatabaseExecutionRuntimeIdentity(
                    identifier: "database-framework-cloudflare-tests",
                    revision: 1
                ),
                entityRuntimes: entityRuntimes,
                authorizationPolicies: authorizationPolicies,
                indexConfigurations: indexConfigurations,
                schemaDrivenAuthorizationPolicyFactory: { entity in
                    AuthorizationPolicyHandler(schemaDriven: entity) { _, authorization in
                        authorization.principal?.identifier == RuntimeVerificationSession.principalIdentifier
                    }
                }
            )
            let configuration = CloudflareDatabaseConfiguration(
                partitionIdentity: partitionIdentity,
                schema: schema,
                runtimeConfiguration: runtimeConfiguration,
                security: .enabled(),
                sqlDatabaseName: "portable-verification",
                logging: .disabled
            )
            try configuration.validateHostingCapabilities()
            return configuration
        }
    }

    func makeSession(
        for database: DBContainer
    ) async throws -> RuntimeVerificationSession {
        return RuntimeVerificationSession(container: database)
    }
}
