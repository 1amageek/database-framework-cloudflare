import CloudflareDatabase
import CloudflareDurableObjectStorage
import CloudflareDurableObjectStorageWire
import DatabaseKit
import DatabaseEngine
import DatabaseRuntime
import DatabaseServer

final class RuntimeVerificationApplication: CloudflareDatabaseApplication {
    let storageScope: StorageWireScope
    let storageLimits = CloudflareDurableObjectLimits.default

    init() throws {
        storageScope = try StorageWireScope(
            databaseID: "runtime-verification"
        )
    }

    func makeContainer(
        storageEngine: CloudflareDurableObjectStorageEngine
    ) async throws -> DBContainer {
        return try await DBContainer.open(
            for: try Schema(
                entities: [try RuntimeVerificationDocument.schemaEntity]
            ),
            configuration: DBConfiguration(
                backend: .custom(storageEngine),
                logging: .disabled
            ),
            runtimeConfiguration: try DatabaseFrameworkRuntime.configuration(
                persistableTypes: [RuntimeVerificationDocument.self]
            ),
            security: .disabled
        )
    }

    func makeServerConfiguration(
        container: DBContainer,
        jobScheduler: AnyDatabaseJobScheduler
    ) async throws -> DatabaseServerRuntimeConfiguration {
        _ = container
        let jobServiceFactory = try DatabasePersistentJobServiceFactory(
            registry: DatabaseResumableOperationRegistry(operations: []),
            scheduler: jobScheduler,
            clock: RealtimeDatabaseWallClock(),
            identifierGenerator: RandomDatabaseUUIDGenerator(),
            storageLimits: DatabasePersistentJobStorageLimits(
                maximumStorageValueBytes: 1_048_576
            )
        )
        return DatabaseServerRuntimeConfiguration(
            identity: DatabaseRuntimeIdentity(
                version: "cloudflare-runtime-verification"
            ),
            serviceFactory: AnyDatabaseServerServiceFactory(
                CanonicalDatabaseServerServiceFactory(
                    maintenanceServiceFactory:
                        DatabaseMaintenanceOperationServiceFactory(),
                    jobServiceFactory: jobServiceFactory
                )
            ),
            admissionPolicy: AnyDatabaseOperationAdmissionPolicy(
                UnrestrictedDatabaseOperationAdmissionPolicy()
            )
        )
    }
}
