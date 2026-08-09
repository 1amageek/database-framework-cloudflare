import CloudflareDatabase
import CloudflareDurableObjectStorage
import CloudflareDurableObjectStorageWire
import DatabaseKit
import DatabaseEngine
import DatabaseRuntime
import DatabaseServer
import DatabaseServerFoundation
import StorageKitSystemClock

final class RuntimeVerificationApplication: CloudflareDatabaseApplication {
    let partitionIdentity: StoragePartitionIdentity
    let storageLimits = CloudflareDurableObjectLimits.default
    let jobService: AnyDatabaseJobService

    init() throws {
        partitionIdentity = try StoragePartitionIdentity(
            databaseID: "runtime-verification"
        )
        self.jobService = AnyDatabaseJobService(
            UnavailableCloudflareDatabaseServices()
        )
    }

    init<JobService: DatabaseJobService>(jobService: JobService) throws {
        partitionIdentity = try StoragePartitionIdentity(
            databaseID: "runtime-verification"
        )
        self.jobService = AnyDatabaseJobService(jobService)
    }

    func makeContainerDefinition() async throws
        -> DatabaseContainerDefinition {
        DatabaseContainerDefinition(
            schema: try RuntimeVerificationSchemaV1.makeSchema(),
            migrationPlan: RuntimeVerificationMigrationPlan.self,
            runtimeConfiguration: try DatabaseFrameworkRuntime.configuration(
                entityRuntimes: [
                    try DatabaseFrameworkRuntime.entity(
                        RuntimeVerificationDocument.self
                    )
                ]
            ),
            security: .disabled,
            monotonicClock: SystemStorageClock(),
            wallClock: RealtimeDatabaseWallClock()
        )
    }

    func makeRuntimeConfiguration(
        for container: DBContainer
    ) async throws -> DatabaseServerRuntimeConfiguration {
        _ = container
        return try DatabaseServerRuntimeConfiguration(
            identity: DatabaseRuntimeIdentity(
                version: "cloudflare-runtime-verification"
            ),
            serviceFactory: AnyDatabaseServerServiceFactory { context in
                try await RuntimeVerificationServiceFactory(
                    jobService: self.jobService
                ).makeServices(context: context)
            },
            admissionPolicy: AnyDatabaseOperationAdmissionPolicy(
                UnrestrictedDatabaseOperationAdmissionPolicy()
            ),
            clock: RealtimeDatabaseWallClock()
        )
    }
}
