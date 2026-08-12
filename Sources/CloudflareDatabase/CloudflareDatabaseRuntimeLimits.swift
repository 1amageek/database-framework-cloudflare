import DatabaseWire

/// Bounded resource policy for one persistent database runtime.
public struct CloudflareDatabaseOperationLimits: Sendable, Hashable {
    public static let protocolMaximumFrameBytes = 16 * 1_024 * 1_024
    public static let protocolMinimumErrorBytes = 256
    public static let protocolMaximumErrorBytes = 16 * 1_024
    public static let protocolMaximumPendingInvocations = 1_024

    public let maximumRequestBytes: Int
    public let maximumResponseBytes: Int
    public let maximumErrorBytes: Int
    public let maximumPendingInvocations: Int

    public init(
        maximumRequestBytes: Int,
        maximumResponseBytes: Int,
        maximumErrorBytes: Int,
        maximumPendingInvocations: Int
    ) throws {
        try Self.validate(
            maximumRequestBytes,
            field: "maximumRequestBytes",
            maximum: Self.protocolMaximumFrameBytes
        )
        try Self.validate(
            maximumResponseBytes,
            field: "maximumResponseBytes",
            maximum: Self.protocolMaximumFrameBytes
        )
        try Self.validate(
            maximumErrorBytes,
            field: "maximumErrorBytes",
            minimum: Self.protocolMinimumErrorBytes,
            maximum: Self.protocolMaximumErrorBytes
        )
        try Self.validate(
            maximumPendingInvocations,
            field: "maximumPendingInvocations",
            maximum: Self.protocolMaximumPendingInvocations
        )
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumResponseBytes = maximumResponseBytes
        self.maximumErrorBytes = maximumErrorBytes
        self.maximumPendingInvocations = maximumPendingInvocations
    }

    public static let `default` = CloudflareDatabaseOperationLimits(
        maximumRequestBytes: protocolMaximumFrameBytes,
        maximumResponseBytes: protocolMaximumFrameBytes,
        maximumErrorBytes: 4 * 1_024,
        maximumPendingInvocations: 64,
        validated: ()
    )

    package init(
        maximumRequestBytes: Int,
        maximumResponseBytes: Int,
        maximumErrorBytes: Int,
        maximumPendingInvocations: Int,
        validated: Void
    ) {
        _ = validated
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumResponseBytes = maximumResponseBytes
        self.maximumErrorBytes = maximumErrorBytes
        self.maximumPendingInvocations = maximumPendingInvocations
    }

    package static func validate(
        _ value: Int,
        field: String,
        minimum: Int = 1,
        maximum: Int
    ) throws {
        guard value >= minimum else {
            throw CloudflareDatabaseOperationLimitsError.belowMinimum(
                field: field,
                value: value,
                minimum: minimum
            )
        }
        guard value <= maximum else {
            throw CloudflareDatabaseOperationLimitsError.exceedsMaximum(
                field: field,
                value: value,
                maximum: maximum
            )
        }
    }

    package func requestWireLimits() throws -> DatabaseWireLimits {
        try wireLimits(maximumFrameBytes: maximumRequestBytes)
    }

    package func responseWireLimits() throws -> DatabaseWireLimits {
        try wireLimits(maximumFrameBytes: maximumResponseBytes)
    }

    private func wireLimits(
        maximumFrameBytes: Int
    ) throws -> DatabaseWireLimits {
        let canonical = DatabaseWireLimits.default
        return try DatabaseWireLimits(
            maximumFrameBytes: maximumFrameBytes,
            maximumStringBytes: min(
                canonical.maximumStringBytes,
                maximumFrameBytes
            ),
            maximumByteStringBytes: min(
                canonical.maximumByteStringBytes,
                maximumFrameBytes
            ),
            maximumCollectionCount: canonical.maximumCollectionCount,
            maximumNestingDepth: canonical.maximumNestingDepth,
            maximumObjectCount: canonical.maximumObjectCount
        )
    }
}
