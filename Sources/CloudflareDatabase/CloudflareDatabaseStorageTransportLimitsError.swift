public enum CloudflareDatabaseStorageTransportLimitsError: Error, Sendable,
    Equatable {
    case nonPositive(field: String, value: Int)
    case exceedsProtocolMaximum(field: String, value: Int, maximum: Int)
}
