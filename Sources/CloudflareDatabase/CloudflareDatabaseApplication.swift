import CloudflareDurableObjectStorage
import CloudflareDurableObjectStorageWire
import DatabaseOperations

/// Application-owned composition root for one compiled database runtime.
public protocol CloudflareDatabaseOperationApplication: DatabaseOperationApplication {
    /// Stable storage partition hosted by the Durable Object instance.
    var partitionIdentity: StoragePartitionIdentity { get }

    /// Storage limits enforced by the platform adapter.
    var storageLimits: CloudflareDurableObjectLimits { get }

    /// Single-domain layout consumed by DatabaseFramework's topology owner.
    /// MultipleBases builds additionally name the Base placement root.
    var storageLayout: CloudflareDatabaseStorageLayout { get }

    /// Application authentication authority for persistent job revalidation.
    /// Jobs remain unadvertised when this authority is absent.
    var jobAuthorizationProvider:
        AnyCloudflareDatabaseJobAuthorizationProvider? { get }
}
