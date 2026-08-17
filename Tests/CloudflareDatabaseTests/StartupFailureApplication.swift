import CloudflareDatabase
@_spi(DatabaseExecution) import DatabaseEngine

struct StartupFailureApplication: CloudflareDatabaseApplication, Sendable {
    private let application: RuntimeVerificationApplication
    private let rejectsSessionCreation: Bool

    init(rejectsSessionCreation: Bool) throws {
        self.application = try RuntimeVerificationApplication()
        self.rejectsSessionCreation = rejectsSessionCreation
    }

    func makeDefinition() async throws -> CloudflareDatabaseDefinition {
        try await application.makeDefinition()
    }

    func makeSession(
        for container: DBContainer
    ) async throws -> RuntimeVerificationSession {
        guard !rejectsSessionCreation else {
            throw RuntimeVerificationError.simulatedSessionCreationFailure
        }
        return try await application.makeSession(for: container)
    }
}
