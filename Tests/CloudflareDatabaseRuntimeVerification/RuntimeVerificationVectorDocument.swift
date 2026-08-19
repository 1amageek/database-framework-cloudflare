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
        .vector(
            name: "RuntimeVerificationVectorDocument_embedding",
            embedding: \RuntimeVerificationVectorDocument.embedding,
            dimensions: 2,
            metric: .dotProduct
        )
    )
}

@Persistable
struct RuntimeVerificationIVFDocument {
    #Directory<RuntimeVerificationIVFDocument>(
        "verification",
        "cloudflare-runtime-vectors-ivf"
    )

    var id: String
    var title: String
    var embedding: Vector

    #Index(
        .vector(
            name: "RuntimeVerificationIVFDocument_embedding",
            embedding: \RuntimeVerificationIVFDocument.embedding,
            dimensions: 2,
            metric: .dotProduct
        )
    )
}

extension RuntimeVerificationIVFDocument: RuntimeVerificationSecurityPolicy {}

@Persistable
struct RuntimeVerificationPQDocument {
    #Directory<RuntimeVerificationPQDocument>(
        "verification",
        "cloudflare-runtime-vectors-pq"
    )

    var id: String
    var title: String
    var embedding: Vector

    #Index(
        .vector(
            name: "RuntimeVerificationPQDocument_embedding",
            embedding: \RuntimeVerificationPQDocument.embedding,
            dimensions: 2,
            metric: .dotProduct
        )
    )
}

extension RuntimeVerificationPQDocument: RuntimeVerificationSecurityPolicy {}

@Persistable
struct RuntimeVerificationFlatDocument {
    #Directory<RuntimeVerificationFlatDocument>(
        "verification",
        "cloudflare-runtime-vectors-flat"
    )

    var id: String
    var title: String
    var embedding: Vector

    #Index(
        .vector(
            name: "RuntimeVerificationFlatDocument_embedding",
            embedding: \RuntimeVerificationFlatDocument.embedding,
            dimensions: 2,
            metric: .dotProduct
        )
    )
}

extension RuntimeVerificationFlatDocument: RuntimeVerificationSecurityPolicy {}
#endif
