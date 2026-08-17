#if CLOUDFLARE_DATABASE_VECTOR_INDEXES
import VectorIndex
#endif

enum CloudflareDatabaseHostingCapabilityValidator {
    static func validate(
        _ definition: CloudflareDatabaseDefinition
    ) throws(CloudflareDatabaseConfigurationError) {
        #if CLOUDFLARE_DATABASE_VECTOR_INDEXES
        let policies: [String: VectorRuntimePolicy]
        do {
            policies = try VectorRuntimePolicy.resolveConfiguredIndexes(
                in: definition.indexConfigurations
            )
        } catch {
            throw .invalidVectorConfiguration
        }
        for indexName in policies.keys.sorted() {
            guard let policy = policies[indexName] else {
                continue
            }
            if case .hnsw = policy.algorithm {
                throw .unsupportedHNSW(indexName: indexName)
            }
        }
        #else
        _ = definition
        #endif
    }
}
