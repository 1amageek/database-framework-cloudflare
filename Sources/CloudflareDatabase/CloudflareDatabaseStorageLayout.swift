import DatabaseEngine
#if CLOUDFLARE_DATABASE_MULTIPLE_BASES
import DatabaseKit
#endif

/// Application-selected logical layout for the single Cloudflare storage domain.
public struct CloudflareDatabaseStorageLayout: Sendable, Hashable {
    public let domainID: DatabaseStorageDomain.ID
    public let domainNamespacePath: [String]
    #if CLOUDFLARE_DATABASE_MULTIPLE_BASES
    public let placementID: Base.Placement.ID
    public let baseNamespacePath: [String]
    #endif

    #if CLOUDFLARE_DATABASE_MULTIPLE_BASES
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
    #else
    public init(
        domainID: DatabaseStorageDomain.ID,
        domainNamespacePath: [String]
    ) throws(CloudflareDatabaseConfigurationError) {
        guard !domainNamespacePath.isEmpty,
              domainNamespacePath.allSatisfy({ !$0.isEmpty }) else {
            throw .invalidStorageNamespacePath
        }
        self.domainID = domainID
        self.domainNamespacePath = domainNamespacePath
    }
    #endif
}
