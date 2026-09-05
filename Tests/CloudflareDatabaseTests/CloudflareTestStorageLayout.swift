#if CLOUDFLARE_TEST_MULTI_BASE
import CloudflareDatabase
import DatabaseEngine
import DatabaseKit

func makeCloudflareTestStorageLayout(
    namespace: String
) throws -> CloudflareDatabaseStorageLayout {
    try CloudflareDatabaseStorageLayout(
        domainID: DatabaseStorageDomain.ID("primary"),
        domainRootPath: ["database", namespace],
        placementID: Base.Placement.ID("default")
    )
}
#endif
