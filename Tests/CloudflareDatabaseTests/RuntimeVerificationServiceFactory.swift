import DatabaseWireRuntime

final class RuntimeVerificationServiceFactory: DatabaseOperationServiceFactory {
    let jobService: AnyDatabaseJobService

    init(jobService: AnyDatabaseJobService) {
        self.jobService = jobService
    }

    func makeServices(
        context: DatabaseOperationServiceContext
    ) async throws -> DatabaseOperationServices {
        let unavailable = UnavailableCloudflareDatabaseServices()
        let statementExecutor = CanonicalDatabaseStatementMutationExecutor(
            runtimeLimits: context.runtimeLimits
        )
        #if GraphIndexes
        return DatabaseOperationServices(
            graphOperations: GraphOperationServices(
                statementExecutor: statementExecutor,
                algorithm: AnyDatabaseGraphAlgorithmService(unavailable),
                ontology: AnyDatabaseOntologyService(unavailable),
                shacl: AnyDatabaseSHACLService(unavailable)
            ),
            readCommandRegistry: try DatabaseReadCommandRegistry(commands: []),
            writeCommandRegistry: try DatabaseWriteCommandRegistry(commands: []),
            maintenanceService: AnyDatabaseMaintenanceService(unavailable),
            jobService: jobService
        )
        #else
        return DatabaseOperationServices(
            statementExecutor: AnyDatabaseStatementMutationExecutor(
                statementExecutor
            ),
            readCommandRegistry: try DatabaseReadCommandRegistry(commands: []),
            writeCommandRegistry: try DatabaseWriteCommandRegistry(commands: []),
            maintenanceService: AnyDatabaseMaintenanceService(unavailable),
            jobService: jobService
        )
        #endif
    }
}
