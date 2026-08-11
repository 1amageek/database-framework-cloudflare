import CloudflareDatabase
import CloudflareDurableObjectStorage
import CloudflareDurableObjectStorageWire
import DatabaseKit
import DatabaseEngine
import DatabaseRuntime
import DatabaseWireRuntime
import DatabaseFoundation
import StorageKitSystemClock

final class RuntimeVerificationApplication: CloudflareDatabaseApplication {
    private enum JobServiceSelection: Sendable {
        case injected(AnyDatabaseJobService)
        case persistent
    }

    let partitionIdentity: StoragePartitionIdentity
    let storageLimits = CloudflareDurableObjectLimits.default
    let storageLayout: CloudflareDatabaseStorageLayout
    let jobAuthorizationProvider:
        AnyCloudflareDatabaseJobAuthorizationProvider?
    private let jobServiceSelection: JobServiceSelection

    init() throws {
        partitionIdentity = try StoragePartitionIdentity(
            databaseID: "runtime-verification"
        )
        storageLayout = try makeCloudflareTestStorageLayout(
            namespace: "runtime-verification"
        )
        self.jobAuthorizationProvider = nil
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
        storageLayout = try makeCloudflareTestStorageLayout(
            namespace: "runtime-verification"
        )
        self.jobAuthorizationProvider =
            AnyCloudflareDatabaseJobAuthorizationProvider(
                RuntimeVerificationJobAuthorizationProvider()
            )
        self.jobServiceSelection = .persistent
    }

    init<JobService: DatabaseJobService>(jobService: JobService) throws {
        partitionIdentity = try StoragePartitionIdentity(
            databaseID: "runtime-verification"
        )
        storageLayout = try makeCloudflareTestStorageLayout(
            namespace: "runtime-verification"
        )
        self.jobAuthorizationProvider = nil
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
    ) async throws -> DatabaseOperationRuntimeConfiguration {
        _ = container
        let serviceFactory: AnyDatabaseOperationServiceFactory
        switch jobServiceSelection {
        case .injected(let jobService):
            serviceFactory = AnyDatabaseOperationServiceFactory { context in
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
            serviceFactory = AnyDatabaseOperationServiceFactory(
                CanonicalDatabaseOperationServiceFactory(
                    maintenanceServiceFactory:
                        DatabaseMaintenanceOperationServiceFactory(
                            identifierGenerator: identifierGenerator
                        ),
                    jobServiceFactory: jobServiceFactory
                )
            )
        }
        return try DatabaseOperationRuntimeConfiguration(
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

private struct RuntimeVerificationJobAuthorizationProvider:
    CloudflareDatabaseJobAuthorizationProviding {
    private static let principalIdentifier = "runtime-verification"

    func reference(
        for authorization: AuthorizationContext
    ) throws -> DatabaseJobAuthorizationReference {
        guard authorization.principal?.identifier == Self.principalIdentifier
        else {
            throw DatabaseJobAuthorizationError.revalidationFailed
        }
        return try DatabaseJobAuthorizationReference(Self.principalIdentifier)
    }

    func revalidate(
        _ reference: DatabaseJobAuthorizationReference
    ) async throws -> AuthorizationContext {
        guard reference.value == Self.principalIdentifier else {
            throw DatabaseJobAuthorizationError.revalidationFailed
        }
        return .authenticated(
            Principal(
                identifier: Self.principalIdentifier,
                roles: ["admin"]
            )
        )
    }
}
