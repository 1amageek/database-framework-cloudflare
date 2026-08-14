import DatabaseTypes
import DatabaseKit
import DatabaseWire
import Foundation
import Testing

@Suite("Runtime verification request vectors")
struct RuntimeVerificationRequestVectorTests {
    private enum VerificationTarget {
        case database

        #if CLOUDFLARE_TEST_MULTIPLE_BASES
        case base(Base.ID)
        #endif
    }

    @Test("golden requests are emitted by the canonical Swift encoder")
    func matchesCanonicalEncoder() throws {
        let testDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let repositoryDirectory = testDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        #if CLOUDFLARE_TEST_MULTIPLE_BASES
        let baseID = try Base.ID("runtime-verification")
        let multipleBasesVectorURL = repositoryDirectory.appending(
            path:
                "Protocol/runtime-verification-requests-multiple-bases-v1.json"
        )
        let multipleBasesRequests = try expectedRequests(
            target: .base(baseID),
            includesBaseCreate: true
        )
        if shouldUpdateVectors {
            try writeVectors(multipleBasesRequests, to: multipleBasesVectorURL)
        }
        try verifyVectors(
            at: multipleBasesVectorURL,
            expected: multipleBasesRequests
        )
        #else
        let standardVectorURL = repositoryDirectory.appending(
            path: "Protocol/runtime-verification-requests-standard-v1.json"
        )
        let standardRequests = try expectedRequests(
            target: .database,
            includesBaseCreate: false
        )
        if shouldUpdateVectors {
            try writeVectors(standardRequests, to: standardVectorURL)
        }
        try verifyVectors(at: standardVectorURL, expected: standardRequests)
        #endif
    }

    private var shouldUpdateVectors: Bool {
        ProcessInfo.processInfo.environment[
            "DATABASE_UPDATE_RUNTIME_VERIFICATION_VECTORS"
        ] == "1"
    }

    private func expectedRequests(
        target: VerificationTarget,
        includesBaseCreate: Bool
    ) throws -> [(String, ByteString)] {
        let identity = try EntityReference(
            entity: RuntimeVerificationDocument.persistableType,
            id: .string("document-1")
        )
        var expected: [(String, ByteString)] = [
            (
                "capabilitiesDescribe",
                try encodeRequest(
                    DatabaseOperationCatalog.capabilitiesDescribe,
                    requestID: 60,
                    target: .database,
                    metadata: OperationRequestMetadata(),
                    request: EmptyOperationPayload()
                )
            ),
            (
                "schemaDescribe",
                try encodeRequest(
                    DatabaseOperationCatalog.schemaDescribe,
                    requestID: 61,
                    target: .database,
                    metadata: OperationRequestMetadata(),
                    request: EmptyOperationPayload()
                )
            ),
        ]
        #if CLOUDFLARE_TEST_MULTIPLE_BASES
        if includesBaseCreate {
            let baseID = try Base.ID("runtime-verification")
            expected.append(
                (
                    "baseCreate",
                    try encodeRequest(
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
        #else
        precondition(!includesBaseCreate)
        #endif
        expected.append(contentsOf: [
            (
                "mutationExecute",
                try encodeRequest(
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
                try encodeRequest(
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
                try encodeRequest(
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
                try encodeRequest(
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
                try encodeRequest(
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
                try encodeRequest(
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
                try encodeRequest(
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
                try encodeRequest(
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
                try encodeRequest(
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
                try encodeRequest(
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

    private func encodeRequest<Request: Sendable, Response: Sendable>(
        _ operation: DatabaseOperation<Request, Response>,
        requestID: UInt64,
        target: VerificationTarget,
        metadata: OperationRequestMetadata,
        request: Request
    ) throws -> ByteString {
        #if CLOUDFLARE_TEST_MULTIPLE_BASES
        let wireTarget: DatabaseOperationTarget
        switch target {
        case .database:
            wireTarget = .database
        case .base(let baseID):
            wireTarget = .base(baseID)
        }
        return try DatabaseWireEncoder().encodeRequest(
            operation,
            requestID: requestID,
            target: wireTarget,
            metadata: metadata,
            request: request
        )
        #else
        _ = target
        return try DatabaseWireEncoder().encodeRequest(
            operation,
            requestID: requestID,
            metadata: metadata,
            request: request
        )
        #endif
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

    private func writeVectors(
        _ vectors: [(String, ByteString)],
        to vectorURL: URL
    ) throws {
        let object = Dictionary(uniqueKeysWithValues: vectors.map { name, bytes in
            let values = bytes.withUnsafeBytes { buffer in
                buffer.map(Int.init)
            }
            return (name, values)
        })
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        var terminated = data
        terminated.append(0x0A)
        try terminated.write(to: vectorURL, options: .atomic)
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
