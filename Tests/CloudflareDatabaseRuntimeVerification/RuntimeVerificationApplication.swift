import CloudflareDatabase
import CloudflareDurableObjectStorage
import CloudflareDurableObjectStorageWire
import DatabaseKit
import DatabaseEngine
import DatabaseRuntime
import DatabaseServer
#if !arch(wasm32)
import DatabaseServerFoundation
import StorageKitSystemClock
#endif

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
        #if arch(wasm32)
        let monotonicClock = CloudflareDatabaseMonotonicClock()
        let wallClock = CloudflareDatabaseWallClock()
        #else
        let monotonicClock = SystemStorageClock()
        let wallClock = RealtimeDatabaseWallClock()
        #endif
        return try await DBContainer.open(
            for: try Schema(
                entities: [try RuntimeVerificationDocument.schemaEntity]
            ),
            configuration: DBConfiguration(
                storageEngine: storageEngine,
                monotonicClock: monotonicClock,
                wallClock: wallClock,
                logging: .disabled
            ),
            runtimeConfiguration: try DatabaseFrameworkRuntime.configuration(
                entityRuntimes: [
                    try DatabaseFrameworkRuntime.entity(
                        RuntimeVerificationDocument.self
                    )
                ]
            ),
            security: .disabled
        )
    }

    func makeServerConfiguration(
        container: DBContainer,
        jobScheduler: AnyDatabaseJobScheduler
    ) async throws -> DatabaseServerRuntimeConfiguration {
        _ = container
        #if arch(wasm32)
        let clock = CloudflareDatabaseWallClock()
        let identifierGenerator = CloudflareDatabaseUUIDGenerator()
        #else
        let clock = RealtimeDatabaseWallClock()
        let identifierGenerator = RandomDatabaseUUIDGenerator()
        #endif
        let jobServiceFactory = try DatabasePersistentJobServiceFactory(
            registry: DatabaseResumableOperationRegistry(operations: []),
            scheduler: jobScheduler,
            identifierGenerator: identifierGenerator,
            storageLimits: DatabasePersistentJobStorageLimits(
                maximumStorageValueBytes: 1_048_576
            )
        )
        return try DatabaseServerRuntimeConfiguration(
            identity: DatabaseRuntimeIdentity(
                version: "cloudflare-runtime-verification"
            ),
            serviceFactory: AnyDatabaseServerServiceFactory(
                CanonicalDatabaseServerServiceFactory(
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
