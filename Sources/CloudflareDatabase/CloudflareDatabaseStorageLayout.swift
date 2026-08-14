#if CLOUDFLARE_DATABASE_MULTIPLE_BASES
import DatabaseEngine
import DatabaseKit

/// Application-selected logical layout for the single Cloudflare storage domain.
public struct CloudflareDatabaseStorageLayout: Sendable, Hashable {
    public let domainNamespacePath: [String]
    public let domainID: DatabaseStorageDomain.ID
    public let placementID: Base.Placement.ID
    public let baseNamespacePath: [String]

    public init(
        domainID: DatabaseStorageDomain.ID,
        domainNamespacePath: [String],
        placementID: Base.Placement.ID,
        baseNamespacePath: [String]
    ) throws(CloudflareDatabaseConfigurationError) {
        guard !domainNamespacePath.isEmpty,
              domainNamespacePath.allSatisfy({ !$0.isEmpty }) else {
            throw .invalidStorageNamespacePath
        }
        guard !baseNamespacePath.isEmpty,
              baseNamespacePath.allSatisfy({ !$0.isEmpty }) else {
            throw .invalidBasePlacementPath
        }
        self.domainID = domainID
        self.domainNamespacePath = domainNamespacePath
        self.placementID = placementID
        self.baseNamespacePath = baseNamespacePath
    }
}
#endif
