/// Bounded resource policy for one persistent Cloudflare database runtime.
public struct CloudflareDatabaseRuntimeLimits: Sendable, Hashable {
    public static let maximumPayloadBytes = 16 * 1_024 * 1_024
    public static let minimumErrorBytes = 256
    public static let maximumErrorBytes = 16 * 1_024
    public static let maximumPendingInvocations = 1_024

    public let maximumContextBytes: Int
    public let maximumRequestBytes: Int
    public let maximumResponseBytes: Int
    public let maximumErrorBytes: Int
    public let maximumPendingInvocations: Int

    public init(
        maximumContextBytes: Int,
        maximumRequestBytes: Int,
        maximumResponseBytes: Int,
        maximumErrorBytes: Int,
        maximumPendingInvocations: Int
    ) throws {
        try Self.validate(
            maximumContextBytes,
            field: "maximumContextBytes",
            maximum: Self.maximumPayloadBytes
        )
        try Self.validate(
            maximumRequestBytes,
            field: "maximumRequestBytes",
            maximum: Self.maximumPayloadBytes
        )
        try Self.validate(
            maximumResponseBytes,
            field: "maximumResponseBytes",
            maximum: Self.maximumPayloadBytes
        )
        try Self.validate(
            maximumErrorBytes,
            field: "maximumErrorBytes",
            minimum: Self.minimumErrorBytes,
            maximum: Self.maximumErrorBytes
        )
        try Self.validate(
            maximumPendingInvocations,
            field: "maximumPendingInvocations",
            maximum: Self.maximumPendingInvocations
        )
        self.maximumContextBytes = maximumContextBytes
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumResponseBytes = maximumResponseBytes
        self.maximumErrorBytes = maximumErrorBytes
        self.maximumPendingInvocations = maximumPendingInvocations
    }

    public static let `default` = CloudflareDatabaseRuntimeLimits(
        maximumContextBytes: 1 * 1_024 * 1_024,
        maximumRequestBytes: 4 * 1_024 * 1_024,
        maximumResponseBytes: 4 * 1_024 * 1_024,
        maximumErrorBytes: 4 * 1_024,
        maximumPendingInvocations: 64,
        validated: ()
    )

    package init(
        maximumContextBytes: Int,
        maximumRequestBytes: Int,
        maximumResponseBytes: Int,
        maximumErrorBytes: Int,
        maximumPendingInvocations: Int,
        validated: Void
    ) {
        _ = validated
        self.maximumContextBytes = maximumContextBytes
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
