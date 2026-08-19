#if CLOUDFLARE_TEST_VECTOR_INDEXES
import DatabaseEngine
import DatabaseKit
import DatabaseTypes

struct CustomHNSWRuntimeConfiguration: IndexRuntimeConfiguration {
    static let indexType: IndexType = .vector

    let indexName = "CloudflareHNSWRejectionDocument_embedding"

    var executionOptions: FieldObject {
        get throws {
            try FieldObject([
                (key: "algorithm", value: .string("hnsw")),
                (key: "efConstruction", value: .int64(200)),
                (key: "efSearch", value: .int64(50)),
                (key: "m", value: .int64(16)),
            ])
        }
    }
}
#endif
