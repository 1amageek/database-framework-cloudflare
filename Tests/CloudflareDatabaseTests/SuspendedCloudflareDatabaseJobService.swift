import DatabaseServer
import DatabaseWire

actor SuspendedCloudflareDatabaseJobService: DatabaseJobService {
    nonisolated var jobOperations: [JobOperationIdentifier] { [] }

    private var hasStartedScheduledWork = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeScheduledWork: CheckedContinuation<Void, Never>?

    func waitUntilScheduledWorkStarts() async {
        guard !hasStartedScheduledWork else {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resume() {
        resumeScheduledWork?.resume()
        resumeScheduledWork = nil
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
        hasStartedScheduledWork = true
        let startWaiters = self.startWaiters
        self.startWaiters.removeAll(keepingCapacity: false)
        for waiter in startWaiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            resumeScheduledWork = continuation
        }
    }
}
