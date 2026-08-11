import CloudflareDatabase
import DatabaseEngine
import DatabaseKit

func makeCloudflareTestStorageLayout(
    namespace: String
) throws -> CloudflareDatabaseStorageLayout {
    #if CLOUDFLARE_TEST_MULTIPLE_BASES
    try CloudflareDatabaseStorageLayout(
        domainID: DatabaseStorageDomain.ID("primary"),
        domainNamespacePath: ["database", namespace],
        placementID: Base.Placement.ID("default"),
        baseNamespacePath: ["bases"]
    )
    #else
    try CloudflareDatabaseStorageLayout(
        domainID: DatabaseStorageDomain.ID("primary"),
        domainNamespacePath: ["database", namespace]
    )
    #endif
}
