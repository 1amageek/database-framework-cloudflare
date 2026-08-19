#if CLOUDFLARE_TEST_VECTOR_INDEXES
import CloudflareDatabase
import StorageKitSystemClock
import Testing

@Suite("Cloudflare database hosting capabilities")
struct CloudflareDatabaseHostingCapabilityTests {
    @Test("HNSW is rejected before platform storage opens")
    func rejectsHNSW() async throws {
        let application = try CloudflareHNSWRejectionApplication()
        let configuration = try await application.configuration
        #expect(
            throws: CloudflareDatabaseConfigurationError.unsupportedHNSW(
                indexName: "CloudflareHNSWRejectionDocument_embedding"
            )
        ) {
            try configuration.validateHostingCapabilities()
        }

        let completion = RecordingCloudflareDatabaseCompletion()
        let storageClient = UnexpectedStorageAccessClient()
        let runtime = CloudflareDatabaseRuntime(
            application: application,
            storageClient: storageClient,
            monotonicClock: SystemStorageClock(),
            wallClock: FixedCloudflareTestWallClock(),
            completion: CloudflareDatabaseCompletionChannel(
                completion: completion
            )
        )
        await runtime.start(callID: 1)
        #expect(completion.completion(callID: 1)?.status == .startupFailed)
        #expect(await storageClient.recordedAccessCount() == 0)
    }

    @Test("custom canonical HNSW configuration cannot bypass admission")
    func rejectsCustomHNSWConfiguration() async throws {
        let configuration = try await CloudflareHNSWRejectionApplication(
            indexConfiguration: CustomHNSWRuntimeConfiguration()
        ).configuration

        #expect(
            throws: CloudflareDatabaseConfigurationError.unsupportedHNSW(
                indexName: "CloudflareHNSWRejectionDocument_embedding"
            )
        ) {
            try configuration.validateHostingCapabilities()
        }
    }

    @Test("invalid vector configuration remains a typed failure")
    func rejectsInvalidVectorConfiguration() async throws {
        let configuration = try await CloudflareHNSWRejectionApplication(
            indexConfiguration: InvalidVectorRuntimeConfiguration()
        ).configuration

        #expect(
            throws: CloudflareDatabaseConfigurationError
                .invalidVectorConfiguration
        ) {
            try configuration.validateHostingCapabilities()
        }
    }
}
#endif
