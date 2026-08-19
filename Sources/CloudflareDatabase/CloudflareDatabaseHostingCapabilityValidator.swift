#if CLOUDFLARE_DATABASE_VECTOR_INDEXES
import DatabaseEngine
import VectorIndex
#endif

enum CloudflareDatabaseHostingCapabilityValidator {
    static func validate(
        _ configuration: CloudflareDatabaseConfiguration
    ) throws(CloudflareDatabaseConfigurationError) {
        #if CLOUDFLARE_DATABASE_VECTOR_INDEXES
        let policies: [String: VectorRuntimePolicy]
        do {
            policies = try VectorRuntimePolicy.resolveConfiguredIndexes(
                in: configuration.runtimeConfiguration.indexConfigurations
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
        _ = configuration
        #endif
    }
}
