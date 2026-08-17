/// Fixed statuses for private reactor ABI v3.
public enum CloudflareDatabaseCompletionStatus: UInt32, Sendable, Hashable {
    case success = 0
    case invalidCallID = 1
    case invalidPayload = 2
    case requestTooLarge = 3
    case responseTooLarge = 4
    case queueCapacityExceeded = 5
    case notStarted = 6
    case alreadyStarted = 7
    case startupInProgress = 8
    case startupFailed = 9
    case cancelled = 10
    case runtimeFailed = 11
    case contextTooLarge = 12
    case alarmFailed = 13
    case applicationFailed = 14
}
