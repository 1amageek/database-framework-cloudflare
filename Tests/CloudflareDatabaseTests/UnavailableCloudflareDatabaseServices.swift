import DatabaseServer
import DatabaseWire

struct UnavailableCloudflareDatabaseServices:
    DatabaseGraphAlgorithmService,
    DatabaseOntologyService,
    DatabaseSHACLService,
    DatabaseMaintenanceService,
    DatabaseJobService {
    var jobOperations: [DatabaseJobOperationIdentifier] { [] }

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
    ) async throws -> DatabasePreparedOperationResponse<
        OntologyExecuteOperation
    > {
        _ = request
        _ = context
        throw RuntimeVerificationError.unexpectedServiceOperation
    }

    func execute(
        _ request: SHACLExecuteOperation.Request,
        context: DatabaseOperationContext
    ) async throws -> DatabasePreparedOperationResponse<
        SHACLExecuteOperation
    > {
        _ = request
        _ = context
        throw RuntimeVerificationError.unexpectedServiceOperation
    }

    func execute(
        _ request: MaintenanceExecuteOperation.Request,
        context: DatabaseOperationContext
    ) async throws -> DatabasePreparedOperationResponse<
        MaintenanceExecuteOperation
    > {
        _ = request
        _ = context
        throw RuntimeVerificationError.unexpectedServiceOperation
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
        throw RuntimeVerificationError.unexpectedServiceOperation
    }
}
