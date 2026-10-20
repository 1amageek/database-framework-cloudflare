@_spi(DatabaseExecution) @testable import DatabaseEngine
import DatabaseKit
import DatabaseTypes

/// S11 lower-path catalog checks share the actual host container and SQLite store.
enum SQLCatalogVerification {
    static let groups = 5
    typealias Failure = ParameterBindingVerification.Failure
    typealias Invocation = SelectedValueVerification.Invocation
    static let initialName = "s11_documents"
    static let restoredName = "s11_renamed"
    static let documentID = "s11-catalog-document"
    static let payload = "catalog payload"

    static func require(_ condition: Bool, _ name: String) throws {
        try ParameterBindingVerification.require(condition, "s11-" + name)
    }

    static var authorization: AuthorizationContext {
        .authenticated(Principal(identifier: RuntimeVerificationSession.principalIdentifier, roles: ["admin"]))
    }

    static func verify(in context: DatabaseContext, container: DBContainer) async throws {
        let invocation = Invocation(context: context, container: container)
        let checks: [(String, @Sendable (Invocation) async throws -> Void)] = [
            ("catalog-codec-strict", codec),
            ("catalog-exact-resolution", exactResolution),
            ("catalog-physical-columns", physicalColumns),
            ("catalog-generation-publication", publication),
        ]
        for (name, check) in checks {
            do { try await check(invocation) }
            catch { throw SQLTextPatternVerification.DiagnosticFailure(phase: "s11-" + name, cause: error) }
            print("ENGINE_S11_CASE " + name + " PASS")
        }
    }

    private static func frameLimits(_ size: Int) throws -> StorageFrameLimits {
        try StorageFrameLimits(maximumFrameBytes: size, maximumStringBytes: size,
            maximumByteStringBytes: size, maximumCollectionCount: 100_000, maximumNestingDepth: 0)
    }

    private static func expectFrame(_ expected: StorageFrameError, _ body: () throws -> Void) throws {
        do { try body(); throw Failure.assertion("s11-frame-must-fail") }
        catch let error as StorageFrameError { try require(error == expected, "frame-typed-cause") }
    }

    private static func codec(_ invocation: Invocation) async throws {
        let lease = invocation.container.acquirePublishedSchemaLease()
        let snapshot = lease.sqlCatalog
        let bytes = try SQLCatalogCodec.encode(snapshot)
        let stored = try SQLCatalogCodec.decode(bytes)
        let restored = try stored.snapshot(physicalSchema: lease.schema,
            runtimeConfiguration: invocation.container.runtimeConfiguration)
        try require(stored.catalog == snapshot.catalog && restored.digest == snapshot.digest
            && restored.protectedContracts == snapshot.protectedContracts
            && SQLCatalogCodec.encode(restored) == bytes, "strict-roundtrip-protection")
        let exact = try frameLimits(bytes.count)
        try require(try SQLCatalogCodec.encode(snapshot, limits: exact) == bytes
            && SQLCatalogCodec.decode(bytes, limits: exact).digest == snapshot.digest, "exact-frame-bound")
        let short = try frameLimits(bytes.count - 1)
        try expectFrame(.frameTooLarge(actual: bytes.count, maximum: bytes.count - 1)) {
            _ = try SQLCatalogCodec.decode(bytes, limits: short)
        }
        do {
            _ = try SQLCatalogCodec.encode(snapshot, limits: short)
            throw Failure.assertion("s11-encode-one-past-must-fail")
        } catch is StorageFrameError {}
        for end in 0..<bytes.count {
            do {
                _ = try SQLCatalogCodec.decode(bytes[bytes.startIndex..<(bytes.startIndex + end)])
                throw Failure.assertion("s11-truncated-prefix-must-fail")
            } catch is StorageFrameError {}
        }
        var damaged = Array(bytes)
        damaged[0] ^= 1
        try expectFrame(.invalidMagic) { _ = try SQLCatalogCodec.decode(ByteString(damaged)) }
        damaged = Array(bytes)
        damaged.append(0)
        try expectFrame(.trailingBytes) { _ = try SQLCatalogCodec.decode(ByteString(damaged)) }
        damaged = Array(bytes)
        damaged[damaged.count - 1] ^= 1
        do {
            _ = try SQLCatalogCodec.decode(ByteString(damaged))
            throw Failure.assertion("s11-digest-must-fail")
        } catch SQLCatalogBindingError.digestMismatch {}
        damaged = Array(bytes)
        let marker = Array("public".utf8)
        guard let offset = (0...(damaged.count - marker.count)).first(where: {
            damaged[$0..<($0 + marker.count)].elementsEqual(marker)
        }) else { throw Failure.assertion("s11-utf8-marker") }
        damaged[offset] = 255
        try expectFrame(.invalidUTF8) { _ = try SQLCatalogCodec.decode(ByteString(damaged)) }
    }

    private static func exactResolution(_ invocation: Invocation) async throws {
        let entities = try ["S11PortableItem", "S11PortableOther"].map { name in
            try Schema.Entity(name: name, identifierType: .string, fields: [
                FieldSchema(name: "id", fieldNumber: 1, type: .string),
                FieldSchema(name: "value", fieldNumber: 2, type: .string)],
                directoryComponents: [.staticPath(name)])
        }
        let schema = try Schema(entities: entities, version: .init(1, 0, 0))
        let runtime = try DatabaseRuntimeConfiguration(executionIdentity: .init(identifier: "s11-portable", revision: 1),
            entityRuntimes: entities.map { EntityRuntimeDefinition(schemaDriven: $0).registration() })
        let composed = "\u{00e9}", decomposed = "e\u{0301}"
        let columns = try [SQLColumn(id: composed, name: composed, fieldNumber: 2),
            SQLColumn(id: decomposed, name: decomposed, fieldNumber: 1)]
        let namespaces = try [SQLNamespace(id: "u", name: "alice"), SQLNamespace(id: "p", name: "public"),
            SQLNamespace(id: composed, name: composed), SQLNamespace(id: decomposed, name: decomposed)]
        let catalog = try SQLCatalog(namespaces: namespaces, relations: [
            SQLRelation(id: composed, namespaceID: "u", name: "items", entityName: entities[0].name, columns: columns),
            SQLRelation(id: decomposed, namespaceID: "p", name: "items", entityName: entities[1].name,
                columns: columns, primaryKeyColumnIDs: [decomposed, composed])])
        let snapshot = try SQLCatalogSnapshot(catalog: catalog, physicalSchema: schema, runtimeConfiguration: runtime)
        let selected = try snapshot.resolveRelation(name: "items", namespace: nil, searchPath: .default, currentUser: "alice")
        try require(selected.entity.name == entities[0].name && selected.columns.map { $0.field?.name } == ["value", "id"]
            && selected.declaration.primaryKeyColumnIDs == nil, "current-user-ordered-physical-map")
        try require(try snapshot.resolveRelation(name: "items", namespace: nil, searchPath: .default,
            currentUser: nil).entity.name == entities[1].name, "anonymous-public-fallback")
        let path = try SQLSearchPath(entries: [.schema("missing"), .schema("public"), .currentUser])
        try require(try snapshot.resolveRelation(name: "items", namespace: nil, searchPath: path,
            currentUser: "alice").entity.name == entities[1].name, "explicit-search-order")
        for namespace in [composed, decomposed] {
            do {
                _ = try snapshot.resolveRelation(name: "items", namespace: namespace, searchPath: .default, currentUser: "alice")
                throw Failure.assertion("s11-qualified-must-not-fallback")
            } catch SQLCatalogBindingError.missingRelation(let actual, let name) {
                try require(actual?.utf8.elementsEqual(namespace.utf8) == true && name == "items", "qualified-exact-namespace")
            }
        }
        let unicodeRelation = try SQLRelation(id: composed, namespaceID: composed, name: composed,
            entityName: entities[0].name, columns: columns)
        let unicode = try SQLCatalogSnapshot(catalog: SQLCatalog(namespaces: namespaces, relations: [unicodeRelation]),
            physicalSchema: schema, runtimeConfiguration: runtime)
        try require(try unicode.resolveRelation(name: composed, namespace: composed, searchPath: .default,
            currentUser: nil).columns[1].declaration.name.utf8.elementsEqual(decomposed.utf8), "unicode-exact-bytes")
        do {
            _ = try unicode.resolveRelation(name: decomposed, namespace: composed, searchPath: .default, currentUser: nil)
            throw Failure.assertion("s11-unicode-relation-must-not-normalize")
        } catch SQLCatalogBindingError.missingRelation(_, _) {}
        do {
            _ = try unicode.resolveRelation(name: composed, namespace: decomposed, searchPath: .default, currentUser: nil)
            throw Failure.assertion("s11-unicode-namespace-must-not-normalize")
        } catch SQLCatalogBindingError.missingRelation(_, _) {}
        let hidden = try SQLRelation(id: "hidden", namespaceID: "p", name: "hidden", entityName: entities[0].name,
            columns: [SQLColumn(id: "visible", name: "visible", fieldNumber: 2)])
        let hiddenSnapshot = try SQLCatalogSnapshot(catalog: SQLCatalog(namespaces: namespaces, relations: [hidden]),
            physicalSchema: schema, runtimeConfiguration: runtime)
        try require(try hiddenSnapshot.resolveRelation(name: "hidden", namespace: "public", searchPath: .default,
            currentUser: nil).columns.map { $0.field?.fieldNumber } == [2], "hidden-internal-id-no-key")
        try require(try SQLCatalogCodec.decode(SQLCatalogCodec.encode(snapshot)).catalog == catalog, "unicode-ordered-key-roundtrip")
    }

    private static func candidate(_ source: SQLCatalog, name: String) throws -> SQLCatalog {
        guard let document = source.relations.first(where: { $0.entityName == "RuntimeVerificationDocument" }) else {
            throw Failure.assertion("s11-document-catalog-backing")
        }
        let user = RuntimeVerificationSession.principalIdentifier
        var namespaces = source.namespaces
        if !namespaces.contains(where: { $0.id == "s11-user" }) {
            namespaces.append(try SQLNamespace(id: "s11-user", name: user))
        }
        let entity = try RuntimeVerificationDocument.schemaEntity
        let fields = entity.fieldMapByNumber
        let columns = try ["title", "id"].map { name in
            guard let field = fields.values.first(where: { $0.name == name }),
                let column = document.columns.first(where: { $0.fieldNumber == field.fieldNumber }) else {
                throw Failure.assertion("s11-declared-field")
            }
            return try SQLColumn(id: column.id, name: name == "id" ? "key" : "label",
                backing: column.backing, policy: column.policy)
        }
        let replacement = try SQLRelation(id: document.id, namespaceID: "s11-user", name: name,
            entityName: document.entityName, columns: columns, primaryKeyColumnIDs: document.primaryKeyColumnIDs,
            primaryKeyConstraint: document.primaryKeyConstraint, constraints: document.constraints)
        return try SQLCatalog(namespaces: namespaces, relations: source.relations.map {
            $0.id == document.id ? replacement : $0
        }, sequences: source.sequences)
    }

    private static func selected(_ name: String) -> SelectQuery {
        SelectQuery(projection: [.wildcard()], source: .table(TableRef(name)),
            filter: .equal(SQLRelationalVerification.column("key"), .string(documentID)))
    }

    private static func query(_ query: SelectQuery, invocation: Invocation, meter: DatabaseWorkMeter,
                              searchPath: SQLSearchPath = .default) async throws -> QueryResponse {
        try await invocation.context.withDataOperation {
            let resolution = try invocation.context.makeSQLReadResolution(searchPath: searchPath, workMeter: meter)
            let execution = ReadExecutionContext(options: ReadExecutionOptions(budget: meter.budget),
                monotonicClock: invocation.container.monotonicClock, workMeter: meter).withSQLResolution(resolution)
            return try await invocation.context.indexQueryContext.withSession(workMeter: meter) { session in
                try await session.executeCanonical(query, execution: execution)
            }
        }
    }

    private static func checkRows(_ result: QueryResponse) throws {
        try require(result.columns.map { $0.name } == ["label", "key"]
            && result.rows.map { $0.values } == [[.primitive(.string(payload)), .primitive(.string(documentID))]],
            "physical-decode-logical-order")
    }

    private static func physicalColumns(_ invocation: Invocation) async throws {
        try invocation.context.upsert(RuntimeVerificationDocument(id: documentID, title: payload))
        try await invocation.context.save()
        let container = invocation.container
        let lease = container.acquirePublishedSchemaLease()
        _ = try await container.publishSQLCatalog(candidate(lease.sqlCatalog.catalog, name: initialName),
            expectedGeneration: lease.generation, idempotencyKey: "s11-portable-initial", authorization: authorization)
        let meter = invocation.meter()
        try checkRows(try await query(selected(initialName), invocation: invocation, meter: meter))
        try SQLCollectionVerification.released(meter, "s11-mapped-read-release")
        let qualified = selected(initialName).replacing(source: .table(TableRef(schema: RuntimeVerificationSession.principalIdentifier,
            table: initialName)))
        try checkRows(try await query(qualified, invocation: invocation, meter: invocation.meter(),
            searchPath: SQLSearchPath(entries: [.schema("missing")])))
        var nested = selected(initialName)
        for _ in 0..<30 { nested = SelectQuery(projection: [.wildcard()], source: .subquery(nested)) }
        let depthMeter = DatabaseWorkMeter(budget: ExecutionBudget(), monotonicClock: container.monotonicClock)
        try checkRows(try await query(nested, invocation: invocation, meter: depthMeter))
        try SQLCollectionVerification.released(depthMeter, "s11-thirty-query-stack-release")
    }

    private static func publication(_ invocation: Invocation) async throws {
        let container = invocation.container
        let old = container.acquirePublishedSchemaLease()
        let next = try candidate(old.sqlCatalog.catalog, name: restoredName)
        let staleMeter = invocation.meter()
        let staleResolution = try await invocation.context.withDataOperation {
            try invocation.context.makeSQLReadResolution(searchPath: .default, workMeter: staleMeter)
        }
        let result = try await container.publishSQLCatalog(next, expectedGeneration: old.generation,
            idempotencyKey: "s11-portable-rename", authorization: authorization)
        let current = container.acquirePublishedSchemaLease()
        try require(result.generation == old.generation + 1 && current.generation == result.generation
            && current.fingerprint == old.fingerprint && current.indexPhysicalFingerprint == old.indexPhysicalFingerprint
            && current.executionRuntimeFingerprint != old.executionRuntimeFingerprint, "atomic-generation-identity")
        try require(try old.sqlCatalog.resolveRelation(name: initialName, namespace: nil,
            searchPath: .default, currentUser: RuntimeVerificationSession.principalIdentifier).declaration.name == initialName,
            "old-lease-retains-original-mapping")
        let retry = try await container.publishSQLCatalog(next, expectedGeneration: old.generation,
            idempotencyKey: "s11-portable-rename", authorization: authorization)
        try require(retry.generation == result.generation, "idempotent-retry")
        do {
            _ = try await invocation.context.withDataOperation {
                let execution = ReadExecutionContext(options: ReadExecutionOptions(budget: staleMeter.budget),
                    monotonicClock: container.monotonicClock, workMeter: staleMeter).withSQLResolution(staleResolution)
                return try await invocation.context.indexQueryContext.withSession(workMeter: staleMeter) { session in
                    try await session.executeCanonical(selected(initialName), execution: execution)
                }
            }
            throw Failure.assertion("s11-stale-resolution-must-fail")
        } catch SQLReadResolutionError.generationMismatch {}
        guard let protected = current.sqlCatalog.catalog.relations.first(where: {
            $0.entityName == "RuntimeVerificationDocument"
        }) else { throw Failure.assertion("s11-protected-document") }
        let removed = try SQLCatalog(namespaces: next.namespaces,
            relations: next.relations.filter { $0.id != protected.id }, sequences: next.sequences)
        do {
            _ = try await container.publishSQLCatalog(removed, expectedGeneration: current.generation,
                idempotencyKey: "s11-portable-protected-removal", authorization: authorization)
            throw Failure.assertion("s11-protected-removal-must-fail")
        } catch SQLCatalogBindingError.protectedRelationRemoved(let id) {
            try require(id == protected.id, "protected-removal-typed-id")
        }
        try require(container.acquirePublishedSchemaLease().generation == current.generation,
            "failed-publication-keeps-generation")
        do {
            _ = try await container.publishSQLCatalog(next, expectedGeneration: old.generation,
                idempotencyKey: "s11-portable-stale", authorization: authorization)
            throw Failure.assertion("s11-stale-generation-must-fail")
        } catch DatabaseSchemaPublicationError.generationConflict(_, _) {}
        do {
            _ = try await container.publishSQLCatalog(old.sqlCatalog.catalog, expectedGeneration: current.generation,
                idempotencyKey: "s11-portable-rename", authorization: authorization)
            throw Failure.assertion("s11-reused-key-must-fail")
        } catch DatabaseSchemaPublicationError.idempotencyKeyReused(_) {}
        try checkRows(try await query(selected(restoredName), invocation: invocation, meter: invocation.meter()))
    }

    /// Called after the harness destroys and recreates the actual application reactor.
    static func verifyRestored(in context: DatabaseContext, container: DBContainer) async throws {
        let invocation = Invocation(context: context, container: container)
        do {
            let lease = container.acquirePublishedSchemaLease()
            let stored = try await DBContainer.restoreSchemaState(storageEngine: container.engine,
                root: container.defaultTenant.systemRoot, metadataSubspace: container.metadataSubspace,
                clock: container.monotonicClock)
            guard let catalog = stored.sqlCatalog else { throw Failure.assertion("s11-restored-catalog-required") }
            try require(stored.generation == lease.generation && stored.fingerprint == lease.fingerprint
                && stored.indexPhysicalFingerprint == lease.indexPhysicalFingerprint
                && stored.executionRuntimeFingerprint == lease.executionRuntimeFingerprint
                && catalog.digest == lease.sqlCatalog.digest
                && !catalog.protectedContracts.isEmpty, "reopened-complete-persisted-pair")
            let selected = selected(restoredName), meter = invocation.meter()
            let retained = try await query(selected, invocation: invocation, meter: meter)
            try checkRows(retained)
            try SQLCollectionVerification.released(meter, "s11-restored-success-release")
            let low = DatabaseWorkMeter(budget: ExecutionBudget(maximumRows: 100, maximumWorkUnits: 100_000_000,
                maximumIntermediateRows: 1_000, maximumIntermediateBytes: 0, timeoutMilliseconds: 60_000),
                monotonicClock: container.monotonicClock)
            do {
                _ = try await query(selected, invocation: invocation, meter: low)
                throw Failure.assertion("s11-zero-metadata-budget-must-fail")
            } catch DatabaseWorkLimitError.maximumIntermediateBytes(_, _, _, _) {}
            try SQLCollectionVerification.released(low, "s11-admission-failure-release")
            let cancelledMeter = invocation.meter()
            try await Task {
                withUnsafeCurrentTask { $0?.cancel() }
                do {
                    _ = try await query(selected, invocation: invocation, meter: cancelledMeter)
                    throw Failure.assertion("s11-cancel-must-fail")
                } catch is CancellationError {}
            }.value
            try SQLCollectionVerification.released(cancelledMeter, "s11-cancel-release")
            try checkRows(try await query(selected, invocation: invocation, meter: invocation.meter()))
            try checkRows(retained)
        } catch { throw SQLTextPatternVerification.DiagnosticFailure(phase: "s11-catalog-restored-lifecycle", cause: error) }
        print("ENGINE_S11_CASE catalog-restored-lifecycle PASS")
        print("ENGINE_S11_PASS cases=5")
    }
}
