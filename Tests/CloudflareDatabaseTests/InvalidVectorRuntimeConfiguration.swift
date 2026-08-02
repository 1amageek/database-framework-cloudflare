#if CLOUDFLARE_TEST_VECTOR_INDEXES
import DatabaseEngine
import DatabaseTypes

struct InvalidVectorRuntimeConfiguration: IndexRuntimeConfiguration {
    static let kindIdentifier = "vector"

    let fieldName = "embedding"
    let entityName = "CloudflareHNSWRejectionDocument"
    let subspaceKey: String? = nil

    var executionOptions: FieldObject {
        get throws {
            try FieldObject([
                (key: "algorithm", value: .string("unsupported")),
            ])
        }
    }
}
#endif
