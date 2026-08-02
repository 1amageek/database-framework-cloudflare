import CloudflareDurableObjectStorage
import DatabaseEngine
import DatabaseKit
import StorageKit

/// Immutable application composition required before a Cloudflare database
/// container may open.
public struct CloudflareDatabaseContainerDefinition: Sendable {
    let schema: Schema
    let runtimeConfiguration: DatabaseRuntimeConfiguration
    let security: SecurityConfiguration
    let databaseName: String?
    let monotonicClock: any StorageMonotonicClock
    let wallClock: any WallClock
    let indexConfigurations: [any IndexRuntimeConfiguration]
    let itemStorage: ItemStorageConfiguration
    let logging: DatabaseLoggingConfiguration
    let metrics: DatabaseMetricsConfiguration

    public init(
        schema: Schema,
        runtimeConfiguration: DatabaseRuntimeConfiguration,
        security: SecurityConfiguration = .enabled(),
        databaseName: String? = nil,
        monotonicClock: any StorageMonotonicClock,
        wallClock: any WallClock,
        indexConfigurations: [any IndexRuntimeConfiguration] = [],
        itemStorage: ItemStorageConfiguration = .v1,
        logging: DatabaseLoggingConfiguration = .disabled,
        metrics: DatabaseMetricsConfiguration = .disabled
    ) {
        self.schema = schema
        self.runtimeConfiguration = runtimeConfiguration
        self.security = security
        self.databaseName = databaseName
        self.monotonicClock = monotonicClock
        self.wallClock = wallClock
        self.indexConfigurations = indexConfigurations
        self.itemStorage = itemStorage
        self.logging = logging
        self.metrics = metrics
    }

    /// Validates hosting restrictions without opening storage or allocating an
    /// index implementation.
    public func validateHostingCapabilities() throws {
        try CloudflareDatabaseHostingCapabilityValidator.validate(self)
    }

    func open(
        storageEngine: CloudflareDurableObjectStorageEngine
    ) async throws -> DBContainer {
        try await DBContainer.open(
            for: schema,
            configuration: DBConfiguration(
                name: databaseName,
                storageEngine: storageEngine,
                monotonicClock: monotonicClock,
                wallClock: wallClock,
                indexConfigurations: indexConfigurations,
                itemStorage: itemStorage,
                logging: logging,
                metrics: metrics
            ),
            runtimeConfiguration: runtimeConfiguration,
            security: security
        )
    }
}
