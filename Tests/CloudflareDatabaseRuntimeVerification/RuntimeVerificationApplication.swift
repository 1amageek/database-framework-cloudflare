import CloudflareDatabase
import CloudflareDurableObjectStorage
import CloudflareDurableObjectStorageWire
import DatabaseKit
import DatabaseEngine
import DatabaseRuntime
import DatabaseServer
#if CLOUDFLARE_RUNTIME_VECTOR_INDEXES
import DatabaseTypes
import VectorIndex
#endif
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
        var entities = [try RuntimeVerificationDocument.schemaEntity]
        var entityRuntimes = [
            try DatabaseFrameworkRuntime.entity(
                RuntimeVerificationDocument.self
            )
        ]
        #if CLOUDFLARE_RUNTIME_VECTOR_INDEXES
        entities.append(try RuntimeVerificationVectorDocument.schemaEntity)
        entityRuntimes.append(
            try DatabaseFrameworkRuntime.entity(
                RuntimeVerificationVectorDocument.self
            )
        )
        #endif

        let container = try await DBContainer.open(
            for: try Schema(
                entities: entities
            ),
            configuration: DBConfiguration(
                storageEngine: storageEngine,
                monotonicClock: monotonicClock,
                wallClock: wallClock,
                logging: .disabled
            ),
            runtimeConfiguration: try DatabaseFrameworkRuntime.configuration(
                entityRuntimes: entityRuntimes
            ),
            security: .disabled
        )
        #if CLOUDFLARE_RUNTIME_VECTOR_INDEXES
        try await verifyVectorExecution(in: container)
        #endif
        return container
    }

    #if CLOUDFLARE_RUNTIME_VECTOR_INDEXES
    private func verifyVectorExecution(in container: DBContainer) async throws {
        let expected = RuntimeVerificationVectorDocument(
            id: "embedded-vector-exact",
            title: "Exact",
            embedding: try Vector(float32: [2, 0])
        )
        let alternate = RuntimeVerificationVectorDocument(
            id: "embedded-vector-alternate",
            title: "Alternate",
            embedding: try Vector(float32: [0, 2])
        )
        let context = container.newContext()
        try context.upsert(expected)
        try context.upsert(alternate)
        try await context.save()

        let results = try await context
            .findSimilar(RuntimeVerificationVectorDocument.self)
            .vector(
                RuntimeVerificationVectorDocument.fields.embedding,
                dimensions: 2
            )
            .query([1, 0], k: 1)
            .metric(.dotProduct)
            .execute()
        guard results.count == 1,
              results[0].item.id == expected.id,
              results[0].distance.isFinite else {
            throw RuntimeVerificationError.vectorExecutionMismatch
        }

        try context.delete(expected)
        try context.delete(alternate)
        try await context.save()
    }
    #endif

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
