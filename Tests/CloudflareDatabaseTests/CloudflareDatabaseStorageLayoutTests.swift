import CloudflareDatabase
import DatabaseEngine
import DatabaseKit
import Testing

@Suite("Cloudflare database storage layout")
struct CloudflareDatabaseStorageLayoutTests {
    @Test("layout preserves the framework-owned domain and placement identity")
    func preservesTopologyIdentity() throws {
        let expectedDomainID = try DatabaseStorageDomain.ID("primary")
        #if CLOUDFLARE_TEST_MULTIPLE_BASES
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
        #else
        let layout = try CloudflareDatabaseStorageLayout(
            domainID: expectedDomainID,
            domainNamespacePath: ["database", "main"]
        )

        #expect(layout.domainID == expectedDomainID)
        #expect(layout.domainNamespacePath == ["database", "main"])
        #endif
    }

    @Test("empty topology paths remain typed configuration failures")
    func rejectsEmptyPaths() throws {
        #expect(
            throws: CloudflareDatabaseConfigurationError
                .invalidStorageNamespacePath
        ) {
            #if CLOUDFLARE_TEST_MULTIPLE_BASES
            try CloudflareDatabaseStorageLayout(
                domainID: DatabaseStorageDomain.ID("primary"),
                domainNamespacePath: [],
                placementID: Base.Placement.ID("default"),
                baseNamespacePath: ["bases"]
            )
            #else
            try CloudflareDatabaseStorageLayout(
                domainID: DatabaseStorageDomain.ID("primary"),
                domainNamespacePath: []
            )
            #endif
        }
        #if CLOUDFLARE_TEST_MULTIPLE_BASES
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
        #endif
    }
}
