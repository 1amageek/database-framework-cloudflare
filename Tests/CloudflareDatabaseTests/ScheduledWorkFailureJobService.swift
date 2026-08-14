import DatabaseServerRuntime
import DatabaseWire

struct ScheduledWorkFailureJobService: DatabaseJobService {
    enum Failure: Sendable {
        case corruptedState
        case privateDetail
    }

    nonisolated var jobOperations: [JobOperationIdentifier] { [] }

    let failure: Failure

    #if CLOUDFLARE_TEST_MULTIPLE_BASES
    func baseAdmission(
        for operation: JobOperationIdentifier
    ) throws -> DatabaseBaseAdmissionKind {
        _ = operation
        throw RuntimeVerificationError.unexpectedServiceOperation
    }
    #endif

    func start(
        _ request: JobStartOperation.Request,
        context: DatabaseOperationContext
    ) async throws -> JobStartExecutionResult {
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
    ) async throws -> JobCancellationExecutionResult {
        _ = request
        _ = context
        throw RuntimeVerificationError.unexpectedServiceOperation
    }

    func runScheduledWork() async throws {
        switch failure {
        case .corruptedState:
            throw PersistentJobScheduledWorkError.processingJob(
                DatabaseJobRuntimeError.corruptedState
            )
        case .privateDetail:
            throw PrivateScheduledWorkError()
        }
    }

    private struct PrivateScheduledWorkError: Error, CustomStringConvertible {
        var description: String { "private scheduled-work detail" }
    }
}
