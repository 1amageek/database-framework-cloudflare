import DatabaseServer
import DatabaseWire

struct UnavailableCloudflareDatabaseServices:
    DatabaseGraphAlgorithmService,
    DatabaseOntologyService,
    DatabaseSHACLService,
    DatabaseMaintenanceService,
    DatabaseJobService {
    var jobOperations: [JobOperationIdentifier] { [] }

    func execute(
        _ request: GraphAlgorithmOperation.Request,
        context: DatabaseOperationContext
    ) async throws -> GraphAlgorithmOperation.Response {
        _ = request
        _ = context
        throw RuntimeVerificationError.unexpectedServiceOperation
    }

    func execute(
        _ request: OntologyExecuteOperation.Request,
        context: DatabaseOperationContext
    ) async throws -> OntologyExecutionResult {
        _ = request
        _ = context
        throw RuntimeVerificationError.unexpectedServiceOperation
    }

    func execute(
        _ request: SHACLExecuteOperation.Request,
        context: DatabaseOperationContext
    ) async throws -> SHACLExecutionResult {
        _ = request
        _ = context
        throw RuntimeVerificationError.unexpectedServiceOperation
    }

    func execute(
        _ request: MaintenanceExecuteOperation.Request,
        context: DatabaseOperationContext
    ) async throws -> MaintenanceExecutionResult {
        _ = request
        _ = context
        throw RuntimeVerificationError.unexpectedServiceOperation
    }

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
        throw RuntimeVerificationError.unexpectedServiceOperation
    }
}
