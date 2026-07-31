import CloudflareDatabase
import Testing

@Suite("Cloudflare database runtime limits")
struct CloudflareDatabaseRuntimeLimitsTests {
    @Test("values below protocol minima are rejected")
    func rejectsValuesBelowProtocolMinima() {
        #expect(
            throws: CloudflareDatabaseRuntimeLimitsError.belowMinimum(
                field: "maximumRequestBytes",
                value: 0,
                minimum: 1
            )
        ) {
            try CloudflareDatabaseRuntimeLimits(
                maximumRequestBytes: 0,
                maximumResponseBytes: 1,
                maximumErrorBytes:
                    CloudflareDatabaseRuntimeLimits.protocolMinimumErrorBytes,
                maximumPendingInvocations: 1
            )
        }
        #expect(
            throws: CloudflareDatabaseRuntimeLimitsError.belowMinimum(
                field: "maximumErrorBytes",
                value:
                    CloudflareDatabaseRuntimeLimits.protocolMinimumErrorBytes - 1,
                minimum:
                    CloudflareDatabaseRuntimeLimits.protocolMinimumErrorBytes
            )
        ) {
            try CloudflareDatabaseRuntimeLimits(
                maximumRequestBytes: 1,
                maximumResponseBytes: 1,
                maximumErrorBytes:
                    CloudflareDatabaseRuntimeLimits.protocolMinimumErrorBytes - 1,
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
                maximumErrorBytes:
                    CloudflareDatabaseRuntimeLimits.protocolMinimumErrorBytes,
                maximumPendingInvocations: 1
            )
        }
    }
}
