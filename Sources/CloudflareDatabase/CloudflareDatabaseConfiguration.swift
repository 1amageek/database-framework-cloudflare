import CloudflareDurableObjectStorage
import CloudflareDurableObjectStorageWire
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit
import StorageKit

/// Immutable application configuration consumed by the Cloudflare adapter.
public struct CloudflareDatabaseConfiguration: Sendable {
    #if CLOUDFLARE_DATABASE_MULTI_BASE
    private struct StorageSelection: Sendable {
        let layout: CloudflareDatabaseStorageLayout

        init(_ layout: CloudflareDatabaseStorageLayout) {
            self.layout = layout
        }
    }

    private typealias OpenContainer =
        @Sendable (
            DatabaseStorageTopology,
            any StorageMonotonicClock,
            any WallClock
        ) async throws -> DBContainer
    #else
    private struct StorageSelection: Sendable {
        init() {}
    }

    private typealias OpenContainer =
        @Sendable (
            any StorageEngine,
            Subspace,
            any StorageMonotonicClock,
            any WallClock
        ) async throws -> DBContainer
    #endif

    public let partitionIdentity: StoragePartitionIdentity
    public let storageLimits: CloudflareDurableObjectLimits
    public let declaredSchema: Schema
    public let security: SecurityConfiguration
    public let databaseName: String?
    public let itemStorage: ItemStorageConfiguration
    public let logging: DatabaseLoggingConfiguration
    public let metrics: DatabaseMetricsConfiguration
    package let runtimeConfiguration: DatabaseRuntimeConfiguration

    #if CLOUDFLARE_DATABASE_MULTI_BASE
    public let storageLayout: CloudflareDatabaseStorageLayout
    #endif
    private let openContainer: OpenContainer

    #if CLOUDFLARE_DATABASE_MULTI_BASE
    /// Defines a container backed by a statically compiled schema.
    public init(
        partitionIdentity: StoragePartitionIdentity,
        storageLimits: CloudflareDurableObjectLimits = .default,
        storageLayout: CloudflareDatabaseStorageLayout,
        schema: Schema,
        runtimeConfiguration: DatabaseRuntimeConfiguration,
        security: SecurityConfiguration = .enabled(),
        databaseName: String? = nil,
        itemStorage: ItemStorageConfiguration = .v1,
        logging: DatabaseLoggingConfiguration = .disabled,
        metrics: DatabaseMetricsConfiguration = .disabled
    ) {
        self.init(
            partitionIdentity: partitionIdentity,
            storageLimits: storageLimits,
            storageSelection: StorageSelection(storageLayout),
            schema: schema,
            runtimeConfiguration: runtimeConfiguration,
            security: security,
            databaseName: databaseName,
            itemStorage: itemStorage,
            logging: logging,
            metrics: metrics,
            openContainer: { topology, monotonicClock, wallClock in
                try await DBContainer.open(
                    for: schema,
                    configuration: DBConfiguration(
                        name: databaseName,
                        storageTopology: topology,
                        monotonicClock: monotonicClock,
                        wallClock: wallClock,
                        itemStorage: itemStorage,
                        logging: logging,
                        metrics: metrics
                    ),
                    runtimeConfiguration: runtimeConfiguration,
                    security: security
                )
            }
        )
    }

    /// Defines a compiled schema with an application-owned migration plan.
    public init<MigrationPlan: SchemaMigrationPlan>(
        partitionIdentity: StoragePartitionIdentity,
        storageLimits: CloudflareDurableObjectLimits = .default,
        storageLayout: CloudflareDatabaseStorageLayout,
        schema: Schema,
        migrationPlan: MigrationPlan.Type,
        runtimeConfiguration: DatabaseRuntimeConfiguration,
        security: SecurityConfiguration = .enabled(),
        databaseName: String? = nil,
        itemStorage: ItemStorageConfiguration = .v1,
        logging: DatabaseLoggingConfiguration = .disabled,
        metrics: DatabaseMetricsConfiguration = .disabled
    ) {
        self.init(
            partitionIdentity: partitionIdentity,
            storageLimits: storageLimits,
            storageSelection: StorageSelection(storageLayout),
            schema: schema,
            runtimeConfiguration: runtimeConfiguration,
            security: security,
            databaseName: databaseName,
            itemStorage: itemStorage,
            logging: logging,
            metrics: metrics,
            openContainer: { topology, monotonicClock, wallClock in
                try await DBContainer.open(
                    for: schema,
                    migrationPlan: migrationPlan,
                    configuration: DBConfiguration(
                        name: databaseName,
                        storageTopology: topology,
                        monotonicClock: monotonicClock,
                        wallClock: wallClock,
                        itemStorage: itemStorage,
                        logging: logging,
                        metrics: metrics
                    ),
                    runtimeConfiguration: runtimeConfiguration,
                    security: security
                )
            }
        )
    }
    #else
    /// Defines a container backed by a statically compiled schema.
    public init(
        partitionIdentity: StoragePartitionIdentity,
        storageLimits: CloudflareDurableObjectLimits = .default,
        schema: Schema,
        runtimeConfiguration: DatabaseRuntimeConfiguration,
        security: SecurityConfiguration = .enabled(),
        databaseName: String? = nil,
        itemStorage: ItemStorageConfiguration = .v1,
        logging: DatabaseLoggingConfiguration = .disabled,
        metrics: DatabaseMetricsConfiguration = .disabled
    ) {
        self.init(
            partitionIdentity: partitionIdentity,
            storageLimits: storageLimits,
            storageSelection: StorageSelection(),
            schema: schema,
            runtimeConfiguration: runtimeConfiguration,
            security: security,
            databaseName: databaseName,
            itemStorage: itemStorage,
            logging: logging,
            metrics: metrics,
            openContainer: { engine, root, monotonicClock, wallClock in
                try await DBContainer.open(
                    for: schema,
                    configuration: DBConfiguration(
                        name: databaseName,
                        storageEngine: engine,
                        databaseRoot: root,
                        monotonicClock: monotonicClock,
                        wallClock: wallClock,
                        itemStorage: itemStorage,
                        logging: logging,
                        metrics: metrics
                    ),
                    runtimeConfiguration: runtimeConfiguration,
                    security: security
                )
            }
        )
    }

    /// Defines a compiled schema with an application-owned migration plan.
    public init<MigrationPlan: SchemaMigrationPlan>(
        partitionIdentity: StoragePartitionIdentity,
        storageLimits: CloudflareDurableObjectLimits = .default,
        schema: Schema,
        migrationPlan: MigrationPlan.Type,
        runtimeConfiguration: DatabaseRuntimeConfiguration,
        security: SecurityConfiguration = .enabled(),
        databaseName: String? = nil,
        itemStorage: ItemStorageConfiguration = .v1,
        logging: DatabaseLoggingConfiguration = .disabled,
        metrics: DatabaseMetricsConfiguration = .disabled
    ) {
        self.init(
            partitionIdentity: partitionIdentity,
            storageLimits: storageLimits,
            storageSelection: StorageSelection(),
            schema: schema,
            runtimeConfiguration: runtimeConfiguration,
            security: security,
            databaseName: databaseName,
            itemStorage: itemStorage,
            logging: logging,
            metrics: metrics,
            openContainer: { engine, root, monotonicClock, wallClock in
                try await DBContainer.open(
                    for: schema,
                    migrationPlan: migrationPlan,
                    configuration: DBConfiguration(
                        name: databaseName,
                        storageEngine: engine,
                        databaseRoot: root,
                        monotonicClock: monotonicClock,
                        wallClock: wallClock,
                        itemStorage: itemStorage,
                        logging: logging,
                        metrics: metrics
                    ),
                    runtimeConfiguration: runtimeConfiguration,
                    security: security
                )
            }
        )
    }
    #endif

    private init(
        partitionIdentity: StoragePartitionIdentity,
        storageLimits: CloudflareDurableObjectLimits,
        storageSelection: StorageSelection,
        schema: Schema,
        runtimeConfiguration: DatabaseRuntimeConfiguration,
        security: SecurityConfiguration,
        databaseName: String?,
        itemStorage: ItemStorageConfiguration,
        logging: DatabaseLoggingConfiguration,
        metrics: DatabaseMetricsConfiguration,
        openContainer: @escaping OpenContainer
    ) {
        self.partitionIdentity = partitionIdentity
        self.storageLimits = storageLimits
        #if CLOUDFLARE_DATABASE_MULTI_BASE
        self.storageLayout = storageSelection.layout
        #else
        _ = storageSelection
        #endif
        self.declaredSchema = schema
        self.runtimeConfiguration = runtimeConfiguration
        self.security = security
        self.databaseName = databaseName
        self.itemStorage = itemStorage
        self.logging = logging
        self.metrics = metrics
        self.openContainer = openContainer
    }

    #if CLOUDFLARE_DATABASE_MULTI_BASE
    package func open(
        storageTopology: DatabaseStorageTopology,
        monotonicClock: any StorageMonotonicClock,
        wallClock: any WallClock
    ) async throws -> DBContainer {
        try await openContainer(
            storageTopology,
            monotonicClock,
            wallClock
        )
    }
    #else
    package func open(
        storageEngine: any StorageEngine,
        databaseRoot: Subspace,
        monotonicClock: any StorageMonotonicClock,
        wallClock: any WallClock
    ) async throws -> DBContainer {
        try await openContainer(
            storageEngine,
            databaseRoot,
            monotonicClock,
            wallClock
        )
    }
    #endif
}
