import CloudflareDatabase
import CloudflareDurableObjectStorage
import Core
import DatabaseEngine
import DatabaseRuntime
import DatabaseServer

final class RuntimeVerificationApplication: CloudflareDatabaseApplication {
    let storageScope: CloudflareDurableObjectStorageScope
    let storageLimits = CloudflareDurableObjectLimits.default

    init() throws {
        storageScope = try CloudflareDurableObjectStorageScope(
            databaseID: "runtime-verification"
        )
    }

    func makeContainer(
        storageEngine: CloudflareDurableObjectStorageEngine
    ) async throws -> DBContainer {
        return try await DBContainer.open(
            for: Schema([RuntimeVerificationDocument.self]),
            configuration: DBConfiguration(
                backend: .custom(storageEngine),
                logging: .disabled
            ),
            runtimeConfiguration: try DatabaseFrameworkRuntime.configuration(),
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
