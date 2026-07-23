import CloudflareDatabase
import Testing

@Suite("Cloudflare database runtime limits")
struct CloudflareDatabaseRuntimeLimitsTests {
    @Test("non-positive values are rejected")
    func rejectsNonPositiveValues() {
        #expect(throws: CloudflareDatabaseRuntimeLimitsError.self) {
            try CloudflareDatabaseRuntimeLimits(
                maximumRequestBytes: 0,
                maximumResponseBytes: 1,
                maximumErrorBytes: 1,
                maximumPendingInvocations: 1
            )
        }
    }

    @Test("values above protocol maxima are rejected")
    func rejectsValuesAboveProtocolMaxima() {
        #expect(throws: CloudflareDatabaseRuntimeLimitsError.self) {
            try CloudflareDatabaseRuntimeLimits(
                maximumRequestBytes:
                    CloudflareDatabaseRuntimeLimits.protocolMaximumFrameBytes + 1,
                maximumResponseBytes: 1,
                maximumErrorBytes: 1,
                maximumPendingInvocations: 1
            )
        }
    }
}
