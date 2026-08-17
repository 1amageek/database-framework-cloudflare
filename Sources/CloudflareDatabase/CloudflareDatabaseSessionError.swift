/// Failures produced by the application session boundary.
public enum CloudflareDatabaseSessionError: Error, Sendable, Equatable {
    case alarmHandlingUnavailable
}
