/// Bounded resource policy for one persistent database runtime.
public struct CloudflareDatabaseRuntimeLimits: Sendable, Hashable {
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

    public static let `default` = CloudflareDatabaseRuntimeLimits(
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
            throw CloudflareDatabaseRuntimeLimitsError.belowMinimum(
                field: field,
                value: value,
                minimum: minimum
            )
        }
        guard value <= maximum else {
            throw CloudflareDatabaseRuntimeLimitsError.exceedsMaximum(
                field: field,
                value: value,
                maximum: maximum
            )
        }
    }
}
