import CloudflareDatabase
import CloudflareDurableObjectStorage
import CloudflareDurableObjectStorageWire
import DatabaseKit
import DatabaseEngine
import DatabaseRuntime
import DatabaseServer
import StorageKit
#if CLOUDFLARE_RUNTIME_VECTOR_INDEXES
import DatabaseTypes
import VectorIndex
#endif
#if !arch(wasm32)
import DatabaseServerFoundation
import StorageKitSystemClock
#endif

final class RuntimeVerificationApplication: CloudflareDatabaseApplication {
    let partitionIdentity: StoragePartitionIdentity
    let storageLimits = CloudflareDurableObjectLimits.default

    init() throws {
        partitionIdentity = try StoragePartitionIdentity(
            databaseID: "runtime-verification"
        )
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
                entityRuntimes: entityRuntimes
            ),
            security: .disabled,
            monotonicClock: monotonicClock,
            wallClock: wallClock,
            indexConfigurations: indexConfigurations,
            logging: .disabled
        )
    }

    #if CLOUDFLARE_RUNTIME_VECTOR_INDEXES
    private func verifyVectorExecution(in container: DBContainer) async throws {
        try await verifyIVF(in: container)
        try await verifyPQ(in: container)
        try await verifyFlat(in: container)
    }

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
            security: .disabled,
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

    private func verifyIVF(in container: DBContainer) async throws {
        let expected = RuntimeVerificationIVFDocument(
            id: "embedded-vector-ivf-exact",
            title: "Exact",
            embedding: try Vector(float32: [2, 0])
        )
        let alternate = RuntimeVerificationIVFDocument(
            id: "embedded-vector-ivf-alternate",
            title: "Alternate",
            embedding: try Vector(float32: [0, 2])
        )
        let context = container.newContext()
        try context.upsert(expected)
        try context.upsert(alternate)
        try await context.save()
        try await context.indexQueryContext.trainVectorIndex(
            named: "RuntimeVerificationIVFDocument_embedding",
            for: RuntimeVerificationIVFDocument.self
        )
        let results = try await context
            .findSimilar(RuntimeVerificationIVFDocument.self)
            .vector(
                RuntimeVerificationIVFDocument.fields.embedding,
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

    private func verifyPQ(in container: DBContainer) async throws {
        let expected = RuntimeVerificationPQDocument(
            id: "embedded-vector-pq-exact",
            title: "Exact",
            embedding: try Vector(float32: [2, 0])
        )
        let alternate = RuntimeVerificationPQDocument(
            id: "embedded-vector-pq-alternate",
            title: "Alternate",
            embedding: try Vector(float32: [0, 2])
        )
        let context = container.newContext()
        try context.upsert(expected)
        try context.upsert(alternate)
        try await context.save()
        try await context.indexQueryContext.trainVectorIndex(
            named: "RuntimeVerificationPQDocument_embedding",
            for: RuntimeVerificationPQDocument.self
        )
        let results = try await context
            .findSimilar(RuntimeVerificationPQDocument.self)
            .vector(
                RuntimeVerificationPQDocument.fields.embedding,
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

    private func verifyFlat(in container: DBContainer) async throws {
        let expected = RuntimeVerificationFlatDocument(
            id: "embedded-vector-flat-exact",
            title: "Exact",
            embedding: try Vector(float32: [2, 0])
        )
        let alternate = RuntimeVerificationFlatDocument(
            id: "embedded-vector-flat-alternate",
            title: "Alternate",
            embedding: try Vector(float32: [0, 2])
        )
        let context = container.newContext()
        try context.upsert(expected)
        try context.upsert(alternate)
        try await context.save()
        let results = try await context
            .findSimilar(RuntimeVerificationFlatDocument.self)
            .vector(
                RuntimeVerificationFlatDocument.fields.embedding,
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

    func makeRuntimeConfiguration(
        for container: DBContainer
    ) async throws -> DatabaseServerRuntimeConfiguration {
        #if CLOUDFLARE_RUNTIME_VECTOR_INDEXES
        try await verifyVectorExecution(in: container)
        #endif
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
