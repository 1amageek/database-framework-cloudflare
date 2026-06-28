import CloudflareDatabase
import DatabaseEngine
import DatabaseWire
import Testing

@Suite("Cloudflare Durable Object database storage")
struct CloudflareDatabaseWireStorageTests {
    @Test func runtimeUsesHostStorageForPutGetAndQuery() throws {
        let host = MemoryStorageHost()
        let storage = HostBackedDatabaseStorage(host: host)
        let runtime = DatabaseEngineRuntime(storage: storage)
        let first = article(id: "a", status: "draft", score: 1, title: "Local Swift", tags: ["swift"])
        let second = article(id: "b", status: "published", score: 5, title: "Workers Runtime", tags: ["cloudflare"])
        let third = article(id: "c", status: "published", score: 9, title: "Durable Swift", tags: ["swift", "cloudflare"])

        _ = try runtime.execute(.putRecord(first))
        _ = try runtime.execute(.putRecord(second))
        _ = try runtime.execute(.putRecord(third))

        #expect(try runtime.execute(.getRecord(typeName: "Article", id: "b")) == .record(second))

        let query = DatabaseWireQueryRequest(
            typeName: "Article",
            predicate: DatabaseWirePredicate.and([
                DatabaseWirePredicate.comparison(field: "status", op: DatabaseWireComparisonOperator.equal, value: DatabaseWireFieldValue.string("published")),
                .or([
                    DatabaseWirePredicate.comparison(field: "score", op: DatabaseWireComparisonOperator.greaterThanOrEqual, value: DatabaseWireFieldValue.int64(9)),
                    DatabaseWirePredicate.comparison(field: "tags", op: DatabaseWireComparisonOperator.contains, value: DatabaseWireFieldValue.string("cloudflare")),
                ]),
            ]),
            limit: 10
        )

        #expect(try runtime.execute(DatabaseWireRequest.query(query)) == .records([second, third]))
    }

    @Test func storageFailureIsReturnedAsExecutionFailureEnvelope() throws {
        let storage = HostBackedDatabaseStorage(host: FailingStorageHost())
        let runtime = DatabaseEngineRuntime(storage: storage)

        let responseBytes = try runtime.handle(
            DatabaseWireCodec.encode(
                request: .getRecord(typeName: "Article", id: "missing")
            )
        )

        #expect(try DatabaseWireCodec.decodeResponse(responseBytes) == .failure(
            status: .executionFailure,
            message: "host unavailable"
        ))
    }

    @Test func hostBackedRuntimeScansAcrossHostBatchesBeforeLimit() throws {
        let runtime = DatabaseEngineRuntime(
            storage: HostBackedDatabaseStorage(host: MemoryStorageHost()),
            queryScanBatchSize: 2
        )
        for record in [
            article(id: "a", status: "draft", score: 1, title: "A", tags: []),
            article(id: "b", status: "draft", score: 2, title: "B", tags: []),
            article(id: "c", status: "draft", score: 3, title: "C", tags: []),
            article(id: "d", status: "draft", score: 4, title: "D", tags: []),
            article(id: "e", status: "published", score: 5, title: "E", tags: [])
        ] {
            _ = try runtime.execute(.putRecord(record))
        }

        let response = try runtime.execute(DatabaseWireRequest.query(DatabaseWireQueryRequest(
            typeName: "Article",
            predicate: DatabaseWirePredicate.comparison(field: "status", op: DatabaseWireComparisonOperator.equal, value: DatabaseWireFieldValue.string("published")),
            limit: 1
        )))

        #expect(response == .records([
            article(id: "e", status: "published", score: 5, title: "E", tags: [])
        ]))
    }

    @Test func hostBackedRuntimeCoversPredicateMatrix() throws {
        let runtime = DatabaseEngineRuntime(storage: HostBackedDatabaseStorage(host: MemoryStorageHost()))
        for record in [
            article(id: "a", status: "draft", score: 1, title: "Local Swift", tags: ["swift"]),
            article(id: "b", status: "published", score: 5, title: "Workers Runtime", tags: ["cloudflare"]),
            article(id: "c", status: "published", score: 9, title: "Durable Swift", tags: ["swift", "cloudflare"]),
            article(id: "d", status: "archived", score: 13, title: "Database Runtime", tags: ["database"]),
            article(id: "e", status: "published", score: 15, title: "Edge Storage", tags: ["edge", "swift"]),
        ] {
            _ = try runtime.execute(.putRecord(record))
        }

        #expect(try ids(from: runtime, predicate: nil as DatabaseWirePredicate?, limit: 0) == ["a", "b", "c", "d", "e"])
        #expect(try ids(
            from: runtime,
            predicate: DatabaseWirePredicate.comparison(field: "status", op: DatabaseWireComparisonOperator.equal, value: DatabaseWireFieldValue.string("published"))
        ) == ["b", "c", "e"])
        #expect(try ids(
            from: runtime,
            predicate: DatabaseWirePredicate.comparison(field: "status", op: DatabaseWireComparisonOperator.notEqual, value: DatabaseWireFieldValue.string("archived"))
        ) == ["a", "b", "c", "e"])
        #expect(try ids(
            from: runtime,
            predicate: DatabaseWirePredicate.comparison(field: "score", op: DatabaseWireComparisonOperator.lessThan, value: DatabaseWireFieldValue.int64(5))
        ) == ["a"])
        #expect(try ids(
            from: runtime,
            predicate: DatabaseWirePredicate.comparison(field: "score", op: DatabaseWireComparisonOperator.lessThanOrEqual, value: DatabaseWireFieldValue.int64(5))
        ) == ["a", "b"])
        #expect(try ids(
            from: runtime,
            predicate: DatabaseWirePredicate.comparison(field: "score", op: DatabaseWireComparisonOperator.greaterThan, value: DatabaseWireFieldValue.int64(9))
        ) == ["d", "e"])
        #expect(try ids(
            from: runtime,
            predicate: DatabaseWirePredicate.comparison(field: "score", op: DatabaseWireComparisonOperator.greaterThanOrEqual, value: DatabaseWireFieldValue.int64(9))
        ) == ["c", "d", "e"])
        #expect(try ids(
            from: runtime,
            predicate: DatabaseWirePredicate.comparison(field: "title", op: DatabaseWireComparisonOperator.contains, value: DatabaseWireFieldValue.string("Runtime"))
        ) == ["b", "d"])
        #expect(try ids(
            from: runtime,
            predicate: DatabaseWirePredicate.comparison(field: "tags", op: DatabaseWireComparisonOperator.contains, value: DatabaseWireFieldValue.string("swift"))
        ) == ["a", "c", "e"])
        #expect(try ids(
            from: runtime,
            predicate: DatabaseWirePredicate.not(DatabaseWirePredicate.comparison(field: "status", op: DatabaseWireComparisonOperator.equal, value: DatabaseWireFieldValue.string("draft")))
        ) == ["b", "c", "d", "e"])
        #expect(try ids(
            from: runtime,
            predicate: DatabaseWirePredicate.and([
                DatabaseWirePredicate.comparison(field: "status", op: DatabaseWireComparisonOperator.equal, value: DatabaseWireFieldValue.string("published")),
                DatabaseWirePredicate.comparison(field: "score", op: DatabaseWireComparisonOperator.greaterThanOrEqual, value: DatabaseWireFieldValue.int64(9)),
            ])
        ) == ["c", "e"])
        #expect(try ids(
            from: runtime,
            predicate: DatabaseWirePredicate.or([
                DatabaseWirePredicate.comparison(field: "score", op: DatabaseWireComparisonOperator.lessThan, value: DatabaseWireFieldValue.int64(2)),
                DatabaseWirePredicate.comparison(field: "tags", op: DatabaseWireComparisonOperator.contains, value: DatabaseWireFieldValue.string("database")),
            ])
        ) == ["a", "d"])
        #expect(try ids(
            from: runtime,
            predicate: DatabaseWirePredicate.comparison(field: "missing", op: DatabaseWireComparisonOperator.equal, value: DatabaseWireFieldValue.string("value"))
        ) == [])
        #expect(try ids(
            from: runtime,
            predicate: DatabaseWirePredicate.comparison(field: "status", op: DatabaseWireComparisonOperator.equal, value: DatabaseWireFieldValue.string("published")),
            limit: 2
        ) == ["b", "c"])
    }

    @Test func hostBackedRuntimeExecutesVectorQuery() throws {
        let runtime = DatabaseEngineRuntime(storage: HostBackedDatabaseStorage(host: MemoryStorageHost()))
        _ = try runtime.execute(.applySchema(vectorSchema()))
        for record in [
            vectorDocument(id: "near", status: "published", title: "Near", embedding: [1, 0, 0]),
            vectorDocument(id: "middle", status: "published", title: "Middle", embedding: [0.8, 0.2, 0]),
            vectorDocument(id: "far", status: "published", title: "Far", embedding: [0, 1, 0]),
            vectorDocument(id: "draft-near", status: "draft", title: "Draft", embedding: [1, 0, 0]),
        ] {
            _ = try runtime.execute(.putRecord(record))
        }

        let response = try runtime.execute(.vectorQuery(DatabaseWireVectorQueryRequest(
            typeName: "Document",
            fieldName: "embedding",
            dimensions: 3,
            metric: .cosine,
            queryVector: [1, 0, 0],
            k: 2,
            predicate: DatabaseWirePredicate.comparison(field: "status", op: .equal, value: .string("published"))
        )))

        guard case .scoredRecords(let records) = response else {
            Issue.record("Expected scored records response")
            return
        }
        #expect(records.map(\.record.id) == ["near", "middle"])
        #expect(records[0].distance == 0)
        #expect(records[1].distance > 0)
    }

    private func article(
        id: String,
        status: String,
        score: Int64,
        title: String,
        tags: [String]
    ) -> DatabaseWireRecord {
        DatabaseWireRecord(
            typeName: "Article",
            id: id,
            fields: [
                DatabaseWireNamedValue(name: "status", value: DatabaseWireFieldValue.string(status)),
                DatabaseWireNamedValue(name: "score", value: DatabaseWireFieldValue.int64(score)),
                DatabaseWireNamedValue(name: "title", value: DatabaseWireFieldValue.string(title)),
                DatabaseWireNamedValue(name: "tags", value: .array(tags.map { .string($0) })),
            ]
        )
    }

    private func vectorSchema() -> DatabaseWireSchema {
        DatabaseWireSchema(
            entities: [
                DatabaseWireEntitySchema(
                    typeName: "Document",
                    version: 1,
                    fields: [
                        DatabaseWireFieldSchema(name: "status", type: .string, isOptional: false, fieldNumber: 1),
                        DatabaseWireFieldSchema(name: "title", type: .string, isOptional: false, fieldNumber: 2),
                        DatabaseWireFieldSchema(name: "embedding", type: .array, isOptional: false, fieldNumber: 3),
                    ],
                    indexes: [
                        DatabaseWireIndexDescriptor(
                            name: "Document.embedding.vector",
                            kind: .vector,
                            fields: ["embedding"],
                            parameters: [
                                DatabaseWireNamedValue(name: "dimensions", value: .int64(3)),
                                DatabaseWireNamedValue(name: "metric", value: .string("cosine")),
                            ]
                        )
                    ]
                )
            ]
        )
    }

    private func vectorDocument(
        id: String,
        status: String,
        title: String,
        embedding: [Double]
    ) -> DatabaseWireRecord {
        DatabaseWireRecord(
            typeName: "Document",
            id: id,
            fields: [
                DatabaseWireNamedValue(name: "status", value: .string(status)),
                DatabaseWireNamedValue(name: "title", value: .string(title)),
                DatabaseWireNamedValue(name: "embedding", value: .array(embedding.map { .double($0) })),
            ]
        )
    }

    private func ids(
        from runtime: DatabaseEngineRuntime<HostBackedDatabaseStorage<MemoryStorageHost>>,
        predicate: DatabaseWirePredicate?,
        limit: UInt32 = 10
    ) throws -> [String] {
        let response = try runtime.execute(DatabaseWireRequest.query(DatabaseWireQueryRequest(
            typeName: "Article",
            predicate: predicate,
            limit: limit
        )))
        guard case .records(let records) = response else {
            return []
        }
        return records.map { $0.id }
    }
}
