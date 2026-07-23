import CloudflareDatabase
import CloudflareDurableObjectStorage
import Core
import DatabaseEngine
import DatabaseRuntime
import DatabaseServer

final class RuntimeVerificationApplication: CloudflareDatabaseApplication {
    let storageScope: CloudflareDurableObjectStorageScope
    let storageLimits = CloudflareDurableObjectLimits.default
    let jobService: AnyDatabaseJobService

    init() throws {
        storageScope = try CloudflareDurableObjectStorageScope(
            databaseID: "runtime-verification"
        )
        self.jobService = AnyDatabaseJobService(
            UnavailableCloudflareDatabaseServices()
        )
    }

    init<JobService: DatabaseJobService>(jobService: JobService) throws {
        storageScope = try CloudflareDurableObjectStorageScope(
            databaseID: "runtime-verification"
        )
        self.jobService = AnyDatabaseJobService(jobService)
    }

    func makeContainer(
        storageEngine: CloudflareDurableObjectStorageEngine
    ) async throws -> DBContainer {
        return try await DBContainer(
            for: Schema([RuntimeVerificationRecord.self]),
            configuration: DBConfiguration(
                backend: .custom(storageEngine)
            ),
            runtimeConfiguration: try DatabaseFrameworkRuntime.configuration(),
            security: .disabled
        )
    }

    func makeServerConfiguration(
        container: DBContainer,
        jobScheduler: AnyDatabaseJobScheduler
    ) async throws -> DatabaseServerRuntimeConfiguration {
        _ = container
        _ = jobScheduler
        return DatabaseServerRuntimeConfiguration(
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
            )
        )
    }
}
