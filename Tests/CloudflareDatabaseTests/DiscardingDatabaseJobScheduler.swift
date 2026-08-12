import DatabaseOperations
import DatabaseTypes

struct DiscardingDatabaseJobScheduler: DatabaseJobScheduler {
    func ensureWakeUp(
        noLaterThan timestamp: Timestamp
    ) async throws {
        _ = timestamp
    }
}
