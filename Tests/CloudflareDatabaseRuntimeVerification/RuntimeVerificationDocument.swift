import DatabaseKit

@Persistable
@OWLClass(
    "https://example.invalid/ontology/RuntimeVerificationDocument",
    individualIRIBase: "https://example.invalid/document/",
    graph: "https://example.invalid/graph/runtime-verification"
)
struct RuntimeVerificationDocument {
    #Directory<RuntimeVerificationDocument>(
        "verification",
        "cloudflare-runtime"
    )

    var id: String = ""

    @OWLDataProperty("https://example.invalid/ontology/title")
    var title: String = ""
}

protocol RuntimeVerificationSecurityPolicy: SecurityPolicy {}

extension RuntimeVerificationSecurityPolicy {
    static func permitsRead(
        of resource: borrowing Self,
        in context: borrowing AuthorizationContext
    ) -> Bool {
        _ = resource
        return context.principal?.identifier == "runtime-verification"
    }

    static func permitsQuery(
        _ query: borrowing SecurityQuery,
        in context: borrowing AuthorizationContext
    ) -> Bool {
        _ = query
        return context.principal?.identifier == "runtime-verification"
    }

    static func permitsCreate(
        _ newResource: borrowing Self,
        in context: borrowing AuthorizationContext
    ) -> Bool {
        _ = newResource
        return context.principal?.identifier == "runtime-verification"
    }

    static func permitsUpdate(
        from resource: borrowing Self,
        to newResource: borrowing Self,
        in context: borrowing AuthorizationContext
    ) -> Bool {
        _ = resource
        _ = newResource
        return context.principal?.identifier == "runtime-verification"
    }

    static func permitsDelete(
        _ resource: borrowing Self,
        in context: borrowing AuthorizationContext
    ) -> Bool {
        _ = resource
        return context.principal?.identifier == "runtime-verification"
    }
}

extension RuntimeVerificationDocument: RuntimeVerificationSecurityPolicy {}
