import CloudflareDatabase
import DatabaseRuntime

actor RuntimeVerificationSession: CloudflareDatabaseSession {
    static let principalIdentifier = "runtime-verification"

    private let container: DBContainer
    #if CLOUDFLARE_RUNTIME_MULTIPLE_BASES
    private let baseID: Base.ID
    #endif

    #if CLOUDFLARE_RUNTIME_MULTIPLE_BASES
    init(container: DBContainer, baseID: Base.ID) {
        self.container = container
        self.baseID = baseID
    }
    #else
    init(container: DBContainer) {
        self.container = container
    }
    #endif

    func respond(
        to invocation: CloudflareDatabaseInvocation
    ) async throws -> ByteString {
        guard Self.string(from: invocation.context)
                == Self.principalIdentifier else {
            throw RuntimeVerificationError.unauthorizedContext
        }
        let request = Self.string(from: invocation.request)
        let authorization = AuthorizationContext.authenticated(
            Principal(
                identifier: Self.principalIdentifier,
                roles: ["admin"]
            )
        )
        let context: DatabaseContext
        #if CLOUDFLARE_RUNTIME_MULTIPLE_BASES
        context = container.session(authorization: authorization)
            .base(baseID)
            .newContext()
        #else
        context = container.newContext(authorization: authorization)
        #endif

        if request.hasPrefix("put:") {
            let title = String(request.dropFirst(4))
            try context.upsert(
                RuntimeVerificationDocument(
                    id: "document-1",
                    title: title
                )
            )
            try await context.save()
            return ByteString(Array(title.utf8))
        }
        if request == "get" {
            let document = try await context
                .fetch(RuntimeVerificationDocument.self)
                .where(RuntimeVerificationDocument.fields.id == "document-1")
                .first()
            guard let document else {
                throw RuntimeVerificationError.documentNotFound
            }
            return ByteString(Array(document.title.utf8))
        }
        if request.hasPrefix("echo:") {
            return ByteString(Array(request.dropFirst(5).utf8))
        }
        #if CLOUDFLARE_RUNTIME_VECTOR_INDEXES
        switch request {
        case "vector:write":
            try await writeVectorFixtures(in: context)
            return Self.bytes("vector:written")
        case "vector:query-initial":
            try await verifyVectorResults(
                in: context,
                query: [1, 0],
                expectedSuffix: "anchor"
            )
            return Self.bytes("vector:initial")
        case "vector:update":
            try await updateVectorFixtures(in: context)
            return Self.bytes("vector:updated")
        case "vector:query-updated":
            try await verifyVectorResults(
                in: context,
                query: [0, 1],
                expectedSuffix: "anchor"
            )
            return Self.bytes("vector:updated-query")
        case "vector:delete":
            try await deleteVectorFixtures(in: context)
            return Self.bytes("vector:deleted")
        case "vector:query-deleted":
            try await verifyVectorResults(
                in: context,
                query: [0, 1],
                expectedSuffix: "other"
            )
            return Self.bytes("vector:deleted-query")
        default:
            break
        }
        #endif
        throw RuntimeVerificationError.invalidApplicationRequest
    }

    #if arch(wasm32)
    func handleAlarm() async throws {
        try CloudflareDatabaseAlarmScheduler().ensureWakeUp(
            noLaterThan: Timestamp(secondsSinceUnixEpoch: 4_102_444_800)
        )
    }
    #endif

    func shutdown() async {}

    private static func string(from bytes: ByteString) -> String {
        bytes.withUnsafeBytes { buffer in
            String(decoding: buffer, as: UTF8.self)
        }
    }

    private static func bytes(_ value: String) -> ByteString {
        ByteString(Array(value.utf8))
    }

    #if CLOUDFLARE_RUNTIME_VECTOR_INDEXES
    private func writeVectorFixtures(
        in context: DatabaseContext
    ) async throws {
        try context.upsert(
            RuntimeVerificationFlatDocument(
                id: "flat-anchor",
                title: "Flat anchor",
                embedding: try Vector(float32: [2, 0])
            )
        )
        try context.upsert(
            RuntimeVerificationFlatDocument(
                id: "flat-other",
                title: "Flat other",
                embedding: try Vector(float32: [0, 1])
            )
        )
        try context.upsert(
            RuntimeVerificationIVFDocument(
                id: "ivf-anchor",
                title: "IVF anchor",
                embedding: try Vector(float32: [2, 0])
            )
        )
        try context.upsert(
            RuntimeVerificationIVFDocument(
                id: "ivf-other",
                title: "IVF other",
                embedding: try Vector(float32: [0, 1])
            )
        )
        try context.upsert(
            RuntimeVerificationPQDocument(
                id: "pq-anchor",
                title: "PQ anchor",
                embedding: try Vector(float32: [2, 0])
            )
        )
        try context.upsert(
            RuntimeVerificationPQDocument(
                id: "pq-other",
                title: "PQ other",
                embedding: try Vector(float32: [0, 1])
            )
        )
        try await context.save()
        try await context.indexQueryContext.trainVectorIndex(
            named: "RuntimeVerificationIVFDocument_embedding",
            for: RuntimeVerificationIVFDocument.self
        )
        try await context.indexQueryContext.trainVectorIndex(
            named: "RuntimeVerificationPQDocument_embedding",
            for: RuntimeVerificationPQDocument.self
        )
    }

    private func updateVectorFixtures(
        in context: DatabaseContext
    ) async throws {
        guard var flat = try await context
            .fetch(RuntimeVerificationFlatDocument.self)
            .where(
                RuntimeVerificationFlatDocument.fields.id == "flat-anchor"
            )
            .first(),
              var ivf = try await context
            .fetch(RuntimeVerificationIVFDocument.self)
            .where(
                RuntimeVerificationIVFDocument.fields.id == "ivf-anchor"
            )
            .first(),
              var pq = try await context
            .fetch(RuntimeVerificationPQDocument.self)
            .where(
                RuntimeVerificationPQDocument.fields.id == "pq-anchor"
            )
            .first() else {
            throw RuntimeVerificationError.documentNotFound
        }
        flat.embedding = try Vector(float32: [0, 2])
        ivf.embedding = try Vector(float32: [0, 2])
        pq.embedding = try Vector(float32: [0, 2])
        try context.upsert(flat)
        try context.upsert(ivf)
        try context.upsert(pq)
        try await context.save()
    }

    private func deleteVectorFixtures(
        in context: DatabaseContext
    ) async throws {
        guard let flat = try await context
            .fetch(RuntimeVerificationFlatDocument.self)
            .where(
                RuntimeVerificationFlatDocument.fields.id == "flat-anchor"
            )
            .first(),
              let ivf = try await context
            .fetch(RuntimeVerificationIVFDocument.self)
            .where(
                RuntimeVerificationIVFDocument.fields.id == "ivf-anchor"
            )
            .first(),
              let pq = try await context
            .fetch(RuntimeVerificationPQDocument.self)
            .where(
                RuntimeVerificationPQDocument.fields.id == "pq-anchor"
            )
            .first() else {
            throw RuntimeVerificationError.documentNotFound
        }
        try context.delete(flat)
        try context.delete(ivf)
        try context.delete(pq)
        try await context.save()
    }

    private func verifyVectorResults(
        in context: DatabaseContext,
        query: [Float],
        expectedSuffix: String
    ) async throws {
        let flat = try await context
            .findSimilar(RuntimeVerificationFlatDocument.self)
            .vector(
                RuntimeVerificationFlatDocument.fields.embedding,
                dimensions: 2
            )
            .query(query, k: 1)
            .metric(.dotProduct)
            .execute()
        let ivf = try await context
            .findSimilar(RuntimeVerificationIVFDocument.self)
            .vector(
                RuntimeVerificationIVFDocument.fields.embedding,
                dimensions: 2
            )
            .query(query, k: 1)
            .metric(.dotProduct)
            .execute()
        let pq = try await context
            .findSimilar(RuntimeVerificationPQDocument.self)
            .vector(
                RuntimeVerificationPQDocument.fields.embedding,
                dimensions: 2
            )
            .query(query, k: 1)
            .metric(.dotProduct)
            .execute()
        guard flat.first?.item.id == "flat-\(expectedSuffix)",
              ivf.first?.item.id == "ivf-\(expectedSuffix)",
              pq.first?.item.id == "pq-\(expectedSuffix)" else {
            throw RuntimeVerificationError.unexpectedVectorResult
        }
    }
    #endif
}
