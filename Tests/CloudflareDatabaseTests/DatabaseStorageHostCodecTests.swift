import CloudflareDatabase
import DatabaseEngine
import Testing

@Suite("Database storage host codec")
struct DatabaseStorageHostCodecTests {
    @Test func requestRoundTripsReadScanAndCommit() throws {
        let requests: [DatabaseStorageHostRequest] = [
            .read(key: [0x01, 0x02]),
            .scan(begin: [0x01], end: [0x02], limit: 10, reverse: true),
            .commit([
                .set(key: [0x01], value: [0x10]),
                .clear(key: [0x02]),
            ]),
        ]

        for request in requests {
            let decoded = try DatabaseStorageHostCodec.decodeRequest(
                DatabaseStorageHostCodec.encode(request: request)
            )
            #expect(decoded == request)
        }
    }

    @Test func responseRoundTripsReadScanCommitAndFailure() throws {
        let responses: [DatabaseStorageHostResponse] = [
            .read(nil),
            .read([0x10]),
            .scan([
                DatabaseKeyValue(key: [0x01], value: [0x10]),
                DatabaseKeyValue(key: [0x02], value: [0x20]),
            ]),
            .committed,
            .failure("failed"),
        ]

        for response in responses {
            let decoded = try DatabaseStorageHostCodec.decodeResponse(
                DatabaseStorageHostCodec.encode(response: response)
            )
            #expect(decoded == response)
        }
    }
}
