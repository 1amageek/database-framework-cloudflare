/// Configuration failures enforced by the Cloudflare hosting boundary.
public enum CloudflareDatabaseConfigurationError:
    Error,
    Sendable,
    Equatable,
    CustomStringConvertible {
    /// The configured vector index requires HNSW, which this host cannot run.
    case unsupportedHNSW(indexName: String)

    public var description: String {
        switch self {
        case .unsupportedHNSW(let indexName):
            return "Cloudflare hosting does not support HNSW for vector index '\(indexName)'"
        }
    }
}
