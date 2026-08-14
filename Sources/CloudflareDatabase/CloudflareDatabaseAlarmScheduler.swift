#if arch(wasm32)
import DatabaseServerRuntime
import DatabaseTypes

@_extern(wasm, module: "database_alarm", name: "schedule")
private func requestDatabaseWakeUpNoLaterThan(
    _ secondsSinceUnixEpoch: Int64,
    _ nanoseconds: UInt32
)

/// Durable Object alarm scheduler provided by the runtime owner.
public struct CloudflareDatabaseAlarmScheduler: DatabaseJobScheduler {
    public init() {}

    public func ensureWakeUp(
        noLaterThan timestamp: Timestamp
    ) async throws {
        guard timestamp.nanoseconds < 1_000_000_000 else {
            throw CloudflareDatabaseAlarmSchedulerError.invalidTimestamp
        }
        requestDatabaseWakeUpNoLaterThan(
            timestamp.secondsSinceUnixEpoch,
            timestamp.nanoseconds
        )
    }
}
#endif
