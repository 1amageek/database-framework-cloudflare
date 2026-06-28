#if !os(WASI)
import CloudflareDurableObjectStorage
import Database
import DatabaseEngine

/// Database-framework container configuration backed by Cloudflare Durable Object storage.
public struct CloudflareDatabaseConfiguration: DatabaseContainerConfiguration {
    public let scope: CloudflareDurableObjectStorageScope
    public let client: any CloudflareDurableObjectStorageClient
    public let nameCodec: any CloudflareDurableObjectNameCodec
    public let limits: CloudflareDurableObjectLimits

    public init(
        scope: CloudflareDurableObjectStorageScope,
        client: any CloudflareDurableObjectStorageClient,
        nameCodec: any CloudflareDurableObjectNameCodec = CloudflareDurableObjectV1NameCodec(),
        limits: CloudflareDurableObjectLimits = .default
    ) {
        self.scope = scope
        self.client = client
        self.nameCodec = nameCodec
        self.limits = limits
    }

    public init(
        databaseID: String = "main",
        tenantID: String? = nil,
        workspaceID: String? = nil,
        client: any CloudflareDurableObjectStorageClient,
        nameCodec: any CloudflareDurableObjectNameCodec = CloudflareDurableObjectV1NameCodec(),
        limits: CloudflareDurableObjectLimits = .default
    ) throws {
        self.init(
            scope: try CloudflareDurableObjectStorageScope(
                databaseID: databaseID,
                tenantID: tenantID,
                workspaceID: workspaceID
            ),
            client: client,
            nameCodec: nameCodec,
            limits: limits
        )
    }

    public func makeDBConfiguration(
        indexConfigurations: [any IndexConfiguration]
    ) async throws -> DBConfiguration {
        let engine = try await CloudflareDurableObjectStorage.CloudflareDurableObjectStorageEngine(
            configuration: CloudflareDurableObjectStorageConfiguration(
                scope: scope,
                client: client,
                nameCodec: nameCodec,
                limits: limits
            )
        )
        return DBConfiguration(
            name: "cloudflare",
            backend: .custom(engine),
            indexConfigurations: indexConfigurations
        )
    }
}
#endif
