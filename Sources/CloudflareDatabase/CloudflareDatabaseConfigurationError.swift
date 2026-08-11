/// Configuration failures enforced by the Cloudflare hosting boundary.
public enum CloudflareDatabaseConfigurationError:
    Error,
    Sendable,
    Equatable,
    CustomStringConvertible {
    /// The configured vector execution policy is malformed or cannot be
    /// represented by the vector runtime.
    case invalidVectorConfiguration

    /// The configured vector index requires HNSW, which this host cannot run.
    case unsupportedHNSW(indexName: String)

    /// A Cloudflare storage namespace path is empty or has an empty component.
    case invalidStorageNamespacePath

    #if CLOUDFLARE_DATABASE_MULTIPLE_BASES
    /// A Cloudflare Base placement path is empty or has an empty component.
    case invalidBasePlacementPath
    #endif

    public var description: String {
        switch self {
        case .invalidVectorConfiguration:
            return "Cloudflare hosting could not resolve the vector index configuration"
        case .unsupportedHNSW(let indexName):
            return "Cloudflare hosting does not support HNSW for vector index '\(indexName)'"
        case .invalidStorageNamespacePath:
            return "Cloudflare storage namespace path must contain only non-empty components"
        #if CLOUDFLARE_DATABASE_MULTIPLE_BASES
        case .invalidBasePlacementPath:
            return "Cloudflare Base placement path must contain only non-empty components"
        #endif
        }
    }
}
