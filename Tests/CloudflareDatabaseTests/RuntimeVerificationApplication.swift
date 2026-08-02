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
    let storageScope: StorageWireScope
    let storageLimits = CloudflareDurableObjectLimits.default
    let jobService: AnyDatabaseJobService

    init() throws {
        storageScope = try StorageWireScope(
            databaseID: "runtime-verification"
        )
        self.jobService = AnyDatabaseJobService(
            UnavailableCloudflareDatabaseServices()
        )
    }

    init<JobService: DatabaseJobService>(jobService: JobService) throws {
        storageScope = try StorageWireScope(
            databaseID: "runtime-verification"
        )
        self.jobService = AnyDatabaseJobService(jobService)
    }

    func makeContainerDefinition() async throws
        -> CloudflareDatabaseContainerDefinition {
        CloudflareDatabaseContainerDefinition(
            schema: try Schema(
                entities: [try RuntimeVerificationDocument.schemaEntity]
            ),
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

    func makeServerConfiguration(
        container: DBContainer,
        jobScheduler: AnyDatabaseJobScheduler
    ) async throws -> DatabaseServerRuntimeConfiguration {
        _ = container
        _ = jobScheduler
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
