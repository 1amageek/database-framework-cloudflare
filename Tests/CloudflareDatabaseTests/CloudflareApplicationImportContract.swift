import CloudflareDatabase
import DatabaseRuntime

private let cloudflareApplicationImportContract: (
    ByteString.Type,
    Schema.Type,
    DBContainer.Type,
    DatabaseRuntimeConfiguration.Type,
    StoragePartitionIdentity.Type,
    CloudflareDurableObjectLimits.Type
) = (
    ByteString.self,
    Schema.self,
    DBContainer.self,
    DatabaseRuntimeConfiguration.self,
    StoragePartitionIdentity.self,
    CloudflareDurableObjectLimits.self
)
