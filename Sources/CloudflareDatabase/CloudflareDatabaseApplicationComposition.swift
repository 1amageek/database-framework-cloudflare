import CloudflareDurableObjectStorage
import CloudflareDurableObjectStorageWire
import DatabaseEngine
import DatabaseServer

/// Closure-backed application composition root retained by the database runtime.
public final class CloudflareDatabaseApplicationComposition:
    CloudflareDatabaseApplication,
    Sendable {
    public let partitionIdentity: StoragePartitionIdentity
    public let storageLimits: CloudflareDurableObjectLimits

    private let createContainerDefinition: @Sendable () async throws
        -> CloudflareDatabaseContainerDefinition
    private let createServerConfiguration: @Sendable (
        DBContainer,
        AnyDatabaseJobScheduler
    ) async throws -> DatabaseServerRuntimeConfiguration

    public init<Application: CloudflareDatabaseApplication>(
        _ application: Application
    ) {
        self.partitionIdentity = application.partitionIdentity
        self.storageLimits = application.storageLimits
        self.createContainerDefinition = {
            try await application.makeContainerDefinition()
        }
        self.createServerConfiguration = { container, jobScheduler in
            try await application.makeServerConfiguration(
                container: container,
                jobScheduler: jobScheduler
            )
        }
    }

    public func makeContainerDefinition() async throws
        -> CloudflareDatabaseContainerDefinition {
        try await createContainerDefinition()
    }

    public func makeServerConfiguration(
        container: DBContainer,
        jobScheduler: AnyDatabaseJobScheduler
    ) async throws -> DatabaseServerRuntimeConfiguration {
        try await createServerConfiguration(container, jobScheduler)
    }
}
