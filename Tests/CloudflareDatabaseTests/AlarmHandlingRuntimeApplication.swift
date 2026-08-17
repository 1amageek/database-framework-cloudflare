import CloudflareDatabase
@_spi(DatabaseExecution) import DatabaseEngine

actor AlarmHandlingRuntimeApplication: CloudflareDatabaseApplication {
    private let wrapped: RuntimeVerificationApplication
    private var session: AlarmHandlingRuntimeSession?

    init() throws {
        self.wrapped = try RuntimeVerificationApplication()
    }

    func makeDefinition() async throws -> CloudflareDatabaseDefinition {
        try await wrapped.makeDefinition()
    }

    func makeSession(
        for container: DBContainer
    ) async throws -> AlarmHandlingRuntimeSession {
        let createdSession = AlarmHandlingRuntimeSession(
            wrapped: try await wrapped.makeSession(for: container)
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
