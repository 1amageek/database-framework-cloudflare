import DatabaseEngine
import DatabaseKit

enum RuntimeVerificationMigrationPlan: SchemaMigrationPlan {
    static let schemas: [any VersionedSchema.Type] = [
        RuntimeVerificationSchemaV1.self,
    ]

    static let stages: [MigrationStage] = []
}
