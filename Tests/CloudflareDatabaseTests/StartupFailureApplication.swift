import CloudflareDatabase
@_spi(DatabaseExecution) import DatabaseEngine

struct StartupFailureApplication: CloudflareDatabaseApplication, Sendable {
    private let application: RuntimeVerificationApplication
    private let rejectsSessionCreation: Bool

    init(rejectsSessionCreation: Bool) throws {
        self.application = try RuntimeVerificationApplication()
        self.rejectsSessionCreation = rejectsSessionCreation
    }

    var configuration: CloudflareDatabaseConfiguration {
        get async throws {
            try await application.configuration
        }
    }

    func makeSession(
        for database: DBContainer
    ) async throws -> RuntimeVerificationSession {
        guard !rejectsSessionCreation else {
            throw RuntimeVerificationError.simulatedSessionCreationFailure
        }
        return try await application.makeSession(for: database)
    }
}
