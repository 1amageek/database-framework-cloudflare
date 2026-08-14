#if CLOUDFLARE_TEST_MULTIPLE_BASES
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
            placementID: expectedPlacementID,
            baseNamespacePath: ["bases"]
        )

        #expect(layout.domainID == expectedDomainID)
        #expect(layout.domainNamespacePath == ["database", "main"])
        #expect(layout.placementID == expectedPlacementID)
        #expect(layout.baseNamespacePath == ["bases"])
    }

    @Test("empty topology paths remain typed configuration failures")
    func rejectsEmptyPaths() throws {
        #expect(
            throws: CloudflareDatabaseConfigurationError
                .invalidStorageNamespacePath
        ) {
            try CloudflareDatabaseStorageLayout(
                domainID: DatabaseStorageDomain.ID("primary"),
                domainNamespacePath: [],
                placementID: Base.Placement.ID("default"),
                baseNamespacePath: ["bases"]
            )
        }
        #expect(
            throws: CloudflareDatabaseConfigurationError
                .invalidBasePlacementPath
        ) {
            try CloudflareDatabaseStorageLayout(
                domainID: DatabaseStorageDomain.ID("primary"),
                domainNamespacePath: ["database"],
                placementID: Base.Placement.ID("default"),
                baseNamespacePath: [""]
            )
        }
    }
}
#endif
