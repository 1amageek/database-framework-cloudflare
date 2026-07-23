import DatabaseServer
import DatabaseValue

struct DiscardingDatabaseJobScheduler: DatabaseJobScheduler {
    func ensureWakeUp(
        noLaterThan timestamp: DatabaseTimestamp
    ) async throws {
        _ = timestamp
    }
}
