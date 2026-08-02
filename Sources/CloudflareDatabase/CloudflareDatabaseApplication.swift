import CloudflareDurableObjectStorage
import CloudflareDurableObjectStorageWire
import DatabaseEngine
import DatabaseServer

/// Application-owned composition root for one compiled database runtime.
public protocol CloudflareDatabaseApplication: AnyObject, Sendable {
    /// Stable StorageKit scope hosted by the Durable Object instance.
    var storageScope: StorageWireScope { get }

    /// Storage limits enforced by both the engine and its platform adapter.
    var storageLimits: CloudflareDurableObjectLimits { get }

    /// Describes the application container before storage or indexes open.
    ///
    /// The runtime validates host capabilities from this value, constructs the
    /// Cloudflare storage engine, and then opens the container.
    func makeContainerDefinition() async throws
        -> CloudflareDatabaseContainerDefinition

    /// Provides every service required by the canonical DatabaseWire runtime.
    ///
    /// The platform scheduler must be passed to the persistent job service so
    /// wake-ups survive runtime eviction through Durable Object alarms.
    func makeServerConfiguration(
        container: DBContainer,
        jobScheduler: AnyDatabaseJobScheduler
    ) async throws -> DatabaseServerRuntimeConfiguration
}
