import DatabaseTypes
import DatabaseWire
import Foundation
import Testing

@Suite("Runtime verification request vectors")
struct RuntimeVerificationRequestVectorTests {
    @Test("golden requests are emitted by the canonical Swift encoder")
    func matchesCanonicalEncoder() throws {
        let testDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let repositoryDirectory = testDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let vectorURL = repositoryDirectory.appending(
            path: "Protocol/runtime-verification-requests-v1.json"
        )
        let data = try Data(contentsOf: vectorURL)
        let vectors = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: [Int]]
        )

        let identity = try EntityReference(
            entity: RuntimeVerificationDocument.persistableType,
            id: .string("document-1")
        )
        let expected: [(String, ByteString)] = [
            (
                "capabilitiesDescribe",
                try DatabaseWireEncoder().encodeRequest(
                    DatabaseOperations.capabilitiesDescribe,
                    requestID: 60,
                    metadata: OperationRequestMetadata(),
                    request: EmptyOperationPayload()
                )
            ),
            (
                "schemaDescribe",
                try DatabaseWireEncoder().encodeRequest(
                    DatabaseOperations.schemaDescribe,
                    requestID: 61,
                    metadata: OperationRequestMetadata(),
                    request: EmptyOperationPayload()
                )
            ),
            (
                "mutationExecute",
                try DatabaseWireEncoder().encodeRequest(
                    DatabaseOperations.mutationExecute,
                    requestID: 62,
                    metadata: OperationRequestMetadata(
                        idempotencyKey: "runtime-document-1"
                    ),
                    request: MutationExecuteOperation.Request(
                        input: .entities([
                            MutationExecuteOperation.Change(
                                kind: .insert,
                                identity: identity,
                                fields: try FieldObject([
                                    (
                                        key: "id",
                                        value: .string("document-1")
                                    ),
                                    (
                                        key: "title",
                                        value: .string("Cloudflare runtime")
                                    ),
                                ])
                            )
                        ])
                    )
                )
            ),
            (
                "queryExecute",
                try DatabaseWireEncoder().encodeRequest(
                    DatabaseOperations.queryExecute,
                    requestID: 63,
                    metadata: OperationRequestMetadata(),
                    request: QueryExecuteOperation.Request(
                        input: .text(
                            language: .sql,
                            statement:
                                "SELECT id, title FROM RuntimeVerificationDocument"
                        )
                    )
                )
            ),
        ]

        #expect(Set(vectors.keys) == Set(expected.map(\.0)))
        for (name, encodedRequest) in expected {
            let storedBytes = try #require(vectors[name])
            #expect(storedBytes.allSatisfy { (0 ... 255).contains($0) })
            #expect(encodedRequest == ByteString(storedBytes.map(UInt8.init)))
        }
    }
}
