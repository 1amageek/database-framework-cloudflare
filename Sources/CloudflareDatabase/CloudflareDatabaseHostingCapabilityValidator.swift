#if CLOUDFLARE_DATABASE_VECTOR_INDEXES
import VectorIndex
#endif

enum CloudflareDatabaseHostingCapabilityValidator {
    static func validate(
        _ definition: CloudflareDatabaseContainerDefinition
    ) throws {
        #if CLOUDFLARE_DATABASE_VECTOR_INDEXES
        let policies = try VectorRuntimePolicy.resolveConfiguredIndexes(
            in: definition.indexConfigurations
        )
        for indexName in policies.keys.sorted() {
            guard let policy = policies[indexName] else {
                continue
            }
            if case .hnsw = policy.algorithm {
                throw CloudflareDatabaseConfigurationError.unsupportedHNSW(
                    indexName: indexName
                )
            }
        }
        #else
        _ = definition
        #endif
    }
}
