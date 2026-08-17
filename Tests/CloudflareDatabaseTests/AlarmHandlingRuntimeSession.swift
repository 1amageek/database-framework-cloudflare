import CloudflareDatabase
import DatabaseTypes

actor AlarmHandlingRuntimeSession: CloudflareDatabaseSession {
    private let wrapped: RuntimeVerificationSession
    private(set) var handledAlarmCount = 0

    init(wrapped: RuntimeVerificationSession) {
        self.wrapped = wrapped
    }

    func respond(
        to invocation: CloudflareDatabaseInvocation
    ) async throws -> ByteString {
        try await wrapped.respond(to: invocation)
    }

    func handleAlarm() async throws {
        handledAlarmCount += 1
    }

    func shutdown() async {
        await wrapped.shutdown()
    }
}
