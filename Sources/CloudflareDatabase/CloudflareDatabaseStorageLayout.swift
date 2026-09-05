#if CLOUDFLARE_DATABASE_MULTI_BASE
import DatabaseEngine
import DatabaseKit

/// Application-selected logical layout for the single Cloudflare storage domain.
public struct CloudflareDatabaseStorageLayout: Sendable, Hashable {
    public let domainNamespacePath: [String]
    public let domainID: DatabaseStorageDomain.ID
    public let placementID: Base.Placement.ID

    public init(
        domainID: DatabaseStorageDomain.ID,
        domainNamespacePath: [String],
        placementID: Base.Placement.ID
    ) throws(CloudflareDatabaseConfigurationError) {
        guard !domainNamespacePath.isEmpty,
            domainNamespacePath.allSatisfy({ !$0.isEmpty })
        else {
            throw .invalidStorageNamespacePath
        }
        self.domainID = domainID
        self.domainNamespacePath = domainNamespacePath
        self.placementID = placementID
    }
}
#endif
