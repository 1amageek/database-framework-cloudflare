import CloudflareDatabase
@_spi(DatabaseExecution) import DatabaseEngine

actor AlarmHandlingRuntimeApplication: CloudflareDatabaseApplication {
    private let wrapped: RuntimeVerificationApplication
    private var session: AlarmHandlingRuntimeSession?

    init() throws {
        self.wrapped = try RuntimeVerificationApplication()
    }

    var configuration: CloudflareDatabaseConfiguration {
        get async throws {
            try await wrapped.configuration
        }
    }

    func makeSession(
        for database: DBContainer
    ) async throws -> AlarmHandlingRuntimeSession {
        let createdSession = AlarmHandlingRuntimeSession(
            wrapped: try await wrapped.makeSession(for: database)
        )
        session = createdSession
        return createdSession
    }

    func handledAlarmCount() async -> Int {
        guard let session else {
            return 0
        }
        return await session.handledAlarmCount
    }
}
