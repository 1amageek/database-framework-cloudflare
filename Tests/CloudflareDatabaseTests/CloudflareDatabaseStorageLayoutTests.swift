#if CLOUDFLARE_TEST_MULTI_BASE
import CloudflareDatabase
import DatabaseEngine
import DatabaseKit
import Testing

@Suite("Cloudflare database storage layout")
struct CloudflareDatabaseStorageLayoutTests {
    @Test("layout preserves the application-selected domain root")
    func preservesTopologyIdentity() throws {
        let expectedDomainID = try DatabaseStorageDomain.ID("primary")
        let expectedPlacementID = try Base.Placement.ID("default")
        let layout = try CloudflareDatabaseStorageLayout(
            domainID: expectedDomainID,
            domainRootPath: ["database", "main"],
            placementID: expectedPlacementID
        )

        #expect(layout.domainID == expectedDomainID)
        #expect(layout.domainRootPath == ["database", "main"])
        #expect(layout.placementID == expectedPlacementID)
    }

    @Test("empty domain root paths remain typed configuration failures")
    func rejectsEmptyPaths() throws {
        #expect(
            throws: CloudflareDatabaseConfigurationError
                .invalidStorageDomainRootPath
        ) {
            try CloudflareDatabaseStorageLayout(
                domainID: DatabaseStorageDomain.ID("primary"),
                domainRootPath: [],
                placementID: Base.Placement.ID("default")
            )
        }
        #expect(
            throws: CloudflareDatabaseConfigurationError
                .invalidStorageDomainRootPath
        ) {
            try CloudflareDatabaseStorageLayout(
                domainID: DatabaseStorageDomain.ID("primary"),
                domainRootPath: ["database", ""],
                placementID: Base.Placement.ID("default")
            )
        }
    }
}
#endif
