#if arch(wasm32)
import DatabaseTypes

@_extern(wasm, module: "database_alarm", name: "schedule")
private func requestDatabaseWakeUpNoLaterThan(
    _ secondsSinceUnixEpoch: Int64,
    _ nanoseconds: UInt32
)

/// Durable Object alarm scheduling service supplied by the Cloudflare host.
public struct CloudflareDatabaseAlarmScheduler: Sendable {
    public init() {}

    public func ensureWakeUp(
        noLaterThan timestamp: Timestamp
    ) throws(CloudflareDatabaseAlarmSchedulerError) {
        guard timestamp.nanoseconds < 1_000_000_000 else {
            throw .invalidTimestamp
        }
        requestDatabaseWakeUpNoLaterThan(
            timestamp.secondsSinceUnixEpoch,
            timestamp.nanoseconds
        )
    }
}
#endif
