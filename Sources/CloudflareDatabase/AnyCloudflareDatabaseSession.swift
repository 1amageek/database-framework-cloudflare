import DatabaseTypes

/// Type-erased owner of one application protocol session.
public struct AnyCloudflareDatabaseSession: CloudflareDatabaseSession, Sendable {
    private let respondToInvocation: @Sendable (
        CloudflareDatabaseInvocation
    ) async throws -> ByteString
    private let shutDown: @Sendable () async -> Void
    private let processAlarm: @Sendable () async throws -> Void

    public init<Session: CloudflareDatabaseSession>(_ session: Session) {
        self.respondToInvocation = { invocation in
            try await session.respond(to: invocation)
        }
        self.shutDown = {
            await session.shutdown()
        }
        self.processAlarm = {
            try await session.handleAlarm()
        }
    }

    public func respond(
        to invocation: CloudflareDatabaseInvocation
    ) async throws -> ByteString {
        try await respondToInvocation(invocation)
    }

    public func handleAlarm() async throws {
        try await processAlarm()
    }

    public func shutdown() async {
        await shutDown()
    }
}
