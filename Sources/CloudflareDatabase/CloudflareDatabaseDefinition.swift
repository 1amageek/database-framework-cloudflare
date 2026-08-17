import CloudflareDurableObjectStorage
import CloudflareDurableObjectStorageWire
@_spi(DatabaseExecution) import DatabaseEngine
import DatabaseKit
import StorageKit

/// Immutable application definition consumed by the Cloudflare adapter.
public struct CloudflareDatabaseDefinition: Sendable {
    #if CLOUDFLARE_DATABASE_MULTIPLE_BASES
    private struct StorageSelection: Sendable {
        let layout: CloudflareDatabaseStorageLayout

        init(_ layout: CloudflareDatabaseStorageLayout) {
            self.layout = layout
        }
    }

    private typealias OpenContainer = @Sendable (
        DatabaseStorageTopology,
        any StorageMonotonicClock,
        any WallClock
    ) async throws -> DBContainer
    #else
    private struct StorageSelection: Sendable {
        init() {}
    }

    private typealias OpenContainer = @Sendable (
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
    public let indexConfigurations: [any IndexRuntimeConfiguration]
    public let itemStorage: ItemStorageConfiguration
    public let logging: DatabaseLoggingConfiguration
    public let metrics: DatabaseMetricsConfiguration

    #if CLOUDFLARE_DATABASE_MULTIPLE_BASES
    public let storageLayout: CloudflareDatabaseStorageLayout
    #endif
    private let openContainer: OpenContainer

    #if CLOUDFLARE_DATABASE_MULTIPLE_BASES
    /// Defines a container backed by a statically compiled schema.
    public init(
        partitionIdentity: StoragePartitionIdentity,
        storageLimits: CloudflareDurableObjectLimits = .default,
        storageLayout: CloudflareDatabaseStorageLayout,
        schema: Schema,
        runtimeConfiguration: DatabaseRuntimeConfiguration,
        security: SecurityConfiguration = .enabled(),
        databaseName: String? = nil,
        indexConfigurations: [any IndexRuntimeConfiguration] = [],
        itemStorage: ItemStorageConfiguration = .v1,
        logging: DatabaseLoggingConfiguration = .disabled,
        metrics: DatabaseMetricsConfiguration = .disabled
    ) {
        self.init(
            partitionIdentity: partitionIdentity,
            storageLimits: storageLimits,
            storageSelection: StorageSelection(storageLayout),
            schema: schema,
            security: security,
            databaseName: databaseName,
            indexConfigurations: indexConfigurations,
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
                        indexConfigurations: indexConfigurations,
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
        indexConfigurations: [any IndexRuntimeConfiguration] = [],
        itemStorage: ItemStorageConfiguration = .v1,
        logging: DatabaseLoggingConfiguration = .disabled,
        metrics: DatabaseMetricsConfiguration = .disabled
    ) {
        self.init(
            partitionIdentity: partitionIdentity,
            storageLimits: storageLimits,
            storageSelection: StorageSelection(storageLayout),
            schema: schema,
            security: security,
            databaseName: databaseName,
            indexConfigurations: indexConfigurations,
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
                        indexConfigurations: indexConfigurations,
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
        indexConfigurations: [any IndexRuntimeConfiguration] = [],
        itemStorage: ItemStorageConfiguration = .v1,
        logging: DatabaseLoggingConfiguration = .disabled,
        metrics: DatabaseMetricsConfiguration = .disabled
    ) {
        self.init(
            partitionIdentity: partitionIdentity,
            storageLimits: storageLimits,
            storageSelection: StorageSelection(),
            schema: schema,
            security: security,
            databaseName: databaseName,
            indexConfigurations: indexConfigurations,
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
                        indexConfigurations: indexConfigurations,
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
        indexConfigurations: [any IndexRuntimeConfiguration] = [],
        itemStorage: ItemStorageConfiguration = .v1,
        logging: DatabaseLoggingConfiguration = .disabled,
        metrics: DatabaseMetricsConfiguration = .disabled
    ) {
        self.init(
            partitionIdentity: partitionIdentity,
            storageLimits: storageLimits,
            storageSelection: StorageSelection(),
            schema: schema,
            security: security,
            databaseName: databaseName,
            indexConfigurations: indexConfigurations,
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
                        indexConfigurations: indexConfigurations,
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
        security: SecurityConfiguration,
        databaseName: String?,
        indexConfigurations: [any IndexRuntimeConfiguration],
        itemStorage: ItemStorageConfiguration,
        logging: DatabaseLoggingConfiguration,
        metrics: DatabaseMetricsConfiguration,
        openContainer: @escaping OpenContainer
    ) {
        self.partitionIdentity = partitionIdentity
        self.storageLimits = storageLimits
        #if CLOUDFLARE_DATABASE_MULTIPLE_BASES
        self.storageLayout = storageSelection.layout
        #else
        _ = storageSelection
        #endif
        self.declaredSchema = schema
        self.security = security
        self.databaseName = databaseName
        self.indexConfigurations = indexConfigurations
        self.itemStorage = itemStorage
        self.logging = logging
        self.metrics = metrics
        self.openContainer = openContainer
    }

    #if CLOUDFLARE_DATABASE_MULTIPLE_BASES
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
