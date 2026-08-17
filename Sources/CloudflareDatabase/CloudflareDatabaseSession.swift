import DatabaseTypes

/// Application protocol running inside one persistent database container.
public protocol CloudflareDatabaseSession: Sendable {
    /// Handles one opaque application invocation.
    func respond(
        to invocation: CloudflareDatabaseInvocation
    ) async throws -> ByteString

    /// Handles one idempotent platform alarm delivery.
    func handleAlarm() async throws

    /// Releases application-owned resources before container shutdown.
    func shutdown() async
}

public extension CloudflareDatabaseSession {
    func handleAlarm() async throws {
        throw CloudflareDatabaseSessionError.alarmHandlingUnavailable
    }
}
