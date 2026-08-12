import CloudflareDatabase
import Testing

@Suite("Cloudflare database runtime limits")
struct CloudflareDatabaseOperationLimitsTests {
    @Test("limits reject values below minima and derive independent Wire budgets")
    func rejectsValuesBelowProtocolMinima() {
        #expect(
            throws: CloudflareDatabaseOperationLimitsError.belowMinimum(
                field: "maximumRequestBytes",
                value: 0,
                minimum: 1
            )
        ) {
            try CloudflareDatabaseOperationLimits(
                maximumRequestBytes: 0,
                maximumResponseBytes: 1,
                maximumErrorBytes:
                    CloudflareDatabaseOperationLimits.protocolMinimumErrorBytes,
                maximumPendingInvocations: 1
            )
        }
        #expect(
            throws: CloudflareDatabaseOperationLimitsError.belowMinimum(
                field: "maximumErrorBytes",
                value:
                    CloudflareDatabaseOperationLimits.protocolMinimumErrorBytes - 1,
                minimum:
                    CloudflareDatabaseOperationLimits.protocolMinimumErrorBytes
            )
        ) {
            try CloudflareDatabaseOperationLimits(
                maximumRequestBytes: 1,
                maximumResponseBytes: 1,
                maximumErrorBytes:
                    CloudflareDatabaseOperationLimits.protocolMinimumErrorBytes - 1,
                maximumPendingInvocations: 1
            )
        }

        do {
            let limits = try CloudflareDatabaseOperationLimits(
                maximumRequestBytes: 1_024,
                maximumResponseBytes: 2_048,
                maximumErrorBytes:
                    CloudflareDatabaseOperationLimits.protocolMinimumErrorBytes,
                maximumPendingInvocations: 1
            )
            #expect(try limits.requestWireLimits().maximumFrameBytes == 1_024)
            #expect(try limits.responseWireLimits().maximumFrameBytes == 2_048)
        } catch {
            Issue.record("Valid runtime limits failed: \(error)")
        }
    }

    @Test("values above protocol maxima are rejected")
    func rejectsValuesAboveProtocolMaxima() {
        #expect(throws: CloudflareDatabaseOperationLimitsError.self) {
            try CloudflareDatabaseOperationLimits(
                maximumRequestBytes:
                    CloudflareDatabaseOperationLimits.protocolMaximumFrameBytes + 1,
                maximumResponseBytes: 1,
                maximumErrorBytes:
                    CloudflareDatabaseOperationLimits.protocolMinimumErrorBytes,
                maximumPendingInvocations: 1
            )
        }
    }
}
