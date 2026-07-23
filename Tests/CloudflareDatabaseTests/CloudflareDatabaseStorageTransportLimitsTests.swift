import CloudflareDatabase
import Testing

struct CloudflareDatabaseStorageTransportLimitsTests {
    @Test("Storage transport frame limits are independent and bounded")
    func validatesIndependentLimits() throws {
        let limits = try CloudflareDatabaseStorageTransportLimits(
            maximumRequestBytes: 1_024,
            maximumResponseBytes: 2_048
        )

        #expect(limits.maximumRequestBytes == 1_024)
        #expect(limits.maximumResponseBytes == 2_048)
    }

    @Test("Storage transport frame limits reject invalid values")
    func rejectsInvalidLimits() {
        #expect(throws: CloudflareDatabaseStorageTransportLimitsError.self) {
            try CloudflareDatabaseStorageTransportLimits(
                maximumRequestBytes: 0,
                maximumResponseBytes: 1
            )
        }
        #expect(throws: CloudflareDatabaseStorageTransportLimitsError.self) {
            try CloudflareDatabaseStorageTransportLimits(
                maximumRequestBytes: 1,
                maximumResponseBytes:
                    CloudflareDatabaseStorageTransportLimits
                        .protocolMaximumFrameBytes + 1
            )
        }
    }
}
