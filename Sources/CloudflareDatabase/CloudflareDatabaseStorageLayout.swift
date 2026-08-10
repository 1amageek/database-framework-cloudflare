import DatabaseEngine
import DatabaseKit

/// Application-selected logical layout for the single Cloudflare storage domain.
///
/// The Durable Object remains one physical transaction domain. DatabaseFramework
/// resolves every Base root below the named placement and owns all Base semantics.
public struct CloudflareDatabaseStorageLayout: Sendable, Hashable {
    public let domainID: DatabaseStorageDomain.ID
    public let domainNamespacePath: [String]
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
