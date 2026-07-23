public enum CloudflareDatabaseRuntimeLimitsError: Error, Sendable, Equatable {
    case nonPositive(field: String, value: Int)
    case exceedsMaximum(field: String, value: Int, maximum: Int)
}
