import CloudflareDatabase
import Testing

@Suite("Cloudflare database runtime limits")
struct CloudflareDatabaseRuntimeLimitsTests {
    @Test("payload limits are independent and bounded")
    func validatesPayloadLimits() throws {
        #expect(
            throws: CloudflareDatabaseRuntimeLimitsError.belowMinimum(
                field: "maximumContextBytes",
                value: 0,
                minimum: 1
            )
        ) {
            try CloudflareDatabaseRuntimeLimits(
                maximumContextBytes: 0,
                maximumRequestBytes: 1,
                maximumResponseBytes: 1,
                maximumErrorBytes:
                    CloudflareDatabaseRuntimeLimits.minimumErrorBytes,
                maximumPendingInvocations: 1
            )
        }

        let limits = try CloudflareDatabaseRuntimeLimits(
            maximumContextBytes: 1_024,
            maximumRequestBytes: 2_048,
            maximumResponseBytes: 4_096,
            maximumErrorBytes:
                CloudflareDatabaseRuntimeLimits.minimumErrorBytes,
            maximumPendingInvocations: 8
        )
        #expect(limits.maximumContextBytes == 1_024)
        #expect(limits.maximumRequestBytes == 2_048)
        #expect(limits.maximumResponseBytes == 4_096)
    }

    @Test("values above adapter maxima are rejected")
    func rejectsValuesAboveMaximum() {
        #expect(throws: CloudflareDatabaseRuntimeLimitsError.self) {
            try CloudflareDatabaseRuntimeLimits(
                maximumContextBytes:
                    CloudflareDatabaseRuntimeLimits.maximumPayloadBytes + 1,
                maximumRequestBytes: 1,
                maximumResponseBytes: 1,
                maximumErrorBytes:
                    CloudflareDatabaseRuntimeLimits.minimumErrorBytes,
                maximumPendingInvocations: 1
            )
        }
    }
}
