import CloudflareDurableObjectStorage
import CloudflareDurableObjectStorageWire
import DatabaseServer

/// Application-owned composition root for one compiled database runtime.
public protocol CloudflareDatabaseApplication: DatabaseServerApplication {
    /// Stable storage partition hosted by the Durable Object instance.
    var partitionIdentity: StoragePartitionIdentity { get }

    /// Storage limits enforced by the platform adapter.
    var storageLimits: CloudflareDurableObjectLimits { get }

    /// Single-domain layout consumed by DatabaseFramework's topology owner.
    var storageLayout: CloudflareDatabaseStorageLayout { get }
}
