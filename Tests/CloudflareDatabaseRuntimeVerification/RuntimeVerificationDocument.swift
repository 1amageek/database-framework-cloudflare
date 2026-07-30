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
