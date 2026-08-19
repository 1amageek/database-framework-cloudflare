#if CLOUDFLARE_TEST_VECTOR_INDEXES
import DatabaseEngine
import DatabaseKit
import DatabaseTypes

struct InvalidVectorRuntimeConfiguration: IndexRuntimeConfiguration {
    static let indexType: IndexType = .vector

    let indexName = "CloudflareHNSWRejectionDocument_embedding"

    var executionOptions: FieldObject {
        get throws {
            try FieldObject([
                (key: "algorithm", value: .string("unsupported"))
            ])
        }
    }
}
#endif
