#if CLOUDFLARE_TEST_MULTI_BASE
import CloudflareDatabase
import DatabaseEngine
import DatabaseKit
import Testing

@Suite("Cloudflare database storage layout")
struct CloudflareDatabaseStorageLayoutTests {
    @Test("layout preserves the application-selected namespace")
    func preservesTopologyIdentity() throws {
        let expectedDomainID = try DatabaseStorageDomain.ID("primary")
        let expectedPlacementID = try Base.Placement.ID("default")
        let layout = try CloudflareDatabaseStorageLayout(
            domainID: expectedDomainID,
            domainNamespacePath: ["database", "main"],
            placementID: expectedPlacementID
        )

        #expect(layout.domainID == expectedDomainID)
        #expect(layout.domainNamespacePath == ["database", "main"])
        #expect(layout.placementID == expectedPlacementID)
    }

    @Test("empty domain paths remain typed configuration failures")
    func rejectsEmptyDomainPath() throws {
        #expect(
            throws: CloudflareDatabaseConfigurationError
                .invalidStorageNamespacePath
        ) {
            try CloudflareDatabaseStorageLayout(
                domainID: DatabaseStorageDomain.ID("primary"),
                domainNamespacePath: [],
                placementID: Base.Placement.ID("default")
            )
        }
    }
}
#endif
