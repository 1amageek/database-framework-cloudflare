public enum CloudflareDatabaseClockError: Error, Sendable, Equatable {
    case capacityExceeded(maximum: Int)
}
