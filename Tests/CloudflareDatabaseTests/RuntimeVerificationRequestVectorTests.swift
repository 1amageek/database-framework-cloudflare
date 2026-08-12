import DatabaseTypes
import DatabaseKit
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
        try verifyVectors(
            at: repositoryDirectory.appending(
                path: "Protocol/runtime-verification-requests-standard-v1.json"
            ),
            expected: expectedRequests(
                target: .database,
                includesBaseCreate: false
            )
        )
        let baseID = try Base.ID("runtime-verification")
        try verifyVectors(
            at: repositoryDirectory.appending(
                path:
                    "Protocol/runtime-verification-requests-multiple-bases-v1.json"
            ),
            expected: expectedRequests(
                target: .base(baseID),
                includesBaseCreate: true
            )
        )
    }

    private func expectedRequests(
        target: DatabaseOperationTarget,
        includesBaseCreate: Bool
    ) throws -> [(String, ByteString)] {
        let identity = try EntityReference(
            entity: RuntimeVerificationDocument.persistableType,
            id: .string("document-1")
        )
        let baseID = try Base.ID("runtime-verification")
        var expected: [(String, ByteString)] = [
            (
                "capabilitiesDescribe",
                try DatabaseWireEncoder().encodeRequest(
                    DatabaseOperationCatalog.capabilitiesDescribe,
                    requestID: 60,
                    target: .database,
                    metadata: OperationRequestMetadata(),
                    request: EmptyOperationPayload()
                )
            ),
            (
                "schemaDescribe",
                try DatabaseWireEncoder().encodeRequest(
                    DatabaseOperationCatalog.schemaDescribe,
                    requestID: 61,
                    target: .database,
                    metadata: OperationRequestMetadata(),
                    request: EmptyOperationPayload()
                )
            ),
        ]
        if includesBaseCreate {
            expected.append(
                (
                    "baseCreate",
                    try DatabaseWireEncoder().encodeRequest(
                        DatabaseOperationCatalog.baseExecute,
                        requestID: 65,
                        target: .database,
                        metadata: OperationRequestMetadata(
                            idempotencyKey: "runtime-verification-base"
                        ),
                        request: BaseExecuteOperation.Request(
                            invocation: .create(
                                baseID: baseID,
                                placementID: try Base.Placement.ID("default"),
                                initialGrants: [
                                    Security.Grant(
                                        subject: .principal(
                                            "runtime-verification"
                                        ),
                                        resource: .base(baseID),
                                        access: .all
                                    ),
                                ],
                                expectedRevision: 0,
                                idempotencyKey: "runtime-verification-base"
                            )
                        )
                    )
                )
            )
        }
        expected.append(contentsOf: [
            (
                "mutationExecute",
                try DatabaseWireEncoder().encodeRequest(
                    DatabaseOperationCatalog.mutationExecute,
                    requestID: 62,
                    target: target,
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
                    DatabaseOperationCatalog.queryExecute,
                    requestID: 63,
                    target: target,
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
            (
                "queryAsk",
                try DatabaseWireEncoder().encodeRequest(
                    DatabaseOperationCatalog.queryExecute,
                    requestID: 64,
                    target: target,
                    metadata: OperationRequestMetadata(),
                    request: QueryExecuteOperation.Request(
                        input: .text(
                            language: .sparql,
                            statement: """
                                ASK { GRAPH <https://example.invalid/graph/runtime-verification> { ?document <https://example.invalid/ontology/title> "Cloudflare runtime" } }
                                """
                        )
                    )
                )
            ),
            (
                "vectorMutationExecute",
                try DatabaseWireEncoder().encodeRequest(
                    DatabaseOperationCatalog.mutationExecute,
                    requestID: 66,
                    target: target,
                    metadata: OperationRequestMetadata(
                        idempotencyKey: "runtime-vectors-insert"
                    ),
                    request: MutationExecuteOperation.Request(
                        input: .entities(try vectorChanges(kind: .insert))
                    )
                )
            ),
            (
                "vectorIVFRebuild",
                try DatabaseWireEncoder().encodeRequest(
                    DatabaseOperationCatalog.maintenanceExecute,
                    requestID: 67,
                    target: target,
                    metadata: OperationRequestMetadata(
                        idempotencyKey: "runtime-ivf-rebuild"
                    ),
                    request: vectorRebuildRequest(
                        entity: "RuntimeVerificationIVFDocument",
                        index: "RuntimeVerificationIVFDocument_embedding"
                    )
                )
            ),
            (
                "vectorPQRebuild",
                try DatabaseWireEncoder().encodeRequest(
                    DatabaseOperationCatalog.maintenanceExecute,
                    requestID: 68,
                    target: target,
                    metadata: OperationRequestMetadata(
                        idempotencyKey: "runtime-pq-rebuild"
                    ),
                    request: vectorRebuildRequest(
                        entity: "RuntimeVerificationPQDocument",
                        index: "RuntimeVerificationPQDocument_embedding"
                    )
                )
            ),
            (
                "vectorIVFQuery",
                try DatabaseWireEncoder().encodeRequest(
                    DatabaseOperationCatalog.queryExecute,
                    requestID: 69,
                    target: target,
                    metadata: OperationRequestMetadata(),
                    request: try vectorQueryRequest(
                        entity: "RuntimeVerificationIVFDocument",
                        index: "RuntimeVerificationIVFDocument_embedding"
                    )
                )
            ),
            (
                "vectorPQQuery",
                try DatabaseWireEncoder().encodeRequest(
                    DatabaseOperationCatalog.queryExecute,
                    requestID: 70,
                    target: target,
                    metadata: OperationRequestMetadata(),
                    request: try vectorQueryRequest(
                        entity: "RuntimeVerificationPQDocument",
                        index: "RuntimeVerificationPQDocument_embedding"
                    )
                )
            ),
            (
                "vectorFlatQuery",
                try DatabaseWireEncoder().encodeRequest(
                    DatabaseOperationCatalog.queryExecute,
                    requestID: 71,
                    target: target,
                    metadata: OperationRequestMetadata(),
                    request: try vectorQueryRequest(
                        entity: "RuntimeVerificationFlatDocument",
                        index: "RuntimeVerificationFlatDocument_embedding"
                    )
                )
            ),
            (
                "vectorDelete",
                try DatabaseWireEncoder().encodeRequest(
                    DatabaseOperationCatalog.mutationExecute,
                    requestID: 72,
                    target: target,
                    metadata: OperationRequestMetadata(
                        idempotencyKey: "runtime-vectors-delete"
                    ),
                    request: MutationExecuteOperation.Request(
                        input: .entities(try vectorChanges(kind: .delete))
                    )
                )
            ),
        ])
        return expected
    }

    private func verifyVectors(
        at vectorURL: URL,
        expected: [(String, ByteString)]
    ) throws {
        let data = try Data(contentsOf: vectorURL)
        let vectors = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: [Int]]
        )

        #expect(Set(vectors.keys) == Set(expected.map(\.0)))
        for (name, encodedRequest) in expected {
            let storedBytes = try #require(vectors[name])
            #expect(storedBytes.allSatisfy { (0 ... 255).contains($0) })
            #expect(encodedRequest == ByteString(storedBytes.map(UInt8.init)))
        }
    }

    private func vectorChanges(
        kind: MutationExecuteOperation.Kind
    ) throws -> [MutationExecuteOperation.Change] {
        let entities = [
            "RuntimeVerificationIVFDocument",
            "RuntimeVerificationPQDocument",
            "RuntimeVerificationFlatDocument",
        ]
        var changes: [MutationExecuteOperation.Change] = []
        changes.reserveCapacity(entities.count * 2)
        for entity in entities {
            for (suffix, vector) in [
                ("exact", [Float(2), 0]),
                ("alternate", [Float(0), 2]),
            ] {
                let identifier = "\(entity)-\(suffix)"
                changes.append(
                    MutationExecuteOperation.Change(
                        kind: kind,
                        identity: try EntityReference(
                            entity: entity,
                            id: .string(identifier)
                        ),
                        fields: kind == .delete
                            ? FieldObject()
                            : try FieldObject([
                                (key: "id", value: .string(identifier)),
                                (key: "title", value: .string(suffix)),
                                (
                                    key: "embedding",
                                    value: .vector(try Vector(float32: vector))
                                ),
                            ])
                    )
                )
            }
        }
        return changes
    }

    private func vectorRebuildRequest(
        entity: String,
        index: String
    ) -> MaintenanceExecuteOperation.Request {
        MaintenanceExecuteOperation.Request(
            invocation: .rebuildIndex(
                entity: entity,
                index: index,
                partitions: FieldObject(),
                batchSize: 100
            )
        )
    }

    private func vectorQueryRequest(
        entity: String,
        index: String
    ) throws -> QueryExecuteOperation.Request {
        QueryExecuteOperation.Request(
            input: .ir(
                .select(
                    SelectQuery(
                        projection: .all,
                        source: .table(TableRef(entity)),
                        accessPath: .index(
                            IndexScanSource(
                                indexName: index,
                                kindIdentifier: "vector",
                                parameters: [
                                    "fieldName": .string("embedding"),
                                    "dimensions": .int64(2),
                                    "queryVector": .vector(
                                        try Vector(float32: [1, 0])
                                    ),
                                    "k": .int64(1),
                                    "metric": .string("dotProduct"),
                                ]
                            )
                        ),
                        limit: 1
                    )
                )
            )
        )
    }
}
