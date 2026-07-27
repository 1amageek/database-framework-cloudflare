import DatabaseServer
import DatabaseWire

actor RecordingCloudflareDatabaseJobService: DatabaseJobService {
    nonisolated var jobOperations: [JobOperationIdentifier] { [] }

    private var scheduledRunCount = 0

    func runCount() -> Int {
        scheduledRunCount
    }

    func start(
        _ request: JobStartOperation.Request,
        context: DatabaseOperationContext
    ) async throws -> DatabasePreparedOperationResponse<JobStartOperation> {
        _ = request
        _ = context
        throw RuntimeVerificationError.unexpectedServiceOperation
    }

    func status(
        _ request: JobStatusOperation.Request,
        context: DatabaseOperationContext
    ) async throws -> JobStatusOperation.Response {
        _ = request
        _ = context
        throw RuntimeVerificationError.unexpectedServiceOperation
    }

    func result(
        _ request: JobResultOperation.Request,
        context: DatabaseOperationContext
    ) async throws -> JobResultOperation.Response {
        _ = request
        _ = context
        throw RuntimeVerificationError.unexpectedServiceOperation
    }

    func cancel(
        _ request: JobCancelOperation.Request,
        context: DatabaseOperationContext
    ) async throws -> DatabasePreparedOperationResponse<JobCancelOperation> {
        _ = request
        _ = context
        throw RuntimeVerificationError.unexpectedServiceOperation
    }

    func runScheduledWork() async throws {
        scheduledRunCount += 1
    }
}
