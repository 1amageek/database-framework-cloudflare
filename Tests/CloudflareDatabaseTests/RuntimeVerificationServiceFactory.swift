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
        return DatabaseServerServices(
            statementExecutor: AnyDatabaseStatementMutationExecutor(
                CanonicalDatabaseStatementMutationExecutor(
                    runtimeLimits: context.runtimeLimits
                )
            ),
            graphAlgorithmService: AnyDatabaseGraphAlgorithmService(unavailable),
            ontologyService: AnyDatabaseOntologyService(unavailable),
            shaclService: AnyDatabaseSHACLService(unavailable),
            readCommandRegistry: try DatabaseReadCommandRegistry(commands: []),
            writeCommandRegistry: try DatabaseWriteCommandRegistry(commands: []),
            maintenanceService: AnyDatabaseMaintenanceService(unavailable),
            jobService: jobService
        )
    }
}
