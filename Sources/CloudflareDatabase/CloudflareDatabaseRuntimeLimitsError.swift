public enum CloudflareDatabaseOperationLimitsError: Error, Sendable, Equatable {
    case belowMinimum(field: String, value: Int, minimum: Int)
    case exceedsMaximum(field: String, value: Int, maximum: Int)
}
