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
    private enum JobServiceSelection: Sendable {
        case injected(AnyDatabaseJobService)
        case persistent
    }

    let partitionIdentity: StoragePartitionIdentity
    let storageLimits = CloudflareDurableObjectLimits.default
    let storageLayout: CloudflareDatabaseStorageLayout
    private let jobServiceSelection: JobServiceSelection

    init() throws {
        partitionIdentity = try StoragePartitionIdentity(
            databaseID: "runtime-verification"
        )
        storageLayout = try CloudflareDatabaseStorageLayout(
            domainID: DatabaseStorageDomain.ID("primary"),
            domainNamespacePath: ["database", "runtime-verification"],
            placementID: Base.Placement.ID("default"),
            baseNamespacePath: ["bases"]
        )
        self.jobServiceSelection = .injected(
            AnyDatabaseJobService(
                UnavailableCloudflareDatabaseServices()
            )
        )
    }

    init(persistentJobs: Void) throws {
        _ = persistentJobs
        partitionIdentity = try StoragePartitionIdentity(
            databaseID: "runtime-verification"
        )
        storageLayout = try CloudflareDatabaseStorageLayout(
            domainID: DatabaseStorageDomain.ID("primary"),
            domainNamespacePath: ["database", "runtime-verification"],
            placementID: Base.Placement.ID("default"),
            baseNamespacePath: ["bases"]
        )
        self.jobServiceSelection = .persistent
    }

    init<JobService: DatabaseJobService>(jobService: JobService) throws {
        partitionIdentity = try StoragePartitionIdentity(
            databaseID: "runtime-verification"
        )
        storageLayout = try CloudflareDatabaseStorageLayout(
            domainID: DatabaseStorageDomain.ID("primary"),
            domainNamespacePath: ["database", "runtime-verification"],
            placementID: Base.Placement.ID("default"),
            baseNamespacePath: ["bases"]
        )
        self.jobServiceSelection = .injected(
            AnyDatabaseJobService(jobService)
        )
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
                ],
                authorizationPolicies: [
                    AuthorizationPolicyHandler(
                        RuntimeVerificationDocument.self
                    )
                ]
            ),
            security: .enabled(),
            monotonicClock: SystemStorageClock(),
            wallClock: RealtimeDatabaseWallClock()
        )
    }

    func makeRuntimeConfiguration(
        for container: DBContainer
    ) async throws -> DatabaseServerRuntimeConfiguration {
        _ = container
        let serviceFactory: AnyDatabaseServerServiceFactory
        switch jobServiceSelection {
        case .injected(let jobService):
            serviceFactory = AnyDatabaseServerServiceFactory { context in
                try await RuntimeVerificationServiceFactory(
                    jobService: jobService
                ).makeServices(context: context)
            }
        case .persistent:
            let identifierGenerator = RandomDatabaseUUIDGenerator()
            let jobServiceFactory = try DatabasePersistentJobServiceFactory(
                registry: DatabaseResumableOperationRegistry(operations: []),
                identifierGenerator: identifierGenerator,
                storageLimits: DatabasePersistentJobStorageLimits(
                    maximumStorageValueBytes: 1_048_576
                )
            )
            serviceFactory = AnyDatabaseServerServiceFactory(
                CanonicalDatabaseServerServiceFactory(
                    maintenanceServiceFactory:
                        DatabaseMaintenanceOperationServiceFactory(
                            identifierGenerator: identifierGenerator
                        ),
                    jobServiceFactory: jobServiceFactory
                )
            )
        }
        return try DatabaseServerRuntimeConfiguration(
            identity: DatabaseRuntimeIdentity(
                version: "cloudflare-runtime-verification"
            ),
            serviceFactory: serviceFactory,
            admissionPolicy: AnyDatabaseOperationAdmissionPolicy(
                UnrestrictedDatabaseOperationAdmissionPolicy()
            ),
            clock: RealtimeDatabaseWallClock()
        )
    }
}
