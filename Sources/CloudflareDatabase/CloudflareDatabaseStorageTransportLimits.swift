/// Bounded frame policy for the StorageKit transport contract.
public struct CloudflareDatabaseStorageTransportLimits: Sendable, Hashable {
    public static let protocolMaximumFrameBytes = 16 * 1_024 * 1_024

    public let maximumRequestBytes: Int
    public let maximumResponseBytes: Int

    public init(
        maximumRequestBytes: Int,
        maximumResponseBytes: Int
    ) throws {
        try Self.validate(maximumRequestBytes, field: "maximumRequestBytes")
        try Self.validate(maximumResponseBytes, field: "maximumResponseBytes")
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumResponseBytes = maximumResponseBytes
    }

    public static let `default` = CloudflareDatabaseStorageTransportLimits(
        maximumRequestBytes: protocolMaximumFrameBytes,
        maximumResponseBytes: protocolMaximumFrameBytes,
        validated: ()
    )

    package init(
        maximumRequestBytes: Int,
        maximumResponseBytes: Int,
        validated: Void
    ) {
        _ = validated
        self.maximumRequestBytes = maximumRequestBytes
        self.maximumResponseBytes = maximumResponseBytes
    }

    package static func validate(
        _ value: Int,
        field: String
    ) throws {
        guard value > 0 else {
            throw CloudflareDatabaseStorageTransportLimitsError.nonPositive(
                field: field,
                value: value
            )
        }
        guard value <= protocolMaximumFrameBytes else {
            throw CloudflareDatabaseStorageTransportLimitsError
                .exceedsProtocolMaximum(
                    field: field,
                    value: value,
                    maximum: protocolMaximumFrameBytes
                )
        }
    }
}
