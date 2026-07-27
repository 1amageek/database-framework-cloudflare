import CloudflareDurableObjectStorage
import CloudflareDurableObjectStorageWire
import DatabaseEngine
import DatabaseServer

/// Closure-backed application composition root retained by the database runtime.
public final class CloudflareDatabaseApplicationComposition:
    CloudflareDatabaseApplication,
    Sendable {
    public let storageScope: StorageWireScope
    public let storageLimits: CloudflareDurableObjectLimits

    private let createContainer: @Sendable (
        CloudflareDurableObjectStorageEngine
    ) async throws -> DBContainer
    private let createServerConfiguration: @Sendable (
        DBContainer,
        AnyDatabaseJobScheduler
    ) async throws -> DatabaseServerRuntimeConfiguration

    public init<Application: CloudflareDatabaseApplication>(
        _ application: Application
    ) {
        self.storageScope = application.storageScope
        self.storageLimits = application.storageLimits
        self.createContainer = { storageEngine in
            try await application.makeContainer(storageEngine: storageEngine)
        }
        self.createServerConfiguration = { container, jobScheduler in
            try await application.makeServerConfiguration(
                container: container,
                jobScheduler: jobScheduler
            )
        }
    }

    public func makeContainer(
        storageEngine: CloudflareDurableObjectStorageEngine
    ) async throws -> DBContainer {
        try await createContainer(storageEngine)
    }

    public func makeServerConfiguration(
        container: DBContainer,
        jobScheduler: AnyDatabaseJobScheduler
    ) async throws -> DatabaseServerRuntimeConfiguration {
        try await createServerConfiguration(container, jobScheduler)
    }
}
