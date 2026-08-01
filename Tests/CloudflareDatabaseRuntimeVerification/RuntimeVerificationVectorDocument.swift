#if CLOUDFLARE_RUNTIME_VECTOR_INDEXES
import DatabaseKit
import DatabaseTypes

@Persistable
struct RuntimeVerificationVectorDocument {
    #Directory<RuntimeVerificationVectorDocument>(
        "verification",
        "cloudflare-runtime-vectors"
    )

    var id: String
    var title: String
    var embedding: Vector

    #Index(
        .vector(dimensions: 2, metric: .dotProduct),
        embedding: \RuntimeVerificationVectorDocument.embedding,
        name: "RuntimeVerificationVectorDocument_embedding"
    )
}
#endif
