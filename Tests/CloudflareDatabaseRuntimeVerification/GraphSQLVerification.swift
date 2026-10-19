#if CLOUDFLARE_RUNTIME_GRAPH_INDEXES
import Database
import DatabaseKit
import DatabaseTypes

@Persistable(type: "RuntimeVerificationGraphUser")
struct RuntimeVerificationGraphUser {
    #Directory<RuntimeVerificationGraphUser>("runtime_verification_graph_users")

    var id: String = ""
    var resource: RDFTerm = .iri(.xsdString)
    var name: String = ""
}

@Persistable(type: "RuntimeVerificationGraphStatement")
struct RuntimeVerificationGraphStatement {
    #Directory<RuntimeVerificationGraphStatement>("runtime_verification_graph_statements")
    #Index(
        .graph(
            name: "RuntimeVerificationGraphStatement_rdf_quad_subject_predicate_object",
            definition: .rdf(
                subject: \RuntimeVerificationGraphStatement.subject,
                predicate: \RuntimeVerificationGraphStatement.predicate,
                object: \RuntimeVerificationGraphStatement.object, graph: nil)))

    var id: String = ""
    var subject: RDFTerm = .iri(.xsdString)
    var predicate: RDFTerm = .iri(.xsdString)
    var object: RDFTerm = .iri(.xsdString)
}

extension RuntimeVerificationGraphUser: RuntimeVerificationSecurityPolicy {}
extension RuntimeVerificationGraphStatement: RuntimeVerificationSecurityPolicy {}

/// Executes the graph-enabled Database facade: SQL SPARQL() occurrence
/// rewriting, direct SPARQL, typed source positions and post-failure reuse.
enum GraphSQLVerification {
    static func verify(in context: DatabaseContext) async throws {
        try await seed(context)
        try await rewrite(context)
        try await producerFailure(context)
        try await structuralLimit(context)
        try await directSPARQL(context)
    }

    private static let membership = """
        SELECT name FROM "RuntimeVerificationGraphUser"
        WHERE resource IN (SPARQL("RuntimeVerificationGraphStatement", 'SELECT ?s WHERE { ?s <urn:predicate:active> "true" }'))
        """

    private static func seed(_ context: DatabaseContext) async throws {
        for (ordinal, active) in [(1, true), (2, true), (3, true), (4, false)] {
            let iri = try RDFIRI("urn:user:graph-\(ordinal)")
            var user = RuntimeVerificationGraphUser()
            user.id = iri.rawValue
            user.resource = .iri(iri)
            user.name = "graph-\(ordinal)"
            try context.insert(user)
            guard active else { continue }
            var statement = RuntimeVerificationGraphStatement()
            statement.id = "graph-statement-\(ordinal)"
            statement.subject = .iri(iri)
            statement.predicate = try .iri(validating: "urn:predicate:active")
            statement.object = .literal(RDFLiteral(lexicalForm: "true", datatype: .xsdString))
            try context.insert(statement)
        }
        try await context.save()
    }

    private static func names(_ response: QueryResponse) throws -> [String] {
        try response.rows.map { row in
            guard row.values.count == 1, case .primitive(.string(let name)) = row.values[0] else {
                throw RuntimeVerificationError.graphAssertion("graph-name-shape")
            }
            return name
        }.sorted()
    }

    private static func rewrite(_ context: DatabaseContext) async throws {
        let response = try await context.executeSQL(membership)
        try require(try names(response) == ["graph-1", "graph-2", "graph-3"], "rewrite-membership")
    }

    private static func producerFailure(_ context: DatabaseContext) async throws {
        let sql = """
            SELECT name FROM "RuntimeVerificationGraphUser"
            WHERE id IN (SPARQL("RuntimeVerificationGraphStatement", 'SELECT ?s WHERE { ?s <urn:predicate:active> "true" }'))
            """
        let expected = offset(of: "SPARQL(", in: sql)
        do {
            _ = try await context.executeSQL(sql)
            throw RuntimeVerificationError.graphAssertion("producer-failure-must-fail")
        } catch let failure as SQLBindingSourceFailure {
            guard case .expression(.typeMismatch(operation: "common result type")) = failure.cause else {
                throw RuntimeVerificationError.graphAssertion("producer-failure-cause")
            }
            try require(expected != nil && failure.position == expected, "producer-failure-position")
        }
        // The rewritten producer leaves no state that blocks the next statement.
        try require(try names(try await context.executeSQL(membership)) == ["graph-1", "graph-2", "graph-3"],
            "producer-failure-recovery")
    }

    private static func structuralLimit(_ context: DatabaseContext) async throws {
        // Two SPARQL() arguments fit; inlining three generated members does not,
        // so the inlining structure meter, not the SQL parser, rejects it.
        let narrow = QueryStructuralLimits(maximumCollectionElements: 2)
        do {
            _ = try await context.executeSQL(membership, structuralLimits: narrow)
            throw RuntimeVerificationError.graphAssertion("structural-limit-must-fail")
        } catch let error as QueryStructuralValidationError {
            guard case .resourceLimitExceeded(.collectionElements, 3, 2) = error else {
                throw RuntimeVerificationError.graphAssertion("structural-limit-cause")
            }
        }
        try require(try names(try await context.executeSQL(membership)) == ["graph-1", "graph-2", "graph-3"],
            "structural-limit-recovery")
    }

    private static func directSPARQL(_ context: DatabaseContext) async throws {
        let result = try await context.executeSPARQL(
            "SELECT ?s WHERE { ?s <urn:predicate:active> \"true\" }",
            on: RuntimeVerificationGraphStatement.self)
        try require(result.count == 3 && result.isComplete && result.projectedVariables == ["?s"], "direct-sparql")
    }

    private static func offset(of needle: String, in text: String) -> Int? {
        let haystack = Array(text.utf8), pattern = Array(needle.utf8)
        guard pattern.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - pattern.count)
            where Array(haystack[start..<(start + pattern.count)]) == pattern {
            return start
        }
        return nil
    }

    private static func require(_ condition: Bool, _ name: String) throws {
        guard condition else { throw RuntimeVerificationError.graphAssertion(name) }
    }
}
#endif
