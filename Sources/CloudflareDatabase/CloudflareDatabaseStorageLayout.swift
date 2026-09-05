#if CLOUDFLARE_DATABASE_MULTI_BASE
import DatabaseEngine
import DatabaseKit

/// Application-selected logical layout for the single Cloudflare storage domain.
///
/// `database-framework` addresses a Base Partition at `bases/<Base.ID>` below
/// its domain's database root, so a placement names a domain and carries no
/// path of its own.
public struct CloudflareDatabaseStorageLayout: Sendable, Hashable {
    /// Directory path of the domain's database root.
    public let domainRootPath: [String]
    public let domainID: DatabaseStorageDomain.ID
    public let placementID: Base.Placement.ID

    public init(
        domainID: DatabaseStorageDomain.ID,
        domainRootPath: [String],
        placementID: Base.Placement.ID
    ) throws(CloudflareDatabaseConfigurationError) {
        guard !domainRootPath.isEmpty,
            domainRootPath.allSatisfy({ !$0.isEmpty })
        else {
            throw .invalidStorageDomainRootPath
        }
        self.domainID = domainID
        self.domainRootPath = domainRootPath
        self.placementID = placementID
    }
}
#endif
