#if CLOUDFLARE_TEST_VECTOR_INDEXES
import DatabaseKit
import DatabaseTypes

@Persistable
struct CloudflareHNSWRejectionDocument {
    #Directory<CloudflareHNSWRejectionDocument>(
        "verification",
        "cloudflare-hnsw-rejection"
    )

    var id: String
    var embedding: Vector

    #Index(
        .vector(
            name: "CloudflareHNSWRejectionDocument_embedding",
            embedding: \CloudflareHNSWRejectionDocument.embedding,
            dimensions: 2, metric: .dotProduct
        )
    )
}
#endif
