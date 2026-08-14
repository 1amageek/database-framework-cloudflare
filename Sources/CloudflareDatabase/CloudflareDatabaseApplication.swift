import CloudflareDurableObjectStorage
import CloudflareDurableObjectStorageWire
import DatabaseServerRuntime

/// Application-owned composition root for one compiled database runtime.
public protocol CloudflareDatabaseOperationApplication: DatabaseOperationApplication {
    /// Stable storage partition hosted by the Durable Object instance.
    var partitionIdentity: StoragePartitionIdentity { get }

    /// Storage limits enforced by the platform adapter.
    var storageLimits: CloudflareDurableObjectLimits { get }

    #if CLOUDFLARE_DATABASE_MULTIPLE_BASES
    /// Application-selected storage topology for the optional MultipleBases trait.
    var storageLayout: CloudflareDatabaseStorageLayout { get }
    #endif

    /// Application authentication authority for persistent job revalidation.
    /// Jobs remain unadvertised when this authority is absent.
    var jobAuthorizationProvider:
        AnyCloudflareDatabaseJobAuthorizationProvider? { get }
}
