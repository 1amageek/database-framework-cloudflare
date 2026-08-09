import DatabaseKit

enum RuntimeVerificationSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var entities: [Schema.Entity] {
        get throws(SchemaEntityError) {
            [try RuntimeVerificationDocument.schemaEntity]
        }
    }
}
