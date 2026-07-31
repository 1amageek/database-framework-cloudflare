import DatabaseServer

final class RuntimeVerificationServiceFactory: DatabaseServerServiceFactory {
    let jobService: AnyDatabaseJobService

    init(jobService: AnyDatabaseJobService) {
        self.jobService = jobService
    }

    func makeServices(
        context: DatabaseServerServiceContext
    ) async throws -> DatabaseServerServices {
        let unavailable = UnavailableCloudflareDatabaseServices()
        let statementExecutor = CanonicalDatabaseStatementMutationExecutor(
            runtimeLimits: context.runtimeLimits
        )
        #if GraphIndexes
        return DatabaseServerServices(
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
        return DatabaseServerServices(
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
