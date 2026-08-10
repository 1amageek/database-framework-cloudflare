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
        .vector(dimensions: 2, metric: .dotProduct),
        embedding: \RuntimeVerificationIVFDocument.embedding,
        name: "RuntimeVerificationIVFDocument_embedding"
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
        .vector(dimensions: 2, metric: .dotProduct),
        embedding: \RuntimeVerificationPQDocument.embedding,
        name: "RuntimeVerificationPQDocument_embedding"
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
        .vector(dimensions: 2, metric: .dotProduct),
        embedding: \RuntimeVerificationFlatDocument.embedding,
        name: "RuntimeVerificationFlatDocument_embedding"
    )
}

extension RuntimeVerificationFlatDocument: RuntimeVerificationSecurityPolicy {}
#endif
